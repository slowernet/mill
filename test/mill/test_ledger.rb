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
		def attempt(status: 'ok', valid: true, success: true, resume_failed: false)
			verdict = Object.new
			verdict.define_singleton_method(:valid?) { valid }
			verdict.define_singleton_method(:status) { status }
			result = Object.new
			result.define_singleton_method(:success?) { success }
			Struct.new(:verdict, :result, :resume_failed?).new(verdict, result, resume_failed)
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
