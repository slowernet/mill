require 'json'
require 'securerandom'

module Mill
	# One stage launch, end to end: build argv, mint the nonce and carry it into
	# the prompt, spawn a process group, tee stream-json, accumulate token counts,
	# and validate the verdict that comes back.
	#
	# This is the seam Plan A exists to build. Everything above it — the runner,
	# the ledger, the supervisor — talks to an Attempt and never to a subprocess.
	#
	# Safety invariants (see CLAUDE.md) are enforced here and asserted in
	# test/mill/test_claude_argv.rb — do not weaken either without reading both.
	class Claude
		BANNED_FLAGS = %w[--dangerously-skip-permissions --permission-mode=bypassPermissions].freeze

		# What one launch produced. `ok?` is deliberately narrow: a launch is good
		# only when the process ended cleanly *and* left a verdict that validates.
		# Neither half implies the other, and silence is never success.
		Attempt = Struct.new(:stage, :invocation, :nonce, :result, :verdict, keyword_init: true) do
			def ok? = result.success? && verdict.valid? && verdict.status == 'ok'
			def blocked? = verdict.valid? && verdict.blocked?
			def rejects? = verdict.valid? && verdict.rejects?
			def session_id = result.stream.session_id
			def tokens = result.stream.tokens
			def model = result.stream.model
			def log_path = result.log_path

			# Why this launch is not usable, for the log and the block comment.
			def errors
				problems = []
				problems << "stage did not start: #{result.error.message}" if result.error
				problems << 'stage exited non-zero' if result.error.nil? && !result.success?
				problems + verdict.errors
			end
		end

		attr_reader :stage, :config

		def initialize(stage, home: Mill.home)
			@stage = stage
			@config = Mill::Stages[stage]
			@home = home
		end

		def settings_path = File.join(@home, 'settings', "#{Mill::Stages.slug(stage)}.json")

		def skill = config[:skill]

		# Recorded on every attempt: a plugin update changes what a stage was told
		# without anyone touching mill, and a verdict should be traceable to the
		# text that produced it.
		def resolved_skill = @resolved_skill ||= (Mill::Skills.resolve(skill) if skill)

		def skill_provenance
			return {} unless resolved_skill

			{ skill_source: resolved_skill.path, skill_version: resolved_skill.version }
		end

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

		# The nonce is minted here, per launch, and reaches the stage only through
		# the prompt — which is what makes a stale or replayed verdict
		# unrepresentable. A stage cannot forge one it was never given.
		#
		# `worktree` is both the stage's working directory (layer 1's real
		# filesystem boundary) and the root the artifact must resolve inside.
		def run(prompt, invocation:, worktree:, log_path:, session_id: nil, env: {}, secrets: [])
			nonce = self.class.nonce
			spawn = Mill::Spawn.new(log_path: log_path, chdir: worktree, secrets: secrets)
			result = spawn.run(argv(envelope(prompt, invocation, nonce), session_id: session_id), env: env)

			Attempt.new(stage: stage, invocation: invocation, nonce: nonce, result: result,
				verdict: Mill::Verdict.validate(result.stream.raw_verdict, stage: stage,
					invocation: invocation, nonce: nonce, worktree: worktree))
		end

		# mill owns the envelope; the stage prompt owns everything above it. The
		# severities are spelled out because the reviewer skill's own output format
		# uses upper case, and an unrecognised severity now fails validation rather
		# than quietly demoting a critical finding to a footnote.
		def envelope(prompt, invocation, nonce)
			<<~ENVELOPE
				#{prompt}

				## Your final message

				Your last message must be one JSON object and nothing else. Not a sentence before
				it, not a closing paragraph after it, not a fenced code block around it — mill
				parses that message directly, so a stage that adds any of those fails validation
				and costs itself a strike.

				Everything you would otherwise want to say — what you found, what you did, what
				you noticed along the way — goes in `summary`. That is what the narration is for,
				and it is what mill puts in the log and the pull request body. There is no need to
				repeat it outside the object, and no room to.

				{
				  "stage": #{stage.to_json},
				  "invocation": #{invocation},
				  "nonce": #{nonce.to_json},
				  "status": "ok" | "blocked" | "failed",
				  "summary": "one paragraph, for the log and the pull request body"#{envelope_extras}
				}

				`questions` must be present and non-empty when status is "blocked", and absent
				otherwise. If you cannot proceed, block and ask — asking costs you nothing.
				Never report "ok" for work you did not finish.

				Emit the JSON object now, as your entire final message.
			ENVELOPE
		end

		def self.nonce = SecureRandom.hex(8)

		private

		def envelope_extras
			extras = []
			extras << %(  "artifact": "path/to/file, relative to this directory") if config[:artifact]
			extras << %(  "route": "plan" | "fast" | "iterate") if stage == 'triage'
			extras << %(  "questions": ["..."])
			if stage.start_with?('review:')
				extras << %(  "objections": [{ "severity": "critical|high|medium|low", ) +
					%("claim": "one line", "notes": "files, lines, and the argument" }])
			end
			extras.empty? ? '' : ",\n#{extras.join(",\n")}"
		end
	end
end
