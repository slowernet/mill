require 'json'

module Mill
	# The single definition of what an attempt is and who pays for one. Every
	# recovery path in mill ends here.
	#
	# mill counts two separate things. **Attempts** count how many times mill has
	# launched a stage during a run: one attempt is one launch, and its number
	# names the log file and is stamped in the verdict. It goes up on every launch
	# without exception. **Strikes** are the two-strikes rule, and go up only when
	# the stage's own work was bad.
	#
	# Keeping them apart is what makes the ordinary case expressible: a reviewer
	# that crashes, gets relaunched, finds a real problem, and reviews again is on
	# its third attempt with one strike, which is exactly the truth.
	#
	# **Every row in stage_attempts is exactly one attempt.** That is what lets the
	# number name a file. A rejection therefore inserts no row for the stage it
	# strikes — there was no launch, so there is no log and no verdict — and rides
	# on the reviewer's row instead, through `struck_stage`.
	class Ledger
		MAX_STRIKES = 2
		MAX_ATTEMPTS = 8
		MAX_INTERRUPTIONS = 3

		# A strike means the work was wrong. Everything the machine did to a stage
		# is free — a laptop that slept, a socket that died, a lock file left by a
		# SIGKILL, and mill restarting are mill's problems, not the stage's, and
		# charging for them produces a run that dies for a reason nobody can
		# reconstruct from the log.
		COST = {
			failed: { attempt: 1, strike: 1 },
			crashed: { attempt: 1, strike: 1 },
			no_verdict: { attempt: 1, strike: 1 },
			artifact_bad: { attempt: 1, strike: 1 },
			# The strike lands now; the attempt it owes is the re-launch itself,
			# which inserts its own row. See the row-per-attempt note above.
			rejected: { attempt: 0, strike: 1 },
			ok: { attempt: 1, strike: 0 },
			blocked: { attempt: 1, strike: 0 },
			reviewed_clean: { attempt: 1, strike: 0 },
			stall_recovery: { attempt: 1, strike: 0 },
			resume_failed: { attempt: 1, strike: 0 },
			interrupted: { attempt: 1, strike: 0 },
			rate_limited: { attempt: 0, strike: 0 }
		}.freeze

		# A process that died outranks whatever it managed to emit: mill has no
		# trustworthy account of what happened either way.
		# Checked before anything else: a session the CLI would not reopen is not the
		# stage failing, and it does not present as a crash either — the process
		# exits cleanly having done nothing.
		def self.classify(attempt)
			return :resume_failed if attempt.resume_failed?
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

		def rows(stage) = @db[:stage_attempts].where(run_id: @run_id, stage: stage)

		# Every guard the runner checks before an attempt, in one pass. Asking
		# separately meant four COUNTs per step, two of them the same query.
		Tally = Struct.new(:attempts, :strikes, :interruptions, keyword_init: true) do
			def out_of_strikes? = strikes >= MAX_STRIKES
			def out_of_attempts? = attempts >= MAX_ATTEMPTS
			def out_of_interruptions? = interruptions >= MAX_INTERRUPTIONS
			def next_attempt = attempts + 1
		end

		def tally(stage)
			rows = rows(stage).select_map(%i[strike_charged status])
			Tally.new(
				attempts: rows.length,
				strikes: rows.count { |charged, _| charged } +
					@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).count,
				interruptions: rows.count { |_, status| status == 'interrupted' }
			)
		end

		def attempts(stage) = rows(stage).count

		# A stage is struck either by its own bad work, or by a reviewer that found
		# something serious in it. The second is recorded on the reviewer's row,
		# because that is the row belonging to a launch that actually happened.
		def strikes(stage)
			rows(stage).where(strike_charged: true).count +
				@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).count
		end

		def interruptions(stage) = rows(stage).where(status: 'interrupted').count

		# What the run has spent, per stage, for the pull request body and the UI.
		# tokens_out is nil for an attempt killed before its result line, and nil
		# means unmeasured — so a stage with any unmeasured attempt reports its
		# output as unmeasured rather than as a total that quietly omits it.
		def spend
			@db[:stage_attempts].where(run_id: @run_id).order(:stage).to_a
				.group_by { |row| row[:stage] }
				.transform_values do |rows|
					{
						attempts: rows.length,
						tokens_in: rows.sum { |r| r[:tokens_in].to_i },
						cache_read_tokens: rows.sum { |r| r[:cache_read_tokens].to_i },
						cache_creation_tokens: rows.sum { |r| r[:cache_creation_tokens].to_i },
						tokens_out: rows.any? { |r| r[:tokens_out].nil? } ? nil : rows.sum { |r| r[:tokens_out] }
					}
				end
		end

		def next_attempt(stage) = attempts(stage) + 1

		# Records one attempt and returns what it cost. A rejection is charged as
		# `charge(stage: reviewer, outcome: :reviewed_clean, struck_stage: reviewed)`
		# — one row, one launch, the strike attributed to whoever pays.
		#
		# Everything the attempt produced goes in this one insert. An earlier draft
		# inserted here and updated the row afterwards, which meant reversing two
		# lines in the runner silently matched zero rows: every attempt lost its
		# session id, and resume broke rather than anything failing loudly.
		def charge(stage:, outcome:, number: nil, attempt: nil, **columns)
			cost = COST.fetch(outcome) { raise Mill::Error, "unknown outcome: #{outcome}" }
			return cost if cost[:attempt].zero?

			@db[:stage_attempts].insert(
				run_id: @run_id, stage: stage, number: number || next_attempt(stage),
				status: outcome.to_s, strike_charged: cost[:strike].positive?, started_at: Mill.now,
				**attempt_columns(attempt), **columns
			)
			cost
		end

		def out_of_strikes?(stage) = strikes(stage) >= MAX_STRIKES

		def out_of_attempts?(stage) = attempts(stage) >= MAX_ATTEMPTS

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

		private

		# tokens_out stays nil when an attempt was killed before its result line:
		# the stream carries no running output total, and nil means unmeasured.
		# Storing 0 would make every reaped attempt read as free. The other three
		# agree with the result line and are NOT NULL, so a missing count is 0.
		def attempt_columns(attempt)
			return { nonce: '' } if attempt.nil?

			tokens = attempt.tokens
			{
				nonce: attempt.nonce.to_s, session_id: attempt.session_id, model: attempt.model,
				log_path: attempt.log_path, verdict_json: attempt.verdict.data.to_json,
				finished_at: Mill.now,
				tokens_in: tokens[:tokens_in] || 0,
				cache_creation_tokens: tokens[:cache_creation_tokens] || 0,
				cache_read_tokens: tokens[:cache_read_tokens] || 0,
				tokens_out: tokens[:tokens_out]
			}
		end
	end
end
