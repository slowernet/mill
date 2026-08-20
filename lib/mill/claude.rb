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
		Attempt = Struct.new(:stage, :number, :nonce, :result, :verdict, keyword_init: true) do
			def ok? = result.success? && verdict.valid? && verdict.status == 'ok'
			def blocked? = verdict.valid? && verdict.blocked?
			def rejects? = verdict.valid? && verdict.rejects?
			def session_id = result.stream.session_id
			def resume_failed? = result.stream.resume_failed?
			def rate_limited? = result.stream.rate_limited?
			def rate_limit_resets_at = result.stream.rate_limit_resets_at
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
			args += ['--json-schema', JSON.generate(Mill::Verdict.schema_for(stage))]
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
		def run(prompt, number:, worktree:, log_path:, session_id: nil, env: {}, secrets: [],
			on_spawn: nil)
			nonce = self.class.nonce
			spawn = Mill::Spawn.new(log_path: log_path, chdir: worktree, secrets: secrets,
				on_spawn: on_spawn)
			result = spawn.run(argv(envelope(prompt, number, nonce), session_id: session_id), env: env)

			Attempt.new(stage: stage, number: number, nonce: nonce, result: result,
				verdict: Mill::Verdict.validate(result.stream.verdict_payload, stage: stage,
					number: number, nonce: nonce, worktree: worktree))
		end

		# mill owns the envelope; the stage prompt owns everything above it.
		#
		# `--json-schema` makes the shape a forced tool call, so this no longer has
		# to argue a model out of narrating — an earlier version spent two pages on
		# that and still lost, twice, on the first real run. What is left is the
		# part a schema cannot express: what each field *means*, and when to block.
		def envelope(prompt, number, nonce)
			<<~ENVELOPE
				#{prompt}

				## Your verdict

				Finish by reporting your verdict through the structured output tool. mill reads it
				directly; it is not a message to a person.

				- `stage` is #{stage.to_json}, `attempt` is #{number}, and `nonce` is
				  #{nonce.to_json}. Copy all three exactly. They are how mill knows this verdict
				  came from this launch and not an earlier one.
				- `status` is `ok` only for work you finished and verified. `blocked` if you need a
				  human. `failed` if you could not do it and asking would not help.
				- `questions` must be non-empty when `status` is `blocked`, and absent otherwise.
				  Asking costs you nothing; guessing costs a wrong implementation nobody asked for.
				- `summary` is one paragraph, and it is where your narration belongs — mill puts it
				  in the log and the pull request body.#{envelope_extras}
			ENVELOPE
		end

		def self.nonce = SecureRandom.hex(8)

		private

		def envelope_extras
			extras = []
			extras << "\n- `artifact` is the path to what you produced, relative to this directory."  if config[:artifact]
			extras << "\n- `route` is your decision: `plan`, `fast`, or `iterate`." if stage == 'triage'
			if stage.start_with?('review:')
				extras << "\n- `objections` is what you found. `severity` is one of `critical`, `high`, " \
					"`medium`, `low` — only `critical` and `high` send the work back, so calibrate " \
					"honestly. `claim` is one line; `notes` carries the files, the lines, and the " \
					'argument, and is what the next agent actually reads.'
			end
			extras.join
		end
	end
end
