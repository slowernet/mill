require 'sequel'

# mill — an orchestrator that drives Claude Code through a fixed SDLC.
# Design: docs/superpowers/specs/2026-08-06-software-factory-design.md
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

require_relative 'mill/db'
require_relative 'mill/stages'
require_relative 'mill/claude'
