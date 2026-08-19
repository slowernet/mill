require 'time'

module Mill
	# mill runs on macOS (a laptop) and Linux (a server), and the two name the same
	# semantics with different constants. Copying a line between them does not merely
	# fail to port — it computes sleep backwards.
	#
	#   awake      — excludes time asleep. Every deadline that measures work.
	#   continuous — includes it. Differencing the two gives the sleep gap.
	#
	# This module is also the only place mill reads the process table, because
	# signalling is the one path that must be correct.
	module Clock
		DARWIN = RUBY_PLATFORM.include?('darwin')

		AWAKE = DARWIN ? Process::CLOCK_UPTIME_RAW : Process::CLOCK_MONOTONIC
		CONTINUOUS = DARWIN ? Process::CLOCK_MONOTONIC : Process::CLOCK_BOOTTIME

		def self.awake = Process.clock_gettime(AWAKE)

		def self.continuous = Process.clock_gettime(CONTINUOUS)

		# Both clocks at once, so a caller comparing them samples the same instant.
		def self.pair = [awake, continuous]

		def self.boot_time
			if DARWIN
				`sysctl -n kern.boottime`[/sec\s*=\s*(\d+)/, 1]&.to_i
			else
				File.read('/proc/stat')[/^btime\s+(\d+)/, 1]&.to_i
			end
		rescue StandardError
			nil
		end

		# When a live pid began, as a UTC epoch second. This is what distinguishes
		# our process from a stranger wearing a recycled pid, and the boot time
		# cannot do that job alone: a reboot early in mill's life moves kern.boottime
		# by less than the tolerance, and an NTP step moves it for no reason at all.
		#
		# nil means "no such process, or the platform would not say" — callers must
		# read that as "cannot confirm" and refuse to signal, never as a match.
		def self.pid_started_at(pid)
			return nil if pid.nil? || pid.to_i <= 1

			DARWIN ? darwin_started_at(pid.to_i) : linux_started_at(pid.to_i)
		rescue StandardError
			nil
		end

		# lstart is stored at process creation and does not move when the clock
		# steps, which is exactly why it is a better identity than the boot time.
		def self.darwin_started_at(pid)
			out = `LC_ALL=C ps -o lstart= -p #{pid} 2>/dev/null`.strip
			out.empty? ? nil : Time.parse(out).utc.to_i
		end

		def self.linux_started_at(pid)
			stat = File.read("/proc/#{pid}/stat")
			# comm is parenthesised and may itself contain spaces and parens, so the
			# numeric fields start after the *last* ')'.
			fields = stat[(stat.rindex(')') + 1)..].split
			boot = boot_time or return nil

			boot + (fields[19].to_i / clock_ticks)		# field 22 overall: starttime
		end

		def self.clock_ticks
			@clock_ticks ||= begin
				require 'etc'
				Etc.sysconf(Etc::SC_CLK_TCK)
			rescue StandardError
				100
			end
		end
	end
end
