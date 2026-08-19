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

		# `worktree` is required rather than defaulted. It may be nil for a stage
		# with no tree, but a caller that simply forgets it would silently skip the
		# existence, emptiness, and symlink checks — and a plan stage that wrote
		# nothing would validate clean.
		def self.validate(raw, stage:, invocation:, nonce:, worktree:)
			new(raw, stage: stage, invocation: invocation, nonce: nonce, worktree: worktree).tap(&:validate)
		end

		def initialize(raw, stage:, invocation:, nonce:, worktree:)
			@raw = raw
			@stage = stage
			@invocation = invocation
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
			return fail!('no verdict: the stage ended without a structured message') if @raw.nil? || @raw.strip.empty?

			@data = JSON.parse(@raw, symbolize_names: true)
			return fail!('verdict is not a JSON object') unless @data.is_a?(Hash)

			check_envelope
			check_status
			check_objections
			check_artifact
			check_route
			self
		rescue JSON::ParserError => e
			# Prose after the JSON lands here. Loud and immediate beats quiet.
			fail!("verdict is not valid JSON: #{e.message}")
		end

		private

		def severity_of(objection) = objection[:severity].to_s.strip.downcase

		# The nonce is what makes a stale or replayed verdict unrepresentable: a
		# stage cannot forge one it was never given, and cannot reuse one from an
		# earlier launch.
		def check_envelope
			fail!("stage mismatch: expected #{@stage}, got #{@data[:stage].inspect}") if @data[:stage] != @stage
			fail!("invocation mismatch: expected #{@invocation}, got #{@data[:invocation].inspect}") if @data[:invocation] != @invocation
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
