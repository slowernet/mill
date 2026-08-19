require 'json'

module Mill
	# Walks the stage graph for one run, applying the ledger to every ending.
	#
	# It never spawns anything. The launcher is injected — Mill::Claude#run in
	# production, a lambda returning scripted attempts in tests — which is what
	# lets the whole control plane be tested with no network and no claude.
	class Runner
		TERMINAL = %i[blocked failed done].freeze

		attr_reader :run_id, :state

		def initialize(db:, run_id:, launcher:, context: {})
			@db = db
			@run_id = run_id
			@launcher = launcher
			@context = context
			@ledger = Mill::Ledger.new(db, run_id)
			@sessions = {}
			@artifacts = {}
			@verdicts = []
			@objections = {}
			@state = {}
		end

		def route
			@route ||= @db[:runs].where(id: @run_id).get(:route) or
				raise Mill::Error, "run #{@run_id} has no route"
		end

		def route_stages = Mill::Stages::ROUTES.fetch(route)

		# Set on first use rather than in initialize, because reading the route
		# needs a query and a Runner may be built and never stepped.
		def stage = @stage ||= route_stages.first

		# Rebuilds what the first walk knew, from the rows it left behind: which
		# session each stage is holding, what the plan produced, what each stage
		# reported, and which stage was waiting for an answer.
		#
		# Answering does not restart anything. The blocked stage resumes its own
		# session with the answer injected, so it wakes up remembering its own work
		# — which is the whole reason the session id is a column.
		def restore
			raise Mill::Error, "run #{@run_id} is not blocked" unless run_row[:status] == 'blocked'

			@db[:stage_attempts].where(run_id: @run_id).order(:id).each do |row|
				verdict = row[:verdict_json] ? JSON.parse(row[:verdict_json], symbolize_names: true) : {}
				@sessions[row[:stage]] = row[:session_id]
				@artifacts[row[:stage]] = verdict[:artifact] if verdict[:artifact]
				@verdicts << { stage: row[:stage], status: verdict[:status], summary: verdict[:summary] }
			end
			@stage = run_row[:current_stage] || route_stages.first
			rescue_from_strikes
			self
		end

		def call
			outcome = nil
			outcome = step until TERMINAL.include?(outcome)
			outcome
		end

		def step
			return finish if stage.nil?
			return terminate("#{@stage} ran out of strikes twice") if @exhausted

			tally = @ledger.tally(@stage)
			return halt(:blocked, "#{@stage} has used both its strikes") if tally.out_of_strikes?
			return halt(:blocked, "#{@stage} hit its number cap") if tally.out_of_attempts?

			settle(launch(@stage, tally.next_attempt), tally.next_attempt)
		end

		private

		def run_row = @db[:runs].where(id: @run_id).first

		# The one sanctioned third strike. A run blocked because a stage ran out of
		# strikes resumes differently from one blocked by a question: answering
		# resets that stage's count, once per run. A stage that runs out a second
		# time is terminal, and the run fails rather than looping.
		def rescue_from_strikes
			return unless @ledger.out_of_strikes?(@stage)

			if @ledger.reset_available?(@stage)
				@ledger.reset!(@stage)
			else
				@exhausted = true
			end
		end

		def launch(stage, number)
			@launcher.call(
				stage: stage, number: number,
				prompt: Mill::Prompts.for(stage, prompt_context(stage)),
				session_id: @sessions[stage]
			)
		end

		# A relaunch resumes the stage's own session so the agent remembers its
		# work. The one exception is a verdict that failed validation: mill has no
		# trustworthy account of what happened, so it starts fresh.
		def settle(attempt, number)
			outcome = Mill::Ledger.classify(attempt)
			@sessions[@stage] = outcome == :no_verdict ? nil : attempt.session_id

			case outcome
			when :blocked
				@ledger.charge(stage: @stage, outcome: :blocked, number: number, attempt: attempt)
				halt(:blocked, "#{@stage} asked a question", questions: attempt.verdict.questions)
			when :ok
				remember(attempt)
				reviewer?(@stage) && attempt.verdict.rejects? ? reject(attempt, number) : advance(attempt, number)
			else
				@ledger.charge(stage: @stage, outcome: outcome, number: number, attempt: attempt)
				:rerun
			end
		end

		def advance(attempt, number)
			@ledger.charge(stage: @stage, outcome: reviewer?(@stage) ? :reviewed_clean : :ok,
				number: number, attempt: attempt)
			@stage = Mill::Stages.next_stage(route, @stage)
			@stage.nil? ? finish : :advanced
		end

		# A reviewer that finds something serious is the reviewer succeeding: it
		# costs the reviewer nothing and strikes the stage it reviewed. One row,
		# for the launch that actually happened — the strike rides on it, attributed
		# to whoever pays. The reviewed stage's number is its re-launch.
		def reject(attempt, number)
			reviewed = Mill::Stages.reviewed_stage(route, @stage)
			@objections[reviewed] = attempt.verdict.serious_objections
			@ledger.charge(stage: @stage, outcome: :reviewed_clean, number: number,
				attempt: attempt, struck_stage: reviewed)

			return halt(:blocked, "#{reviewed} has used both its strikes") if @ledger.out_of_strikes?(reviewed)

			@stage = reviewed
			:rerun
		end

		def remember(attempt)
			path = attempt.verdict.data[:artifact]
			@artifacts[@stage] = path if path
			@verdicts << { stage: @stage, status: attempt.verdict.status,
				summary: attempt.verdict.data[:summary] }
		end

		def prompt_context(stage)
			@context.merge(
				plan_path: @artifacts['plan'],
				verdicts: @verdicts,
				objections: @objections[stage],
				route: route,
				spend: (spend_lines if stage == 'pr')
			).compact
		end

		# The pr stage is told to put the per-stage cost in the body. On the first
		# real run it was told nothing, and correctly said so rather than inventing
		# numbers — but the body was then missing a section the design requires.
		def spend_lines
			@ledger.spend.map do |stage, t|
				out = t[:tokens_out].nil? ? 'unmeasured' : t[:tokens_out]
				"#{stage}: #{t[:attempts]} attempt(s), in #{t[:tokens_in]}, out #{out}, " \
					"cache read #{t[:cache_read_tokens]}, cache write #{t[:cache_creation_tokens]}"
			end
		end

		def reviewer?(stage) = stage.start_with?('review:')

		def halt(status, reason, questions: [])
			@state = { stage: @stage, status: status, reason: reason, questions: questions }
			@db[:runs].where(id: @run_id).update(status: status.to_s, current_stage: @stage)
			status
		end

		# The only path to a terminal failure: a stage that exhausted its strikes,
		# was rescued once, and exhausted them again.
		def terminate(reason)
			@state = { stage: @stage, status: :failed, reason: reason, questions: [] }
			@db[:runs].where(id: @run_id).update(status: 'failed', finished_at: Mill.now)
			:failed
		end

		def finish
			@state = { stage: nil, status: :done, reason: 'the route is complete', questions: [] }
			@db[:runs].where(id: @run_id).update(status: 'done', current_stage: nil, finished_at: Mill.now)
			:done
		end
	end
end
