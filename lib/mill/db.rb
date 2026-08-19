require 'fileutils'
require 'sequel'

module Mill
	module DB
		MIGRATIONS = File.join(Mill::ROOT, 'db', 'migrations')

		def self.path
			ENV['MILL_DB'] || File.join(Mill.home, 'mill.db')
		end

		# 0700 on ~/.mill: it holds the stage token, per-repo secrets, and every
		# run's verdicts.
		def self.connect(path = self.path)
			unless path == ':memory:'
				dir = File.dirname(path)
				FileUtils.mkdir_p(dir)
				FileUtils.chmod(0o700, dir)
			end

			# Hash form, not a URI: ':memory:' is not parseable as one, and a
			# file path containing spaces would need escaping.
			db = Sequel.connect(adapter: 'sqlite', database: path)
			db.run 'PRAGMA foreign_keys = ON'
			db.run 'PRAGMA journal_mode = WAL' unless path == ':memory:'
			db
		end

		def self.migrate!(db, target: nil)
			Sequel.extension :migration
			Sequel::Migrator.run(db, MIGRATIONS, target: target)
			db
		end
	end
end
