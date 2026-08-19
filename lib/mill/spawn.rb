require 'fileutils'
require 'open3'

module Mill
	# Spawning, teeing, and reaping. The only place mill starts a subprocess.
	#
	# A stage is spawned in its own process group so the whole tree can be reaped:
	# killing the claude pid alone leaves test runners, package managers, and dev
	# servers holding the worktree and its ports, and the next attempt then fails
	# for reasons the log does not show.
	class Spawn
		LOG_CAP = 32 * 1024 * 1024
		TRUNCATED = "\n{\"type\":\"mill\",\"note\":\"log truncated at cap\"}\n".freeze
		BOOT_TOLERANCE = 300		# an NTP step moves kern.boottime; a reboot moves it far more

		Result = Struct.new(:stream, :status, :pid, :pgid, :pid_started_at, :host_boot_at, :log_path,
			keyword_init: true) do
			def success? = status&.success?
		end

		attr_reader :pid, :pgid

		def initialize(log_path:, secrets: [], clock: -> { Mill::Clock.awake })
			@log_path = log_path
			@secrets = secrets.reject { |s| s.nil? || s.empty? }
			@clock = clock
		end

		# Runs to completion, teeing each line to the log and into the parser as it
		# arrives, so a killed attempt keeps whatever it had.
		def run(argv, env: {})
			FileUtils.mkdir_p(File.dirname(@log_path))
			stream = Mill::Stream.new(clock: @clock)
			written = 0
			boot_at = Mill::Clock.boot_time

			File.open(@log_path, 'w') do |log|
				Open3.popen3(env, *argv, pgroup: true) do |stdin, stdout, stderr, wait_thr|
					stdin.close
					@pid = wait_thr.pid
					@pgid = safe_pgid(@pid)
					drain_stderr(stderr)

					stdout.each_line do |line|
						stream.consume(line)
						written = append(log, written, scrub(line))
					end

					@status = wait_thr.value
				end
			end

			Result.new(stream: stream, status: @status, pid: @pid, pgid: @pgid,
				pid_started_at: nil, host_boot_at: boot_at, log_path: @log_path)
		end

		# TERM the group, KILL after a grace period, then confirm nothing survived.
		def kill!(grace: 5)
			self.class.reap(@pgid, boot_at: Mill::Clock.boot_time, grace: grace)
		end

		# Signalling is the one path that must be correct: pids are recycled, so
		# after a reboot a stored pgid of 431 may well belong to a system daemon.
		# Never signal a bare pid, and never signal on a boot time that does not
		# match — with tolerance, because an NTP correction shifts kern.boottime.
		def self.reap(pgid, boot_at:, grace: 5, now: Mill::Clock.boot_time)
			return :no_pgid if pgid.nil? || pgid <= 1
			# Never signal at all without checking the recorded boot time first.
			# Clock.boot_time returns nil on an unreadable platform, and skipping
			# the check there would TERM a recycled pgid after a reboot.
			return :unknown_boot if boot_at.nil? || now.nil?
			return :rebooted if (now - boot_at).abs > BOOT_TOLERANCE
			return :gone unless alive?(pgid)

			signal(pgid, 'TERM')
			waited = 0.0
			while waited < grace && alive?(pgid)
				sleep 0.1
				waited += 0.1
			end
			return :terminated unless alive?(pgid)

			signal(pgid, 'KILL')
			sleep 0.2
			alive?(pgid) ? :survived : :killed
		end

		# A negative pid signals the whole group. Passing a bare pid here would
		# leave every descendant running.
		def self.signal(pgid, sig)
			Process.kill(sig, -pgid)
		rescue Errno::ESRCH, Errno::EPERM
			nil
		end

		def self.alive?(pgid)
			Process.kill(0, -pgid)
			true
		rescue Errno::ESRCH
			false
		rescue Errno::EPERM
			true		# exists but is not ours to signal
		end

		private

		def safe_pgid(pid)
			Process.getpgid(pid)
		rescue Errno::ESRCH
			nil
		end

		# Secrets are injected into the stage environment and must never reach the
		# log, which mill keeps and the UI tails.
		def scrub(line)
			@secrets.reduce(line) { |acc, secret| acc.gsub(secret, '[redacted]') }
		end

		def append(log, written, line)
			return written if written >= LOG_CAP

			if written + line.bytesize > LOG_CAP
				log.write(TRUNCATED)
				return LOG_CAP
			end

			log.write(line)
			written + line.bytesize
		end

		def drain_stderr(stderr)
			Thread.new { stderr.read }		# never let the pipe fill and wedge the child
		end
	end
end
