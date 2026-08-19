require 'test_helper'

module Mill
	class TestPrompts < Minitest::Test
		def prompt(stage, **context) = Mill::Prompts.for(stage, context)

		def test_every_stage_on_the_plan_route_has_a_prompt
			Mill::Stages::ROUTES['plan'].each do |stage|
				refute_empty prompt(stage, issue: 'Do the thing.'), "#{stage} has no prompt"
			end
		end

		# Claude Code never has to guess which skill to load — the quickstart warns
		# about exactly that guessing.
		def test_a_stage_prompt_names_its_own_skill
			assert_includes prompt('plan', issue: 'x'), 'superpowers:writing-plans'
			assert_includes prompt('review:plan', issue: 'x'), 'adversarial-reviewer'
			assert_includes prompt('implement', issue: 'x'), 'mill:implement'
			assert_includes prompt('pr', issue: 'x'), 'mill:pr'
		end

		# A real triage launch read the inherited SessionStart hook as a
		# prompt-injection attempt and said so in its final message.
		def test_every_prompt_disarms_the_inherited_session_start_hook
			Mill::Stages::ROUTES['plan'].each do |stage|
				assert_match(/SessionStart/, prompt(stage, issue: 'x'),
					"#{stage} does not account for the inherited hook")
			end
		end

		def test_a_stage_with_no_skill_says_so_rather_than_leaving_it_open
			body = prompt('triage', issue: 'x')

			assert_match(/loads no skill/i, body)
			refute_includes body, 'superpowers:'
		end

		def test_the_issue_body_reaches_the_stage
			assert_includes prompt('triage', issue: 'Track low-stock items'), 'Track low-stock items'
		end

		def test_predecessor_verdicts_are_passed_down
			body = prompt('implement', issue: 'x', plan_path: 'docs/superpowers/plans/p.md',
				verdicts: [{ stage: 'plan', status: 'ok', summary: 'wrote the plan' }])

			assert_includes body, 'docs/superpowers/plans/p.md'
			assert_includes body, 'wrote the plan'
		end

		# A reviewer's notes are what the coding agent reads on a re-run.
		def test_objections_are_injected_verbatim_on_a_rerun
			body = prompt('implement', issue: 'x', plan_path: 'p.md',
				objections: [{ severity: 'high', claim: 'race on restock',
					notes: 'lib/inventory.rb:14 — two callers can interleave' }])

			assert_includes body, 'race on restock'
			assert_includes body, 'lib/inventory.rb:14'
		end

		# Answering a blocked run injects the answer into the same session.
		def test_answers_are_injected_when_a_block_resumes
			body = prompt('plan', issue: 'x', spec_path: 's.md', answers: ['Use 30 seconds.'])

			assert_includes body, 'Use 30 seconds.'
		end

		# A missing key must never render as a blank. A stage told "the plan is: "
		# will invent one.
		def test_an_absent_context_key_is_stated_not_blanked
			body = prompt('review:code', issue: 'x')

			refute_match(/^`?`?$/, body.lines.grep(/plan/).join)
			assert_match(/no plan|not applicable/i, body)
		end

		def test_the_three_extra_review_lenses_are_present
			plan_review = prompt('review:plan', issue: 'x')

			assert_match(/buildabilit|execute each task/i, plan_review)
			assert_match(/simplicity|simplest/i, plan_review)
			assert_match(/convention|alignment/i, plan_review)

			code_review = prompt('review:code', issue: 'x')

			assert_match(/plan alignment/i, code_review)
			assert_match(/consistenc/i, code_review)
			assert_match(/test quality/i, code_review)
		end

		# review:code must not trust the implement verdict.
		def test_review_code_is_told_to_run_the_tests_itself
			body = prompt('review:code', issue: 'x', test_command: 'bundle exec rake test')

			assert_match(/run the test suite yourself/i, body)
			assert_includes body, 'bundle exec rake test'
		end

		# mill never merges, and the pr stage no longer calls the API at all — it
		# pushes and hands mill a title and a body.
		def test_the_pr_prompt_says_mill_never_merges
			assert_match(/never merges/i, prompt('pr', issue: 'x', branch: 'b'))
		end

		def test_the_pr_prompt_asks_for_a_title_and_body_not_an_api_call
			body = prompt('pr', issue: 'x', branch: 'b')

			assert_match(/`title` and `body`/, body)
			refute_match(/gh pr create/, body)
		end

		# The first real run published +16/-3 for a file that gained 13 and lost 3,
		# having read `git diff --stat`'s "16 +++---" as insertions.
		def test_the_pr_prompt_says_where_a_diffstat_comes_from
			body = prompt('pr', issue: 'x', branch: 'b')

			assert_match(/--numstat/, body)
			assert_match(/lines \*touched\*|insertions plus\s*\n?\s*deletions/, body)
		end

		def test_an_unknown_stage_raises_rather_than_rendering_nothing
			assert_raises(Mill::Error) { prompt('nonesuch', issue: 'x') }
		end

		# Braces and backticks are ordinary in prose about code, and an issue body is
		# arbitrary text. A template engine turns a stray brace into a crash, and a
		# naive one re-scans what it substituted.
		def test_an_issue_body_full_of_braces_survives_substitution
			body = prompt('triage', issue: 'use { key: value } syntax, not {{spec_path}}')

			assert_includes body, '{ key: value }'
			assert_includes body, '{{spec_path}}', 'a substituted value must not be re-scanned'
		end

		# implement is handed the plan and the verdicts, not the issue body — the
		# planner already read the issue and decided what it meant.
		def test_implement_reads_the_plan_rather_than_the_issue
			body = prompt('implement', issue: 'the original issue text', plan_path: 'p.md')

			refute_includes body, 'the original issue text'
			assert_includes body, 'p.md'
		end
	end
end
