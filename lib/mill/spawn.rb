require 'fileutils'
require 'json'
require 'open3'

module Mill
	# Spawning, teeing, and reaping. The only place mill starts a stage subprocess.
	#
	# A stage is spawned in its own process group so the whole tree can be reaped:
	# killing the claude pid alone leaves test runners, package managers, and dev
	# servers holding the worktree and its ports, and the next attempt then fails
	# for reasons the log does not show.
	#
	# It is also spawned with the worktree as its working directory, because the
	# working directory *is* the filesystem boundary — measured with an empty deny
	# list, a stage refused to read or write outside it. Inheriting mill's own cwd
	# would point that boundary at mill's source tree.
	class Spawn
		LOG_CAP = 32 * 1024 * 1024
		TRUNCATED = "\n{\"type\":\"mill\",\"note\":\"log truncated at cap\"}\n".freeze
		CONTENT_CAP = LOG_CAP - TRUNCATED.bytesize
		STDERR_CAP = 64 * 1024
		BOOT_TOLERANCE = 300		# an NTP step moves kern.boottime; a reboot moves it far more

		Result = Struct.new(:stream, :status, :error, :pid, :pgid, :pid_started_at, :host_boot_at,
			:log_path, keyword_init: true) do
			# A launch mill could not start is not a success, and neither is one whose
			# status is unknown. Silence is never success.
			def success? = error.nil? && !status.nil? && status.success?
		end

		attr_reader :pid, :pgid, :pid_started_at, :host_boot_at

		def initialize(log_path:, chdir:, secrets: [], clock: -> { Mill::Clock.awake })
			@log_path = log_path
			@chdir = chdir
			@secrets = expand_secrets(secrets)
			@clock = clock
		end

		# Runs to completion, teeing each line to the log and into the parser as it
		# arrives, so a killed attempt keeps whatever it had.
		def run(argv, env: {})
			FileUtils.mkdir_p(File.dirname(@log_path))
			stream = Mill::Stream.new(clock: @clock)
			@host_boot_at = Mill::Clock.boot_time
			written = 0

			File.open(@log_path, 'w:UTF-8') do |log|
				written = pump(log, written, stream, argv, env)
			rescue SystemCallError => e
				# A stage mill could not even start is a failed launch, not a dead
				# runner thread. Record it where the ledger and the log can see it.
				@error = e
				append(log, written, mill_line(spawn_failed: e.message))
			end

			Result.new(stream: stream, status: @status, error: @error, pid: @pid, pgid: @pgid,
				pid_started_at: @pid_started_at, host_boot_at: @host_boot_at, log_path: @log_path)
		end

		# TERM the group, KILL after a grace period, then confirm nothing survived.
		def kill!(grace: 5)
			self.class.reap(@pgid, boot_at: @host_boot_at, started_at: @pid_started_at, grace: grace)
		end

		# Signalling is the one path that must be correct: pids are recycled, so
		# after a reboot a stored pgid of 431 may well belong to a system daemon.
		# Never signal a bare pid, and never signal without both checks below.
		def self.reap(pgid, boot_at:, started_at: nil, grace: 5, now: Mill::Clock.boot_time)
			return :no_pgid if pgid.nil? || pgid <= 1
			# Never signal at all without checking the recorded boot time first.
			# Clock.boot_time returns nil on an unreadable platform, and skipping
			# the check there would TERM a recycled pgid after a reboot.
			return :unknown_boot if boot_at.nil? || now.nil?
			return :rebooted if (now - boot_at).abs > BOOT_TOLERANCE
			return :gone unless alive?(pgid)

			case identify(pgid, started_at)
			when :recycled then return :recycled
			when :unverified then return :unverified
			end

			signal(pgid, 'TERM')
			waited = 0.0
			while waited < grace && alive?(pgid)
				sleep 0.1
				waited += 0.1
			end
			return :terminated unless alive?(pgid)

			signal(pgid, 'KILL')
			# A killed leader lingers as a zombie until something waits on it, and a
			# zombie still answers to its process group. Poll rather than sampling
			# once, or a reap that worked reports :survived and blocks the worktree.
			settled = 0.0
			while settled < 1.0 && alive?(pgid)
				sleep 0.1
				settled += 0.1
			end
			alive?(pgid) ? :survived : :killed
		end

		# The boot time alone is not enough: a reboot two minutes into mill's life
		# moves it by less than the tolerance, and then a stored pgid of 431 belongs
		# to whichever daemon claimed the number this time round.
		#
		# The group leader's pid *is* the pgid, and a process group id cannot be
		# reused while any member of the group is alive. So a leader that is gone
		# under a group that is not is still our group — that is precisely the
		# orphaned-descendant case, and it must still be reaped. Only a *live*
		# leader can be a stranger wearing our number, and that is the one we check.
		def self.identify(pgid, started_at)
			live = Mill::Clock.pid_started_at(pgid)
			return :orphans if live.nil?
			return :unverified if started_at.nil?

			live == started_at ? :ours : :recycled
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

		def pump(log, written, stream, argv, env)
			Open3.popen3(env, *argv, pgroup: true, chdir: @chdir) do |stdin, stdout, stderr, wait_thr|
				stdin.close
				# The stage's output is UTF-8 whatever the ambient locale says. Left
				# to Encoding.default_external it can arrive tagged US-ASCII, and
				# then the first non-ASCII character a stage reads raises an
				# encoding error out of the parser and kills the launch.
				stdout.set_encoding(Encoding::UTF_8)
				stderr.set_encoding(Encoding::UTF_8)
				@pid = wait_thr.pid
				# Recorded before the pgid, because a caller racing us watches the
				# pgid and would otherwise reach kill! with no identity to check.
				@pid_started_at = Mill::Clock.pid_started_at(@pid)
				@pgid = safe_pgid(@pid)
				drain = drain_stderr(stderr)

				stdout.each_line do |raw|
					line = utf8(raw)
					stream.consume(line)
					written = append(log, written, redact(line))
				end

				@status = wait_thr.value
				written = append(log, written, mill_line(stderr: drain.join(2) ? utf8(drain.value.to_s) : ''))
			end
			written
		end

		def safe_pgid(pid)
			Process.getpgid(pid)
		rescue Errno::ESRCH
			nil
		end

		# Secrets are injected into the stage environment and must never reach the
		# log, which mill keeps and the UI tails. A secret travels through the log
		# as JSON, so its escaped form is a different string from the one in the
		# environment: a password containing a quote, a backslash, a newline, or any
		# non-ASCII would otherwise pass the scrubber untouched.
		def expand_secrets(secrets)
			secrets.reject { |s| s.nil? || s.empty? }
				.flat_map { |s| [s, s.to_json[1..-2]] }
				.reject { |s| s.nil? || s.empty? }
				.uniq
		end

		def redact(line)
			@secrets.reduce(line) { |acc, secret| acc.gsub(secret, '[redacted]') }
		end

		# A stray byte in a file the stage read is not a reason to lose the launch.
		def utf8(line)
			line = line.dup.force_encoding(Encoding::UTF_8)
			line.valid_encoding? ? line : line.scrub('?')
		end

		# mill's own annotations ride the stream as ordinary JSON lines so the log
		# stays one parseable format, and go through the scrubber like anything else.
		def mill_line(fields)
			return '' if fields.values.all? { |v| v.nil? || v.to_s.empty? }

			redact(utf8("#{{ type: 'mill' }.merge(fields).to_json}\n"))
		end

		def append(log, written, line)
			return written if line.empty? || written >= CONTENT_CAP

			room = CONTENT_CAP - written
			if line.bytesize > room
				# Keep what fits rather than discarding the line whole: one oversized
				# tool result would otherwise throw away the entire log before it.
				# scrub('') drops the partial character a byte offset leaves behind —
				# the log is tailed by the UI and re-parsed on replay, so it has to
				# stay valid UTF-8 even where it was cut.
				log.write(line.byteslice(0, room).scrub(''))
				log.write(TRUNCATED)
				return CONTENT_CAP
			end

			log.write(line)
			written + line.bytesize
		end

		# stderr must be drained or a chatty stage fills the pipe and wedges itself,
		# which looks exactly like a stall. It is kept rather than discarded: a stage
		# that dies on an auth error says so only here, and a strike charged against
		# an empty log is a failure nobody can reconstruct.
		#
		# It is buffered and written after the child exits rather than teed live, so
		# it cannot interleave mid-line with the stream the parser is reading.
		def drain_stderr(stderr)
			Thread.new do
				buf = +''
				while (chunk = stderr.read(4096))
					buf << chunk if buf.bytesize < STDERR_CAP
				end
				buf
			rescue StandardError
				buf		# a kill racing the pipe close is expected, not reportable
			end
		end
	end
end
