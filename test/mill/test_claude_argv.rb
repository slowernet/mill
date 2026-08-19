require 'test_helper'

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

		def test_nonces_are_unique_per_spawn
			refute_equal Mill::Claude.nonce, Mill::Claude.nonce
		end
	end
end
