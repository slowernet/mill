require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Real git in a tmpdir; no network, no claude.
	class TestSupervisor < Mill::TestCase
		def setup
			super
			@root = Dir.mktmpdir('mill-supervisor')
			@home = File.join(@root, 'home')
			FileUtils.mkdir_p(@home)
			Mill.instance_variable_set(:@home, @home)
			@clone = File.join(@root, 'rep')
			Mill::Git.clone_init(@clone)
			File.write(File.join(@clone, 'README.md'), "# rep\n")
			Mill::Git.run!(@clone, 'add', '-A')
			Mill::Git.run!(@clone, 'commit', '-m', 'first')
			Mill::Git.run!(@clone, 'branch', '1-a-feature')
			@repo_id = create_repo(owner: 'slowernet', name: 'rep', local_path: @clone,
				base_branch: 'main', prepared_at: Mill.now)
		end

		def teardown
			FileUtils.remove_entry(@root, true)
			Mill.instance_variable_set(:@home, nil)
			ENV.delete('MILL_CONCURRENCY')
			super
		end

		def repo_row = db[:repos].where(id: @repo_id).first

		def supervisor(comments: [], git: Mill::Git)
			gh = Mill::Github.new(runner: ->(args) { comments << args; '' })
			Mill::Supervisor.new(db: db, github: gh, git: git, board: nil)
		end

		def claim(sup, branch: '1-a-feature', number: 1)
			sup.claim(repo_row: repo_row, subject_kind: 'issue', subject_number: number,
				route: 'plan', branch: branch, spec_path: 'docs/spec.md', board_item_id: 'PVTI_1')
		end

		# A git double that behaves normally except for the one command named.
		def git_failing_at(command)
			Class.new do
				define_singleton_method(command) { |*| raise Mill::Git::Error, 'no space left on device' }
				def self.method_missing(name, *args, &blk) = Mill::Git.send(name, *args, &blk)
				def self.respond_to_missing?(*) = true
			end
		end

		def test_claiming_inserts_a_running_run_and_a_worktree
			run_id = claim(supervisor)
			row = db[:runs].where(id: run_id).first

			assert_equal 'running', row[:status]
			assert_equal '1-a-feature', row[:branch]
			assert_equal 'PVTI_1', row[:board_item_id]
			assert_equal 'docs/spec.md', row[:spec_path]
			assert_path_exists File.join(row[:worktree_path], 'README.md')
		end

		def test_the_cap_counts_running_rows_only
			ENV['MILL_CONCURRENCY'] = '1'
			sup = supervisor
			claim(sup)

			assert_predicate sup, :at_cap?

			db[:runs].update(status: 'blocked')

			refute_predicate sup, :at_cap?
		end

		def test_the_cap_falls_back_rather_than_reading_a_typo_as_zero
			ENV['MILL_CONCURRENCY'] = 'lots'

			assert_equal Mill::Supervisor::DEFAULT_CAP, supervisor.cap
		end

		# A blocked run holds its branch by design, so the item behind it waits.
		def test_a_branch_another_live_run_holds_is_skipped
			sup = supervisor
			claim(sup)

			assert_equal :held, claim(sup, number: 2)
		end

		def test_a_branch_a_finished_run_held_is_free_again
			sup = supervisor
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'done')
			Mill::Git.worktree_remove(@clone, db[:runs].where(id: run_id).get(:worktree_path))

			assert_operator claim(sup, number: 2), :>, 0
		end

		# Silence here means mill appears to ignore you forever.
		def test_the_skip_is_announced_once
			calls = []
			sup = supervisor(comments: calls)
			claim(sup)
			claim(sup, number: 2)
			claim(sup, number: 2)
			comments = calls.select { |args| args.first(2) == %w[issue comment] }

			assert_equal 1, comments.length
			assert_match(/1-a-feature/, comments.first.join(' '))
		end

		# git worktree add refuses a branch checked out anywhere, including the
		# clone's own HEAD, and the prescribed workflow leaves it that way.
		def test_a_branch_checked_out_in_your_clone_blocks_the_item
			Mill::Git.run!(@clone, 'switch', '1-a-feature')

			result = claim(supervisor)

			assert_kind_of Mill::Supervisor::Blocked, result
			assert_equal :branch_checked_out, result.problem
			assert_match(/#{Regexp.escape(@clone)}/, result.questions.first)
			assert_match(/1-a-feature/, result.questions.first)
		end

		def test_mill_never_forces_a_worktree_onto_a_checked_out_branch
			Mill::Git.run!(@clone, 'switch', '1-a-feature')
			claim(supervisor)

			assert_equal 0, db[:runs].count
		end

		# A SIGKILL during git commit leaves a lock git never cleans, and the next
		# launch fails instantly on it.
		def test_a_stale_lock_is_cleared_before_claiming
			lock = File.join(@clone, '.git', 'index.lock')
			File.write(lock, '')
			FileUtils.touch(lock, mtime: Time.now - 3600)

			claim(supervisor)

			refute_path_exists lock
		end

		# A lock that is minutes old may belong to a command running right now —
		# one of mill's own stages, or you in a terminal on the same clone.
		def test_a_fresh_lock_is_left_alone
			lock = File.join(@clone, '.git', 'index.lock')
			File.write(lock, '')

			claim(supervisor)

			assert_path_exists lock
		end

		# Scoping this to mill/* would miss the plan route entirely, which adopts
		# the branch gh issue develop made and keeps its name.
		def test_the_branchs_own_ref_lock_is_cleared_whatever_it_is_named
			lock = File.join(@clone, '.git', 'refs', 'heads', '1-a-feature.lock')
			FileUtils.mkdir_p(File.dirname(lock))
			File.write(lock, '')
			FileUtils.touch(lock, mtime: Time.now - 3600)

			claim(supervisor)

			refute_path_exists lock
		end

		# git worktree add refuses a branch whose admin entry survives even after
		# its directory is gone.
		def test_a_stale_worktree_entry_is_pruned
			dead = File.join(@root, 'dead')
			Mill::Git.run!(@clone, 'worktree', 'add', dead, '1-a-feature')
			FileUtils.remove_entry(dead, true)

			assert_operator claim(supervisor), :>, 0
		end

		# A row inserted before a worktree that never appears is a running run with
		# no process, which nothing reaps and which holds a slot forever. Two of
		# those stop mill claiming anything again, with every check still green.
		def test_a_worktree_that_cannot_be_made_leaves_no_run_behind
			sup = supervisor(git: git_failing_at(:worktree_add))

			assert_raises(Mill::Git::Error) { claim(sup) }
			assert_equal 0, db[:runs].count
		end

		# Not knowing whether a branch is checked out is not the same as it not
		# being checked out, and claiming on that guess is how two live checkouts
		# of one branch happen.
		def test_a_git_failure_is_never_read_as_a_free_branch
			sup = supervisor(git: git_failing_at(:checked_out_branches))

			assert_raises(Mill::Git::Error) { claim(sup) }
			assert_equal 0, db[:runs].count
		end

		# --- running, announcing, tearing down -----------------------------------

		def state(status, questions: [], stage: 'plan')
			{ stage: stage, status: status, reason: 'scripted', questions: questions }
		end

		def bodies(calls)
			calls.select { |args| args.first(2) == %w[issue comment] }.map { |args| args.join(' ') }
		end

		def test_a_finished_run_is_torn_down_and_its_branch_freed
			sup = supervisor
			run_id = claim(sup)
			worktree = db[:runs].where(id: run_id).get(:worktree_path)
			db[:runs].where(id: run_id).update(status: 'done', pr_number: 7)

			sup.finish(run_id, state(:done))

			refute_path_exists worktree
			refute_includes Mill::Git.checked_out_branches(@clone), '1-a-feature'
		end

		# mill needs the worktree to resume, and a timer should not destroy the
		# thing you have to answer a question about.
		def test_a_blocked_run_keeps_its_worktree
			sup = supervisor
			run_id = claim(sup)
			worktree = db[:runs].where(id: run_id).get(:worktree_path)
			db[:runs].where(id: run_id).update(status: 'blocked')

			sup.finish(run_id, state(:blocked, questions: ['Which spec is authoritative?']))

			assert_path_exists worktree
		end

		# The questions are the only channel that reaches a person once you have
		# walked away.
		def test_a_blocked_run_posts_its_questions
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'blocked')

			sup.finish(run_id, state(:blocked, questions: ['Which spec is authoritative?']))

			assert_match(/Which spec is authoritative\?/, bodies(calls).last)
		end

		def test_a_blocked_run_with_no_questions_still_says_why
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'blocked')

			sup.finish(run_id, state(:blocked))

			assert_match(/Blocked at `plan`/, bodies(calls).last)
		end

		def test_a_finished_run_names_its_pull_request
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'done', pr_number: 7)

			sup.finish(run_id, state(:done))

			assert_match(/#7/, bodies(calls).last)
		end

		def test_a_failed_run_says_so
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'failed')

			sup.finish(run_id, state(:failed))

			assert_match(/failed/i, bodies(calls).last)
		end

		def test_a_run_thread_is_tracked_while_it_walks
			sup = supervisor
			run_id = claim(sup)
			gate = Queue.new
			thread = sup.start(run_id, walker: ->(_id) { gate.pop; state(:done) })

			assert sup.running?(run_id)

			gate << :go
			thread.join

			refute sup.running?(run_id)
		end

		# A dead runner thread must not leave a run marked running forever, which
		# is a slot held against the cap that nothing else releases.
		def test_a_thread_that_dies_leaves_the_run_failed_rather_than_running
			sup = supervisor
			run_id = claim(sup)
			sup.start(run_id, walker: ->(_id) { raise 'boom' }).join

			assert_equal 'failed', db[:runs].where(id: run_id).get(:status)
			refute sup.running?(run_id)
		end
	end
end
