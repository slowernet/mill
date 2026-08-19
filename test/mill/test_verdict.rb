require 'test_helper'
require 'tmpdir'

module Mill
	class TestVerdict < Minitest::Test
		ENVELOPE = { stage: 'plan', attempt: 1, nonce: 'n1' }.freeze

		def validate(overrides = {}, stage: 'plan', number: 1, nonce: 'n1', worktree: nil)
			body = { status: 'ok', artifact: 'docs/superpowers/plans/x.md', summary: 's' }
			raw = ENVELOPE.merge(body).merge(overrides)
			raw = raw.to_json unless raw.is_a?(String)
			Mill::Verdict.validate(raw, stage: stage, number: number, nonce: nonce, worktree: worktree)
		end

		# With --json-schema the CLI hands back the verdict already parsed, so the
		# usual input is a Hash rather than a string to parse.
		def test_a_parsed_verdict_validates_without_a_round_trip
			v = Mill::Verdict.validate(
				{ stage: 'triage', attempt: 1, nonce: 'n1', status: 'ok', summary: 's' },
				stage: 'triage', number: 1, nonce: 'n1', worktree: nil
			)

			assert_predicate v, :valid?
			assert_equal 'ok', v.status
		end

		def test_a_parsed_verdict_is_still_checked_against_this_launch
			v = Mill::Verdict.validate(
				{ stage: 'triage', attempt: 1, nonce: 'stale', status: 'ok' },
				stage: 'triage', number: 1, nonce: 'n1', worktree: nil
			)

			refute_predicate v, :valid?
			assert_includes v.errors, 'nonce mismatch'
		end

		# String keys would arrive if anything ever hands mill an unsymbolized hash.
		def test_a_parsed_verdict_with_string_keys_is_read_the_same_way
			v = Mill::Verdict.validate(
				{ 'stage' => 'triage', 'attempt' => 1, 'nonce' => 'n1', 'status' => 'ok' },
				stage: 'triage', number: 1, nonce: 'n1', worktree: nil
			)

			assert_predicate v, :valid?
		end

		# Silence is never success.
		def test_a_missing_verdict_is_a_failure
			%w[  ].push(nil, '').each do |raw|
				v = Mill::Verdict.validate(raw, stage: 'plan', number: 1, nonce: 'n1', worktree: nil)

				refute v.valid?
				assert_match(/no verdict/, v.errors.first)
			end
		end

		# A crashed reviewer must never read as approval.
		def test_a_crashed_stage_does_not_inherit_a_pass
			v = Mill::Verdict.validate('', stage: 'review:code', number: 2, nonce: 'n9', worktree: nil)

			refute v.valid?
			refute_equal 'ok', v.status
		end

		def test_accepts_a_well_formed_verdict
			assert_predicate validate, :valid?
		end

		# The nonce makes a replayed verdict unrepresentable.
		def test_rejects_a_replayed_nonce
			v = validate({ nonce: 'stale' })

			refute v.valid?
			assert_includes v.errors, 'nonce mismatch'
		end

		def test_rejects_a_verdict_from_another_stage
			refute_predicate validate({ stage: 'implement' }), :valid?
		end

		def test_rejects_a_verdict_from_an_earlier_launch
			refute_predicate validate({ attempt: 1 }, number: 2), :valid?
		end

		# Prose after the JSON is a loud, immediate failure rather than a quiet one.
		def test_rejects_trailing_prose
			raw = ENVELOPE.merge(status: 'ok', artifact: 'docs/superpowers/plans/x.md').to_json + "\n\nHope that helps!"
			v = Mill::Verdict.validate(raw, stage: 'plan', number: 1, nonce: 'n1', worktree: nil)

			refute v.valid?
			assert_match(/not valid JSON/, v.errors.first)
		end

		def test_rejects_an_unknown_status
			refute_predicate validate({ status: 'finished' }), :valid?
		end

		# A blocked run with no questions has nothing to ask and cannot resume.
		def test_blocked_requires_questions
			refute_predicate validate({ status: 'blocked', artifact: nil, questions: [] }), :valid?
			assert_predicate validate({ status: 'blocked', artifact: nil, questions: ['which one?'] }), :valid?
		end

		def test_questions_without_blocking_are_rejected
			refute_predicate validate({ questions: ['why?'] }), :valid?
		end

		def test_artifact_must_match_the_stage_pattern
			refute_predicate validate({ artifact: 'notes/whatever.md' }), :valid?
		end

		def test_artifact_must_stay_inside_the_worktree
			refute_predicate validate({ artifact: '/etc/passwd' }), :valid?
			refute_predicate validate({ artifact: '../outside.md' }), :valid?
			refute_predicate validate({ artifact: 'docs/superpowers/plans/../../../x.md' }), :valid?
		end

		def test_a_stage_with_a_pattern_must_produce_an_artifact
			refute_predicate validate({ artifact: nil }), :valid?
		end

		def test_artifact_must_exist_and_be_non_empty
			Dir.mktmpdir do |dir|
				path = File.join(dir, 'docs/superpowers/plans')
				FileUtils.mkdir_p(path)

				refute_predicate validate({}, worktree: dir), :valid?, 'missing file must fail'

				File.write(File.join(path, 'x.md'), '')
				refute_predicate validate({}, worktree: dir), :valid?, 'empty file must fail'

				File.write(File.join(path, 'x.md'), 'real content')
				assert_predicate validate({}, worktree: dir), :valid?
			end
		end

		# Only triage picks the route.
		def test_only_triage_may_set_a_route
			refute_predicate validate({ route: 'fast' }), :valid?
		end

		def test_triage_may_set_a_known_route
			v = Mill::Verdict.validate(
				{ stage: 'triage', attempt: 1, nonce: 'n1', status: 'ok', route: 'fast' }.to_json,
				stage: 'triage', number: 1, nonce: 'n1', worktree: nil
			)

			assert_predicate v, :valid?
		end

		def test_triage_may_not_invent_a_route
			v = Mill::Verdict.validate(
				{ stage: 'triage', attempt: 1, nonce: 'n1', status: 'ok', route: 'refactor' }.to_json,
				stage: 'triage', number: 1, nonce: 'n1', worktree: nil
			)

			refute_predicate v, :valid?
		end

		# A reviewer returns ok with objections; it does not fail. Only high or
		# critical re-runs the reviewed stage.
		def test_only_serious_objections_reject
			body = { stage: 'review:code', attempt: 1, nonce: 'n1', status: 'ok' }
			minor = Mill::Verdict.validate(
				body.merge(objections: [{ severity: 'low', claim: 'nit' }, { severity: 'medium', claim: 'meh' }]).to_json,
				stage: 'review:code', number: 1, nonce: 'n1', worktree: nil
			)
			serious = Mill::Verdict.validate(
				body.merge(objections: [{ severity: 'low', claim: 'nit' }, { severity: 'high', claim: 'race' }]).to_json,
				stage: 'review:code', number: 1, nonce: 'n1', worktree: nil
			)

			assert_predicate minor, :valid?
			refute_predicate minor, :rejects?
			assert_predicate serious, :rejects?
			assert_equal 1, serious.serious_objections.length
		end

		def test_a_clean_review_rejects_nothing
			v = Mill::Verdict.validate(
				{ stage: 'review:plan', attempt: 1, nonce: 'n1', status: 'ok' }.to_json,
				stage: 'review:plan', number: 1, nonce: 'n1', worktree: nil
			)

			assert_predicate v, :valid?
			refute_predicate v, :rejects?
		end
	end
end
