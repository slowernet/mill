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

		# --- the comment sweep ---------------------------------------------------

		def sweeping(sup: FakeSupervisor.new, calls: [], failing: false)
			gh = Mill::Github.new(runner: lambda { |args|
				calls << args
				if args.first == 'api'
					raise Mill::Github::Error, 'boom' if failing

					next fixture('comments_dated')
				end
				args[1] == 'item-list' ? fixture('board_ready') : ''
			})
			board = Mill::Board.new(db: db, github: gh, project: 3, owner: 'slowernet')
			Mill::Poller.new(db: db, github: gh, board: board, supervisor: sup)
		end

		def blocked_subject
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			repo_id
		end

		def test_a_trusted_comment_becomes_an_event
			blocked_subject
			sweeping.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_11').count
		end

		# Comment text becomes prompt text, and a subprocess holds real credentials.
		def test_a_stranger_starts_nothing
			blocked_subject
			sweeping.sweep

			assert_equal 0, db[:events].where(gh_node_id: 'IC_12').count
		end

		def test_mills_own_comment_is_not_a_trigger
			blocked_subject
			sweeping.sweep

			assert_equal 0, db[:events].where(gh_node_id: 'IC_13').count
		end

		# GitHub's quote-reply copies the source markdown including HTML comments,
		# so a whole-body search for the marker would silently discard the only
		# channel in the design that reaches a person.
		def test_a_quote_reply_carrying_the_marker_is_still_your_answer
			blocked_subject
			sweeping.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_14').count
		end

		def test_the_same_comment_is_never_recorded_twice
			blocked_subject
			p = sweeping
			p.sweep
			p.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_11').count
		end

		def test_the_cursor_advances_after_a_complete_sweep
			repo_id = blocked_subject
			sweeping.sweep

			assert_equal '2026-08-19T10:03:00Z', db[:repos].where(id: repo_id).get(:comments_cursor)
		end

		# A fetch that stops partway must write no cursor, or the comments it never
		# saw are skipped forever.
		def test_a_failed_fetch_leaves_the_cursor_alone
			repo_id = blocked_subject
			p = sweeping(failing: true)

			assert_raises(Mill::Github::Error) { p.sweep }
			assert_nil db[:repos].where(id: repo_id).get(:comments_cursor)
		end

		# Without `since` a blocked run re-fetches its whole comment history every
		# tick, which on a busy issue ends in a rate limit.
		def test_the_cursor_is_sent_to_github_rather_than_only_filtering_here
			repo_id = blocked_subject
			db[:repos].where(id: repo_id).update(comments_cursor: '2026-08-19T09:00:00Z')
			calls = []
			sweeping(calls: calls).sweep

			assert(calls.any? { |args| args[1].to_s.include?('since=2026-08-19T09:00:00Z') })
		end

		# Bounded deliberately: subjects mill has a live run on, not every issue in
		# every repo the board touches.
		def test_only_interesting_subjects_are_swept
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			create_run(repo_id: repo_id, subject_number: 9, status: 'done')
			calls = []
			sweeping(calls: calls).sweep
			fetched = calls.select { |args| args.first == 'api' }.map { |args| args[1] }

			assert(fetched.any? { |url| url.include?('/issues/1/comments') })
			refute(fetched.any? { |url| url.include?('/issues/9/comments') })
		end

		def test_a_repo_with_nothing_live_is_not_swept
			prepared_repo
			calls = []
			sweeping(calls: calls).sweep

			assert_empty calls.select { |args| args.first == 'api' }
		end
	end
end
