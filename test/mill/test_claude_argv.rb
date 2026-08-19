require 'test_helper'
require 'json'

module Mill
	# These assert CLAUDE.md's safety invariants. A failure here is a containment
	# bug, not a style problem.
	class TestClaudeArgv < Minitest::Test
		def argv_for(stage, **rest)
			Mill::Claude.new(stage, home: '/tmp/mill-test').argv('do the thing', **rest)
		end

		def test_every_stage_confines_with_tools_and_strict_mcp
			Mill::Stages.names.each do |stage|
				args = argv_for(stage)

				assert_includes args, '--tools', "#{stage} must restrict its toolset"
				assert_includes args, '--strict-mcp-config', "#{stage} must not inherit MCP servers"
				refute_empty args[args.index('--tools') + 1]
			end
		end

		def test_no_stage_bypasses_permissions
			Mill::Stages.names.each do |stage|
				args = argv_for(stage)

				Mill::Claude::BANNED_FLAGS.each { |flag| refute_includes args, flag }
				refute_includes args, 'bypassPermissions'
			end
		end

		# An allow list is advisory in headless mode — a tool in neither allow nor
		# deny runs anyway. Confinement must never move there.
		def test_confinement_never_moves_into_an_allow_list
			Mill::Stages.names.each do |stage|
				refute_includes argv_for(stage), '--allowed-tools'
			end
		end

		# Measured 2026-08-19: a stage without Skill in --tools cannot load one, so
		# a stage that names a skill and lacks the tool would silently improvise.
		def test_stages_that_name_a_skill_can_load_one
			Mill::Stages::ALL.each do |stage, config|
				next unless config[:skill]

				assert_includes config[:tools], 'Skill', "#{stage} names #{config[:skill]} but cannot load it"
			end
		end

		def test_stages_without_a_skill_do_not_get_the_tool
			Mill::Stages::ALL.each do |stage, config|
				next if config[:skill]

				refute_includes config[:tools], 'Skill', "#{stage} names no skill and should not carry the tool"
			end
		end

		# Headless mode refuses every file write under the default permission mode,
		# including files no rule mentions. Without acceptEdits, implement produces
		# nothing and burns both strikes.
		def test_writing_stages_can_actually_write
			Mill::Stages::ALL.each do |stage, config|
				writes = (config[:tools] & %w[Write Edit]).any?
				args = argv_for(stage)
				mode = args.include?('--permission-mode') ? args[args.index('--permission-mode') + 1] : nil

				if writes
					assert_equal 'acceptEdits', mode, "#{stage} holds a write tool but cannot write"
				else
					assert_nil mode, "#{stage} writes nothing and needs no permission mode"
				end
			end
		end

		def test_settings_come_from_outside_any_worktree
			path = Mill::Claude.new('implement', home: '/tmp/mill-test').settings_path

			assert_equal '/tmp/mill-test/settings/implement.json', path
			assert_includes argv_for('implement'), '--settings'
		end

		# Stage names carry a colon; the settings path must not.
		def test_settings_path_is_slugged
			assert_equal '/tmp/mill-test/settings/review-code.json',
				Mill::Claude.new('review:code', home: '/tmp/mill-test').settings_path
		end

		def test_relaunch_resumes_the_session
			args = argv_for('plan', session_id: 'sess-abc')

			assert_includes args, '--resume'
			assert_equal 'sess-abc', args[args.index('--resume') + 1]
		end

		def test_first_launch_does_not_resume
			refute_includes argv_for('plan'), '--resume'
		end

		def test_triage_runs_the_cheap_model_and_reads_only
			assert_equal Mill::Stages::SONNET, Mill::Stages['triage'][:model]
			assert_empty Mill::Stages['triage'][:tools] & %w[Write Edit Bash]
		end

		# review:plan cannot modify the plan it is reviewing, no matter what its
		# prompt says.
		def test_reviewers_cannot_write
			%w[review:plan review:code].each do |stage|
				assert_empty Mill::Stages[stage][:tools] & %w[Write Edit], "#{stage} must not be able to write"
			end
		end

		def test_stream_json_is_requested_so_the_verdict_can_arrive
			args = argv_for('triage')

			assert_includes args, '--output-format'
			assert_equal 'stream-json', args[args.index('--output-format') + 1]
		end

		# --json-schema turns the verdict into a forced tool call, so a stage cannot
		# wrap it in prose or a code fence. Measured 2026-08-19: without it, both
		# triage attempts on the first real run prefixed a sentence and were
		# rejected, costing two strikes for a correct answer.
		def test_every_stage_constrains_its_verdict_with_a_schema
			Mill::Stages.names.each do |stage|
				args = argv_for(stage)

				assert_includes args, '--json-schema', "#{stage} does not constrain its verdict"
				schema = JSON.parse(args[args.index('--json-schema') + 1])

				assert_equal 'object', schema['type']
				assert_equal [stage], schema.dig('properties', 'stage', 'enum')
				assert_equal %w[stage invocation nonce status summary].sort, schema['required'].sort
				refute schema['additionalProperties'], 'a stage must not invent fields'
			end
		end

		def test_only_triage_is_offered_a_route
			Mill::Stages.names.each do |stage|
				properties = Mill::Verdict.schema_for(stage)[:properties]

				assert_equal(stage == 'triage', properties.key?(:route), "route on #{stage}")
			end
		end

		def test_only_a_stage_with_an_artifact_pattern_is_offered_one
			Mill::Stages.names.each do |stage|
				properties = Mill::Verdict.schema_for(stage)[:properties]

				assert_equal !Mill::Stages[stage][:artifact].nil?, properties.key?(:artifact),
					"artifact on #{stage}"
			end
		end

		# The reviewer skill spells its severities in upper case. Constraining the
		# tool call is what stops that reaching mill at all.
		def test_only_reviewers_are_offered_objections_and_the_severities_are_bounded
			%w[review:plan review:code].each do |stage|
				items = Mill::Verdict.schema_for(stage).dig(:properties, :objections, :items)

				assert_equal Mill::Verdict::SEVERITIES, items.dig(:properties, :severity, :enum)
				assert_equal %w[severity claim notes].sort, items[:required].sort
			end

			refute Mill::Verdict.schema_for('implement')[:properties].key?(:objections)
		end

		def test_nonces_are_unique_per_spawn
			refute_equal Mill::Claude.nonce, Mill::Claude.nonce
		end
	end
end
