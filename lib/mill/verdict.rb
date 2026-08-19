require 'json'

module Mill
	# Validates the structured message a stage ends with. A stage that produces no
	# verdict has failed: silence is never success, and mill must never infer a
	# pass from the absence of an error.
	class Verdict
		STATUSES = %w[ok blocked failed].freeze
		ROUTES = %w[plan fast iterate].freeze
		SEVERITIES = %w[critical high medium low].freeze
		SERIOUS = %w[critical high].freeze

		attr_reader :data, :errors

		# The shape mill requires, as JSON Schema, passed to `claude --json-schema`.
		# The CLI turns it into a forced tool call, so a stage cannot wrap its
		# verdict in prose or a code fence — measured 2026-08-19, including under
		# --permission-mode acceptEdits with write tools.
		#
		# This enforces shape only. Everything that depends on *this* launch — the
		# nonce, the artifact resolving inside the worktree, questions iff blocked —
		# stays here, because a schema cannot know any of it.
		def self.schema_for(stage)
			config = Mill::Stages[stage]
			properties = {
				stage: { type: 'string', enum: [stage] },
				attempt: { type: 'integer' },
				nonce: { type: 'string' },
				status: { type: 'string', enum: STATUSES },
				summary: { type: 'string' },
				questions: { type: 'array', items: { type: 'string' } }
			}
			properties[:artifact] = { type: %w[string null] } if config[:artifact]
			properties[:route] = { type: %w[string null], enum: ROUTES + [nil] } if stage == 'triage'
			properties[:objections] = objections_schema if stage.start_with?('review:')

			{ type: 'object', properties: properties,
			  required: %w[stage attempt nonce status summary], additionalProperties: false }
		end

		# The severity enum lives here rather than only in mill's own check: the
		# reviewer skill's output format spells its severities in upper case, and
		# constraining the tool call is what stops that reaching mill at all.
		def self.objections_schema
			{
				type: 'array',
				items: {
					type: 'object',
					properties: {
						severity: { type: 'string', enum: SEVERITIES },
						claim: { type: 'string' },
						notes: { type: 'string' }
					},
					required: %w[severity claim notes], additionalProperties: false
				}
			}
		end

		# `worktree` is required rather than defaulted. It may be nil for a stage
		# with no tree, but a caller that simply forgets it would silently skip the
		# existence, emptiness, and symlink checks — and a plan stage that wrote
		# nothing would validate clean.
		def self.validate(raw, stage:, number:, nonce:, worktree:)
			new(raw, stage: stage, number: number, nonce: nonce, worktree: worktree).tap(&:validate)
		end

		def initialize(raw, stage:, number:, nonce:, worktree:)
			@raw = raw
			@stage = stage
			@number = number
			@nonce = nonce
			@worktree = worktree
			@errors = []
		end

		def valid? = @errors.empty?

		def status = @data && @data[:status]

		def blocked? = status == 'blocked'

		def questions = Array(@data && @data[:questions])

		# A verdict is agent-controlled and untrusted. Anything not shaped the way
		# the contract requires is a validation failure, never a crash: a malformed
		# verdict must cost the stage a strike, not take mill down with it.
		def objections = Array(@data && @data[:objections]).select { |o| o.is_a?(Hash) }

		# A reviewer returns ok with objections; it does not fail. Only high or
		# critical re-runs the stage it reviewed.
		#
		# Matched case-insensitively because the reviewer skill's own output format
		# specifies `Severity: CRITICAL | HIGH | MEDIUM | LOW`. Matching only
		# lowercase read every objection it raised as advisory, so the reviewed
		# stage never re-ran and the whole review gate was inert.
		def serious_objections
			objections.select { |o| SERIOUS.include?(severity_of(o)) }
		end

		def rejects? = serious_objections.any?

		def validate
			@data = coerce
			return self if @data.nil?

			check_envelope
			check_status
			check_objections
			check_artifact
			check_route
			self
		end

		private

		# `--json-schema` makes the CLI return the verdict already parsed, so the
		# usual input here is a Hash. The string path stays for a stage that
		# somehow answered without the tool: it is still a verdict if it parses,
		# and still a failed attempt if it does not.
		def coerce
			return @raw.transform_keys(&:to_sym) if @raw.is_a?(Hash)

			if @raw.nil? || @raw.to_s.strip.empty?
				fail!('no verdict: the stage ended without a structured message')
				return nil
			end

			parsed = JSON.parse(@raw, symbolize_names: true)
			return parsed if parsed.is_a?(Hash)

			fail!('verdict is not a JSON object')
			nil
		rescue JSON::ParserError => e
			fail!("verdict is not valid JSON: #{e.message}")
			nil
		end

		def severity_of(objection) = objection[:severity].to_s.strip.downcase

		# The nonce is what makes a stale or replayed verdict unrepresentable: a
		# stage cannot forge one it was never given, and cannot reuse one from an
		# earlier launch.
		def check_envelope
			fail!("stage mismatch: expected #{@stage}, got #{@data[:stage].inspect}") if @data[:stage] != @stage
			fail!("attempt mismatch: expected #{@number}, got #{@data[:attempt].inspect}") if @data[:attempt] != @number
			fail!('nonce mismatch') if @data[:nonce] != @nonce
		end

		def check_status
			fail!("status must be one of #{STATUSES.join(', ')}") unless STATUSES.include?(@data[:status])

			# Questions must be non-empty iff blocked, or a blocked run has nothing
			# to ask and no way to resume.
			if blocked?
				fail!('blocked without questions') if questions.empty?
			elsif questions.any?
				fail!('questions on a non-blocked verdict')
			end
		end

		def check_objections
			raw = @data[:objections]
			return if raw.nil?
			return fail!('objections must be a list') unless raw.is_a?(Array)
			return fail!('every objection must be an object') unless raw.all? { |o| o.is_a?(Hash) }

			# An unrecognised severity has to fail loudly. Filing it quietly as
			# non-serious is how a critical finding becomes a footnote.
			unknown = raw.reject { |o| SEVERITIES.include?(severity_of(o)) }
			return if unknown.empty?

			fail!("objection severity must be one of #{SEVERITIES.join(', ')}: " \
				"#{unknown.map { |o| o[:severity].inspect }.uniq.join(', ')}")
		end

		def check_artifact
			path = @data[:artifact]
			pattern = Mill::Stages[@stage][:artifact]
			return fail!("#{@stage} must produce an artifact") if pattern && path.nil? && status == 'ok'
			return if path.nil?
			return fail!('artifact must be a string') unless path.is_a?(String)

			fail!('artifact must be relative to the worktree') if path.start_with?('/', '~')
			fail!('artifact escapes the worktree') if path.include?('..')
			fail!("artifact does not match the pattern for #{@stage}") if pattern && !path.match?(pattern)
			check_artifact_on_disk(path) if @worktree
		end

		# File.exist? is true for a directory and File.size reports its inode size,
		# so `mkdir -p docs/superpowers/plans/x.md` passed both checks and handed
		# implement a directory as the plan to execute.
		def check_artifact_on_disk(path)
			full = File.join(@worktree, path)
			return fail!('artifact is not a file') unless File.file?(full)
			fail!('artifact is empty') if File.size(full).zero?
			# Compare against the worktree plus a separator: a bare prefix test lets
			# /tmp/work-evil/x pass for a worktree of /tmp/work.
			root = File.join(File.realpath(@worktree), '')
			fail!('artifact traverses a symlink') unless File.realpath(full).start_with?(root)
		rescue SystemCallError => e
			# The path is agent-controlled. A symlink loop or a vanished worktree
			# costs the stage a strike; it does not take mill down.
			fail!("artifact could not be resolved: #{e.message}")
		end

		# Only triage picks the route. The Evidence directive is the board's alone.
		def check_route
			return if @data[:route].nil?

			fail!('only triage may set a route') unless @stage == 'triage'
			fail!("unknown route: #{@data[:route]}") unless ROUTES.include?(@data[:route])
		end

		def fail!(message)
			@errors << message
			self
		end
	end
end
