require 'fileutils'
require 'json'

module Mill
	# The permission rulesets, as data. One definition, written to
	# ~/.mill/settings/<stage>.json by `rake mill:settings` and checked by doctor,
	# so what the runbook creates and what doctor demands cannot drift apart.
	#
	# These are layer 1's *fail-open* third mechanism: they scope paths and commands
	# inside a box the working directory and `--tools` have already closed. Read
	# Containment in the design doc before adding one.
	module Rules
		# Every rule is worktree-relative. An absolute path is accepted without
		# complaint and enforces nothing, so one naming ~/.ssh would look like
		# protection while providing none — doctor rejects any rule containing one.
		#
		# File denies use the Edit(...) form, never Write(...): Claude Code matches
		# file permission checks against Edit rules only, and Edit covers every
		# file-editing tool including Write. A Write(.github/workflows/**) rule was
		# measured modifying the file it claimed to protect.
		REQUIRED_DENY = [
			'Edit(.claude/**)',
			'Edit(.mill.yml)',
			'Edit(.github/workflows/**)',
			'Edit(.github/actions/**)',
			'Read(.env)',
			'Read(.env.*)',
			'Bash(gh issue comment:*)',
			'Bash(gh pr comment:*)',
			'Bash(gh api:*)'
		].freeze

		# Stages cannot comment at all — only Mill::Github comments, and it always
		# stamps the marker. Nothing here may merge: mill never merges.
		EXTRA_DENY = [
			'Bash(gh pr merge:*)',
			'Bash(gh project:*)',
			'Bash(gh auth:*)'
		].freeze

		def self.deny = REQUIRED_DENY + EXTRA_DENY

		# No `allow` key, ever. An allow list is advisory in headless mode — a tool
		# in neither allow nor deny runs anyway — so confinement placed there turns
		# layer 1 off while looking like it tightened something.
		def self.for_stage(_stage)
			{
				permissions: { deny: deny },
				sandbox: { enabled: true }
			}
		end

		def self.write!(home: Mill.home)
			dir = File.join(home, 'settings')
			FileUtils.mkdir_p(dir)
			FileUtils.chmod(0o700, home)
			FileUtils.chmod(0o700, dir)

			Mill::Stages.names.map do |stage|
				path = File.join(dir, "#{Mill::Stages.slug(stage)}.json")
				File.write(path, JSON.pretty_generate(for_stage(stage)))
				FileUtils.chmod(0o600, path)
				path
			end
		end
	end
end
