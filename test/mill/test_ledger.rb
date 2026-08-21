require 'test_helper'

module Mill
	# One case per row of the spec's cost table. This is the control plane every
	# other subsystem routes its failures into, and its rules were the least
	# pinned-down part of the design, so it gets the most direct test in the suite.
	class TestLedger < Mill::TestCase
		def setup
			super
			@run = create_run(repo_id: create_repo, route: 'plan')
			@ledger = Mill::Ledger.new(db, @run)
		end

		# The smallest thing shaped like a Mill::Claude::Attempt.
		def attempt(status: 'ok', valid: true, success: true, resume_failed: false,
			rate_limited: false)
			verdict = Object.new
			verdict.define_singleton_method(:valid?) { valid }
			verdict.define_singleton_method(:status) { status }
			result = Object.new
			result.define_singleton_method(:success?) { success }
			Struct.new(:verdict, :result, :resume_failed?, :rate_limited?)
				.new(verdict, result, resume_failed, rate_limited)
		end

		# A launch the subscription refused never ran, so classified after :crashed
		# it would take a strike for a door mill could not open — measured live
		# 2026-08-20, when a five-hour window closed mid-run.
		#
		# What marks it is the empty verdict, not the exit status: with no result
		# line there is no payload, so Verdict.validate fails it. Nothing here has
		# measured what such a launch exits with, which is why these fixtures no
		# longer claim one.
		def test_a_refused_launch_is_rate_limited_not_crashed
			assert_equal :rate_limited,
				Mill::Ledger.classify(attempt(success: false, valid: false, rate_limited: true))
		end

		def test_a_rate_limited_launch_costs_neither_an_attempt_nor_a_strike
			assert_equal({ attempt: 0, strike: 0 }, Mill::Ledger::COST[:rate_limited])
		end

		# The limit outranks a session that would not reopen: mill never got far
		# enough to try the session. Neither refusal produces a verdict.
		def test_the_limit_outranks_a_failed_resume
			assert_equal :rate_limited,
				Mill::Ledger.classify(attempt(success: false, valid: false, rate_limited: true,
					resume_failed: true))
		end

		# rate_limited? reports the last rate-limit event the stream saw, not the
		# fate of the launch: an "allowed" heartbeat clears it, and a refusal sets
		# it again. A stage refused at minute 2, that then got its launch, exited
		# 0 and returned a valid verdict, still carries the flag whenever the
		# result line arrives before the next heartbeat could clear it. Reading
		# the flag as "this launch was refused" throws that finished work away,
		# and charges no attempt — so the relaunch reuses the log filename and
		# overwrites the log of the run that succeeded.
		def test_a_throttled_stage_that_still_finished_keeps_its_work
			assert_equal :ok, Mill::Ledger.classify(attempt(success: true, rate_limited: true))
		end

		# PINS A KNOWN-BAD STATE. Delete this and re-price it when the row-insertion
		# fix lands; it is here so the behaviour is visible rather than merely
		# absent, not because it is right.
		#
		# A launch that ran, hit the window partway, and handed back nothing looks
		# from here exactly like one that was refused outright, so it is priced as
		# a refusal: no row, no attempt number, and therefore the relaunch reuses
		# the log filename and truncates the log of the twenty minutes that did
		# happen. The session goes with it — `reload` rebuilds `@sessions` from
		# `stage_attempts`, and there is no row to rebuild from.
		#
		# Charging it a strike instead is not the answer either: nothing measures
		# what a refusal exits with, and charging on an unproven premise is how a
		# stage gets blocked for a door mill could not open. The fix is to tell the
		# two apart from the stream — a session id, a model, any turns at all —
		# and price a launch that happened as an attempt that cost no strike.
		#
		# Note the wait cap is no comfort here: `@rate_limit_waits` lives on the
		# Runner instance, so a restarted or resumed run starts counting again with
		# nothing in the database to reconstruct it from.
		def test_a_throttled_stage_that_did_work_and_said_nothing_is_priced_as_a_refusal
			assert_equal :rate_limited,
				Mill::Ledger.classify(attempt(success: true, rate_limited: true, valid: false))
		end

		# The one combination this change re-priced upward, pinned so the decision
		# is visible. A readable verdict means the stage produced something, so the
		# limit is not what stopped it, and a non-zero exit on top of that is a
		# crash like any other. Thin on the ground — it needs a valid result line
		# and a bad exit and a still-rejected limit — and if it turns out to be
		# reachable in a way that is mill's fault rather than the stage's, this is
		# the test that should argue about it.
		def test_a_readable_verdict_with_a_bad_exit_is_a_crash_even_under_a_limit
			assert_equal :crashed,
				Mill::Ledger.classify(attempt(success: false, valid: true, rate_limited: true))
		end

		# --- classification -------------------------------------------------

		def test_a_clean_stage_is_ok
			assert_equal :ok, Mill::Ledger.classify(attempt)
		end

		def test_a_blocked_stage_is_blocked
			assert_equal :blocked, Mill::Ledger.classify(attempt(status: 'blocked'))
		end

		def test_a_stage_reporting_failed_is_failed
			assert_equal :failed, Mill::Ledger.classify(attempt(status: 'failed'))
		end

		def test_an_invalid_verdict_is_no_verdict
			assert_equal :no_verdict, Mill::Ledger.classify(attempt(valid: false))
		end

		# A process that died outranks whatever it managed to emit: mill has no
		# trustworthy account of what happened either way.
		def test_a_dead_process_is_crashed_whatever_it_said
			assert_equal :crashed, Mill::Ledger.classify(attempt(success: false))
			assert_equal :crashed, Mill::Ledger.classify(attempt(status: 'ok', success: false))
		end

		# A session the CLI will not reopen exits cleanly having done nothing, so it
		# looks like neither a crash nor a bad verdict. It is checked first because
		# it is the only one of the three the stage did not cause.
		def test_a_session_that_will_not_reopen_is_not_the_stage_failing
			assert_equal :resume_failed, Mill::Ledger.classify(attempt(resume_failed: true, valid: false))
			assert_equal :resume_failed, Mill::Ledger.classify(attempt(resume_failed: true, success: false))
		end

		# --- the cost table, one case per row -------------------------------

		def test_bad_work_costs_a_strike
			%i[failed crashed no_verdict artifact_bad].each do |outcome|
				cost = Mill::Ledger::COST.fetch(outcome)

				assert_equal 1, cost[:attempt], "#{outcome} must count as a launch"
				assert_equal 1, cost[:strike], "#{outcome} is the stage's own work being wrong"
			end
		end

		# A rejection strikes the reviewed stage now; the attempt it owes is its
		# re-launch, which has not happened yet. Counting one here would name a log
		# file nothing ever wrote and make the next real launch attempt 3.
		def test_a_rejection_strikes_without_counting_a_launch
			cost = Mill::Ledger::COST.fetch(:rejected)

			assert_equal 0, cost[:attempt]
			assert_equal 1, cost[:strike]
		end

		# A strike means the work was wrong. Everything the machine did is free.
		def test_everything_the_machine_did_is_free
			%i[blocked reviewed_clean stall_recovery resume_failed interrupted].each do |outcome|
				cost = Mill::Ledger::COST.fetch(outcome)

				assert_equal 1, cost[:attempt], "#{outcome} still names a log and a verdict"
				assert_equal 0, cost[:strike], "#{outcome} was not the stage failing"
			end
		end

		def test_waiting_behind_a_rate_limit_is_not_a_launch_at_all
			assert_equal 0, Mill::Ledger::COST.fetch(:rate_limited)[:attempt]
			assert_equal 0, Mill::Ledger::COST.fetch(:rate_limited)[:strike]
		end

		# --- accounting -----------------------------------------------------

		def test_the_attempt_number_rises_on_every_launch
			assert_equal 1, @ledger.next_attempt('plan')
			@ledger.charge(stage: 'plan', outcome: :blocked)

			assert_equal 2, @ledger.next_attempt('plan')
			@ledger.charge(stage: 'plan', outcome: :failed)

			assert_equal 3, @ledger.next_attempt('plan')
		end

		def test_strikes_rise_only_on_bad_work
			3.times { @ledger.charge(stage: 'plan', outcome: :blocked) }

			assert_equal 0, @ledger.strikes('plan')
			assert_equal 3, @ledger.attempts('plan')
		end

		def test_two_strikes_stops_the_stage
			@ledger.charge(stage: 'plan', outcome: :failed)

			refute @ledger.out_of_strikes?('plan')

			@ledger.charge(stage: 'plan', outcome: :failed)

			assert @ledger.out_of_strikes?('plan')
		end

		# The case the old one-number rules could not express: a reviewer that
		# crashes, then reviews cleanly, then reviews again after a fix.
		def test_a_reviewer_that_crashes_then_reviews_twice
			@ledger.charge(stage: 'review:code', outcome: :crashed)
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean)
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean)

			assert_equal 3, @ledger.attempts('review:code'), 'three distinct launches'
			assert_equal 1, @ledger.strikes('review:code'), 'only the crash was the reviewer failing'
			refute @ledger.out_of_strikes?('review:code')
			assert_equal 3, db[:stage_attempts].where(run_id: @run, stage: 'review:code').count
		end

		# A reviewer that finds something serious strikes the stage it reviewed,
		# not itself — and the row belongs to the reviewer, because the reviewer is
		# the one that launched.
		def test_a_rejection_strikes_the_reviewed_stage
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement')

			assert_equal 1, @ledger.strikes('implement')
			assert_equal 0, @ledger.strikes('review:code')
		end

		# Every row is one launch. A rejection must not invent an attempt for a
		# stage that has not run again yet.
		def test_a_rejection_does_not_invent_an_attempt
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement')

			assert_equal 0, @ledger.attempts('implement'), 'no launch happened, so no row'
			assert_equal 1, @ledger.next_attempt('implement'), 'the re-launch is attempt 1'
			assert_equal 1, db[:stage_attempts].where(run_id: @run).count
		end

		# Two serious objections against one stage means it has used both strikes,
		# and the run blocks — before the second re-launch, not after it.
		def test_two_rejections_use_both_strikes
			2.times { @ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement') }

			assert @ledger.out_of_strikes?('implement')
		end

		def test_free_paths_are_still_bounded
			8.times { @ledger.charge(stage: 'plan', outcome: :blocked) }

			assert @ledger.out_of_attempts?('plan'), 'nothing may loop forever, even for free'
		end

		def test_interruptions_are_capped_separately
			3.times { @ledger.charge(stage: 'plan', outcome: :interrupted) }

			assert_equal 0, @ledger.strikes('plan')
			assert @ledger.out_of_interruptions?('plan')
		end

		def test_an_unknown_outcome_raises_rather_than_costing_nothing
			assert_raises(Mill::Error) { @ledger.charge(stage: 'plan', outcome: :made_up) }
		end

		# --- the one sanctioned third strike --------------------------------

		def test_answering_resets_a_stage_once_per_run
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }

			assert @ledger.out_of_strikes?('plan')
			assert @ledger.reset_available?('plan')

			@ledger.reset!('plan')

			refute @ledger.out_of_strikes?('plan')
			assert_equal 0, @ledger.strikes('plan')
			assert_equal 2, @ledger.attempts('plan'), 'a reset forgives strikes, not history'
		end

		# A reset has to forgive strikes charged from someone else's row too.
		def test_a_reset_forgives_strikes_charged_by_a_reviewer
			2.times { @ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement') }
			@ledger.reset!('implement')

			assert_equal 0, @ledger.strikes('implement')
			refute @ledger.out_of_strikes?('implement')
			assert_equal 2, @ledger.attempts('review:code'), 'the reviewer still reviewed twice'
		end

		def test_a_stage_may_only_be_reset_once
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }
			@ledger.reset!('plan')
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }

			assert @ledger.out_of_strikes?('plan')
			refute @ledger.reset_available?('plan'), 'the second time out is terminal'
			assert_raises(Mill::Error) { @ledger.reset!('plan') }
		end

		# The reset is per stage, so a run is never trapped by one it spent earlier.
		def test_a_reset_spent_on_one_stage_leaves_another_entitled
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }
			@ledger.reset!('plan')
			2.times { @ledger.charge(stage: 'implement', outcome: :failed) }

			assert @ledger.reset_available?('implement')
		end
	end
end
