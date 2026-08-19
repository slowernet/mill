require 'test_helper'

module Mill
	# The two skills mill owns ship in this repo — version-controlled, reviewed
	# alongside the code, and outside every worktree so a stage cannot edit the
	# instructions it runs under. These assert the files exist and say the things
	# the design requires, without needing the plugin enabled.
	class TestOwnSkills < Minitest::Test
		PLUGIN = File.join(Mill::ROOT, 'plugin')

		def skill(name) = File.read(File.join(PLUGIN, 'skills', name, 'SKILL.md'))

		def test_the_plugin_declares_itself_as_mill
			manifest = JSON.parse(File.read(File.join(PLUGIN, '.claude-plugin', 'plugin.json')),
				symbolize_names: true)

			assert_equal 'mill', manifest[:name], 'the prefix in mill:implement is the plugin name'
		end

		def test_every_skill_the_graph_names_from_mill_exists
			named = Mill::Stages::ALL.each_value.filter_map { |c| c[:skill] }
				.select { |s| s.start_with?('mill:') }.uniq

			refute_empty named
			named.each do |full|
				assert_path_exists File.join(PLUGIN, 'skills', full.split(':', 2).last, 'SKILL.md')
			end
		end

		# Each is self-contained in one SKILL.md rather than the multi-file shape
		# Superpowers uses, so a stage never has to Read a supporting file.
		def test_each_skill_is_self_contained
			%w[implement pr mill-headless].each do |name|
				assert_equal ['SKILL.md'], Dir.children(File.join(PLUGIN, 'skills', name)).sort
			end
		end

		def test_each_skill_has_the_required_front_matter
			%w[implement pr mill-headless].each do |name|
				body = skill(name)

				assert_match(/\A---\nname: /, body, "#{name} needs name front matter")
				assert_match(/^description: /, body, "#{name} needs a description")
			end
		end

		# mill never merges. The skill that opens pull requests must not describe
		# merging as an option — the Superpowers version it replaces puts it first
		# on a menu.
		def test_the_pr_skill_never_offers_to_merge
			body = skill('pr')

			assert_match(/never merges|does not merge/i, body)
			body.lines.grep(/gh pr merge/).each do |line|
				assert_match(/denied|never|not/i, line, "a bare mention of merging: #{line.strip}"
				)
			end
		end

		# The Superpowers version opens by redirecting to a different skill, creates
		# a worktree mill already made, and ends by opening the pull request before
		# review has run. All three would break mill's graph.
		def test_the_implement_skill_does_not_redirect_or_finish_the_branch
			body = skill('implement')

			refute_match(/use subagent-driven-development/i, body)
			refute_match(/use .*finishing-a-development-branch/i, body)
			assert_match(/checkbox/i, body, 'the plan file is the ledger')
		end

		def test_the_implement_skill_states_the_iron_law
			assert_match(/no production code without a failing test/i, skill('implement'))
		end

		# Every borrowed skill's interactive gate maps onto block-and-ask, and the
		# adapter has to name them or a stage meets one it was never told about.
		def test_mill_headless_covers_every_gate_the_borrowed_skills_have
			body = skill('mill-headless')

			%w[writing-plans test-driven-development systematic-debugging].each do |named|
				assert_match(/#{named}/, body, "mill-headless must say what #{named} does when it would ask")
			end
		end

		# The marketplace manifest is what makes `claude plugin install` work
		# without a network round trip.
		def test_the_marketplace_points_at_the_plugin_in_this_repo
			manifest = JSON.parse(File.read(File.join(Mill::ROOT, '.claude-plugin', 'marketplace.json')),
				symbolize_names: true)

			assert_equal ['mill'], manifest[:plugins].map { |p| p[:name] }
			assert_equal './plugin', manifest[:plugins].first[:source]
		end
	end
end
