require 'test_helper'

module Mill
	# Walks the graph against scripted verdicts. Never runs claude, never touches
	# the network. Every branch of the ledger is reachable from here.
	class TestRunner < Mill::TestCase
		# mill opens the pull request, so a runner walking a route that ends in one
		# needs a seam. Records what it was asked for.
		class FakeGithub
			attr_reader :created

			def initialize(fail_with: nil) = (@created = []; @fail_with = fail_with)

			def create_pull_request(repo, head:, base:, title:, body:)
				raise Mill::Github::Error, @fail_with if @fail_with

				@created << { repo: repo, head: head, base: base, title: title, body: body }
				{ number: 50 + @created.length, state: 'OPEN' }
			end
		end

		# The smallest thing shaped like a Mill::Claude::Attempt.
		def scripted(status: 'ok', valid: true, success: true, objections: [], questions: [],
			artifact: nil, session: 'sess-1', summary: 'did the thing', title: 'A title', body: 'A body',
			resume_failed: false, rate_limited: false, resets_at: nil)
			verdict = Object.new
			verdict.define_singleton_method(:valid?) { valid }
			verdict.define_singleton_method(:status) { status }
			verdict.define_singleton_method(:blocked?) { status == 'blocked' }
			verdict.define_singleton_method(:rejects?) { objections.any? }
			verdict.define_singleton_method(:serious_objections) { objections }
			verdict.define_singleton_method(:questions) { questions }
			verdict.define_singleton_method(:errors) { valid ? [] : ['no verdict'] }
			verdict.define_singleton_method(:data) do
				{ artifact: artifact, summary: summary, title: title, body: body }
			end

			stream = Object.new
			stream.define_singleton_method(:session_id) { session }
			stream.define_singleton_method(:resume_failed?) { resume_failed }
			stream.define_singleton_method(:rate_limited?) { rate_limited }
			stream.define_singleton_method(:rate_limit_resets_at) { resets_at }
			stream.define_singleton_method(:tokens) { { tokens_in: 1, tokens_out: 2 } }
			stream.define_singleton_method(:model) { 'claude-opus-5' }

			result = Object.new
			result.define_singleton_method(:success?) { success }
			result.define_singleton_method(:error) { nil }
			result.define_singleton_method(:log_path) { '/dev/null' }
			result.define_singleton_method(:stream) { stream }

			Mill::Claude::Attempt.new(stage: nil, number: nil, nonce: 'n',
				result: result, verdict: verdict)
		end

		# Scripts one reply per stage visit, in order.
		def runner_for(script, route: 'plan', github: FakeGithub.new)
			@calls = []
			@github = github
			run_id = @run_id = create_run(
				repo_id: create_repo(local_path: '/tmp/clone', base_branch: 'main'),
				route: route, branch: 'a-branch'
			)
			queue = script.dup
			launcher = lambda do |stage:, prompt:, number:, session_id:|
				@calls << { stage: stage, number: number, session_id: session_id, prompt: prompt }
				reply = queue.shift or raise "script exhausted at #{stage}"
				reply.is_a?(Proc) ? reply.call(stage) : reply
			end
			Mill::Runner.new(db: db, run_id: run_id, launcher: launcher, github: @github,
				context: { issue: 'Track low-stock items' })
		end

		def ok_for(stage)
			scripted(artifact: Mill::Stages[stage][:artifact] ? 'docs/superpowers/plans/p.md' : nil)
		end

		def clean_run = Array.new(6) { ->(stage) { ok_for(stage) } }

		# --- what a live run is doing ---------------------------------------

		# The column is what a supervisor reaping a live run reads to know which
		# stage to charge. Written only at halt, it is nil for the whole time a
		# stage is actually running, and the reaper then silently charges nothing.
		def test_the_current_stage_is_recorded_while_the_stage_is_running
			seen = []
			runner = runner_for(Array.new(6) do |i|
				lambda do |stage|
					seen << [stage, db[:runs].where(id: @run_id).get(:current_stage)]
					ok_for(stage)
				end
			end)
			runner.call

			assert_equal seen.map(&:first), seen.map(&:last)
		end

		def test_a_finished_run_is_in_no_stage
			runner_for(clean_run).call

			assert_nil db[:runs].where(id: @run_id).get(:current_stage)
		end

		# --- the happy path -------------------------------------------------

		def test_a_clean_run_walks_the_whole_plan_route
			runner = runner_for(clean_run)

			assert_equal :done, runner.call
			assert_equal Mill::Stages::ROUTES['plan'], @calls.map { |c| c[:stage] }
		end

		def test_every_stage_is_launched_as_attempt_one_on_a_clean_run
			runner_for(clean_run).call

			assert_equal [1] * 6, @calls.map { |c| c[:number] }
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
			assert_equal 1, Mill::Ledger.new(db, runner.run_id).attempts('triage')
		end

		# --- the subscription said no ---------------------------------------

		# A launch the subscription refused never ran, so it hands back no verdict —
		# which is what marks it, not the exit status. Without being classified
		# first it reads as a crash and takes a strike, charging a stage for a door
		# mill could not open. Measured live 2026-08-20.
		def test_a_rate_limited_launch_costs_no_strike
			waits = []
			runner = runner_with_pause(waits,
				[scripted(rate_limited: true, success: false, valid: false)] + clean_run)
			runner.call

			assert_equal 0, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# attempt: 0 in the ledger, so it leaves no row: nothing happened.
		def test_a_rate_limited_launch_leaves_no_attempt_behind
			waits = []
			runner = runner_with_pause(waits,
				[scripted(rate_limited: true, success: false, valid: false)] + clean_run)
			runner.call

			assert_equal 1, Mill::Ledger.new(db, runner.run_id).attempts('triage')
			assert_equal [1, 1], @calls.first(2).map { |c| c[:number] },
				'the refused launch must not consume an attempt number'
		end

		# Retrying straight away is a hot loop against a door that will not open for
		# hours, so it waits for the window the CLI named.
		def test_it_waits_for_the_window_the_cli_named
			waits = []
			resets = Mill.now + 900
			runner = runner_with_pause(waits,
				[scripted(rate_limited: true, success: false, valid: false, resets_at: resets)] + clean_run)
			runner.call

			assert_equal 1, waits.length
			assert_in_delta 900, waits.first, 5
		end

		def test_an_unknown_reset_waits_the_cap
			waits = []
			runner = runner_with_pause(waits,
				[scripted(rate_limited: true, success: false, valid: false)] + clean_run)
			runner.call

			assert_equal Mill::Ledger::MAX_RATE_LIMIT_PAUSE, waits.first
		end

		# The shape the ledger change introduced, exercised through the runner
		# rather than asserted as a classification. A clean exit with nothing
		# readable is still treated as a refusal, so it must wait rather than
		# relaunch straight away, and must leave the ledger untouched.
		def test_a_clean_exit_with_no_verdict_under_a_limit_waits_rather_than_striking
			waits = []
			runner = runner_with_pause(waits,
				[scripted(rate_limited: true, success: true, valid: false)] + clean_run)
			runner.call
			ledger = Mill::Ledger.new(db, runner.run_id)

			assert_equal 1, waits.length, 'a refusal must wait for the window, not relaunch at once'
			assert_equal 0, ledger.strikes('triage')
			assert_equal 1, ledger.attempts('triage')
		end

		def test_a_reset_already_past_still_leaves_a_minute
			assert_equal 60, Mill::Runner.rate_limit_pause(Mill.now - 500)
		end

		# Free is not unlimited. Every strike-free path has its own cap.
		def test_endless_rate_limiting_blocks_rather_than_waiting_forever
			waits = []
			refused = Array.new(Mill::Ledger::MAX_RATE_LIMIT_WAITS + 1) do
				scripted(rate_limited: true, success: false, valid: false)
			end
			runner = runner_with_pause(waits, refused)

			assert_equal :blocked, runner.call
			assert_match(/rate limited/i, runner.state[:reason])
			assert_equal 0, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# A runner whose pause is recorded rather than taken.
		def runner_with_pause(waits, script)
			runner = runner_for(script)
			runner.instance_variable_set(:@pause, ->(seconds) { waits << seconds })
			runner
		end

		# --- failure and resume ---------------------------------------------

		# A relaunch resumes the session, so the agent remembers its own work.
		def test_a_failed_stage_is_relaunched_against_its_own_session
			runner = runner_for([scripted(status: 'failed')] + clean_run)
			runner.call

			assert_equal %w[triage triage], @calls.first(2).map { |c| c[:stage] }
			assert_equal [1, 2], @calls.first(2).map { |c| c[:number] }
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
			assert_equal 2, ledger.attempts('review:plan'), 'the reviewer reviewed twice'
		end

		# Every row is one launch: a rejection must not invent an attempt for a
		# stage that has not re-run yet.
		def test_a_rejection_does_not_skip_an_attempt_number
			runner = runner_for(rejecting_run)
			runner.call
			plan_calls = @calls.select { |c| c[:stage] == 'plan' }

			assert_equal [1, 2], plan_calls.map { |c| c[:number] }
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

		# --- a session mill could not reopen ----------------------------------

		# The ledger prices a failed resume as something the machine did to the
		# stage: an attempt and no strike. It does not present as a crash — the CLI
		# exits cleanly having done nothing — so without this it read as a stage
		# that produced no verdict, and took a strike for mill's problem.
		def test_a_session_that_will_not_reopen_costs_no_strike
			runner = runner_for([scripted(resume_failed: true, valid: false)] + clean_run)
			runner.call

			assert_equal 0, Mill::Ledger.new(db, runner.run_id).strikes('triage')
			assert_equal 'resume_failed', db[:stage_attempts]
				.where(run_id: runner.run_id, stage: 'triage', number: 1).get(:status)
		end

		def test_the_stage_is_started_fresh_after_a_failed_resume
			runner = runner_for([scripted(status: 'failed'),					# strike, session kept
				scripted(resume_failed: true, valid: false),					# resume fails
				->(stage) { ok_for(stage) }] + clean_run)
			runner.call

			assert_nil @calls[0][:session_id], 'first launch is always fresh'
			assert_equal 'sess-1', @calls[1][:session_id], 'the retry resumes'
			assert_nil @calls[2][:session_id], 'after a failed resume, fresh again'
		end

		# The session held what the stage had worked out. What survives it is what
		# the stage reported, so mill hands that back.
		def test_what_the_stage_reported_before_is_handed_back
			runner = runner_for([scripted(status: 'failed', summary: 'I got halfway'),
				scripted(resume_failed: true, valid: false),
				->(stage) { ok_for(stage) }] + clean_run)
			runner.call

			assert_includes @calls[2][:prompt], 'I got halfway'
		end

		# --- the pull request -------------------------------------------------

		# The stage pushes and composes; mill makes the call, because gh cannot
		# verify TLS inside the sandbox and because this leaves one GitHub seam.
		def test_mill_opens_the_pull_request_with_what_the_stage_composed
			runner = runner_for(clean_run)
			runner.call

			assert_equal 1, @github.created.length
			opened = @github.created.first

			assert_equal 'slowernet/mill-scratch', opened[:repo]
			assert_equal 'a-branch', opened[:head]
			assert_equal 'main', opened[:base]
			assert_equal 'A title', opened[:title]
			assert_equal 'A body', opened[:body]
		end

		def test_the_pull_request_number_is_recorded_on_the_run
			runner = runner_for(clean_run)
			runner.call

			assert_equal 51, db[:runs].where(id: runner.run_id).get(:pr_number)
		end

		# A run that says done with no pull request has produced nothing, and the
		# pull request is the only thing a human ever reads.
		def test_a_run_whose_pull_request_fails_blocks_rather_than_finishing
			runner = runner_for(clean_run, github: FakeGithub.new(fail_with: 'rate limited'))
			outcome = runner.call

			assert_equal :blocked, outcome
			assert_match(/could not be opened/, runner.state[:reason])
			assert_nil db[:runs].where(id: runner.run_id).get(:pr_number)
		end

		# --- caps -----------------------------------------------------------

		# Free is not unlimited. A stage that keeps producing nothing mill can use
		# costs no strike per the ledger, but it must not loop forever either.
		def test_the_attempt_cap_stops_the_runner_not_just_the_ledger
			runner = runner_for(Array.new(20) { scripted(status: 'blocked', questions: ['?']) })

			# Blocking halts on the first one, so drive the free path that repeats:
			# an interrupted attempt costs an number and no strike.
			ledger = Mill::Ledger.new(db, runner.run_id)
			(Mill::Ledger::MAX_ATTEMPTS).times { ledger.charge(stage: 'triage', outcome: :interrupted) }

			assert_equal :blocked, runner.call
			assert_match(/number cap/i, runner.state[:reason])
			assert_empty @calls, 'a stage at its cap must not be launched again'
		end

		# Two strikes stop a stage well before the number cap does, so the cap
		# is only reachable on the paths that cost nothing.
		def test_strikes_stop_a_stage_before_the_attempt_cap_can
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
