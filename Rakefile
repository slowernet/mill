require 'rake/testtask'

# Everything fixture-backed. No network, no tokens, no `claude`. This is CI.
Rake::TestTask.new(:test) do |t|
	t.libs << 'lib' << 'test'
	t.test_files = FileList['test/**/test_*.rb'].exclude('test/boundary/**/*')
	t.warning = false
end

namespace :test do
	desc 'Permission ruleset against the real claude CLI. Cannot run in CI.'
	Rake::TestTask.new(:boundary) do |t|
		t.libs << 'lib' << 'test'
		t.test_files = FileList['test/boundary/test_*.rb']
		t.warning = false
	end
end

namespace :mill do
	desc 'Create or update the schema'
	task :migrate do
		require_relative 'lib/mill'
		db = Mill::DB.connect
		Mill::DB.migrate!(db)
		puts "migrated #{Mill::DB.path}"
	end
end

task default: :test
