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
end

require_relative 'mill/clock'
require_relative 'mill/db'
require_relative 'mill/stream'
require_relative 'mill/verdict'
require_relative 'mill/spawn'
require_relative 'mill/stages'
require_relative 'mill/rules'
require_relative 'mill/skills'
require_relative 'mill/github'
require_relative 'mill/claude'
require_relative 'mill/doctor'
