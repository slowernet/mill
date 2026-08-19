require 'fileutils'
require 'set'

module Mill
	# Claims work up to the cap, owns the worktree lifecycle, and reaps process
	# groups. Everything here is about the machine rather than the work: what a
	# stage decides is the runner's business, and what an item means is the
	# poller's.
	#
	# There is exactly one of these per process. It is the only object that knows
	# which process groups mill spawned and which runs have a live thread, so a
	# second instance answers "none" to both — and a reaper holding that belief
	# kills every healthy stage it finds.
	class Supervisor
		Blocked = Struct.new(:problem, :questions, keyword_init: true)

		DEFAULT_CAP = 2
		MAX_CAP = 8
		# A lock younger than this may belong to a command running right now — one
		# of mill's own stages, or you in a terminal on the same clone.
		STALE_LOCK_AFTER = 300

		attr_reader :own_pgids

		def initialize(db: Mill.db, github: nil, git: Mill::Git, board: nil)
			@db = db
			@github = github || Mill::Github.new
			@git = git
			@board = board
			@threads = {}
			@own_pgids = Set.new
			@announced = {}
		end

		# Not `.to_i`: MILL_CONCURRENCY=lots would become 0, at_cap? would be true
		# forever, and mill would claim nothing while every check stayed green.
		def cap = Mill.setting_int('MILL_CONCURRENCY', default: DEFAULT_CAP, min: 1, max: MAX_CAP)

		# Counts running rows only. A blocked run is not working, and there is no
		# queued status: a run is inserted as running in the act of claiming it.
		def at_cap? = @db[:runs].where(status: 'running').count >= cap

		def claim(repo_row:, subject_kind:, subject_number:, route:, branch:, spec_path:,
			board_item_id: nil)
			holder = live_holder(repo_row[:id], branch)
			return held(repo_row, subject_number, branch, holder) if holder

			clone = repo_row[:local_path]
			@git.run(clone, 'worktree', 'prune')
			clear_stale_locks(clone, branch)
			return checked_out_block(clone, branch) if checked_out?(clone, branch)

			# The row and the worktree go together. A row inserted before a worktree
			# that then fails to appear is a running run with no process and no
			# thread — nothing reaps it, because there is nothing to identify, and it
			# counts against the cap for as long as the database survives.
			run_id = nil
			begin
				@db.transaction do
					run_id = insert_run(repo_row, subject_kind, subject_number, route, branch,
						spec_path, board_item_id)
					attach_worktree(repo_row, run_id, branch)
				end
			rescue StandardError
				discard(repo_row, run_id)
				raise
			end

			@board&.want(run_id, 'running')
			run_id
		end

		private

		# Running or blocked: a blocked run keeps its worktree, and therefore its
		# branch, until it is answered or killed.
		def live_holder(repo_id, branch)
			@db[:runs].where(repo_id: repo_id, branch: branch, status: %w[running blocked]).first
		end

		# A blocked run holds its branch indefinitely by design, so an item waiting
		# behind one can wait forever. Said once, or you comment a fix request and
		# from your side mill simply ignored you.
		def held(repo_row, subject_number, branch, holder)
			key = [repo_row[:id], subject_number, branch]
			unless @announced[key]
				@announced[key] = true
				comment(repo_row, subject_number,
					"Waiting: run #{holder[:id]} still has `#{branch}` checked out (it is " \
					"#{holder[:status]}). This item starts as soon as that run finishes or is killed.")
			end
			:held
		end

		# No rescue. `git worktree list` failing means mill does not know whether
		# the branch is checked out, and answering "it is not" is a rescue that
		# turns a failure into a pass — which is how two live checkouts of one
		# branch happen.
		def checked_out?(clone, branch) = @git.checked_out_branches(clone).include?(branch)

		def checked_out_block(clone, branch)
			Blocked.new(problem: :branch_checked_out, questions: [
				"`#{branch}` is checked out in #{clone}. mill will not force a second working " \
				'copy of one branch, because two live checkouts can diverge the ref without ' \
				'either side noticing. Switch that clone to your base branch and reply here.'
			])
		end

		# A SIGKILL during git commit leaves an index or ref lock that git never
		# cleans, and the next launch fails instantly on it. The branch's own ref
		# lock is included whatever the branch is named — scoping this to mill/*
		# would miss the plan route entirely, which adopts the branch gh made.
		def clear_stale_locks(clone, branch)
			dir = @git.run(clone, 'rev-parse', '--git-common-dir')
			return unless dir.ok

			common = File.expand_path(dir.out.strip, clone)
			(Dir[File.join(common, '*.lock')] +
				Dir[File.join(common, 'worktrees', '*', '*.lock')] +
				[File.join(common, 'refs', 'heads', "#{branch}.lock")]).uniq.each do |lock|
					delete_if_stale(lock)
				end
		end

		def delete_if_stale(lock)
			return unless File.file?(lock)
			return if Mill.now - File.stat(lock).mtime.utc.to_i < STALE_LOCK_AFTER

			File.delete(lock)
		rescue SystemCallError
			nil
		end

		def insert_run(repo_row, subject_kind, subject_number, route, branch, spec_path, item_id)
			@db[:runs].insert(
				repo_id: repo_row[:id], subject_kind: subject_kind, subject_number: subject_number,
				route: route, branch: branch, spec_path: spec_path, status: 'running',
				board_item_id: item_id, created_at: Mill.now
			)
		end

		def attach_worktree(repo_row, run_id, branch)
			path = worktree_path(repo_row, run_id)
			@git.worktree_add(repo_row[:local_path], path, branch)
			@db[:runs].where(id: run_id).update(worktree_path: path)
			path
		end

		def worktree_path(repo_row, run_id)
			File.join(Mill.home, 'worktrees', "#{repo_row[:owner]}-#{repo_row[:name]}", run_id.to_s)
		end

		# The transaction rolls the row back; a worktree is not transactional, so a
		# directory that did appear before the failure has to go by hand or the next
		# claim on this branch trips over it.
		def discard(repo_row, run_id)
			return if run_id.nil?

			path = worktree_path(repo_row, run_id)
			@git.worktree_remove(repo_row[:local_path], path) if Dir.exist?(path)
			@git.run(repo_row[:local_path], 'worktree', 'prune')
		rescue Mill::Git::Error
			nil
		end

		def comment(repo_row, number, body)
			@github.comment("#{repo_row[:owner]}/#{repo_row[:name]}", number, body)
		rescue Mill::Github::Error
			nil
		end
	end
end
