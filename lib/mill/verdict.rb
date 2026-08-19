require 'json'

module Mill
	# Validates the structured message a stage ends with. A stage that produces no
	# verdict has failed: silence is never success, and mill must never infer a
	# pass from the absence of an error.
	class Verdict
		STATUSES = %w[ok blocked failed].freeze
		ROUTES = %w[plan fast iterate].freeze

		attr_reader :data, :errors

		def self.validate(raw, stage:, invocation:, nonce:, worktree: nil)
			new(raw, stage: stage, invocation: invocation, nonce: nonce, worktree: worktree).tap(&:validate)
		end

		def initialize(raw, stage:, invocation:, nonce:, worktree: nil)
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
		def serious_objections
			objections.select { |o| %w[high critical].include?(o[:severity].to_s) }
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

			fail!('every objection must be an object') unless raw.all? { |o| o.is_a?(Hash) }
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

		def check_artifact_on_disk(path)
			full = File.join(@worktree, path)
			return fail!('artifact does not exist') unless File.exist?(full)
			fail!('artifact is empty') if File.size(full).zero?
			# Compare against the worktree plus a separator: a bare prefix test lets
			# /tmp/work-evil/x pass for a worktree of /tmp/work.
			root = File.join(File.realpath(@worktree), '')
			fail!('artifact traverses a symlink') unless File.realpath(full).start_with?(root)
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
