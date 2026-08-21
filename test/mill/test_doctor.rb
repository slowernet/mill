require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	class TestDoctor < Minitest::Test
		# The canonical ruleset, per stage, so the test and the runbook cannot drift
		# from what doctor demands. Rules::write! produces exactly this — and it is
		# per stage because pr and push are the only two with any network reach.
		def good_for(stage) = Mill::Rules.for_stage(stage)

		def with_home(rulesets: :all)
			Dir.mktmpdir do |home|
				%w[settings secrets].each do |sub|
					FileUtils.mkdir_p(File.join(home, sub))
					FileUtils.chmod(0o700, File.join(home, sub))
				end
				FileUtils.chmod(0o700, home)
				write_rulesets(home, rulesets)
				yield home
			end
		end

		# The board check needs a real project, so it is switched off here and
		# exercised on its own against a fixture.
		def doctor(home, **rest) = Mill::Doctor.new(home: home, project: nil, project_owner: nil, **rest).run

		def write_rulesets(home, rulesets)
			return if rulesets == :none

			Mill::Stages.names.each do |stage|
				body = rulesets.is_a?(Hash) ? (rulesets[stage] || good_for(stage)) : good_for(stage)
				File.write(File.join(home, 'settings', "#{Mill::Stages.slug(stage)}.json"), body.to_json)
			end
		end

		# A synthetic Claude config, so these never depend on what the operator
		# happens to have installed.
		def with_claude_config
			Dir.mktmpdir do |dir|
				install = File.join(dir, 'plugins', 'cache', 'm', 'superpowers', '9.9.9')
				%w[writing-plans systematic-debugging test-driven-development].each do |s|
					FileUtils.mkdir_p(File.join(install, 'skills', s))
					File.write(File.join(install, 'skills', s, 'SKILL.md'), '#')
				end
				%w[adversarial-reviewer].each do |s|
					FileUtils.mkdir_p(File.join(dir, 'skills', s))
					File.write(File.join(dir, 'skills', s, 'SKILL.md'), '#')
				end
				File.write(File.join(dir, 'settings.json'),
					{ enabledPlugins: { 'superpowers@m' => true } }.to_json)
				FileUtils.mkdir_p(File.join(dir, 'plugins'))
				File.write(File.join(dir, 'plugins', 'installed_plugins.json'),
					{ plugins: { 'superpowers@m' => [{ installPath: install, version: '9.9.9' }] } }.to_json)
				yield dir
			end
		end

		def doctor_for(home, config_dir = nil)
			config_dir ? doctor(home, config_dir: config_dir) : doctor(home)
		end

		def check(home, name)
			doctor(home).checks.find { |c| c.name == name }
		end

		def test_a_correctly_configured_home_passes_its_containment_checks
			with_home do |home|
				with_claude_config do |config|
					failures = doctor_for(home, config).checks.reject(&:ok)
						.reject { |c| c.name == 'schema' }							# needs a real db
						.reject { |c| c.name == 'board configured' }					# needs a real board
						.reject { |c| c.name.start_with?('skill mill:') }			# written in Plan B

					assert_empty failures, failures.map(&:to_s).join("\n")
				end
			end
		end

		# A stage that names a skill it cannot load improvises from memory,
		# silently and at full cost. Doctor must block instead.
		def test_a_missing_skill_blocks_everything
			with_home do |home|
				with_claude_config do |config|
					checked = doctor_for(home, config)
					missing = checked.checks.select { |c| c.name.start_with?('skill') && !c.ok }

					refute_predicate checked, :ok?
					assert_equal ['skill mill:implement', 'skill mill:pr'], missing.map(&:name).sort
				end
			end
		end

		# The version moves underneath mill when a plugin updates, so it is
		# recorded rather than assumed.
		def test_resolved_skills_report_their_version
			with_home do |home|
				with_claude_config do |config|
					found = doctor_for(home, config).checks.select { |c| c.name.start_with?('skill') && c.ok }

					refute_empty found
					assert(found.all? { |c| c.detail.include?('9.9.9') || c.detail.include?('personal') })
				end
			end
		end

		def test_a_missing_home_is_named_not_guessed
			checked = doctor('/nonexistent/mill')

			refute_predicate checked, :ok?
			assert_match(/is missing/, checked.checks.first.detail)
		end

		# ~/.mill holds the stage token, per-repo secrets, and every verdict.
		def test_loose_permissions_are_caught
			with_home do |home|
				FileUtils.chmod(0o755, File.join(home, 'settings'))

				refute check(home, 'settings is 0700').ok
			end
		end

		def test_a_missing_ruleset_is_caught
			with_home(rulesets: :none) do |home|
				refute check(home, 'ruleset for implement').ok
			end
		end

		# ~/.mill/secrets holds the stage token and every repo's env file. A missing
		# one used to emit no check at all, so doctor stayed green while every
		# stage's test suite would fail for want of a variable.
		def test_a_missing_secrets_directory_is_named
			with_home do |home|
				FileUtils.rm_rf(File.join(home, 'secrets'))

				refute check(home, 'secrets is 0700').ok
			end
		end

		# Claude Code matches file permission checks against Edit(...) only, so a
		# Write(...) rule is accepted and enforces nothing. Measured: a workflow
		# file was modified under exactly that rule.
		def test_write_form_deny_rules_are_rejected
			bad = Mill::Rules.for_stage('implement').merge(
				permissions: { deny: Mill::Rules.deny + ['Write(.github/workflows/**)'] })

			with_home(rulesets: { 'implement' => bad }) do |home|
				failed = check(home, 'ruleset for implement')

				refute failed.ok
				assert_match(/Write\(\.\.\.\) rules match nothing/, failed.detail)
			end
		end

		# A non-empty denylist is not the test. A ruleset can carry one irrelevant
		# rule and satisfy every count while protecting nothing that matters.
		def test_a_ruleset_missing_a_mandated_rule_is_rejected
			thin = Mill::Rules.for_stage('implement').merge(permissions: { deny: ['Bash(sl:*)'] })

			with_home(rulesets: { 'implement' => thin }) do |home|
				failed = check(home, 'ruleset for implement')

				refute failed.ok
				assert_match(/missing required deny rules/, failed.detail)
				assert_match(/Edit\(\.github\/workflows\/\*\*\)/, failed.detail)
			end
		end

		# A settings file that parses but is not an object used to raise TypeError
		# out of doctor rather than being reported.
		def test_a_ruleset_that_is_not_an_object_is_reported_not_raised
			with_home do |home|
				File.write(File.join(home, 'settings', 'pr.json'), '[]')

				assert_match(/must be a JSON object/, check(home, 'ruleset for pr').detail)
			end
		end

		# The sandbox's domain allowlist is a proxy and does confine, unlike the
		# permissions allow list. Widening it is a real change in reach.
		def test_egress_beyond_what_mill_writes_is_rejected
			bad = Mill::Rules.for_stage('implement')
			bad[:sandbox][:network][:allowedDomains] = ['rubygems.org']

			with_home(rulesets: { 'implement' => bad }) do |home|
				failed = check(home, 'ruleset for implement')

				refute failed.ok
				assert_match(/network egress differs/, failed.detail)
			end
		end

		# Only the two stages that open or push a pull request reach anything.
		def test_only_pr_and_push_are_given_egress
			Mill::Stages.names.each do |stage|
				allowed = Mill::Rules.for_stage(stage).dig(:sandbox, :network, :allowedDomains)

				if %w[pr push].include?(stage)
					assert_equal %w[github.com], allowed,
						"#{stage} pushes a branch; mill makes every API call from outside the sandbox"
				else
					assert_empty allowed, "#{stage} has no business on the network"
				end
			end
		end

		def test_a_ruleset_with_the_sandbox_off_is_rejected
			bad = Mill::Rules.for_stage('implement')
			bad[:sandbox][:enabled] = false

			with_home(rulesets: { 'implement' => bad }) do |home|
				refute check(home, 'ruleset for implement').ok
			end
		end

		# For tools that read a CA file. Not for gh: Go on macOS ignores this and
		# calls SecTrustEvaluate, which the sandbox blocks.
		def test_every_stage_is_given_a_ca_bundle
			skip 'no CA bundle on this platform' unless Mill::Rules.ca_bundle

			Mill::Stages.names.each do |stage|
				assert_path_exists Mill::Rules.env_for(stage)['SSL_CERT_FILE'],
					"#{stage} has no usable CA bundle"
			end
		end

		# An empty check list makes `all?` true, so an unrun doctor reported the
		# machine green — in a codebase whose fourth principle is fail closed.
		def test_an_unrun_doctor_is_not_ok
			with_home do |home|
				refute_predicate Mill::Doctor.new(home: home), :ok?
			end
		end

		# Doctor demands the canonical ruleset; rake mill:settings is what writes
		# it. If these two disagree, setup can never go green.
		def test_the_rulesets_mill_writes_are_the_ones_doctor_accepts
			Dir.mktmpdir do |home|
				FileUtils.mkdir_p(File.join(home, 'secrets'))
				FileUtils.chmod(0o700, File.join(home, 'secrets'))
				Mill::Rules.write!(home: home)

				bad = doctor(home).checks.select { |c| c.name.start_with?('ruleset') && !c.ok }
				assert_empty bad, bad.map(&:to_s).join("\n")
			end
		end

		# Absolute deny rules are accepted without complaint and enforce nothing,
		# so one naming ~/.ssh looks like protection while providing none.
		def test_absolute_deny_rules_are_rejected
			bad = Mill::Rules.for_stage('implement').merge(
				permissions: { deny: Mill::Rules.deny + ['Read(~/.ssh/**)', 'Edit(/etc/**)'] })

			with_home(rulesets: { 'implement' => bad }) do |home|
				failed = check(home, 'ruleset for implement')

				refute failed.ok
				assert_match(/enforce nothing/, failed.detail)
			end
		end

		# An allow list is advisory in headless mode: anything not denied runs
		# regardless, so moving confinement there turns layer 1 off.
		def test_confinement_in_an_allow_list_is_rejected
			bad = Mill::Rules.for_stage('implement').merge(
				permissions: { deny: Mill::Rules.deny, allow: ['Bash(git:*)'] })

			with_home(rulesets: { 'implement' => bad }) do |home|
				problems = doctor(home).checks
					.select { |c| c.name == 'ruleset for implement' && !c.ok }

				assert_equal 1, problems.length
				assert_match(/allow list/, problems.first.detail)
			end
		end

		def test_an_empty_denylist_is_rejected
			empty = Mill::Rules.for_stage('plan').merge(permissions: { deny: [] })
			with_home(rulesets: { 'plan' => empty }) do |home|
				refute check(home, 'ruleset for plan').ok
			end
		end

		def test_an_unparseable_ruleset_is_named
			with_home do |home|
				File.write(File.join(home, 'settings', 'pr.json'), '{ not json')

				assert_match(/unparseable/, check(home, 'ruleset for pr').detail)
			end
		end

		# Doctor checks the running config, which can drift from the test suite.
		def test_every_stage_argv_passes_its_invariants
			with_home do |home|
				argv_checks = doctor(home).checks.select { |c| c.name.start_with?('argv') }

				assert_equal Mill::Stages.names.length, argv_checks.length
				assert(argv_checks.all?(&:ok), argv_checks.reject(&:ok).map(&:to_s).join("\n"))
			end
		end

		def test_a_red_doctor_is_not_ok
			with_home(rulesets: :none) do |home|
				refute_predicate doctor(home), :ok?
			end
		end

		# --- Plan 3a's preconditions --------------------------------------------

		def teardown
			%w[MILL_CLONES MILL_BIND MILL_ADMIN_EMAILS].each { |name| ENV.delete(name) }
		end

		# These values reach a subprocess environment, and the runbook is the only
		# thing that ever said to chmod them.
		def test_a_world_readable_secrets_file_fails
			with_home do |home|
				path = File.join(home, 'secrets', 'slowernet-rep.env')
				File.write(path, "A=1\n")
				FileUtils.chmod(0o644, path)

				assert_match(/slowernet-rep\.env/, check(home, 'secrets files are 0600').detail)
			end
		end

		def test_correctly_moded_secrets_pass
			with_home do |home|
				path = File.join(home, 'secrets', 'slowernet-rep.env')
				File.write(path, "A=1\n")
				FileUtils.chmod(0o600, path)

				assert_predicate check(home, 'secrets files are 0600'), :ok
			end
		end

		# A root that does not exist silently becomes "clone it myself" for every
		# repo, and mill then works in a checkout nobody is looking at.
		def test_a_clone_root_that_does_not_exist_is_named
			ENV['MILL_CLONES'] = '/no/such/place'

			with_home do |home|
				assert_match(%r{/no/such/place}, check(home, 'clone roots exist').detail)
			end
		end

		def test_no_clone_roots_is_not_a_failure
			ENV['MILL_CLONES'] = ''

			with_home do |home|
				assert_predicate check(home, 'clone roots exist'), :ok
			end
		end

		# The write paths are a kill switch and a worktree deleter. On loopback the
		# interface is the boundary; anywhere else the allowlist is all there is.
		def test_a_public_bind_with_no_admin_list_fails
			ENV['MILL_BIND'] = 'tcp://0.0.0.0:9494'

			with_home do |home|
				refute_predicate check(home, 'bind is loopback or guarded'), :ok
			end
		end

		def test_a_public_bind_with_an_admin_list_passes
			ENV['MILL_BIND'] = 'tcp://0.0.0.0:9494'
			ENV['MILL_ADMIN_EMAILS'] = 'eshepard@slower.net'

			with_home do |home|
				assert_predicate check(home, 'bind is loopback or guarded'), :ok
			end
		end

		def test_the_default_loopback_bind_passes
			with_home do |home|
				assert_predicate check(home, 'bind is loopback or guarded'), :ok
			end
		end

		# mill writes five Status values, and a board missing one fails at the
		# moment it matters — a run blocking, or finishing — rather than at setup.
		def test_a_board_missing_a_status_option_is_named
			gh = Mill::Github.new(runner: lambda { |args|
				next '{"fields":[{"id":"F","name":"Status","options":[{"id":"1","name":"Ready"}]}]}' if
					args[1] == 'field-list'

				'{"data":{"user":{"projectV2":{"workflows":{"nodes":[]}}}}}'
			})

			with_home do |home|
				checked = Mill::Doctor.new(home: home, github: gh, project: '3',
					project_owner: 'slowernet').run
				found = checked.checks.find { |c| c.name == 'board Status has every option mill writes' }

				refute_predicate found, :ok
				assert_match(/Blocked/, found.detail)
			end
		end

		def test_a_complete_board_passes_its_option_check
			gh = Mill::Github.new(runner: lambda { |args|
				next File.read(File.join(__dir__, '..', 'fixtures', 'gh', 'project_fields.json')) if
					args[1] == 'field-list'

				'{"data":{"user":{"projectV2":{"workflows":{"nodes":[]}}}}}'
			})

			with_home do |home|
				checked = Mill::Doctor.new(home: home, github: gh, project: '3',
					project_owner: 'slowernet').run

				assert_predicate checked.checks.find { |c|
					c.name == 'board Status has every option mill writes'
				}, :ok
			end
		end
	end
end
