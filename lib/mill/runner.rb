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
			@stage = nil
		end

		def route
			@route ||= @db[:runs].where(id: @run_id).get(:route) or
				raise Mill::Error, "run #{@run_id} has no route"
		end

		def route_stages = Mill::Stages::ROUTES.fetch(route)

		def call
			@stage ||= route_stages.first
			outcome = nil
			outcome = step until TERMINAL.include?(outcome)
			outcome
		end

		def step
			@stage ||= route_stages.first
			return finish if @stage.nil?
			return halt(:blocked, "#{@stage} has used both its strikes") if @ledger.out_of_strikes?(@stage)
			return halt(:blocked, "#{@stage} hit its invocation cap") if @ledger.out_of_invocations?(@stage)

			invocation = @ledger.next_invocation(@stage)
			attempt = launch(@stage, invocation)
			launched = @stage				# settle may move it before we record
			outcome = settle(attempt, invocation)
			record(attempt, launched, invocation)
			outcome
		end

		private

		def launch(stage, invocation)
			@launcher.call(
				stage: stage, invocation: invocation,
				prompt: Mill::Prompts.for(stage, prompt_context(stage)),
				session_id: @sessions[stage]
			)
		end

		# A relaunch resumes the stage's own session so the agent remembers its
		# work. The one exception is a verdict that failed validation: mill has no
		# trustworthy account of what happened, so it starts fresh.
		def settle(attempt, invocation)
			outcome = Mill::Ledger.classify(attempt)
			@sessions[@stage] = outcome == :no_verdict ? nil : attempt.session_id

			case outcome
			when :blocked
				@ledger.charge(stage: @stage, outcome: :blocked, invocation: invocation)
				halt(:blocked, "#{@stage} asked a question", questions: attempt.verdict.questions)
			when :ok
				remember(attempt)
				reviewer?(@stage) && attempt.verdict.rejects? ? reject(attempt, invocation) : advance(invocation)
			else
				@ledger.charge(stage: @stage, outcome: outcome, invocation: invocation)
				:rerun
			end
		end

		def advance(invocation)
			@ledger.charge(stage: @stage, outcome: reviewer?(@stage) ? :reviewed_clean : :ok,
				invocation: invocation)
			@stage = Mill::Stages.next_stage(route, @stage)
			@stage.nil? ? finish : :advanced
		end

		# A reviewer that finds something serious is the reviewer succeeding: it
		# costs the reviewer nothing and strikes the stage it reviewed. One row,
		# for the launch that actually happened — the strike rides on it, attributed
		# to whoever pays. The reviewed stage's invocation is its re-launch.
		def reject(attempt, invocation)
			reviewed = Mill::Stages.reviewed_stage(route, @stage)
			@objections[reviewed] = attempt.verdict.serious_objections
			@ledger.charge(stage: @stage, outcome: :reviewed_clean, invocation: invocation,
				struck_stage: reviewed)

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

		def record(attempt, stage, invocation)
			@db[:stage_attempts].where(run_id: @run_id, stage: stage, invocation: invocation)
				.update(session_id: attempt.session_id, model: attempt.model, log_path: attempt.log_path,
					verdict_json: attempt.verdict.data.to_json, finished_at: Mill.now,
					**token_columns(attempt))
		end

		# tokens_out stays nil when an attempt was killed before its result line:
		# the stream carries no running output total, and nil means unmeasured.
		# Storing 0 would make every reaped attempt read as free. The other three
		# agree with the result line and are NOT NULL, so a missing count is 0.
		def token_columns(attempt)
			tokens = attempt.tokens
			{
				tokens_in: tokens[:tokens_in] || 0,
				cache_creation_tokens: tokens[:cache_creation_tokens] || 0,
				cache_read_tokens: tokens[:cache_read_tokens] || 0,
				tokens_out: tokens[:tokens_out]
			}
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
