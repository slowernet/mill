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

		# One thread per run: a route walk takes tens of minutes, and a supervisor
		# that walked it would claim one item and then stop reconciling.
		def start(run_id, walker: nil, answers: [])
			resumed(run_id)
			walk = walker || ->(id) { walk(id, answers: answers) }
			@threads[run_id] = Thread.new do
				finish(run_id, walk.call(run_id))
			rescue StandardError => e
				# A dead runner thread must not leave a run marked running forever.
				# That is a concurrency slot nothing else releases.
				warn "run #{run_id} thread died: #{e.class}: #{e.message}"
				@db[:runs].where(id: run_id).update(status: 'failed', finished_at: Mill.now)
				finish(run_id, { stage: nil, status: :failed, reason: e.message, questions: [] })
			ensure
				@threads.delete(run_id)
			end
		end

		def running?(run_id) = @threads[run_id]&.alive? || false

		def finish(run_id, state)
			row = @db[:runs].where(id: run_id).first or return

			announce(row, state)
			@board&.want(run_id, row[:status])
			teardown(run_id)
		end

		# A blocked run keeps its worktree indefinitely: mill needs it to resume,
		# and a timer should not destroy the thing you have to answer a question
		# about.
		def teardown(run_id)
			row = @db[:runs].where(id: run_id).first or return
			return unless %w[done failed killed].include?(row[:status])

			repo = @db[:repos].where(id: row[:repo_id]).first
			path = row[:worktree_path]
			return if path.nil? || !Dir.exist?(path)

			@git.worktree_remove(repo[:local_path], path)
			@git.run(repo[:local_path], 'worktree', 'prune')
		rescue Mill::Git::Error => e
			warn "run #{run_id} worktree not removed: #{e.message}"
		end

		# Every run marked running, checked against the live process table. Called
		# at boot and on a timer. At boot mill has no live threads, so every group
		# it finds is foreign by definition — which is the right answer: mill
		# restarted and the stage outlived it.
		#
		# Interrupting is only half the job. A run interrupted and not restarted
		# stays running with no thread forever, holds its slot against the cap, and
		# is skipped by the poller because its item has an active run. Two of those
		# stop the factory with nothing anywhere reporting a problem.
		def reap
			@db[:runs].where(status: 'running').select_map(:id).filter_map do |run_id|
				row = @db[:runs].where(id: run_id).first
				next if row.nil? || row[:status] != 'running'

				case identify(row)
				when :ours then next
				when :foreign
					Mill::Spawn.reap(row[:pgid], boot_at: row[:host_boot_at],
						started_at: row[:pid_started_at])
				end

				interrupt(row)
				restart(run_id)
				run_id
			end
		end

		# Three branches, in this order. Nothing is signalled on the strength of
		# the boot time alone: kern.boottime moves when NTP corrects the clock,
		# which it does routinely on waking, so the live process settles it.
		#
		# `:ours` means a thread is walking this run right now, not merely that no
		# process is recorded. pid and pgid are nil for the whole gap between two
		# stages, five times over on the plan route, so reading nil as "in hand"
		# strands any run mill was restarted during.
		def identify(row)
			return :ours if running?(row[:id])
			return :gone if row[:pid].nil? || row[:pid_started_at].nil?

			started = Mill::Clock.pid_started_at(row[:pid])
			return :gone if started.nil?
			return :gone if (started - row[:pid_started_at]).abs > 2

			@own_pgids.include?(row[:pgid]) ? :ours : :foreign
		end

		private

		# Re-enters the stage the run was in. Costs an attempt and no strike: the
		# machine lost the process, the stage did not fail. A run interrupt has
		# just blocked, because it hit the interruption cap, is waiting for a
		# person, and the next tick would otherwise start it again.
		# A run that has been answered is working again, and nothing else says so.
		# Left blocked it lies in three ways at once: the board keeps saying Blocked
		# for the whole rest of the route, the run does not count against the
		# concurrency cap, and `reap` queries running rows only — so if its stage
		# died, nothing could ever recover it.
		def resumed(run_id)
			row = @db[:runs].where(id: run_id).first
			return unless row && row[:status] == 'blocked'

			@db[:runs].where(id: run_id).update(status: 'running')
			@board&.want(run_id, 'running')
		end

		def restart(run_id)
			return if at_cap?
			return unless @db[:runs].where(id: run_id).get(:status) == 'running'

			start(run_id)
		end

		def interrupt(row)
			stage = row[:current_stage] or
				raise Mill::Error, "run #{row[:id]} is running with no current_stage"

			ledger = Mill::Ledger.new(@db, row[:id])
			ledger.charge(stage: stage, outcome: :interrupted)
			@db[:runs].where(id: row[:id]).update(pid: nil, pgid: nil, heartbeat_at: nil)
			return unless ledger.out_of_interruptions?(stage)

			@db[:runs].where(id: row[:id]).update(status: 'blocked')
			comment(@db[:repos].where(id: row[:repo_id]).first, row[:subject_number],
				"Blocked at `#{stage}`: this stage has been interrupted " \
				"#{Mill::Ledger::MAX_INTERRUPTIONS} times without finishing. Nothing was charged " \
				'against it — each interruption was mill losing the process, not the stage ' \
				'failing. Reply here to try again.')
			@board&.want(row[:id], 'blocked')
		end

		# Returns the runner's state — which stage stopped, why, and what it asked —
		# not the run row. `finish` announces from this, and the row carries none of
		# it: a row-shaped return posted `Blocked at ``: .` to the subject, which is
		# the only channel that reaches a person, saying nothing.
		def walk(run_id, answers: [])
			run = Mill::Run.adopt(run_id, answers: answers, db: @db)
			run.on_identity = ->(pgid) { @own_pgids << pgid }
			run.call
			run.runner.state
		end

		def announce(row, state)
			repo = @db[:repos].where(id: row[:repo_id]).first
			body = case row[:status]
			when 'blocked' then blocked_body(state)
			when 'done' then "Opened ##{row[:pr_number]}."
			else
				"This run #{row[:status]}: #{state[:reason]}. Nothing was merged and no further " \
					'work starts on it. Fix the cause and set Status back to `Ready`.'
			end
			comment(repo, row[:subject_number], body)
		end

		def blocked_body(state)
			questions = Array(state[:questions])
			return "Blocked at `#{state[:stage]}`: #{state[:reason]}." if questions.empty?

			["Blocked at `#{state[:stage]}`: #{state[:reason]}.", '',
			 'Answer in a reply and this run continues from where it stopped.', '',
			 *questions.map { |question| "- #{question}" }].join("\n")
		end

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
