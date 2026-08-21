require 'test_helper'

module Mill
	# Fixture-backed. Nothing here reaches the network.
	class TestBoard < Mill::TestCase
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'gh')

		def fixture(name) = File.read(File.join(FIXTURES, "#{name}.json"))

		# Answers each gh call from a fixture chosen by its subcommand, and records
		# every call so the writes can be asserted.
		def github(failing: false, fields: nil, &before_edit)
			calls = []
			gh = Mill::Github.new(runner: lambda { |args|
				calls << args
				if args[1] == 'item-edit'
					before_edit&.call
					raise Mill::Github::Error, 'network is down' if failing
				end

				case args[1]
				when 'view' then fixture('project_view')
				when 'field-list' then fields || fixture('project_fields')
				when 'item-list' then fixture('board_items')
				else ''
				end
			})
			[gh, calls]
		end

		def board(**opts, &blk)
			gh, calls = github(**opts, &blk)
			[Mill::Board.new(db: db, github: gh, project: 3, owner: 'slowernet'), calls]
		end

		def a_run(status: 'running', item: 'PVTI_1', number: 1)
			create_run(repo_id: (@repo_id ||= create_repo), status: status,
				subject_number: number, board_item_id: item)
		end

		def test_writing_a_status_names_the_option_by_id
			run_id = a_run
			b, calls = board

			assert b.want(run_id, 'running')
			edit = calls.find { |args| args[1] == 'item-edit' }

			assert_includes edit, 'PVTI_1'
			assert_includes edit, 'PVTSSF_status'
			assert_includes edit, 'opt_running'
			assert_includes edit, 'PVT_board'
		end

		def test_a_killed_run_reads_as_failed_on_the_board
			run_id = a_run(status: 'killed')
			b, calls = board
			b.want(run_id, 'killed')

			assert_includes calls.find { |args| args[1] == 'item-edit' }, 'opt_failed'
		end

		# The whole mechanism: an unconfirmed write is what redrive looks for.
		def test_a_failed_write_leaves_the_run_unconfirmed
			run_id = a_run
			b, = board(failing: true)

			refute b.want(run_id, 'blocked')
			row = db[:runs].where(id: run_id).first

			assert_equal 'Blocked', row[:desired_board_status]
			assert_nil row[:board_status_at]
		end

		def test_redrive_retries_what_was_never_confirmed
			run_id = a_run
			failing, = board(failing: true)
			failing.want(run_id, 'blocked')

			ok, calls = board
			ok.redrive

			refute_nil db[:runs].where(id: run_id).get(:board_status_at)
			assert_includes calls.find { |args| args[1] == 'item-edit' }, 'opt_blocked'
		end

		def test_redrive_leaves_a_confirmed_run_alone
			run_id = a_run
			b, = board
			b.want(run_id, 'running')

			again, calls = board
			again.redrive

			assert_nil calls.find { |args| args[1] == 'item-edit' }
		end

		def test_redrive_leaves_a_run_that_was_never_asked_for_alone
			a_run
			b, calls = board
			b.redrive

			assert_nil calls.find { |args| args[1] == 'item-edit' }
		end

		# redrive runs in the poller thread while run threads decide. A label read
		# a moment ago may already be stale, and stamping board_status_at against a
		# stale one is exactly what would stop it ever being retried — leaving a
		# blocked run behind a board that says Running, where the answer to its
		# questions is never read as an answer.
		def test_a_decision_that_changed_underneath_a_write_is_not_confirmed
			run_id = a_run
			db[:runs].where(id: run_id).update(desired_board_status: 'Running',
				board_status_at: nil)

			racing, = board do
				db[:runs].where(id: run_id).update(desired_board_status: 'Blocked',
					board_status_at: nil)
			end

			refute racing.send(:confirm, run_id)
			assert_nil db[:runs].where(id: run_id).get(:board_status_at)
		end

		# A run with no board item was started by hand. It must not raise, and it
		# must not read as confirmed either.
		def test_a_run_with_no_board_item_is_not_confirmed
			run_id = a_run(item: nil)
			b, calls = board

			refute b.want(run_id, 'done')
			assert_nil calls.find { |args| args[1] == 'item-edit' }
			assert_nil db[:runs].where(id: run_id).get(:board_status_at)
		end

		# A board missing an option is a configuration error rather than a network
		# blip, and must not be swallowed into an endless retry.
		def test_a_board_missing_a_status_option_raises
			run_id = a_run
			b, = board(fields:
				'{"fields":[{"id":"F","name":"Status","options":[{"id":"1","name":"Ready"}]}]}')

			error = assert_raises(Mill::Error) { b.want(run_id, 'running') }

			assert_match(/Blocked/, error.message)
		end

		def test_a_board_with_no_status_field_raises
			run_id = a_run
			b, = board(fields: '{"fields":[{"id":"F","name":"Evidence","options":[]}]}')

			assert_raises(Mill::Error) { b.want(run_id, 'running') }
		end

		# Board automation writing Status under a live run is what the runbook
		# disables. Catching it later is what catches it being re-enabled.
		def test_a_status_mill_did_not_write_is_interference
			run_id = a_run
			b, = board
			b.want(run_id, 'running')
			row = db[:runs].where(id: run_id).first

			assert b.interference?({ id: 'PVTI_1', status: 'Done' }, row)
			refute b.interference?({ id: 'PVTI_1', status: 'Running' }, row)
		end

		def test_another_items_status_is_not_this_runs_interference
			run_id = a_run
			b, = board
			b.want(run_id, 'running')
			row = db[:runs].where(id: run_id).first

			refute b.interference?({ id: 'PVTI_2', status: 'Done' }, row)
		end

		def test_field_and_option_ids_are_resolved_once
			run_id = a_run
			b, calls = board
			b.want(run_id, 'running')
			b.want(run_id, 'done')

			assert_equal 1, calls.count { |args| args[1] == 'field-list' }
		end

		def test_an_unconfigured_board_writes_nothing
			run_id = a_run
			gh, calls = github
			b = Mill::Board.new(db: db, github: gh, project: nil, owner: nil)

			refute b.configured?
			refute b.want(run_id, 'running')
			assert_empty calls
		end

		def test_an_unknown_run_status_has_no_board_status
			run_id = a_run
			b, = board

			assert_raises(Mill::Error) { b.want(run_id, 'queued') }
		end
	end
end
