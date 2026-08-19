require 'json'
require 'securerandom'

module Mill
	# The only component that spawns a subprocess. Builds argv, tees stream-json,
	# accumulates token counts, and validates the verdict.
	#
	# Safety invariants (see CLAUDE.md) are enforced here and asserted in
	# test/mill/test_claude_argv.rb — do not weaken either without reading both.
	class Claude
		BANNED_FLAGS = %w[--dangerously-skip-permissions --permission-mode=bypassPermissions].freeze

		attr_reader :stage, :config

		def initialize(stage, home: Mill.home)
			@stage = stage
			@config = Mill::Stages[stage]
			@home = home
		end

		def settings_path = File.join(@home, 'settings', "#{Mill::Stages.slug(stage)}.json")

		# `--tools` is the fail-closed boundary and `--strict-mcp-config` stops a
		# stage inheriting the operator's MCP servers. Neither is optional.
		# `acceptEdits` is not bypassPermissions: deny rules still bind under it,
		# but without it headless mode refuses every file write.
		def argv(prompt, session_id: nil)
			args = ['claude', '-p', prompt]
			args += ['--model', config[:model]]
			args += ['--tools', config[:tools].join(',')]
			args += ['--settings', settings_path]
			args << '--strict-mcp-config'
			args += ['--output-format', 'stream-json', '--verbose']
			args += ['--permission-mode', config[:permission_mode]] if config[:permission_mode]
			args += ['--resume', session_id] if session_id
			args
		end

		def self.nonce = SecureRandom.hex(8)
	end
end
