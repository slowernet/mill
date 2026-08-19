require 'sequel'

# mill — an orchestrator that drives Claude Code through a fixed SDLC.
# Design: docs/superpowers/specs/2026-08-06-software-factory-design.md
# Text mill handles is UTF-8: issue bodies, comments, specs, source files, and
# everything a stage emits. Ruby derives Encoding.default_external from the
# locale, and a server process started by systemd usually has no locale at all —
# so US-ASCII is the expected production condition, not a test artifact. Left
# alone it makes the first emoji in an issue body raise out of JSON.parse.
#
# Pinned here as well as normalised at each seam: this catches the paths nobody
# thought about, and the seams catch the streams whose encoding is fixed when
# the pipe is opened rather than when a string is built.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

module Mill
	class Error < StandardError; end

	ROOT = File.expand_path('..', __dir__)

	# Everything mill owns lives outside any worktree, so no stage can reach it.
	def self.home
		@home ||= File.expand_path(ENV['MILL_HOME'] || '~/.mill')
	end

	def self.db
		@db ||= Mill::DB.connect
	end

	def self.now
		Time.now.utc.to_i
	end

	# Settings are parsed, never coerced. `'lots'.to_i` is 0, and a concurrency cap
	# of 0 makes mill think it is always at capacity: it claims nothing, forever,
	# with every check still green. A rejected value falls back and says so, so the
	# mistake shows up in the log rather than in the absence of work.
	def self.setting_int(name, default:, min:, max:)
		setting(name, default: default, min: min, max: max) { |raw| Integer(raw, 10) }
	end

	def self.setting_float(name, default:, min:, max:)
		setting(name, default: default.to_f, min: min, max: max) { |raw| Float(raw) }
	end

	def self.setting(name, default:, min:, max:)
		raw = ENV[name]
		return default if raw.nil? || raw.strip.empty?

		value = yield(raw.strip)
		return value if value >= min && value <= max

		warn "#{name}=#{raw} is outside #{min}..#{max}; using #{default}"
		default
	rescue ArgumentError, TypeError
		warn "#{name}=#{raw} is not a number; using #{default}"
		default
	end

	# Text mill did not write — gh output, git output, a stage's stdout — is UTF-8
	# whatever the locale claims. A byte that is genuinely undecodable is dropped
	# rather than losing the payload it sits in.
	def self.utf8(text)
		text = text.to_s.dup.force_encoding(Encoding::UTF_8)
		text.valid_encoding? ? text : text.scrub('')
	end
end

require_relative 'mill/clock'
require_relative 'mill/db'
require_relative 'mill/stream'
require_relative 'mill/verdict'
require_relative 'mill/spawn'
require_relative 'mill/stages'
require_relative 'mill/secrets'
require_relative 'mill/rules'
require_relative 'mill/skills'
require_relative 'mill/github'
require_relative 'mill/board'
require_relative 'mill/git'
require_relative 'mill/repo'
require_relative 'mill/supervisor'
require_relative 'mill/poller'
require_relative 'mill/spec'
require_relative 'mill/ledger'
require_relative 'mill/prompts'
require_relative 'mill/runner'
require_relative 'mill/run'
require_relative 'mill/claude'
require_relative 'mill/doctor'
