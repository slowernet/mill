module Mill
	# What a stage runs with beyond its own argv. A fresh worktree holds tracked
	# files only, so .env and config/master.key are absent and a repo whose suite
	# needs them would fail identically on both attempts — which reads as the stage
	# being wrong and is not.
	#
	# Values from here reach a subprocess environment, so every caller also hands
	# them to Spawn's scrubber. Not all of them: see SHORTEST_REDACTABLE.
	module Secrets
		MODE = 0o600

		# Pushing is the only thing a stage does that needs a credential of its own.
		PUSHING = %w[pr push].freeze

		# A value shorter than this is not redacted, because redacting it does more
		# damage than leaking it. The scrubber gsubs literally over every log line,
		# and the log is stream-json that mill's own parser reads back: an env file
		# carrying RAILS_ENV=test turns every "test" in the transcript into
		# [redacted], and DEBUG=true turns "success":true into "success":[redacted],
		# which stops being JSON. The stage then reads as having produced no verdict
		# and is charged a strike for mill's own scrubber. No real credential is
		# this short.
		SHORTEST_REDACTABLE = 16

		def self.dir = File.join(Mill.home, 'secrets')

		def self.path_for(owner, name) = File.join(dir, "#{owner}-#{name}.env")

		def self.for_repo(owner, name)
			return {} if owner.nil? || name.nil?

			read_env(path_for(owner, name))
		end

		# The narrow token the pushing stages carry. Setting GH_TOKEN is enough:
		# the credential helper the runbook configures asks gh for a credential, and
		# gh honours GH_TOKEN over its stored login — so one variable re-points both
		# `gh` and `git push` at the scoped token without touching the worktree.
		def self.token
			path = File.join(dir, 'stage-token')
			return nil unless File.exist?(path)

			check_mode!(path)
			value = Mill.utf8(File.read(path)).strip
			value.empty? ? nil : value
		end

		# Exactly the strings that must never appear in a log, and no others.
		def self.values_for(stage, owner: nil, name: nil)
			values = for_repo(owner, name).values
			values += [token].compact if PUSHING.include?(stage)
			values.reject { |value| value.to_s.length < SHORTEST_REDACTABLE }
		end

		def self.read_env(path)
			return {} unless File.exist?(path)

			check_mode!(path)
			parse(File.read(path))
		end

		def self.parse(text)
			Mill.utf8(text).lines.filter_map do |line|
				line = line.strip
				next if line.empty? || line.start_with?('#')

				key, value = line.split('=', 2)
				next if value.nil?

				key = key.strip
				key.empty? ? nil : [key, unquote(value.strip)]
			end.to_h
		end

		# Matching quotes only. A value that opens with one quote and closes with
		# another is not quoted, it is a value containing quotes.
		def self.unquote(value)
			return value if value.length < 2

			%w[" '].each do |quote|
				return value[1..-2] if value.start_with?(quote) && value.end_with?(quote)
			end
			value
		end

		def self.check_mode!(path)
			mode = File.stat(path).mode & 0o777
			return if mode == MODE

			raise Mill::Error, "#{path} is mode #{format('%o', mode)}, expected 600"
		end
	end
end
