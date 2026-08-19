module Mill
	# Both loops, inside one process. Each is wrapped in a supervising loop that
	# logs the exception and restarts with backoff — a factory whose poller thread
	# died in the night and left no trace is worse than one that never started.
	#
	# Thread.report_on_exception stays at its default of true.
	class Workers
		DEFAULT_INTERVAL = 30
		MAX_BACKOFF = 300

		attr_reader :supervisor, :board

		def initialize(poller: nil, supervisor: nil, interval: nil, db: Mill.db)
			@db = db
			# One board and one supervisor, both shared.
			#
			# The supervisor is the only object holding which process groups mill
			# spawned and which runs have a live thread; a second instance answers
			# "none" to both and reaps healthy stages.
			#
			# The board has to be handed to the supervisor as well as the poller.
			# Built without one, every `@board&.want` in claim, finish and interrupt
			# is a silent no-op — mill runs perfectly and never writes a Status, so
			# the board sits on Ready while a run works, finishes and opens a pull
			# request. Measured on the first real poll, 2026-08-19.
			@board = Mill::Board.new(db: db)
			@supervisor = Mill::Supervisor.new(db: db, board: @board)
			@poller_tick = poller
			@supervisor_tick = supervisor
			# Not `.to_f`: an empty or unparseable MILL_POLL_SECONDS would become 0.0
			# and turn the tick into a loop hammering the API as fast as it answers.
			@interval = interval ||
				Mill.setting_float('MILL_POLL_SECONDS', default: DEFAULT_INTERVAL, min: 5, max: 3600)
			@beats = {}
			@threads = {}
			@lock = Mutex.new
			@stopping = false
		end

		# A stray Ready on the board must not launch a real run against a real repo
		# while somebody is editing a template.
		def self.enabled? = ENV['MILL_WORKERS'].to_s.downcase != 'off'

		def start
			return self unless self.class.enabled?

			@lock.synchronize do
				@threads[:supervisor] = loop_thread(:supervisor, supervisor_tick)
				@threads[:poller] = loop_thread(:poller, poller_tick)
			end
			self
		end

		def stop
			@stopping = true
			@lock.synchronize do
				@threads.each_value { |thread| thread&.kill }
				@threads.clear
			end
		end

		# Reads a snapshot of both hashes rather than iterating live ones: this runs
		# in a Puma thread while two worker threads are writing.
		def health
			beats = @lock.synchronize { @beats }
			threads = @lock.synchronize { @threads.dup }
			%i[poller supervisor].to_h do |name|
				[name, (beats[name] || {}).merge(alive: threads[name]&.alive? || false)]
			end
		end

		private

		def poller_tick
			@poller_tick || begin
				poller = Mill::Poller.new(db: @db, supervisor: @supervisor, board: @board)
				-> { poller.tick }
			end
		end

		def supervisor_tick = @supervisor_tick || -> { @supervisor.reap }

		def loop_thread(name, work)
			Thread.new do
				failures = 0
				until @stopping
					begin
						work.call
						beat(name, nil)
						failures = 0
						sleep @interval
					rescue StandardError => e
						failures += 1
						beat(name, "#{e.class}: #{e.message}")
						warn "#{name} raised: #{e.class}: #{e.message}"
						sleep backoff(failures)
					end
				end
			end
		end

		# The cap is in seconds, and applying it before the multiplier would make
		# the real ceiling three seconds rather than five minutes. An expired token
		# would then retry twelve hundred times an hour, indefinitely.
		def backoff(failures) = [@interval * (2**failures), MAX_BACKOFF].min

		# @beats is written from two worker threads and read from a Puma thread.
		# Replacing the hash rather than mutating it means a reader never sees it
		# part-written.
		def beat(name, error)
			@lock.synchronize { @beats = @beats.merge(name => { at: Mill.now, error: error }) }
		end
	end
end
