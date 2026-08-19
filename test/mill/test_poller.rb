require 'test_helper'

module Mill
	# Fixture-backed. The supervisor is a stub: claiming is Task 6's business and
	# is tested there against real git.
	class TestPoller < Mill::TestCase
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'gh')

		def fixture(name) = File.read(File.join(FIXTURES, "#{name}.json"))

		# Records what it was asked to claim and answers with an incrementing id.
		class FakeSupervisor
			attr_reader :claimed, :started, :answers

			def initialize(answer: nil, capped: false)
				@claimed = []
				@started = []
				@answers = {}
				@answer = answer
				@capped = capped
				@next = 100
			end

			def at_cap? = @capped

			def running?(_run_id) = false

			def claim(**args)
				@claimed << args
				return @answer if @answer

				@next += 1
			end

			def start(run_id, **kwargs)
				@started << run_id
				@answers[run_id] = kwargs[:answers]
			end
		end

		def located(branch: 'x', path: 'docs/s.md', problem: nil)
			Mill::Spec::Located.new(branch: branch, path: path, problem: problem)
		end

		def poller(supervisor: FakeSupervisor.new, locator: nil, preparer: nil, calls: [])
			gh = Mill::Github.new(runner: lambda { |args|
				calls << args
				args[1] == 'item-list' ? fixture('board_ready') : ''
			})
			board = Mill::Board.new(db: db, github: gh, project: 3, owner: 'slowernet')
			Mill::Poller.new(db: db, github: gh, board: board, supervisor: supervisor,
				locator: locator || ->(*) { located },
				preparer: preparer || ->(**) { Mill::Repo::Result.new(path: '/tmp/rep') })
		end

		def prepared_repo
			create_repo(owner: 'slowernet', name: 'rep', local_path: '/tmp/rep',
				base_branch: 'main', prepared_at: Mill.now)
		end

		def bodies(calls)
			calls.select { |args| args.first(2) == %w[issue comment] }.map { |args| args.join(' ') }
		end

		def test_only_ready_items_are_claimed
			prepared_repo
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [1, 4], sup.claimed.map { |c| c[:subject_number] }.sort
		end

		def test_an_item_with_an_active_run_is_left_alone
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'running')
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [4], sup.claimed.map { |c| c[:subject_number] }
		end

		# A blocked run still guards its subject: resume is comment-triggered, so a
		# second run would take the branch and the answer would find nothing.
		def test_a_blocked_run_still_guards_its_subject
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [4], sup.claimed.map { |c| c[:subject_number] }
		end

		def test_a_finished_run_does_not_guard_its_subject
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'done')
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_includes sup.claimed.map { |c| c[:subject_number] }, 1
		end

		def test_nothing_is_claimed_at_the_cap
			prepared_repo
			sup = FakeSupervisor.new(capped: true)
			poller(supervisor: sup).reconcile

			assert_empty sup.claimed
		end

		def test_the_board_item_id_reaches_the_run
			prepared_repo
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal %w[PVTI_1 PVTI_4], sup.claimed.map { |c| c[:board_item_id] }.sort
		end

		def test_a_claimed_run_is_started
			prepared_repo
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal sup.claimed.length, sup.started.length
		end

		# The item waits rather than failing: the run holding the branch will
		# finish or be reaped.
		def test_a_held_item_starts_nothing
			prepared_repo
			sup = FakeSupervisor.new(answer: :held)
			poller(supervisor: sup).reconcile

			assert_empty sup.started
		end

		def test_a_blocked_claim_is_reported_and_starts_nothing
			prepared_repo
			calls = []
			blocked = Mill::Supervisor::Blocked.new(problem: :branch_checked_out,
				questions: ['switch your clone off it'])
			sup = FakeSupervisor.new(answer: blocked)
			poller(supervisor: sup, calls: calls).reconcile

			assert_empty sup.started
			assert_match(/switch your clone off it/, bodies(calls).first)
		end

		# An unprepared repo blocks that one item and names what is missing.
		def test_an_unpreparable_repo_blocks_only_its_own_item
			calls = []
			sup = FakeSupervisor.new
			preparer = ->(**) do
				Mill::Repo::Result.new(problem: :missing_secrets, questions: ['API_KEY is missing'])
			end
			poller(supervisor: sup, preparer: preparer, calls: calls).reconcile

			assert_empty sup.claimed
			assert_match(/API_KEY/, bodies(calls).first)
		end

		# :no_spec carries no questions, so the generic block comment would post a
		# heading over an empty list and read as a bug in mill.
		def test_an_item_with_no_spec_is_told_what_to_commit
			prepared_repo
			calls = []
			poller(locator: ->(*) { located(path: nil, problem: :no_spec) }, calls: calls).reconcile

			body = bodies(calls).first

			assert_match(%r{docs/superpowers/specs/}, body)
			refute_match(/^- $/, body)
		end

		def test_an_item_with_no_linked_branch_is_told_to_make_one
			prepared_repo
			calls = []
			poller(locator: ->(*) { located(branch: nil, path: nil, problem: :no_branch) },
				calls: calls).reconcile

			assert_match(/gh issue develop/, bodies(calls).first)
		end

		# An ambiguous branch is a real question, and Located already words it.
		def test_an_ambiguous_branch_asks_its_own_question
			prepared_repo
			calls = []
			ambiguous = Mill::Spec::Located.new(problem: :many_branches, detail: 'a, b')
			poller(locator: ->(*) { ambiguous }, calls: calls).reconcile

			assert_match(/more than one linked branch/, bodies(calls).first)
		end

		# Silence is never success: a board mill could not read is not an empty
		# board, and treating it as one would look like there being no work.
		def test_an_unreadable_board_raises_rather_than_reading_as_empty
			gh = Mill::Github.new(runner: ->(_) { raise Mill::Github::Unauthorized, 'bad token' })
			board = Mill::Board.new(db: db, github: gh, project: 3, owner: 'slowernet')
			p = Mill::Poller.new(db: db, github: gh, board: board, supervisor: FakeSupervisor.new)

			assert_raises(Mill::Github::Unauthorized) { p.reconcile }
		end

		def test_an_unconfigured_board_is_not_polled
			calls = []
			gh = Mill::Github.new(runner: ->(args) { calls << args; '' })
			board = Mill::Board.new(db: db, github: gh, project: nil, owner: nil)
			p = Mill::Poller.new(db: db, github: gh, board: board, supervisor: FakeSupervisor.new)
			p.reconcile

			assert_empty calls
		end

		# There must be exactly one supervisor in the process: it alone knows which
		# process groups mill spawned and which runs have a live thread.
		def test_a_poller_will_not_invent_its_own_supervisor
			assert_raises(ArgumentError) { Mill::Poller.new(db: db) }
		end
	end
end
