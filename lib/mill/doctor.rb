require 'json'

module Mill
	# Verifies every precondition and names what is missing. Most of what it
	# checks is critical to containment, so a red doctor blocks everything.
	class Doctor
		Check = Struct.new(:name, :ok, :detail, keyword_init: true) do
			def to_s = "#{ok ? '✓' : '✗'} #{name}#{detail ? " — #{detail}" : ''}"
		end

		attr_reader :checks

		def initialize(home: Mill.home, github: nil, config_dir: Mill::Skills.config_dir,
			project: ENV.fetch('MILL_PROJECT', nil), project_owner: ENV.fetch('MILL_PROJECT_OWNER', nil))
			@home = home
			@github = github
			@config_dir = config_dir
			@project = project
			@project_owner = project_owner
			@checks = []
			@ran = false
		end

		def run
			check_home_permissions
			check_stage_settings
			check_argv_invariants
			check_skills
			check_schema
			check_secret_modes
			check_clone_roots
			check_bind
			check_board
			check_board_options
			@ran = true
			self
		end

		# False until run, because an empty check list makes `all?` true and an
		# unrun doctor would report the machine green. Fail closed.
		def ok? = @ran && @checks.all?(&:ok)

		def report = @checks.map(&:to_s).join("\n")

		private

		def pass(name, detail = nil) = @checks << Check.new(name: name, ok: true, detail: detail)

		def fail(name, detail) = @checks << Check.new(name: name, ok: false, detail: detail)

		# ~/.mill holds the stage token, per-repo secrets, and every run's verdicts.
		# A missing subdirectory is a failure, not a check to skip: secrets that are
		# absent make every stage's test suite fail identically on both attempts.
		def check_home_permissions
			return fail('~/.mill exists', "#{@home} is missing — run setup") unless Dir.exist?(@home)

			%w[. secrets settings].each do |sub|
				path = File.expand_path(sub, @home)
				next fail("#{sub} is 0700", "#{path} is missing — see the setup runbook") unless Dir.exist?(path)

				mode = File.stat(path).mode & 0o777
				if mode == 0o700
					pass("#{sub} is 0700")
				else
					fail("#{sub} is 0700", format('%s is %04o', path, mode))
				end
			end
		end

		# Three separate traps, each of which leaves a ruleset that reads as
		# protection and enforces nothing.
		def check_stage_settings
			Mill::Stages.names.each { |stage| check_ruleset(stage) }
		end

		def check_ruleset(stage)
			name = "ruleset for #{stage}"
			path = File.join(@home, 'settings', "#{Mill::Stages.slug(stage)}.json")
			return fail(name, "#{path} is missing — run rake mill:settings") unless File.exist?(path)

			settings = JSON.parse(File.read(path), symbolize_names: true)
			return fail(name, 'must be a JSON object') unless settings.is_a?(Hash)

			@stage_under_check = stage
			problems = ruleset_problems(settings)
			deny = Array(settings.dig(:permissions, :deny))
			problems.empty? ? pass(name, "#{deny.length} deny rules") : fail(name, problems.join('; '))
		rescue JSON::ParserError => e
			fail(name, "unparseable: #{e.message}")
		end

		def ruleset_problems(settings)
			deny = Array(settings.dig(:permissions, :deny)).grep(String)
			problems = []

			# An absolute path is accepted without complaint and enforces nothing;
			# the working directory already covers everything outside the worktree.
			absolute = deny.grep(/\(\s*[\/~]/)
			problems << "absolute deny rules enforce nothing: #{absolute.join(', ')}" if absolute.any?

			# Claude Code matches file permission checks against Edit(...) only, so a
			# Write(...) rule silently does nothing. Measured: a workflow file was
			# modified under exactly that rule and blocked under the Edit form.
			write_form = deny.grep(/\AWrite\(/)
			problems << "Write(...) rules match nothing, use Edit(...): #{write_form.join(', ')}" if write_form.any?

			missing = Mill::Rules::REQUIRED_DENY - deny
			problems << "missing required deny rules: #{missing.join(', ')}" if missing.any?

			# An allow list is advisory in headless mode; anything not denied
			# runs regardless. Treating it as a boundary turns layer 1 off.
			problems << 'confinement must not live in an allow list' if Array(settings.dig(:permissions, :allow)).any?
			problems + network_problems(settings)
		end

		# The sandbox's domain allowlist is a proxy and does confine, so widening it
		# is a real change in what a stage can reach. Only the two stages that open
		# or push a pull request get any egress at all.
		def network_problems(settings)
			return ['the Bash sandbox must be enabled'] unless settings.dig(:sandbox, :enabled)

			allowed = Array(settings.dig(:sandbox, :network, :allowedDomains))
			expected = Mill::Rules::NETWORK.fetch(@stage_under_check, [])
			return [] if allowed.sort == expected.sort

			["network egress differs from the ruleset mill writes: allowed #{allowed.inspect}, " \
				"expected #{expected.inspect}"]
		end

		# The argv builder carries the containment flags. These are asserted in the
		# test suite too; doctor checks the running config, which can differ.
		def check_argv_invariants
			Mill::Stages.names.each do |stage|
				args = Mill::Claude.new(stage, home: @home).argv('probe')
				problems = []
				problems << 'missing --tools' unless args.include?('--tools')
				problems << 'missing --strict-mcp-config' unless args.include?('--strict-mcp-config')
				problems << 'missing --settings' unless args.include?('--settings')
				problems << 'confinement in an allow list' if args.include?('--allowed-tools')
				Mill::Claude::BANNED_FLAGS.each { |f| problems << "banned flag #{f}" if args.include?(f) }

				config = Mill::Stages[stage]
				problems << 'names a skill but cannot load one' if config[:skill] && !config[:tools].include?('Skill')
				if (config[:tools] & %w[Write Edit]).any? && config[:permission_mode] != 'acceptEdits'
					problems << 'holds a write tool but cannot write'
				end

				problems.empty? ? pass("argv for #{stage}") : fail("argv for #{stage}", problems.join('; '))
			end
		end

		# A stage that names a skill it cannot load does not fail — it improvises
		# from memory, silently, at full cost, and the CLI reports nothing. The
		# version is recorded because it moves underneath mill: a plugin update
		# changes what a stage was told without anyone touching mill.
		def check_skills
			Mill::Skills.required(config_dir: @config_dir).each do |skill|
				if skill.found?
					pass("skill #{skill.name}", "#{skill.kind} #{skill.version}")
				else
					fail("skill #{skill.name}", skill.detail)
				end
			end
		end

		# Tables alone are not enough. A database several migrations behind has
		# every table and is still missing columns mill writes — and it fails at the
		# moment a run is claimed, deep inside a worker thread, rather than here.
		# Measured 2026-08-19: the first real poll against a stale database raised
		# `table runs has no column named board_item_id` on every tick, and doctor
		# had reported the schema green.
		def check_schema
			db = Mill.db
			missing = %i[repos runs stage_attempts ci_fixes events] - db.tables
			return fail('schema', "missing tables: #{missing.join(', ')}") if missing.any?

			latest = Dir[File.join(Mill::DB::MIGRATIONS, '*.rb')]
				.map { |path| File.basename(path).to_i }.max
			applied = db[:schema_info].get(:version).to_i

			if applied >= latest
				pass('schema', "migration #{applied}")
			else
				fail('schema', "database is at migration #{applied}, code expects #{latest} — " \
					'run `bundle exec rake mill:migrate`')
			end
		rescue StandardError => e
			fail('schema', e.message)
		end

		# mill is the sole writer of Status. Projects v2 automation writes it too,
		# and "Item closed → Done" would flip Status out from under a Running run,
		# leaving the poller blind to a live subprocess.
		#
		# Settled 2026-08-19: ProjectV2Workflow exposes `enabled`, so this is a
		# direct check rather than the sentinel the design planned as a fallback.
		# These values reach a subprocess environment. A mode drift is otherwise
		# silent, and the runbook is the only thing that ever said to chmod them.
		def check_secret_modes
			dir = File.join(@home, 'secrets')
			return unless Dir.exist?(dir)

			loose = Dir.children(dir).select do |name|
				path = File.join(dir, name)
				File.file?(path) && (File.stat(path).mode & 0o777) != Mill::Secrets::MODE
			end

			if loose.empty?
				pass('secrets files are 0600')
			else
				fail('secrets files are 0600', "#{loose.sort.join(', ')} — chmod 600 them")
			end
		end

		# A root that does not exist silently turns into "clone it myself" for
		# every repo, and mill then works in a checkout you are not looking at.
		def check_clone_roots
			missing = Mill::Repo.roots.reject { |root| Dir.exist?(root) }

			if missing.empty?
				pass('clone roots exist', Mill::Repo.roots.empty? ? 'none set; mill clones its own' : nil)
			else
				fail('clone roots exist', "MILL_CLONES names #{missing.join(', ')}, which do not exist")
			end
		end

		# The write paths are a kill switch and a worktree deleter, and the log
		# endpoint streams repo contents. On loopback the interface is the boundary;
		# anywhere else, the allowlist is the only thing in front of them.
		def check_bind
			bind = ENV['MILL_BIND'].to_s
			return pass('bind is loopback or guarded', 'loopback') if
				bind.empty? || bind.include?('127.0.0.1') || bind.include?('localhost')

			if ENV['MILL_ADMIN_EMAILS'].to_s.strip.empty?
				fail('bind is loopback or guarded',
					"MILL_BIND=#{bind} is reachable off this machine and MILL_ADMIN_EMAILS is empty")
			else
				pass('bind is loopback or guarded', bind)
			end
		end

		# mill writes five Status values. A board missing one fails at the moment
		# it matters — a run finishing, or blocking — rather than at setup.
		def check_board_options
			return if @project.nil? || @project_owner.nil?

			github = @github || Mill::Github.new
			status = github.project_fields(@project, owner: @project_owner)
				.find { |field| field[:name] == 'Status' }
			return fail('board Status has every option mill writes', 'no Status field') if status.nil?

			names = status.fetch(:options, []).map { |option| option[:name] }
			missing = Mill::Board::STATUS.values.uniq - names

			if missing.empty?
				pass('board Status has every option mill writes')
			else
				fail('board Status has every option mill writes', "missing #{missing.join(', ')}")
			end
		rescue StandardError => e
			fail('board Status has every option mill writes', e.message)
		end

		def check_board
			return fail('board configured', 'set MILL_PROJECT and MILL_PROJECT_OWNER — see the runbook') if
				@project.nil? || @project_owner.nil?

			github = @github || Mill::Github.new
			enabled = github.project_workflows(@project, owner: @project_owner)
				.select { |w| w[:enabled] }

			if enabled.empty?
				pass('board built-in workflows are off')
			else
				fail('board built-in workflows are off',
					"mill must be the sole writer of Status: #{enabled.map { |w| w[:name] }.join(', ')}")
			end
		rescue StandardError => e
			fail('board built-in workflows are off', e.message)
		end
	end
end
