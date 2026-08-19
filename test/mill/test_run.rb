require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# The by-hand entry point, against a real git repository in a tmpdir and a
	# fake github. Never runs claude: the launcher is injected.
	class TestRun < Mill::TestCase
		def setup
			super
			@home = Dir.mktmpdir('mill-run-home')
			ENV['MILL_HOME'] = @home
			Mill.instance_variable_set(:@home, nil)

			@clone = Dir.mktmpdir('mill-run-clone')
			git('init', '--initial-branch=main')
			git('config', 'user.email', 't@example.com')
			git('config', 'user.name', 'T')
			write('README.md', "# scratch\n")
			git('add', '-A')
			git('commit', '-m', 'first')
			git('switch', '-c', '42-add-widget')
			write('docs/superpowers/specs/2026-08-19-widget.md', "# widget spec\n")
			git('add', '-A')
			git('commit', '-m', 'spec')
			git('switch', 'main')
		end

		def teardown
			Mill.instance_variable_set(:@home, nil)
			ENV.delete('MILL_HOME')
			[@home, @clone].each { |d| FileUtils.remove_entry(d, true) }
			super
		end

		def git(*args) = Mill::Git.run!(@clone, *args)

		def write(path, body)
			full = File.join(@clone, path)
			FileUtils.mkdir_p(File.dirname(full))
			File.write(full, body)
		end

		def fake_github(branches: ['42-add-widget'], body: 'Track low-stock items')
			Class.new do
				define_method(:linked_branches) { |*| branches }
				define_method(:issue) { |*| { number: 42, body: body } }
			end.new
		end

		def run_for(claude: Mill::Claude, **rest)
			Mill::Run.new(repo: 'slowernet/mill-scratch', number: 42, clone: @clone, db: db,
				github: fake_github(**rest), claude: claude)
		end

		# Stands in for Mill::Claude so the default launcher can be exercised
		# without spawning anything.
		class FakeClaude
			def initialize(stage, **) = @stage = stage

			def run(_prompt, log_path:, **_rest) = Mill::TestRun.scripted_attempt(@stage, log_path)
		end

		def test_a_prepared_run_adopts_the_branch_and_gets_a_worktree
			run = run_for.prepare

			assert_predicate run, :prepared?
			assert_equal '42-add-widget', run.branch
			assert_equal 'docs/superpowers/specs/2026-08-19-widget.md', run.spec_path
			assert_path_exists File.join(run.worktree, 'docs/superpowers/specs/2026-08-19-widget.md')
			assert_equal run.worktree, db[:runs].where(id: run.run_id).get(:worktree_path)
		ensure
			run&.teardown
		end

		def test_the_repo_is_recorded_once_however_often_a_run_starts
			first = run_for.prepare
			first.teardown
			Mill::Git.run(@clone, 'worktree', 'prune')
			db[:runs].where(id: first.run_id).update(status: 'done')
			second = run_for.prepare

			assert_equal 1, db[:repos].count
			refute_equal first.run_id, second.run_id
		ensure
			second&.teardown
		end

		# The design session leaves the branch current in the clone, and
		# git worktree add refuses it. mill blocks rather than forcing it.
		def test_a_branch_checked_out_in_the_clone_stops_the_run_before_it_claims
			git('switch', '42-add-widget')
			run = run_for.prepare

			refute_predicate run, :prepared?
			assert_equal :branch_checked_out, run.problem
			refute_empty run.questions
			assert_equal 0, db[:runs].count, 'nothing may be claimed before the worktree is possible'
		end

		def test_an_issue_with_no_linked_branch_does_not_claim_anything
			run = run_for(branches: []).prepare

			refute_predicate run, :prepared?
			assert_equal :no_branch, run.problem
			assert_equal 0, db[:runs].count
		end

		def test_a_path_that_is_not_a_clone_is_named_rather_than_raised
			run = Mill::Run.new(repo: 'a/b', number: 1, clone: '/tmp/definitely-not-a-repo',
				db: db, github: fake_github).prepare

			refute_predicate run, :prepared?
			assert_equal :not_a_clone, run.problem
		end

		def test_a_repo_without_a_slash_is_refused_at_construction
			assert_raises(Mill::Error) do
				Mill::Run.new(repo: 'noslash', number: 1, clone: @clone, db: db, github: fake_github)
			end
		end

		# The whole point of the seam: a run walks end to end with no claude.
		def test_a_run_walks_the_route_with_an_injected_launcher
			run = run_for.prepare
			stages = []
			outcome = run.call(launcher: lambda { |stage:, prompt:, invocation:, session_id:|
				stages << stage
				scripted_attempt(stage)
			})

			assert_equal :done, outcome
			assert_equal Mill::Stages::ROUTES['plan'], stages
			assert_equal 6, run.attempts.length
		ensure
			run&.teardown
		end

		def test_calling_before_preparing_is_an_error_not_a_silent_no_op
			assert_raises(Mill::Error) { run_for.call(launcher: ->(**) {}) }
		end

		# `rake mill:run` announces each launch as it starts. The block wraps the
		# real launcher rather than replacing it, so watching a run cannot change
		# what it does — which is why it is a block and not a launcher argument.
		def test_the_default_launcher_announces_every_launch_before_running_it
			run = run_for(claude: FakeClaude).prepare
			seen = []
			run.call { |stage, invocation, resuming| seen << [stage, invocation, resuming] }

			assert_equal Mill::Stages::ROUTES['plan'], seen.map(&:first)
			assert_equal [1] * 6, seen.map { |s| s[1] }
			assert_equal [false] * 6, seen.map(&:last), 'a clean run never resumes'
		ensure
			run&.teardown
		end

		# The launcher writes one log per attempt, named by stage and invocation.
		def test_each_attempt_gets_its_own_log_path
			run = run_for(claude: FakeClaude).prepare
			run.call

			paths = run.attempts.map { |a| File.basename(a[:log_path].to_s) }

			assert_includes paths, 'triage-1.jsonl'
			assert_includes paths, 'review-code-1.jsonl', 'a stage name carries a colon; a path must not'
			assert_equal paths.length, paths.uniq.length
		ensure
			run&.teardown
		end

		def self.scripted_attempt(stage, log_path = '/dev/null')
			verdict = Object.new
			artifact = Mill::Stages[stage][:artifact] ? 'docs/superpowers/plans/p.md' : nil
			verdict.define_singleton_method(:valid?) { true }
			verdict.define_singleton_method(:status) { 'ok' }
			verdict.define_singleton_method(:rejects?) { false }
			verdict.define_singleton_method(:data) { { artifact: artifact, summary: 'done' } }
			stream = Object.new
			stream.define_singleton_method(:session_id) { 's' }
			stream.define_singleton_method(:tokens) { { tokens_in: 1, tokens_out: 2 } }
			stream.define_singleton_method(:model) { 'm' }
			result = Object.new
			result.define_singleton_method(:success?) { true }
			result.define_singleton_method(:log_path) { log_path }
			result.define_singleton_method(:stream) { stream }
			Mill::Claude::Attempt.new(stage: stage, invocation: 1, nonce: 'n',
				result: result, verdict: verdict)
		end

		def scripted_attempt(stage) = self.class.scripted_attempt(stage)
	end
end
