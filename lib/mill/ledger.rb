require 'json'

module Mill
	# The single definition of what an attempt is and who pays for one. Every
	# recovery path in mill ends here.
	#
	# mill counts two separate things. The invocation number counts how many times
	# mill has launched a stage during a run; it goes up on every launch without
	# exception, and it names the log file and the verdict file. The strike count
	# is the two-strikes rule, and it goes up only when the stage's own work was bad.
	#
	# Keeping them apart is what makes the ordinary case expressible: a reviewer
	# that crashes, gets relaunched, finds a real problem, and reviews again is on
	# invocation 3 with one strike, which is exactly the truth.
	#
	# **Every row in stage_attempts is exactly one launch.** That is what lets the
	# invocation number name a file. A rejection therefore inserts no row for the
	# stage it strikes — there was no launch, so there is no log and no verdict —
	# and rides on the reviewer's row instead, through `struck_stage`.
	class Ledger
		MAX_STRIKES = 2
		MAX_INVOCATIONS = 8
		MAX_INTERRUPTIONS = 3

		# A strike means the work was wrong. Everything the machine did to a stage
		# is free — a laptop that slept, a socket that died, a lock file left by a
		# SIGKILL, and mill restarting are mill's problems, not the stage's, and
		# charging for them produces a run that dies for a reason nobody can
		# reconstruct from the log.
		COST = {
			failed: { invocation: 1, strike: 1 },
			crashed: { invocation: 1, strike: 1 },
			no_verdict: { invocation: 1, strike: 1 },
			artifact_bad: { invocation: 1, strike: 1 },
			# The strike lands now; the invocation it owes is the re-launch itself,
			# which inserts its own row. See the row-per-launch note above.
			rejected: { invocation: 0, strike: 1 },
			ok: { invocation: 1, strike: 0 },
			blocked: { invocation: 1, strike: 0 },
			reviewed_clean: { invocation: 1, strike: 0 },
			stall_recovery: { invocation: 1, strike: 0 },
			resume_failed: { invocation: 1, strike: 0 },
			interrupted: { invocation: 1, strike: 0 },
			rate_limited: { invocation: 0, strike: 0 }
		}.freeze

		# A process that died outranks whatever it managed to emit: mill has no
		# trustworthy account of what happened either way.
		def self.classify(attempt)
			return :crashed unless attempt.result.success?
			return :no_verdict unless attempt.verdict.valid?

			case attempt.verdict.status
			when 'ok' then :ok
			when 'blocked' then :blocked
			else :failed
			end
		end

		def initialize(db, run_id)
			@db = db
			@run_id = run_id
		end

		def attempts(stage) = @db[:stage_attempts].where(run_id: @run_id, stage: stage)

		def invocations(stage) = attempts(stage).count

		# A stage is struck either by its own bad work, or by a reviewer that found
		# something serious in it. The second is recorded on the reviewer's row,
		# because that is the row belonging to a launch that actually happened.
		def strikes(stage)
			attempts(stage).where(strike_charged: true).count +
				@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).count
		end

		def interruptions(stage) = attempts(stage).where(status: 'interrupted').count

		def next_invocation(stage) = invocations(stage) + 1

		# Records one launch and returns what it cost. A rejection is charged as
		# `charge(stage: reviewer, outcome: :reviewed_clean, struck_stage: reviewed)`
		# — one row, one launch, the strike attributed to whoever pays.
		def charge(stage:, outcome:, invocation: nil, **columns)
			cost = COST.fetch(outcome) { raise Mill::Error, "unknown outcome: #{outcome}" }
			return cost if cost[:invocation].zero?

			@db[:stage_attempts].insert(
				run_id: @run_id, stage: stage, invocation: invocation || next_invocation(stage),
				nonce: columns.delete(:nonce) || '', status: outcome.to_s,
				strike_charged: cost[:strike].positive?, started_at: Mill.now, **columns
			)
			cost
		end

		def out_of_strikes?(stage) = strikes(stage) >= MAX_STRIKES

		def out_of_invocations?(stage) = invocations(stage) >= MAX_INVOCATIONS

		def out_of_interruptions?(stage) = interruptions(stage) >= MAX_INTERRUPTIONS

		# The one sanctioned third strike. When a stage runs out, mill blocks and
		# asks; answering resets that stage's count. Each stage may be reset once
		# per run, so a run is never trapped by a reset it spent on some earlier
		# stage — which is why this is a list of stage names and not one column.
		def reset_available?(stage) = !resets.include?(stage)

		def reset!(stage)
			raise Mill::Error, "#{stage} has already used its reset" unless reset_available?(stage)

			@db[:runs].where(id: @run_id).update(strike_resets_json: (resets + [stage]).to_json)
			@db[:stage_attempts].where(run_id: @run_id, stage: stage, strike_charged: true)
				.update(strike_charged: false)
			@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).update(struck_stage: nil)
		end

		def resets
			row = @db[:runs].where(id: @run_id).get(:strike_resets_json)
			row ? JSON.parse(row) : []
		end
	end
end
