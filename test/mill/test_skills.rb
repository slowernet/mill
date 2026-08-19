require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Builds a synthetic ~/.claude so these never depend on what the operator
	# happens to have installed.
	class TestSkills < Minitest::Test
		def with_config(enabled: { 'superpowers@superpowers-marketplace' => true },
			installed: :default, personal: ['adversarial-reviewer'], plugin_skills: ['writing-plans'])
			Dir.mktmpdir do |dir|
				install = File.join(dir, 'plugins', 'cache', 'superpowers-marketplace', 'superpowers', '6.3.0')
				plugin_skills.each do |s|
					FileUtils.mkdir_p(File.join(install, 'skills', s))
					File.write(File.join(install, 'skills', s, 'SKILL.md'), "# #{s}")
				end
				personal.each do |s|
					FileUtils.mkdir_p(File.join(dir, 'skills', s))
					File.write(File.join(dir, 'skills', s, 'SKILL.md'), "# #{s}")
				end
				File.write(File.join(dir, 'settings.json'), { enabledPlugins: enabled }.to_json)

				entry = installed == :default ? { installPath: install, version: '6.3.0' } : installed
				FileUtils.mkdir_p(File.join(dir, 'plugins'))
				File.write(File.join(dir, 'plugins', 'installed_plugins.json'),
					{ plugins: { 'superpowers@superpowers-marketplace' => (entry ? [entry] : []) } }.to_json)

				yield dir
			end
		end

		def resolve(name, dir) = Mill::Skills.resolve(name, config_dir: dir)

		def test_resolves_a_plugin_skill_with_its_version
			with_config do |dir|
				r = resolve('superpowers:writing-plans', dir)

				assert_predicate r, :found?
				assert_equal :plugin, r.kind
				assert_equal '6.3.0', r.version
				assert_path_exists r.path
			end
		end

		def test_resolves_a_personal_skill
			with_config do |dir|
				r = resolve('adversarial-reviewer', dir)

				assert_predicate r, :found?
				assert_equal :personal, r.kind
			end
		end

		# An installed but disabled plugin provides nothing, and its files are
		# still on disk — so existence on disk is not the test.
		def test_a_disabled_plugin_provides_nothing
			with_config(enabled: { 'superpowers@superpowers-marketplace' => false }) do |dir|
				r = resolve('superpowers:writing-plans', dir)

				refute_predicate r, :found?
				assert_match(/not enabled/, r.detail)
			end
		end

		def test_a_plugin_that_was_never_installed_is_named
			with_config(enabled: { 'mill@local' => true }) do |dir|
				r = resolve('mill:implement', dir)

				refute_predicate r, :found?
				assert_match(/not enabled|not installed/, r.detail)
			end
		end

		def test_an_enabled_plugin_with_no_install_record_is_named
			with_config(installed: nil) do |dir|
				r = resolve('superpowers:writing-plans', dir)

				refute_predicate r, :found?
				assert_match(/not installed/, r.detail)
			end
		end

		# The plugin is present and enabled but does not carry this skill.
		def test_a_plugin_missing_the_named_skill_is_named
			with_config(plugin_skills: ['writing-plans']) do |dir|
				r = resolve('superpowers:nonexistent', dir)

				refute_predicate r, :found?
				assert_match(/provides no skill/, r.detail)
			end
		end

		def test_a_missing_personal_skill_is_named
			with_config(personal: []) do |dir|
				r = resolve('adversarial-reviewer', dir)

				refute_predicate r, :found?
				assert_match(/no skill at/, r.detail)
			end
		end

		def test_a_missing_config_directory_does_not_crash
			r = resolve('superpowers:writing-plans', '/nonexistent/claude')

			refute_predicate r, :found?
		end

		def test_unparseable_settings_do_not_crash
			Dir.mktmpdir do |dir|
				File.write(File.join(dir, 'settings.json'), '{ not json')

				refute_predicate resolve('superpowers:writing-plans', dir), :found?
			end
		end

		# Every skill the graph names must be checked, or a stage improvises.
		def test_required_covers_every_skill_the_graph_names
			named = Mill::Stages::ALL.values.filter_map { |c| c[:skill] }.uniq

			assert_equal named.sort, Mill::Skills.required.map(&:name).sort
		end

		# A plugin update changes what a stage was told without anyone touching
		# mill, so a verdict has to be traceable to the text that produced it.
		def test_an_attempt_records_the_skill_it_ran_under
			provenance = Mill::Claude.new('plan').skill_provenance

			assert provenance.key?(:skill_source)
			assert provenance.key?(:skill_version)
		end

		def test_a_stage_with_no_skill_records_nothing
			assert_empty Mill::Claude.new('triage').skill_provenance
		end
	end
end
