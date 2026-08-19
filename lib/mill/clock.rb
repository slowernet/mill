module Mill
	# mill runs on macOS (a laptop) and Linux (a server), and the two name the same
	# semantics with different constants. Copying a line between them does not merely
	# fail to port — it computes sleep backwards.
	#
	#   awake      — excludes time asleep. Every deadline that measures work.
	#   continuous — includes it. Differencing the two gives the sleep gap.
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
	end
end
