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

		MAX_EVENT_ATTEMPTS = 3

		def tick
			@board.redrive
			reconcile
			sweep
			dispatch
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

		# Board Status decides what a comment is. While an item is Blocked, every
		# comment on it is an answer and none of them starts a run — otherwise your
		# answer tries to start a second run, the uniqueness index refuses it, the
		# event retries until it dies, and the blocked run waits for an answer that
		# already arrived.
		#
		# The cap binds here too: a blocked run is not counted as running until its
		# own thread says so, so ten answers at once would start ten route walks.
		def dispatch
			@db[:events].where(kind: 'comment', state: 'pending').order(:id).each do |event|
				break if @supervisor.at_cap?

				handle(event)
			end
		end

		private

		# Marked processed, committed, and only then is the thread spawned — never
		# inside the same transaction as it.
		#
		# A thread started inside an open transaction writes to the same SQLite
		# file from another connection while this one holds the write lock, so
		# either the thread or the commit fails. If the commit is what fails, the
		# event rolls back to pending while the thread it already spawned keeps
		# running, and the next dispatch starts a second walker on the same run.
		#
		# Marking first would drop the answer if `start` then failed, which is what
		# the design's same-transaction rule exists to prevent. fail_event is the
		# compensation: it puts the event back to pending, so a failed start is
		# retried rather than lost. `running?` is what stops a retry becoming a
		# second walker.
		def handle(event)
			payload = JSON.parse(event[:payload_json].to_s, symbolize_names: true)
			run = blocked_run_for(event[:repo_id], payload)

			return no_route(event) if run.nil?
			return if @supervisor.running?(run[:id])

			finish_event(event, 'processed')
			@supervisor.start(run[:id], answers: [payload[:body].to_s])
		rescue StandardError => e
			fail_event(event, e)
		end

		def blocked_run_for(repo_id, payload)
			@db[:runs].where(repo_id: repo_id, subject_kind: payload[:subject_kind].to_s,
				subject_number: payload[:subject_number], status: 'blocked').first
		end

		# Only two of the five triggers have a route: the `mill:` marker, review
		# comments and red checks all need the iterate route, which does not exist.
		# Recorded and logged rather than dropped, so Plan 5 can see what it missed.
		def no_route(event)
			warn "no route for comment event #{event[:gh_node_id]}"
			finish_event(event, 'no_route')
		end

		def finish_event(event, state)
			@db[:events].where(id: event[:id]).update(state: state, processed_at: Mill.now)
		end

		def fail_event(event, error)
			attempts = event[:attempts].to_i + 1
			dead = attempts >= MAX_EVENT_ATTEMPTS
			@db[:events].where(id: event[:id]).update(
				attempts: attempts, state: dead ? 'dead' : 'pending',
				last_error: "#{error.class}: #{error.message}"[0, 300],
				processed_at: dead ? Mill.now : nil
			)
		end

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
