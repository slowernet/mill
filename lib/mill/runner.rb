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

		def call
			outcome = nil
			outcome = step until TERMINAL.include?(outcome)
			outcome
		end

		def step
			return finish if stage.nil?

			tally = @ledger.tally(@stage)
			return halt(:blocked, "#{@stage} has used both its strikes") if tally.out_of_strikes?
			return halt(:blocked, "#{@stage} hit its number cap") if tally.out_of_attempts?

			settle(launch(@stage, tally.next_attempt), tally.next_attempt)
		end

		private

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
				route: route
			).compact
		end

		def reviewer?(stage) = stage.start_with?('review:')

		def halt(status, reason, questions: [])
			@state = { stage: @stage, status: status, reason: reason, questions: questions }
			@db[:runs].where(id: @run_id).update(status: status.to_s, current_stage: @stage)
			status
		end

		def finish
			@state = { stage: nil, status: :done, reason: 'the route is complete', questions: [] }
			@db[:runs].where(id: @run_id).update(status: 'done', current_stage: nil, finished_at: Mill.now)
			:done
		end
	end
end
