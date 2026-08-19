require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Regressions from the 2026-08-19 adversarial review. Each of these crashed,
	# mis-reported, or let containment widen before the fix.
	class TestHostileInput < Minitest::Test
		# A verdict is agent-controlled. Malformed shapes must cost the stage a
		# strike, never take mill down with it.
		def verdict(body, stage: 'review:code')
			Mill::Verdict.validate(
				{ stage: stage, invocation: 1, nonce: 'n' }.merge(body).to_json,
				stage: stage, invocation: 1, nonce: 'n', worktree: nil
			)
		end

		def test_objections_of_the_wrong_shape_fail_rather_than_crash
			[['a string'], [42], [nil], 'not a list', { severity: 'high' }].each do |bad|
				v = verdict({ status: 'ok', objections: bad })

				refute_predicate v, :valid?, "objections: #{bad.inspect} should be invalid"
				refute_predicate v, :rejects?
			end
		end

		def test_an_artifact_of_the_wrong_type_fails_rather_than_crashing
			[42, true, ['a'], { path: 'x' }].each do |bad|
				refute_predicate verdict({ status: 'ok', artifact: bad }, stage: 'plan'), :valid?
			end
		end

		# A stage cannot smuggle a serious objection past validation by malforming it.
		def test_a_malformed_objection_never_counts_as_a_rejection
			v = verdict({ status: 'ok', objections: ['high'] })

			refute_predicate v, :rejects?
		end

		# content is a plain string on simple messages, not always a block list.
		def test_the_stream_survives_string_message_content
			s = Mill::Stream.new

			s.consume('{"type":"user","session_id":"s","message":{"role":"user","content":"hello"}}')
			s.consume('{"type":"assistant","session_id":"s","message":{"id":"m","content":"hi"}}')

			assert_equal 's', s.session_id
			refute_predicate s, :tool_pending?
		end

		def test_the_stream_survives_junk_content_blocks
			s = Mill::Stream.new

			s.consume('{"type":"assistant","session_id":"s","message":{"id":"m","content":[null,"x",7]}}')
			s.consume('{"type":"user","session_id":"s","message":{"content":[null,"x"]}}')

			refute_predicate s, :tool_pending?
		end

		# The stream carries no running output total: summed per-message output was
		# 13/15/37/16 across four real runs where the result line said 356/361/786/645.
		# An unmeasured attempt must report nothing rather than a number 20x too low.
		def test_output_tokens_are_unmeasured_until_the_result_arrives
			s = Mill::Stream.new
			s.consume('{"type":"assistant","session_id":"s","message":{"id":"m","usage":' \
				'{"input_tokens":5,"cache_read_input_tokens":200,"cache_creation_input_tokens":10,' \
				'"output_tokens":11},"content":[]}}')

			refute_predicate s, :tokens_complete?
			assert_nil s.tokens[:tokens_out], 'a partial output count is wrong by an order of magnitude'
			assert_equal 5, s.tokens[:tokens_in], 'input counts do agree and stay useful'
			assert_equal 200, s.tokens[:cache_read_tokens]
		end

		def test_output_tokens_are_reported_once_the_result_arrives
			s = Mill::Stream.new
			s.consume('{"type":"result","subtype":"success","is_error":false,"session_id":"s",' \
				'"usage":{"input_tokens":5,"output_tokens":356},"result":"{}"}')

			assert_predicate s, :tokens_complete?
			assert_equal 356, s.tokens[:tokens_out]
		end

		# Freezing the outer hash left every toolset mutable, so a reviewer could be
		# handed a write tool in-process and the argv tests would still pass.
		def test_a_stage_toolset_cannot_be_widened_at_runtime
			assert_raises(FrozenError) { Mill::Stages['review:code'][:tools] << 'Write' }
			assert_raises(FrozenError) { Mill::Stages['implement'][:permission_mode] = 'bypassPermissions' }
			refute_includes Mill::Stages['review:code'][:tools], 'Write'
		end

		# Never signal at all without checking the recorded boot time first.
		def test_reaping_refuses_when_the_boot_time_is_unknown
			assert_equal :unknown_boot, Mill::Spawn.reap(99_999, boot_at: nil, now: 1_000)
			assert_equal :unknown_boot, Mill::Spawn.reap(99_999, boot_at: 1_000, now: nil)
		end

		# A bare prefix test let /tmp/work-evil pass for a worktree of /tmp/work,
		# defeating the symlink check that exists for exactly this.
		def test_an_artifact_symlinked_to_a_sibling_directory_is_rejected
			Dir.mktmpdir do |base|
				work = File.join(base, 'work')
				sibling = File.join(base, 'work-evil')
				FileUtils.mkdir_p(File.join(work, 'docs/superpowers/plans'))
				FileUtils.mkdir_p(sibling)
				File.write(File.join(sibling, 'x.md'), 'secrets')
				File.symlink(File.join(sibling, 'x.md'), File.join(work, 'docs/superpowers/plans/x.md'))

				v = Mill::Verdict.validate(
					{ stage: 'plan', invocation: 1, nonce: 'n', status: 'ok',
					  artifact: 'docs/superpowers/plans/x.md' }.to_json,
					stage: 'plan', invocation: 1, nonce: 'n', worktree: work
				)

				refute_predicate v, :valid?
				assert_includes v.errors, 'artifact traverses a symlink'
			end
		end
		# The reviewer skill's own output format specifies uppercase severities, so
		# matching only lowercase read every objection it raised as advisory: the
		# reviewed stage never re-ran and the whole review gate was inert.
		def test_the_severities_the_reviewer_skill_emits_actually_reject
			%w[CRITICAL HIGH Critical High critical high].each do |severity|
				v = verdict({ status: 'ok', objections: [{ severity: severity, claim: 'data loss' }] })

				assert_predicate v, :valid?, "#{severity} should be a valid severity"
				assert_predicate v, :rejects?, "#{severity} must re-run the reviewed stage"
			end
		end

		def test_the_lesser_severities_still_do_not_reject
			%w[MEDIUM LOW medium low].each do |severity|
				v = verdict({ status: 'ok', objections: [{ severity: severity, claim: 'nit' }] })

				assert_predicate v, :valid?
				refute_predicate v, :rejects?
			end
		end

		# An invented severity has to fail loudly. Filing it quietly as non-serious
		# is how a critical finding becomes a footnote nobody acts on.
		def test_an_unrecognised_severity_fails_validation
			['blocker', 'sev1', '', nil, 42].each do |severity|
				v = verdict({ status: 'ok', objections: [{ severity: severity, claim: 'x' }] })

				refute_predicate v, :valid?, "severity #{severity.inspect} should not validate"
				assert(v.errors.any? { |e| e.include?('severity') })
			end
		end

		# File.exist? is true for a directory and File.size reports its inode size,
		# so `mkdir docs/superpowers/plans/x.md` passed as a written plan.
		def test_a_directory_is_not_an_artifact
			Dir.mktmpdir do |work|
				FileUtils.mkdir_p(File.join(work, 'docs/superpowers/plans/x.md'))

				v = Mill::Verdict.validate(
					{ stage: 'plan', invocation: 1, nonce: 'n', status: 'ok',
					  artifact: 'docs/superpowers/plans/x.md' }.to_json,
					stage: 'plan', invocation: 1, nonce: 'n', worktree: work
				)

				refute_predicate v, :valid?
				assert_includes v.errors, 'artifact is not a file'
			end
		end

		# A rate limit that lifts must stop exempting the stage from its deadlines,
		# or a stage throttled at minute 2 and wedged at minute 20 is never reaped.
		def test_a_rate_limit_clears_when_it_lifts
			s = Mill::Stream.new
			s.consume('{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}')

			assert_predicate s, :rate_limited?

			s.consume('{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}')

			refute_predicate s, :rate_limited?, 'a lifted limit must not exempt the stage forever'
		end

		# A line that arrives is output whatever it contains. Stamping after the
		# parse meant a banner or a partial line read as silence.
		def test_any_line_refreshes_the_silence_clock
			now = 0.0
			s = Mill::Stream.new(clock: -> { now += 1.0 })
			s.consume('{"type":"system","subtype":"init","session_id":"s"}')
			first = s.last_output_at
			s.consume("not json at all\n")

			assert_operator s.last_output_at, :>, first
		end

		# Encoding.default_external is US-ASCII on a machine with no locale set, so
		# the pipe hands back lines tagged that way and the first non-ASCII byte a
		# stage reads raised an encoding error straight out of the parser. Spawn now
		# forces the pipe to UTF-8; this is the second line of defence.
		def test_a_mis_encoded_line_is_not_a_crash
			line = %({"type":"system","note":"caf\xC3"}).dup.force_encoding(Encoding::US_ASCII)

			assert_nil Mill::Stream.new.consume(line), 'a mis-encoded line must not raise out of consume'
		end

		# The token hash used to carry only tokens_out when nothing had been
		# counted, so a caller writing it into a row dropped three columns.
		def test_the_token_hash_always_names_all_four_counts
			expected = %i[tokens_in tokens_out cache_creation_tokens cache_read_tokens].sort

			assert_equal expected, Mill::Stream.new.tokens.keys.sort
			assert_equal 0, Mill::Stream.new.tokens[:tokens_in]
		end

		# A reviewer's objections re-run whatever produced the artifact, and on the
		# fast and iterate routes that is implement:fast. A global map named
		# `implement`, which is not on either route.
		def test_a_rejection_re_runs_the_implementer_that_is_on_this_route
			assert_equal 'implement', Mill::Stages.reviewed_stage('plan', 'review:code')
			assert_equal 'implement:fast', Mill::Stages.reviewed_stage('fast', 'review:code')
			assert_equal 'implement:fast', Mill::Stages.reviewed_stage('iterate', 'review:code')
			assert_equal 'plan', Mill::Stages.reviewed_stage('plan', 'review:plan')
		end

		def test_a_reviewed_stage_is_always_on_its_own_route
			Mill::Stages::ROUTES.each do |route, stages|
				stages.grep(/\Areview:/).each do |reviewer|
					assert_includes stages, Mill::Stages.reviewed_stage(route, reviewer),
						"#{route}: #{reviewer} would re-run a stage that is not on the route"
				end
			end
		end
	end
end
