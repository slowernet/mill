require 'test_helper'
require 'tmpdir'

module Mill
	# Drives real subprocesses, but never `claude` — a ruby script stands in,
	# emitting recorded stream-json shapes.
	class TestSpawn < Minitest::Test
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'stream')

		def with_log
			Dir.mktmpdir { |dir| yield File.join(dir, 'run', 'plan-1.jsonl') }
		end

		def fake_stage(fixture)
			['ruby', '-e', "print File.read(#{File.join(FIXTURES, "#{fixture}.jsonl").inspect})"]
		end

		def test_tees_the_stream_and_parses_it_at_once
			with_log do |log|
				result = Mill::Spawn.new(log_path: log).run(fake_stage('plan_ok'))

				assert_predicate result, :success?
				assert_equal 'sess-plan-1', result.stream.session_id
				assert_equal 356, result.stream.tokens[:tokens_out]
				assert_equal File.read(File.join(FIXTURES, 'plan_ok.jsonl')), File.read(log)
			end
		end

		def test_records_what_is_needed_to_reap_it_later
			with_log do |log|
				spawn = Mill::Spawn.new(log_path: log)
				result = spawn.run(fake_stage('plan_ok'))

				refute_nil result.pid
				refute_nil result.pgid
				refute_nil result.host_boot_at
			end
		end

		# The stage runs in its own group, or killing it leaves the tree behind.
		def test_the_stage_gets_its_own_process_group
			with_log do |log|
				spawn = Mill::Spawn.new(log_path: log)
				spawn.run(fake_stage('plan_ok'))

				refute_equal Process.getpgid(Process.pid), spawn.pgid
			end
		end

		def test_a_failing_stage_is_not_a_success
			with_log do |log|
				result = Mill::Spawn.new(log_path: log).run(['ruby', '-e', 'exit 1'])

				refute_predicate result, :success?
			end
		end

		# Secrets are injected into the environment and must never reach a log mill
		# keeps and the UI tails.
		def test_secrets_never_reach_the_log
			with_log do |log|
				script = ['ruby', '-e', 'require "json"; puts({type: "system", note: ENV["SEKRIT"]}.to_json)']
				Mill::Spawn.new(log_path: log, secrets: ['hunter2']).run(script, env: { 'SEKRIT' => 'hunter2' })

				refute_includes File.read(log), 'hunter2'
				assert_includes File.read(log), '[redacted]'
			end
		end

		def test_a_long_running_stage_can_be_reaped_as_a_group
			with_log do |log|
				spawn = Mill::Spawn.new(log_path: log)
				thread = Thread.new { spawn.run(['ruby', '-e', 'sleep 30']) }
				sleep 0.5 until spawn.pgid

				assert_includes %i[terminated killed], spawn.kill!(grace: 3)
				thread.join(5)
			end
		end

		# Killing the claude pid alone would leave test runners and dev servers
		# holding the worktree. The whole group has to go.
		def test_a_child_that_outlives_its_parent_is_still_reaped
			with_log do |log|
				spawn = Mill::Spawn.new(log_path: log)
				# Parent exits immediately; the grandchild sleeps on in the same group.
				script = ['ruby', '-e', 'spawn("sleep 30"); exit 0']
				thread = Thread.new { spawn.run(script) }
				sleep 0.5 until spawn.pgid
				pgid = spawn.pgid
				thread.join(5)

				assert Mill::Spawn.alive?(pgid), 'the orphaned child should still hold the group'
				Mill::Spawn.reap(pgid, boot_at: Mill::Clock.boot_time, grace: 2)
				refute Mill::Spawn.alive?(pgid), 'the group survived a reap'
			end
		end

		# Pids are recycled: after a reboot a stored pgid may belong to a daemon.
		def test_never_signals_across_a_reboot
			assert_equal :rebooted,
				Mill::Spawn.reap(99_999, boot_at: 1_000_000, now: 2_000_000)
		end

		def test_a_clock_step_is_not_a_reboot
			# An NTP correction moves kern.boottime by seconds, not days.
			refute_equal :rebooted,
				Mill::Spawn.reap(99_999, boot_at: 1_000_000, now: 1_000_012)
		end

		def test_refuses_to_signal_a_meaningless_group
			[nil, 0, 1].each do |pgid|
				assert_equal :no_pgid, Mill::Spawn.reap(pgid, boot_at: nil, now: nil)
			end
		end

		def test_reaping_something_already_gone_is_not_an_error
			assert_equal :gone, Mill::Spawn.reap(99_999, boot_at: 1_000_000, now: 1_000_000)
		end

		def test_the_log_is_capped
			with_log do |log|
				spawn = Mill::Spawn.new(log_path: log)
				spawn.instance_variable_set(:@secrets, [])
				stub_cap = Mill::Spawn::LOG_CAP
				script = ['ruby', '-e', 'require "json"; 200.times { puts({type: "system", pad: "x" * 100}.to_json) }']
				result = spawn.run(script)

				assert_operator File.size(log), :<=, stub_cap
				assert_predicate result, :success?
			end
		end
	end
end
