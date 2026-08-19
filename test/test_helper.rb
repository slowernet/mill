ENV['MILL_DB'] = ':memory:'

require 'minitest/autorun'
require 'mill'

module Mill
	# Gives each test an isolated, migrated in-memory schema. No file, no network.
	class TestCase < Minitest::Test
		attr_reader :db

		def setup
			@db = Mill::DB.connect(':memory:')
			Mill::DB.migrate!(@db)
		end

		def teardown
			@db&.disconnect
		end

		def create_repo(owner: 'slowernet', name: 'mill-scratch', **rest)
			@db[:repos].insert(owner: owner, name: name, created_at: Mill.now, **rest)
		end

		def create_run(repo_id:, subject_number: 1, subject_kind: 'issue', status: 'running', **rest)
			@db[:runs].insert(
				repo_id: repo_id, subject_kind: subject_kind, subject_number: subject_number,
				status: status, created_at: Mill.now, **rest
			)
		end
	end
end
