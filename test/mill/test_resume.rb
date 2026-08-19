require 'test_helper'
require 'json'

module Mill
	# Answering a blocked run. The stage's own session is resumed with the answer
	# injected, so it keeps everything it had worked out — nothing restarts.
	class TestResume < Mill::TestCase
		def setup
			super
			@run = create_run(repo_id: create_repo(local_path: '/tmp/c', base_branch: 'main'),
				route: 'plan', status: 'blocked', current_stage: 'pr', branch: 'b')
			@calls = []
		end

		# A run that got to `pr` and blocked there, as it would be on disk.
		def blocked_at(stage, questions: ['Which one?'], status: 'blocked')
			Mill::Stages::ROUTES['plan'].each do |name|
				break if Mill::Stages::ROUTES['plan'].index(name) > Mill::Stages::ROUTES['plan'].index(stage)

				last = name == stage
				verdict = { stage: name, status: last ? status : 'ok' }
				verdict[:questions] = questions if last && status == 'blocked'
				verdict[:artifact] = 'docs/superpowers/plans/p.md' if name == 'plan'
				db[:stage_attempts].insert(run_id: @run, stage: name, number: 1, nonce: 'n',
					status: last ? status : 'ok', session_id: "sess-#{Mill::Stages.slug(name)}",
					verdict_json: verdict.to_json, started_at: Mill.now)
			end
			db[:runs].where(id: @run).update(current_stage: stage)
		end

		FakeGithub = Class.new do
			def create_pull_request(*, **) = { number: 7, state: 'OPEN' }
		end

		def scripted(stage, status: 'ok', questions: [])
			verdict = Object.new
			artifact = Mill::Stages[stage][:artifact] ? 'docs/superpowers/plans/p.md' : nil
			verdict.define_singleton_method(:valid?) { true }
			verdict.define_singleton_method(:status) { status }
			verdict.define_singleton_method(:rejects?) { false }
			verdict.define_singleton_method(:questions) { questions }
			verdict.define_singleton_method(:data) do
				{ artifact: artifact, summary: 'done', title: 'T', body: 'B' }
			end
			stream = Object.new
			stream.define_singleton_method(:session_id) { "sess-#{Mill::Stages.slug(stage)}" }
			stream.define_singleton_method(:tokens) { { tokens_in: 1, tokens_out: 2 } }
			stream.define_singleton_method(:model) { 'm' }
			result = Object.new
			result.define_singleton_method(:success?) { true }
			result.define_singleton_method(:log_path) { '/dev/null' }
			result.define_singleton_method(:stream) { stream }
			Mill::Claude::Attempt.new(stage: stage, number: 1, nonce: 'n', result: result, verdict: verdict)
		end

		def runner(answers: [], &script)
			launcher = lambda do |stage:, prompt:, number:, session_id:|
				@calls << { stage: stage, number: number, session_id: session_id, prompt: prompt }
				(script || ->(s) { scripted(s) }).call(stage)
			end
			Mill::Runner.new(db: db, run_id: @run, launcher: launcher, github: FakeGithub.new,
				context: { issue: 'x', answers: answers }).restore
		end

		# --- restoring what the first walk knew --------------------------------

		def test_a_restored_run_re_enters_the_stage_that_blocked
			blocked_at('pr')
			runner.call

			assert_equal 'pr', @calls.first[:stage], 'answering resumes the blocked stage, not the route'
		end

		def test_it_does_not_re_run_the_stages_that_already_passed
			blocked_at('pr')
			runner.call

			assert_equal %w[pr], @calls.map { |c| c[:stage] }
			assert_equal 1, db[:stage_attempts].where(stage: 'triage').count, 'triage must not run twice'
		end

		# The whole point of resume: the agent wakes up remembering its own work.
		def test_the_blocked_stage_resumes_its_own_session
			blocked_at('pr')
			runner.call

			assert_equal 'sess-pr', @calls.first[:session_id]
		end

		def test_the_relaunch_is_the_next_attempt_not_the_first
			blocked_at('pr')
			runner.call

			assert_equal 2, @calls.first[:number]
			assert_equal 2, db[:stage_attempts].where(run_id: @run, stage: 'pr').count
		end

		# Blocking is free, and answering does not make it retrospectively costly.
		def test_answering_costs_an_attempt_and_no_strike
			blocked_at('pr')
			runner.call

			assert_equal 0, Mill::Ledger.new(db, @run).strikes('pr')
		end

		def test_the_answer_reaches_the_stage
			blocked_at('pr')
			runner(answers: ['Egress is open now. Keep the body as composed.']).call

			assert_includes @calls.first[:prompt], 'Egress is open now'
		end

		# An earlier stage's artifact has to survive the restore, or the resumed
		# stage is handed nothing where the first walk had a plan.
		def test_the_plans_artifact_survives_the_restore
			blocked_at('review:code')
			runner.call

			assert_includes @calls.first[:prompt], 'docs/superpowers/plans/p.md'
		end

		def test_the_run_finishes_the_rest_of_the_route
			blocked_at('implement')
			runner.call

			assert_equal %w[implement review:code pr], @calls.map { |c| c[:stage] }
			assert_equal 'done', db[:runs].where(id: @run).get(:status)
		end

		def test_a_stage_that_blocks_again_blocks_again
			blocked_at('pr')
			outcome = runner { |s| scripted(s, status: 'blocked', questions: ['Still stuck']) }.call

			assert_equal :blocked, outcome
			assert_equal 2, db[:stage_attempts].where(run_id: @run, stage: 'pr').count
			assert_equal 0, Mill::Ledger.new(db, @run).strikes('pr'), 'asking twice is still free'
		end

		# --- the one sanctioned third strike ------------------------------------

		# A run blocked because a stage ran out of strikes resumes differently:
		# answering resets that stage's count, once per run.
		def test_answering_a_strikes_block_resets_that_stage
			db[:stage_attempts].insert(run_id: @run, stage: 'plan', number: 1, nonce: 'n',
				status: 'failed', strike_charged: true, started_at: Mill.now)
			db[:stage_attempts].insert(run_id: @run, stage: 'plan', number: 2, nonce: 'n',
				status: 'failed', strike_charged: true, started_at: Mill.now)
			db[:runs].where(id: @run).update(current_stage: 'plan')

			assert Mill::Ledger.new(db, @run).out_of_strikes?('plan')

			runner(answers: ['Try it this way instead.']).call

			assert_equal 0, Mill::Ledger.new(db, @run).strikes('plan'), 'answering forgives the strikes'
			assert_equal 'plan', @calls.first[:stage]
		end

		def test_a_stage_may_only_be_rescued_once
			2.times do |i|
				db[:stage_attempts].insert(run_id: @run, stage: 'plan', number: i + 1, nonce: 'n',
					status: 'failed', strike_charged: true, started_at: Mill.now)
			end
			db[:runs].where(id: @run).update(current_stage: 'plan',
				strike_resets_json: ['plan'].to_json)

			outcome = runner(answers: ['Again?']).call

			assert_equal :failed, outcome, 'a second time out is terminal'
			assert_empty @calls, 'nothing is relaunched'
			assert_equal 'failed', db[:runs].where(id: @run).get(:status)
		end

		# --- refusing to resume what cannot be resumed --------------------------

		def test_a_run_that_is_not_blocked_is_not_resumed
			db[:runs].where(id: @run).update(status: 'running')
			blocked_at('pr')

			assert_raises(Mill::Error) { runner.call }
		end
	end
end
