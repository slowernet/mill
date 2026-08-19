# frozen-string-literal: true

require 'bundler'
Bundler.require

require_relative 'lib/mill'

# Plan 4 mounts the run list, the log tail and the kill switch beside this.
# Plan 3a needs one thing from the web layer: somewhere for the two worker
# threads to live, and a way to tell whether they are still alive.
class App < Roda
	plugin :json

	# Built here, started in config.ru. Starting threads as a side effect of
	# `require` means anything that loads this file — a test, a console, a rake
	# task — silently starts polling a real board.
	#
	# Built now rather than on first use because App.freeze makes the class
	# immutable, and a request is too late to memoise anything onto it.
	@workers = Mill::Workers.new

	class << self
		attr_reader :workers
	end

	route do |r|
		r.root do
			{ workers: App.workers.health, runs: Mill.db[:runs].where(status: 'running').count }
		end
	end
end
