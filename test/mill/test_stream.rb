require 'test_helper'

module Mill
	class TestStream < Minitest::Test
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'stream')

		def stream_for(name, clock: nil)
			s = clock ? Mill::Stream.new(clock: clock) : Mill::Stream.new
			File.readlines(File.join(FIXTURES, "#{name}.jsonl")).each { |line| s.consume(line) }
			s
		end

		def test_captures_the_session_id_for_resume
			assert_equal 'sess-plan-1', stream_for('plan_ok').session_id
		end

		def test_captures_the_model_that_actually_ran
			assert_equal 'claude-opus-5', stream_for('plan_ok').model
		end

		# Usage repeats on every content block of a message. This fixture has one
		# message across three blocks; summing blindly triples every count.
		def test_usage_is_deduped_per_message_not_per_block
			partial = Mill::Stream.new
			File.readlines(File.join(FIXTURES, 'plan_ok.jsonl'))
				.reject { |l| l.include?('"result"') }
				.each { |l| partial.consume(l) }

			assert_equal 8890, partial.tokens[:cache_read_tokens], 'block-level usage was double counted'
			assert_equal 3, partial.tokens[:tokens_in]
			assert_equal 4499, partial.tokens[:cache_creation_tokens]
		end

		# The result line carries authoritative cumulative usage for the run.
		def test_final_usage_wins_once_the_result_arrives
			tokens = stream_for('plan_ok').tokens

			assert_equal 356, tokens[:tokens_out]
			assert_equal 22_279, tokens[:cache_read_tokens]
			assert_equal 7383, tokens[:cache_creation_tokens]
		end

		# Cache reads dominated fresh input 7182:3 in the spike, so all four counts
		# are recorded or the numbers mean nothing.
		def test_records_all_four_counts
			tokens = stream_for('plan_ok').tokens

			assert_equal %i[tokens_in tokens_out cache_creation_tokens cache_read_tokens].sort,
				tokens.keys.sort
			refute_equal 0, tokens[:cache_read_tokens]
		end

		# Input and cache counts agree with the result line, so they survive a kill.
		# Output does not, so it is reported as unmeasured rather than 20x too low.
		def test_a_killed_attempt_keeps_the_counts_that_are_trustworthy
			s = stream_for('killed_midway')

			refute s.finished?
			refute s.tokens_complete?
			assert_equal 200, s.tokens[:cache_read_tokens]
			assert_equal 7, s.tokens[:tokens_in]
			assert_nil s.tokens[:tokens_out]
		end

		def test_a_truncated_line_is_not_a_failure
			assert_nil Mill::Stream.new.consume('{"type":"assist')
		end

		# The stall detector suspends its silence window while a command runs.
		#
		# This fixture is hand-authored, not recorded. It pins the parser's
		# behaviour, and it does *not* establish that the real CLI announces a
		# command as it starts rather than only when it finishes — that is still an
		# open measurement, and the design doc gates it on Plan 3.
		def test_an_outstanding_command_is_visible
			s = stream_for('tool_pending')

			assert s.tool_pending?
			refute_nil s.pending_tool_at
		end

		def test_a_completed_command_clears
			s = stream_for('plan_ok')

			refute s.tool_pending?
			assert_nil s.pending_tool_at
		end

		# Every rate_limit_event observed in the spike carried status "allowed".
		# Stamping on those would exempt every healthy attempt from its deadlines.
		def test_allowed_rate_limit_events_are_heartbeats
			s = Mill::Stream.new
			s.consume('{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}')

			refute s.rate_limited?
		end

		def test_a_real_rate_limit_is_stamped
			assert stream_for('rate_limited').rate_limited?
		end

		def test_tracks_silence_for_the_stall_detector
			now = 0.0
			s = Mill::Stream.new(clock: -> { now += 1.0 })

			s.consume('{"type":"system","subtype":"init","session_id":"s"}')
			first = s.last_output_at
			s.consume('{"type":"system","subtype":"init","session_id":"s"}')

			assert_operator s.last_output_at, :>, first, 'each line must refresh the silence clock'
		end

		def test_the_verdict_is_the_final_message
			verdict = JSON.parse(stream_for('plan_ok').raw_verdict, symbolize_names: true)

			assert_equal 'plan', verdict[:stage]
			assert_equal 1, verdict[:attempt]
			assert_equal 'abc123', verdict[:nonce]
		end

		# --json-schema makes the CLI return the verdict already parsed. mill prefers
		# that and keeps the string form for the log.
		def test_the_structured_output_is_preferred_over_the_final_message
			s = Mill::Stream.new
			s.consume('{"type":"result","subtype":"success","is_error":false,"session_id":"s",' \
				'"result":"{\\"stage\\":\\"triage\\"}",' \
				'"structured_output":{"stage":"triage","status":"ok"}}')

			assert_equal({ stage: 'triage', status: 'ok' }, s.structured_verdict)
			assert_equal({ stage: 'triage', status: 'ok' }, s.verdict_payload)
			refute_nil s.raw_verdict, 'the string form stays, for the log'
		end

		def test_the_final_message_is_used_when_there_is_no_structured_output
			s = Mill::Stream.new
			s.consume('{"type":"result","subtype":"success","is_error":false,"session_id":"s",' \
				'"result":"{}"}')

			assert_equal '{}', s.verdict_payload
		end

		# Measured 2026-08-19 against an unusable session id: the CLI answers with
		# subtype error_during_execution, is_error true, zero turns, and an errors
		# entry naming the session — it does not crash.
		def test_a_session_that_will_not_reopen_is_recognisable
			s = Mill::Stream.new
			s.consume('{"type":"result","subtype":"error_during_execution","is_error":true,' \
				'"session_id":"00000000-0000-0000-0000-000000000000","num_turns":0,' \
				'"errors":["No conversation found with session ID: 00000000-0000-0000-0000-000000000000"]}')

			assert_predicate s, :resume_failed?
			assert_predicate s, :error?
			assert_nil s.raw_verdict, 'it produced no verdict either, which is why this must be checked first'
		end

		def test_an_ordinary_failure_is_not_a_failed_resume
			s = Mill::Stream.new
			s.consume('{"type":"result","subtype":"error_during_execution","is_error":true,' \
				'"session_id":"s","errors":["something else went wrong"]}')

			refute_predicate s, :resume_failed?
		end

		def test_a_clean_result_is_not_a_failed_resume
			refute_predicate stream_for('plan_ok'), :resume_failed?
		end

		def test_reports_completion_and_success
			s = stream_for('plan_ok')

			assert s.finished?
			refute s.error?
		end
	end
end
