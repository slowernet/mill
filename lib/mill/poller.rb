require 'json'

module Mill
	# Reconciles the board into runnable work. It asks one idempotent question —
	# which items are Ready with no active run — which needs no dedupe key and
	# heals itself when mill crashes mid-transition.
	#
	# The label design that preceded this consumed change *events*, and four bugs
	# came from that shape: a relabelled issue deduped permanently, an item that
	# was Ready and Running at once, nothing clearing Running when a run was
	# killed, and no label change reaching a terminal state. A single-select
	# cannot express any of them.
	class Poller
		# `supervisor` is required and is never built here. There must be exactly
		# one supervisor in the process: it is the only thing that knows which
		# process groups mill spawned and which runs have a live thread, and a
		# second instance believes the answer to both is "none". A reaper holding
		# that belief classifies every healthy stage mill just started as a foreign
		# process and kills it, about thirty seconds into every run.
		def initialize(supervisor:, db: Mill.db, github: nil, board: nil,
			preparer: Mill::Repo.method(:prepare), locator: nil)
			@db = db
			@github = github || Mill::Github.new
			@board = board || Mill::Board.new(db: db, github: @github)
			@supervisor = supervisor
			@preparer = preparer
			@locator = locator
		end

		def tick
			@board.redrive
			reconcile
			sweep
		end

		def reconcile
			return unless @board.configured?

			ready_items.each do |item|
				break if @supervisor.at_cap?

				start(item)
			end
		end

		def ready_items
			@board.items.select { |item| item[:status] == 'Ready' && !active?(item) }
		end

		# Comments are genuinely events, unlike board state, so these are consumed
		# rather than reconciled — which is why they need a cursor and a dedupe key.
		def sweep
			subjects_of_interest.group_by { |subject| subject[:repo_id] }.each do |repo_id, subjects|
				repo = @db[:repos].where(id: repo_id).first
				record(repo, subjects.flat_map { |subject| fetch(repo, subject) })
			end
		end

		# Bounded deliberately: subjects mill has a live run on, not every issue in
		# every repo the board touches. An unbounded sweep on an active repo would
		# leave tens of thousands of rows behind with nothing explaining them.
		def subjects_of_interest
			@db[:runs].where(status: %w[running blocked])
				.select_map(%i[repo_id subject_kind subject_number]).uniq
				.map { |repo_id, kind, number| { repo_id: repo_id, kind: kind, number: number } }
		end

		private

		def fetch(repo, subject)
			slug = "#{repo[:owner]}/#{repo[:name]}"
			@github.comments(slug, subject[:number], since: repo[:comments_cursor])
				.map { |c| c.merge(subject_kind: subject[:kind], subject_number: subject[:number]) }
		end

		# The cursor is advanced inside the same transaction as the inserts. A
		# fetch that raises partway therefore writes no cursor, and the comments it
		# never saw are picked up next tick rather than skipped forever.
		def record(repo, comments)
			usable = comments.select { |comment| trigger?(comment, repo) }
			latest = comments.filter_map { |comment| comment[:created_at] }.max

			@db.transaction do
				usable.each { |comment| insert_event(repo, comment) }
				@db[:repos].where(id: repo[:id]).update(comments_cursor: latest) if latest
			end
		end

		def trigger?(comment, repo)
			return false unless Mill::Github.trusted_author?(comment)
			return false if Mill::Github.own_comment?(comment[:body])

			cursor = repo[:comments_cursor]
			cursor.nil? || comment[:created_at].to_s > cursor
		end

		def insert_event(repo, comment)
			@db[:events].insert_conflict.insert(
				repo_id: repo[:id], kind: 'comment', gh_node_id: comment[:node_id].to_s,
				payload_json: comment.to_json, attempts: 0, state: 'pending', created_at: Mill.now
			)
		end

		# Both issues and PRs appear as items, and a PR-entry item is a subject in
		# its own right — a Dependabot PR has no issue, so questions need somewhere
		# to go.
		def subject_kind(item) = item.dig(:content, :type) == 'PullRequest' ? 'pr' : 'issue'

		def active?(item)
			repo = repo_row(item) or return false

			@db[:runs].where(repo_id: repo[:id], subject_kind: subject_kind(item),
				subject_number: item.dig(:content, :number), status: %w[running blocked]).any?
		end

		def repo_row(item)
			owner, name = split(item)
			return nil if name.nil?

			@db[:repos].where(owner: owner, name: name).first
		end

		def split(item) = item.dig(:content, :repository).to_s.split('/', 2)

		def start(item)
			owner, name = split(item)
			number = item.dig(:content, :number)
			return if name.nil? || number.nil?

			prepared = @preparer.call(db: @db, owner: owner, name: name)
			return block_item(owner, name, number, prepared) unless prepared.ok?

			repo = @db[:repos].where(owner: owner, name: name).first
			located = locate(repo, "#{owner}/#{name}", number)
			return no_spec(owner, name, number, located) unless located.found?

			claim(item, repo, number, located)
		end

		def claim(item, repo, number, located)
			result = @supervisor.claim(repo_row: repo, subject_kind: subject_kind(item),
				subject_number: number, route: 'plan', branch: located.branch,
				spec_path: located.path, board_item_id: item[:id])

			case result
			when :held then nil
			when Mill::Supervisor::Blocked
				block_item(repo[:owner], repo[:name], number, result)
			else
				@supervisor.start(result)
			end
		end

		def locate(repo, slug, number)
			return @locator.call(repo, slug, number) if @locator

			Mill::Spec.locate(github: @github, repo: slug, number: number,
				repo_path: repo[:local_path], base: repo[:base_branch], git: Mill::Git)
		end

		# :no_branch and :no_spec carry no questions, because there is nothing to
		# ask — the answer is a branch or a file, not a decision. Saying "mill
		# cannot start this" and then listing nothing reads as a bug in mill rather
		# than as a missing spec, so those two are told plainly instead.
		def no_spec(owner, name, number, located)
			return block_item(owner, name, number, located) if located.blocked?

			body = case located.problem
			when :no_branch
				'This item has no linked branch, so there is nothing for mill to adopt. Run ' \
					"`gh issue develop #{number}`, commit a spec on that branch under " \
					'`docs/superpowers/specs/`, and set Status back to `Ready`.'
			else
				"`#{located.branch}` adds no file under `docs/superpowers/specs/`, so mill has no " \
					'spec to plan from. Commit one on that branch and set Status back to `Ready`.'
			end
			comment_on(owner, name, number, body)
		end

		# Blocking an item that has no run yet: there is nothing to resume, so it
		# re-enters at the top of the graph when you set it Ready again.
		def block_item(owner, name, number, result)
			body = ["mill cannot start this yet (`#{result.problem}`).", '',
				*Array(result.questions).map { |question| "- #{question}" }, '',
				'Fix the cause and set Status back to `Ready`.'].join("\n")
			comment_on(owner, name, number, body)
		end

		def comment_on(owner, name, number, body)
			@github.comment("#{owner}/#{name}", number, body)
		rescue Mill::Github::Error => e
			warn "could not comment on #{owner}/#{name}##{number}: #{e.message}"
		end
	end
end
