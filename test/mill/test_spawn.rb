require 'test_helper'
require 'tmpdir'

module Mill
	# Drives real subprocesses, but never `claude` — a ruby script stands in,
	# emitting recorded stream-json shapes.
	class TestSpawn < Minitest::Test
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'stream')

		def with_log
			Dir.mktmpdir { |dir| yield File.join(dir, 'run', 'plan-1.jsonl'), dir }
		end

		def spawn_in(log, dir, **rest) = Mill::Spawn.new(log_path: log, chdir: dir, **rest)

		def fake_stage(fixture)
			['ruby', '-e', "print File.read(#{File.join(FIXTURES, "#{fixture}.jsonl").inspect})"]
		end

		def test_tees_the_stream_and_parses_it_at_once
			with_log do |log, dir|
				result = spawn_in(log, dir).run(fake_stage('plan_ok'))

				assert_predicate result, :success?
				assert_equal 'sess-plan-1', result.stream.session_id
				assert_equal 356, result.stream.tokens[:tokens_out]
				assert_includes File.read(log), File.read(File.join(FIXTURES, 'plan_ok.jsonl'))
			end
		end

		def test_records_what_is_needed_to_reap_it_later
			with_log do |log, dir|
				result = spawn_in(log, dir).run(fake_stage('plan_ok'))

				refute_nil result.pid
				refute_nil result.pgid
				refute_nil result.host_boot_at
				refute_nil result.pid_started_at, 'the boot time alone cannot identify a recycled pgid'
			end
		end

		# The stage runs in its own group, or killing it leaves the tree behind.
		def test_the_stage_gets_its_own_process_group
			with_log do |log, dir|
				spawn = spawn_in(log, dir)
				spawn.run(fake_stage('plan_ok'))

				refute_equal Process.getpgid(Process.pid), spawn.pgid
			end
		end

		# The working directory is layer 1's real filesystem boundary — measured
		# with an empty deny list, a stage refused to read or write outside it.
		# Inheriting mill's own cwd would point that boundary at mill's source.
		def test_the_stage_runs_in_the_worktree_not_in_mills_cwd
			with_log do |log, dir|
				spawn_in(log, dir).run(['ruby', '-e', 'require "json"; puts({type: "system", cwd: Dir.pwd}.to_json)'])

				assert_equal File.realpath(dir), JSON.parse(File.read(log).lines.first)['cwd']
				refute_equal Dir.pwd, JSON.parse(File.read(log).lines.first)['cwd']
			end
		end

		def test_a_failing_stage_is_not_a_success
			with_log do |log, dir|
				refute_predicate spawn_in(log, dir).run(['ruby', '-e', 'exit 1']), :success?
			end
		end

		# A stage mill cannot even start is a failed launch the ledger can see, not
		# an exception that kills the runner thread and retries forever.
		def test_a_missing_binary_is_a_failed_launch_not_a_crash
			with_log do |log, dir|
				result = spawn_in(log, dir).run(['mill-no-such-binary-xyz'])

				refute_predicate result, :success?
				refute_nil result.error
				assert_includes File.read(log), 'spawn_failed'
			end
		end

		# Secrets are injected into the environment and must never reach a log mill
		# keeps and the UI tails.
		def test_secrets_never_reach_the_log
			with_log do |log, dir|
				script = ['ruby', '-e', 'require "json"; puts({type: "system", note: ENV["SEKRIT"]}.to_json)']
				spawn_in(log, dir, secrets: ['hunter2']).run(script, env: { 'SEKRIT' => 'hunter2' })

				refute_includes File.read(log), 'hunter2'
				assert_includes File.read(log), '[redacted]'
			end
		end

		# A secret travels through the log as JSON, so its escaped form is a
		# different string from the one in the environment. Scrubbing only the raw
		# bytes let a password containing a quote through untouched.
		def test_a_secret_is_scrubbed_in_its_json_escaped_form_too
			['hunter"2', 'back\\slash', "two\nlines", 'café'].each do |secret|
				with_log do |log, dir|
					script = ['ruby', '-e', 'require "json"; puts({type: "system", note: ENV["SEKRIT"]}.to_json)']
					spawn_in(log, dir, secrets: [secret]).run(script, env: { 'SEKRIT' => secret })
					body = File.read(log)

					refute_includes body, secret.to_json[1..-2], "escaped #{secret.inspect} leaked"
					refute_includes body, secret, "raw #{secret.inspect} leaked"
					assert_includes body, '[redacted]'
				end
			end
		end

		# A stage that dies on an auth error says so only on stderr. Charging a
		# strike against an empty log is a failure nobody can reconstruct.
		def test_stderr_is_kept_so_a_dead_stage_can_be_diagnosed
			with_log do |log, dir|
				script = ['ruby', '-e', 'STDERR.puts "Invalid API key - please run /login"; exit 1']
				result = spawn_in(log, dir).run(script)

				refute_predicate result, :success?
				assert_includes File.read(log), 'Invalid API key'
			end
		end

		def test_stderr_stays_out_of_the_log_when_it_carries_a_secret
			with_log do |log, dir|
				script = ['ruby', '-e', 'STDERR.puts "token=#{ENV["SEKRIT"]}"']
				spawn_in(log, dir, secrets: ['hunter2']).run(script, env: { 'SEKRIT' => 'hunter2' })

				refute_includes File.read(log), 'hunter2'
			end
		end

		def test_a_long_running_stage_can_be_reaped_as_a_group
			with_log do |log, dir|
				spawn = spawn_in(log, dir)
				thread = Thread.new { spawn.run(['ruby', '-e', 'sleep 30']) }
				sleep 0.5 until spawn.pgid

				assert_includes %i[terminated killed], spawn.kill!(grace: 3)
				thread.join(5)
			end
		end

		# Killing the claude pid alone would leave test runners and dev servers
		# holding the worktree. The whole group has to go.
		def test_a_child_that_outlives_its_parent_is_still_reaped
			with_log do |log, dir|
				spawn = spawn_in(log, dir)
				# Parent exits immediately; the grandchild sleeps on in the same group.
				script = ['ruby', '-e', 'spawn("sleep 30"); exit 0']
				thread = Thread.new { spawn.run(script) }
				sleep 0.5 until spawn.pgid
				pgid = spawn.pgid
				thread.join(5)

				assert Mill::Spawn.alive?(pgid), 'the orphaned child should still hold the group'
				# The leader is gone, so there is no start time to match — and a pgid
				# cannot be reused while the group has a member, so this is still ours.
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

		# The boot time inside the tolerance is not evidence of identity: a reboot
		# two minutes into mill's life moves it by less than five, and then the
		# stored pgid belongs to whichever daemon claimed the number this time.
		def test_a_live_leader_whose_start_time_disagrees_is_never_signalled
			pid = Process.spawn('sleep 30', pgroup: true)
			pgid = Process.getpgid(pid)
			boot = Mill::Clock.boot_time

			assert_equal :recycled,
				Mill::Spawn.reap(pgid, boot_at: boot, started_at: Mill::Clock.pid_started_at(pid) - 3600)
			assert Mill::Spawn.alive?(pgid), 'a process mill could not identify must be left alone'
		ensure
			Process.kill('KILL', -pgid) if pgid
			Process.wait(pid) if pid
		end

		def test_a_live_leader_with_no_recorded_start_time_is_never_signalled
			pid = Process.spawn('sleep 30', pgroup: true)
			pgid = Process.getpgid(pid)

			assert_equal :unverified,
				Mill::Spawn.reap(pgid, boot_at: Mill::Clock.boot_time, started_at: nil)
			assert Mill::Spawn.alive?(pgid)
		ensure
			Process.kill('KILL', -pgid) if pgid
			Process.wait(pid) if pid
		end

		def test_a_matching_start_time_is_reaped
			pid = Process.spawn('sleep 30', pgroup: true)
			Process.detach(pid)		# so the killed leader does not linger as a zombie
			pgid = Process.getpgid(pid)

			assert_includes %i[terminated killed],
				Mill::Spawn.reap(pgid, boot_at: Mill::Clock.boot_time,
					started_at: Mill::Clock.pid_started_at(pid), grace: 2)
		end

		def test_refuses_to_signal_a_meaningless_group
			[nil, 0, 1].each do |pgid|
				assert_equal :no_pgid, Mill::Spawn.reap(pgid, boot_at: nil, now: nil)
			end
		end

		def test_reaping_something_already_gone_is_not_an_error
			assert_equal :gone, Mill::Spawn.reap(99_999, boot_at: 1_000_000, now: 1_000_000)
		end

		# One oversized line used to throw away the whole log: everything written
		# before it and everything after. The log is the only forensic record.
		def test_an_oversized_line_keeps_what_fits_rather_than_discarding_everything
			with_log do |log, dir|
				with_cap(2_000) do
					script = ['ruby', '-e', 'require "json"; puts({type: "system", note: "keep me"}.to_json); ' \
						'puts "x" * 50_000; puts({type: "system", note: "after"}.to_json)']
					spawn_in(log, dir).run(script)
					body = File.read(log)

					assert_includes body, 'keep me', 'the lines before the overflow must survive'
					assert_includes body, 'log truncated at cap'
					assert_operator File.size(log), :<=, Mill::Spawn::LOG_CAP
				end
			end
		end

		def test_the_log_is_capped
			with_log do |log, dir|
				with_cap(4_000) do
					script = ['ruby', '-e', 'require "json"; 200.times { puts({type: "system", pad: "x" * 100}.to_json) }']
					result = spawn_in(log, dir).run(script)

					assert_operator File.size(log), :<=, Mill::Spawn::LOG_CAP
					assert_includes File.read(log), 'log truncated at cap'
					assert_predicate result, :success?
				end
			end
		end

		# The log is what the UI tails and what a replay parses. Cutting a line at a
		# byte offset lands mid-character on any multibyte text, and the truncated
		# log is then not valid UTF-8 at all.
		def test_truncating_never_cuts_a_character_in_half
			with_log do |log, dir|
				with_cap(200) do
					script = ['ruby', '-e', '$stdout.set_encoding(Encoding::UTF_8); ' \
						'puts([0x1F6A2].pack("U") * 200)']
					spawn_in(log, dir).run(script)
					bytes = File.binread(log).force_encoding(Encoding::UTF_8)

					assert_predicate bytes, :valid_encoding?, 'the truncated log is not valid UTF-8'
					assert_includes bytes, 'log truncated at cap'
				end
			end
		end

		# Emoji and accented text are ordinary input: they arrive in issue bodies,
		# in comments, and in the files a stage reads.
		def test_non_ascii_output_reaches_the_log_intact
			with_log do |log, dir|
				text = [0x1F6A2].pack('U') + ' caf' + [0x00E9].pack('U')
				script = ['ruby', '-e', '$stdout.set_encoding(Encoding::UTF_8); require "json"; ' \
					'puts({ type: "system", note: ARGV[0] }.to_json)', '--', text]
				result = spawn_in(log, dir).run(script)

				assert_predicate result, :success?
				assert_includes File.read(log, encoding: 'UTF-8'), text
			end
		end

		private

		def with_cap(bytes)
			original = Mill::Spawn::LOG_CAP
			set_cap(bytes)
			yield
		ensure
			set_cap(original)
		end

		def set_cap(bytes)
			Mill::Spawn.send(:remove_const, :LOG_CAP)
			Mill::Spawn.const_set(:LOG_CAP, bytes)
			Mill::Spawn.send(:remove_const, :CONTENT_CAP)
			Mill::Spawn.const_set(:CONTENT_CAP, bytes - Mill::Spawn::TRUNCATED.bytesize)
		end
	end
end
