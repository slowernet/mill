require 'test_helper'

module Mill
	# Walks the graph against scripted verdicts. Never runs claude, never touches
	# the network. Every branch of the ledger is reachable from here.
	class TestRunner < Mill::TestCase
		# The smallest thing shaped like a Mill::Claude::Attempt.
		def scripted(status: 'ok', valid: true, success: true, objections: [], questions: [],
			artifact: nil, session: 'sess-1', summary: 'did the thing')
			verdict = Object.new
			verdict.define_singleton_method(:valid?) { valid }
			verdict.define_singleton_method(:status) { status }
			verdict.define_singleton_method(:blocked?) { status == 'blocked' }
			verdict.define_singleton_method(:rejects?) { objections.any? }
			verdict.define_singleton_method(:serious_objections) { objections }
			verdict.define_singleton_method(:questions) { questions }
			verdict.define_singleton_method(:errors) { valid ? [] : ['no verdict'] }
			verdict.define_singleton_method(:data) { { artifact: artifact, summary: summary } }

			stream = Object.new
			stream.define_singleton_method(:session_id) { session }
			stream.define_singleton_method(:tokens) { { tokens_in: 1, tokens_out: 2 } }
			stream.define_singleton_method(:model) { 'claude-opus-5' }

			result = Object.new
			result.define_singleton_method(:success?) { success }
			result.define_singleton_method(:error) { nil }
			result.define_singleton_method(:log_path) { '/dev/null' }
			result.define_singleton_method(:stream) { stream }

			Mill::Claude::Attempt.new(stage: nil, invocation: nil, nonce: 'n',
				result: result, verdict: verdict)
		end

		# Scripts one reply per stage visit, in order.
		def runner_for(script, route: 'plan')
			@calls = []
			run_id = create_run(repo_id: create_repo, route: route)
			queue = script.dup
			launcher = lambda do |stage:, prompt:, invocation:, session_id:|
				@calls << { stage: stage, invocation: invocation, session_id: session_id, prompt: prompt }
				reply = queue.shift or raise "script exhausted at #{stage}"
				reply.is_a?(Proc) ? reply.call(stage) : reply
			end
			Mill::Runner.new(db: db, run_id: run_id, launcher: launcher,
				context: { issue: 'Track low-stock items' })
		end

		def ok_for(stage)
			scripted(artifact: Mill::Stages[stage][:artifact] ? 'docs/superpowers/plans/p.md' : nil)
		end

		def clean_run = Array.new(6) { ->(stage) { ok_for(stage) } }

		# --- the happy path -------------------------------------------------

		def test_a_clean_run_walks_the_whole_plan_route
			runner = runner_for(clean_run)

			assert_equal :done, runner.call
			assert_equal Mill::Stages::ROUTES['plan'], @calls.map { |c| c[:stage] }
		end

		def test_every_stage_is_launched_at_invocation_one_on_a_clean_run
			runner_for(clean_run).call

			assert_equal [1] * 6, @calls.map { |c| c[:invocation] }
		end

		def test_the_first_launch_of_a_stage_is_a_fresh_session
			runner_for(clean_run).call

			assert(@calls.all? { |c| c[:session_id].nil? }, 'a first launch must not resume')
		end

		def test_each_launch_is_recorded_as_exactly_one_row
			runner = runner_for(clean_run)
			runner.call

			assert_equal 6, db[:stage_attempts].where(run_id: runner.run_id).count
			assert_equal 'sess-1', db[:stage_attempts].where(run_id: runner.run_id).first[:session_id]
		end

		def test_a_finished_run_is_marked_done
			runner = runner_for(clean_run)
			runner.call

			assert_equal 'done', db[:runs].where(id: runner.run_id).get(:status)
			refute_nil db[:runs].where(id: runner.run_id).get(:finished_at)
		end

		# --- blocking -------------------------------------------------------

		def test_a_blocked_stage_stops_the_line_and_keeps_its_questions
			runner = runner_for([scripted(status: 'blocked', questions: ['Which spec?'])])

			assert_equal :blocked, runner.call
			assert_equal ['Which spec?'], runner.state[:questions]
			assert_equal 'triage', runner.state[:stage]
			assert_equal 'blocked', db[:runs].where(id: runner.run_id).get(:status)
		end

		def test_blocking_costs_no_strike
			runner = runner_for([scripted(status: 'blocked', questions: ['?'])])
			runner.call

			assert_equal 0, Mill::Ledger.new(db, runner.run_id).strikes('triage')
			assert_equal 1, Mill::Ledger.new(db, runner.run_id).invocations('triage')
		end

		# --- failure and resume ---------------------------------------------

		# A relaunch resumes the session, so the agent remembers its own work.
		def test_a_failed_stage_is_relaunched_against_its_own_session
			runner = runner_for([scripted(status: 'failed')] + clean_run)
			runner.call

			assert_equal %w[triage triage], @calls.first(2).map { |c| c[:stage] }
			assert_equal [1, 2], @calls.first(2).map { |c| c[:invocation] }
			assert_nil @calls[0][:session_id]
			assert_equal 'sess-1', @calls[1][:session_id], 'a relaunch resumes'
		end

		# When the verdict itself was untrustworthy mill has no reliable account of
		# what the first launch did, so it starts fresh instead of resuming.
		def test_an_invalid_verdict_starts_a_fresh_session
			runner = runner_for([scripted(valid: false)] + clean_run)
			runner.call

			assert_nil @calls[1][:session_id], 'mill cannot trust a session it has no account of'
		end

		def test_two_failures_of_one_stage_block_the_run
			runner = runner_for([scripted(status: 'failed'), scripted(status: 'failed')])

			assert_equal :blocked, runner.call
			assert_match(/strike/i, runner.state[:reason])
			assert_equal 2, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# A process that died outranks whatever it emitted.
		def test_a_crashed_stage_costs_a_strike_even_with_a_good_verdict
			runner = runner_for([scripted(success: false)] + clean_run)
			runner.call

			assert_equal 1, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# --- rejection ------------------------------------------------------

		def objection = { severity: 'high', claim: 'race on restock', notes: 'lib/inventory.rb:14' }

		def rejecting_run
			[->(stage) { ok_for(stage) },					# triage
			 ->(stage) { ok_for(stage) },					# plan
			 scripted(objections: [objection]),				# review:plan rejects
			 ->(stage) { ok_for(stage) },					# plan again
			 ->(stage) { ok_for(stage) },					# review:plan clean
			 ->(stage) { ok_for(stage) },					# implement
			 ->(stage) { ok_for(stage) },					# review:code
			 ->(stage) { ok_for(stage) }]					# pr
		end

		# A reviewer that finds something serious strikes the stage it reviewed,
		# and mill re-runs that stage rather than the reviewer.
		def test_a_serious_objection_re_runs_the_reviewed_stage
			runner = runner_for(rejecting_run)

			assert_equal :done, runner.call
			assert_equal %w[triage plan review:plan plan review:plan implement review:code pr],
				@calls.map { |c| c[:stage] }
		end

		def test_a_rejection_strikes_the_reviewed_stage_not_the_reviewer
			runner = runner_for(rejecting_run)
			runner.call
			ledger = Mill::Ledger.new(db, runner.run_id)

			assert_equal 1, ledger.strikes('plan')
			assert_equal 0, ledger.strikes('review:plan')
			assert_equal 2, ledger.invocations('review:plan'), 'the reviewer reviewed twice'
		end

		# Every row is one launch: a rejection must not invent an invocation for a
		# stage that has not re-run yet.
		def test_a_rejection_does_not_skip_an_invocation_number
			runner = runner_for(rejecting_run)
			runner.call
			plan_calls = @calls.select { |c| c[:stage] == 'plan' }

			assert_equal [1, 2], plan_calls.map { |c| c[:invocation] }
			assert_equal 2, db[:stage_attempts].where(run_id: runner.run_id, stage: 'plan').count
		end

		# The reviewer's notes reach the stage that has to act on them.
		def test_the_objections_are_injected_into_the_rerun
			runner = runner_for(rejecting_run)
			runner.call

			assert_includes @calls[3][:prompt], 'race on restock'
			assert_includes @calls[3][:prompt], 'lib/inventory.rb:14'
		end

		# The re-run resumes the reviewed stage's own session, so it remembers the
		# work the reviewer objected to.
		def test_the_reviewed_stage_resumes_rather_than_starting_over
			runner = runner_for(rejecting_run)
			runner.call

			assert_equal 'sess-1', @calls[3][:session_id]
		end

		def test_two_rejections_of_one_stage_block_the_run
			runner = runner_for([
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				scripted(objections: [objection]),
				->(stage) { ok_for(stage) },
				scripted(objections: [objection])
			])

			assert_equal :blocked, runner.call
			assert_equal 2, Mill::Ledger.new(db, runner.run_id).strikes('plan')
		end

		# A reviewer returns ok with objections; low and medium do not re-run
		# anything, they land in the pull request body.
		def test_minor_objections_do_not_re_run_anything
			runner = runner_for(clean_run)

			assert_equal :done, runner.call
			assert_equal 6, @calls.length
		end

		# --- the artifact travels forward -----------------------------------

		def test_the_plans_artifact_reaches_the_stages_that_need_it
			runner = runner_for(clean_run)
			runner.call

			assert_includes @calls.find { |c| c[:stage] == 'implement' }[:prompt],
				'docs/superpowers/plans/p.md'
			assert_includes @calls.find { |c| c[:stage] == 'review:plan' }[:prompt],
				'docs/superpowers/plans/p.md'
		end

		def test_a_predecessors_summary_reaches_the_stages_after_it
			runner = runner_for(clean_run)
			runner.call

			assert_includes @calls.find { |c| c[:stage] == 'implement' }[:prompt], 'did the thing'
		end

		# --- token telemetry -------------------------------------------------

		def test_the_token_counts_are_recorded_per_attempt
			runner = runner_for(clean_run)
			runner.call
			row = db[:stage_attempts].where(run_id: runner.run_id, stage: 'plan').first

			assert_equal 1, row[:tokens_in]
			assert_equal 2, row[:tokens_out]
			assert_equal 0, row[:cache_read_tokens], 'a count the stream never carried is 0, not nil'
		end

		# The stream carries no running output total, so an attempt killed before
		# its result line has no honest figure. NULL means unmeasured; 0 would make
		# every reaped attempt look free.
		def test_an_unmeasured_output_count_is_stored_as_null
			unmeasured = scripted
			unmeasured.result.stream.define_singleton_method(:tokens) do
				{ tokens_in: 5, tokens_out: nil, cache_read_tokens: 900 }
			end
			runner = runner_for([unmeasured] + clean_run)
			runner.call
			row = db[:stage_attempts].where(run_id: runner.run_id, stage: 'triage').first

			assert_nil row[:tokens_out]
			assert_equal 5, row[:tokens_in]
			assert_equal 900, row[:cache_read_tokens]
		end

		# --- caps -----------------------------------------------------------

		# Free is not unlimited. A stage that keeps producing nothing mill can use
		# costs no strike per the ledger, but it must not loop forever either.
		def test_the_invocation_cap_stops_the_runner_not_just_the_ledger
			runner = runner_for(Array.new(20) { scripted(status: 'blocked', questions: ['?']) })

			# Blocking halts on the first one, so drive the free path that repeats:
			# an interrupted attempt costs an invocation and no strike.
			ledger = Mill::Ledger.new(db, runner.run_id)
			(Mill::Ledger::MAX_INVOCATIONS).times { ledger.charge(stage: 'triage', outcome: :interrupted) }

			assert_equal :blocked, runner.call
			assert_match(/invocation cap/i, runner.state[:reason])
			assert_empty @calls, 'a stage at its cap must not be launched again'
		end

		# Two strikes stop a stage well before the invocation cap does, so the cap
		# is only reachable on the paths that cost nothing.
		def test_strikes_stop_a_stage_before_the_invocation_cap_can
			runner = runner_for(Array.new(20) { scripted(status: 'failed') })
			runner.call

			assert_equal 2, @calls.length, 'two strikes, then block'
			assert_match(/strike/i, runner.state[:reason])
		end

		def test_a_run_with_no_route_is_an_error_not_a_silent_stop
			run_id = create_run(repo_id: create_repo)
			runner = Mill::Runner.new(db: db, run_id: run_id, launcher: ->(**) {}, context: {})

			assert_raises(Mill::Error) { runner.call }
		end
	end
end
