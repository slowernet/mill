require 'test_helper'
require 'rack/test'
require_relative '../../app'

module Mill
	class TestWorkers < Minitest::Test
		include Rack::Test::Methods

		def app = App.freeze.app

		# GET / counts running runs, so the process-wide connection the app uses
		# needs a schema. MILL_DB is ':memory:' for the whole suite.
		def setup
			Mill::DB.migrate!(Mill.db)
		end

		def teardown
			ENV.delete('MILL_WORKERS')
			@workers&.stop
		end

		def workers(**opts)
			@workers = Mill::Workers.new(poller: -> {}, supervisor: -> {}, **opts)
		end

		# A stray Ready on the board must not launch a real run against a real repo
		# while somebody is editing a template.
		def test_workers_are_off_when_the_environment_says_so
			ENV['MILL_WORKERS'] = 'off'

			refute Mill::Workers.enabled?
		end

		def test_off_is_case_insensitive
			ENV['MILL_WORKERS'] = 'OFF'

			refute Mill::Workers.enabled?
		end

		def test_workers_are_on_by_default
			ENV.delete('MILL_WORKERS')

			assert Mill::Workers.enabled?
		end

		def test_disabled_workers_start_no_threads
			ENV['MILL_WORKERS'] = 'off'
			workers(interval: 0.01).start

			refute @workers.health[:poller][:alive]
		end

		def test_each_loop_ticks_and_heartbeats
			ticks = Queue.new
			@workers = Mill::Workers.new(interval: 0.01, supervisor: -> {},
				poller: -> { ticks << :tick })
			@workers.start
			ticks.pop
			ticks.pop

			refute_nil @workers.health[:poller][:at]
			assert @workers.health[:poller][:alive]
		end

		# A thread that raises must come back, or the factory silently stops.
		def test_a_raising_loop_is_restarted
			calls = Queue.new
			first = true
			@workers = Mill::Workers.new(interval: 0.01, supervisor: -> {}, poller: lambda {
				calls << :call
				next unless first

				first = false
				raise 'boom'
			})
			@workers.start
			3.times { calls.pop }

			assert @workers.health[:poller][:alive]
		end

		def test_a_raising_loop_records_what_it_raised
			raised = Queue.new
			@workers = Mill::Workers.new(interval: 0.01, supervisor: -> {}, poller: lambda {
				raised << :raised
				raise 'boom'
			})
			@workers.start
			raised.pop
			sleep 0.05

			assert_match(/boom/, @workers.health[:poller][:error].to_s)
		end

		# The cap is in seconds. Applied before the multiplier it was three
		# seconds, so an expired token retried twelve hundred times an hour.
		def test_backoff_grows_to_the_stated_ceiling
			w = workers(interval: 30)

			assert_in_delta 60, w.send(:backoff, 1)
			assert_in_delta Mill::Workers::MAX_BACKOFF, w.send(:backoff, 20)
			assert_operator w.send(:backoff, 20), :>, 60
		end

		def test_the_root_route_reports_worker_health
			get '/'

			assert last_response.ok?
			assert_match(/poller/, last_response.body)
			assert_match(/supervisor/, last_response.body)
		end

		# Requiring app.rb must not start polling a real board.
		def test_loading_the_app_starts_nothing
			refute App.workers.health[:poller][:alive]
		end
	end
end
