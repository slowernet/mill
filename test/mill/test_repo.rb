require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Real git in a tmpdir, no network: the "remote" is a bare repository on disk.
	class TestRepo < Mill::TestCase
		def setup
			super
			@root = Dir.mktmpdir('mill-repo')
			@home = File.join(@root, 'home')
			@clones = File.join(@root, 'code')
			FileUtils.mkdir_p([@home, @clones])
			Mill.instance_variable_set(:@home, @home)
			ENV['MILL_CLONES'] = @clones
			@origin = build_origin
		end

		def teardown
			FileUtils.remove_entry(@root, true)
			Mill.instance_variable_set(:@home, nil)
			ENV.delete('MILL_CLONES')
			super
		end

		# A bare repo standing in for github.com/slowernet/rep. The path has to end
		# in owner/name.git, because that is what Repo.slug reads — a bare repo at
		# some arbitrary tmpdir path would not resolve to the right slug and the
		# test would be exercising nothing.
		def build_origin(owner = 'slowernet', name = 'rep')
			path = File.join(@root, 'remote', owner, "#{name}.git")
			FileUtils.mkdir_p(File.dirname(path))
			Mill::Git.run!(seed, 'clone', '--bare', seed, path)
			path
		end

		def seed
			@seed ||= begin
				path = File.join(@root, 'seed')
				Mill::Git.clone_init(path)
				File.write(File.join(path, 'README.md'), "# seed\n")
				Mill::Git.run!(path, 'add', '-A')
				Mill::Git.run!(path, 'commit', '-m', 'first')
				path
			end
		end

		def place_clone(dir_name, origin_url = @origin)
			Mill::Git.clone(origin_url, File.join(@clones, dir_name))
		end

		def test_one_matching_clone_is_used_as_it_stands
			expected = place_clone('rep')

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal expected, result.path
		end

		# Choosing between two silently means working in a checkout you did not
		# pick, and committing to it for the whole run.
		def test_two_matching_clones_block_rather_than_choosing
			place_clone('rep')
			place_clone('rep-again')

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			refute_predicate result, :ok?
			assert_equal :ambiguous_clone, result.problem
			assert_match(/more than one/, result.questions.first)
			assert_match(/rep-again/, result.questions.first)
		end

		# The server case: nothing on disk, so mill makes its own.
		def test_no_match_clones_into_mills_own_directory
			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal File.join(@home, 'clones', 'slowernet-rep'), result.path
			assert_path_exists File.join(result.path, '.git')
		end

		def test_a_clone_mill_already_made_is_reused_rather_than_remade
			first = Mill::Repo.resolve('slowernet', 'rep', url: @origin)
			marker = File.join(first.path, 'MARKER')
			File.write(marker, 'x')

			second = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_equal first.path, second.path
			assert_path_exists marker
		end

		def test_a_directory_that_is_not_a_repository_is_ignored
			FileUtils.mkdir_p(File.join(@clones, 'rep'))

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal File.join(@home, 'clones', 'slowernet-rep'), result.path
		end

		# A directory full of clones is the normal laptop case, and only the one
		# whose origin matches may be picked.
		def test_a_clone_of_a_different_repo_is_not_a_match
			place_clone('something-else')
			other = build_origin('slowernet', 'other')

			result = Mill::Repo.resolve('slowernet', 'other', url: other)

			assert_equal File.join(@home, 'clones', 'slowernet-other'), result.path
		end

		# The same repository is written four ways depending on how it was cloned.
		def test_every_origin_form_names_the_same_repository
			%w[
				git@github.com:slowernet/rep.git
				https://github.com/slowernet/rep.git
				https://github.com/slowernet/rep
				ssh://git@github.com/slowernet/rep.git
			].each do |url|
				assert_equal 'slowernet/rep', Mill::Repo.slug(url), url
			end
		end

		def test_slug_is_case_insensitive
			assert_equal 'slowernet/rep', Mill::Repo.slug('https://github.com/SlowerNet/Rep.git')
		end

		def test_roots_default_by_platform
			ENV.delete('MILL_CLONES')

			roots = Mill::Repo.roots

			if Mill::Clock::DARWIN
				assert_equal [File.expand_path('~/code')], roots
			else
				assert_empty roots
			end
		end

		def test_roots_accept_several_directories
			ENV['MILL_CLONES'] = "#{@clones}:#{@root}"

			assert_equal [@clones, @root], Mill::Repo.roots
		end

		def test_a_root_that_does_not_exist_is_not_an_error
			ENV['MILL_CLONES'] = '/no/such/place'

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal File.join(@home, 'clones', 'slowernet-rep'), result.path
		end

		# A clone mill cannot make is a problem to report, not an exception to
		# throw at the poller loop.
		def test_a_clone_that_fails_reports_rather_than_raising
			result = Mill::Repo.resolve('slowernet', 'rep', url: File.join(@root, 'not-a-repo'))

			refute_predicate result, :ok?
			assert_equal :clone_failed, result.problem
		end

		# --- preparation --------------------------------------------------------

		def prepare = Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

		def repo_id = db[:repos].where(owner: 'slowernet', name: 'rep').get(:id)

		def commit_to_base(clone, path, body)
			File.write(File.join(clone, path), body)
			Mill::Git.run!(clone, 'add', '-A')
			Mill::Git.run!(clone, 'commit', '-m', "add #{path}")
			Mill::Git.run!(clone, 'push', 'origin', 'main')
		end

		def write_secret_file(name, body)
			FileUtils.mkdir_p(File.join(@home, 'secrets'))
			path = File.join(@home, 'secrets', name)
			File.write(path, body)
			FileUtils.chmod(0o600, path)
		end

		# A stage's commit must not trigger a gc that rewrites refs while other
		# runs are holding them.
		def test_preparation_sets_the_config_that_stops_a_stage_triggering_gc
			place_clone('rep')

			result = prepare

			assert_predicate result, :ok?
			assert_equal '0', Mill::Git.run!(result.path, 'config', 'gc.auto').strip
			assert_equal '0', Mill::Git.run!(result.path, 'config', 'maintenance.auto').strip
		end

		def test_preparation_caches_the_repo_row
			place_clone('rep')
			prepare
			row = db[:repos].where(id: repo_id).first

			refute_nil row[:prepared_at]
			assert_equal 'main', row[:base_branch]
			assert_equal File.join(@clones, 'rep'), row[:local_path]
		end

		# .mill.yml is read from the base branch, never from a checkout: an agent
		# can edit it in its own worktree and that edit must not weaken the next run.
		def test_reads_the_config_from_the_base_branch_only
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml',
				"test_command: bundle exec rake test\nsecrets:\n  - API_KEY\n")
			Mill::Git.run!(clone, 'switch', '-c', 'feature')
			File.write(File.join(clone, '.mill.yml'), "secrets: []\n")
			write_secret_file('slowernet-rep.env', "API_KEY=x\n")

			prepare
			config = Mill::Repo.config(db, repo_id)

			assert_equal 'bundle exec rake test', config[:test_command]
			assert_equal ['API_KEY'], config[:secrets]
		end

		def test_a_repo_with_no_config_file_prepares_anyway
			place_clone('rep')

			assert_predicate prepare, :ok?
			assert_empty Mill::Repo.config(db, repo_id)
		end

		# A missing secret fails the suite on both attempts, which reads as the
		# stage being wrong. Say so before the run starts instead.
		def test_a_named_secret_that_is_absent_blocks_the_item
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml', "secrets:\n  - API_KEY\n  - DATABASE_URL\n")

			result = prepare

			refute_predicate result, :ok?
			assert_equal :missing_secrets, result.problem
			assert_match(/API_KEY/, result.questions.first)
			assert_match(/DATABASE_URL/, result.questions.first)
		end

		def test_a_named_secret_that_is_present_does_not_block
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml', "secrets:\n  - API_KEY\n")
			write_secret_file('slowernet-rep.env', "API_KEY=x\n")

			assert_predicate prepare, :ok?
		end

		def test_a_prepared_repo_is_not_prepared_twice
			place_clone('rep')
			prepare
			first = db[:repos].where(id: repo_id).get(:prepared_at)
			db[:repos].where(id: repo_id).update(local_path: '/gone')

			result = prepare

			assert_equal '/gone', result.path
			assert_equal first, db[:repos].where(id: repo_id).get(:prepared_at)
		end

		# A config file that does not parse blocks the item. Left to raise it would
		# wedge the poller loop in a retry cycle instead.
		def test_a_config_file_that_does_not_parse_blocks_the_item
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml', "secrets:\n  - [unclosed\n")

			result = prepare

			refute_predicate result, :ok?
			assert_equal :unprepared, result.problem
			assert_match(/\.mill\.yml/, result.questions.first)
		end

		# safe_load rejects Date by default, and an unquoted date in YAML is a Date.
		# That must block the item, not escape as an unhandled Psych error.
		def test_a_config_file_with_a_disallowed_class_blocks_the_item
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml', "released: 2026-08-19\n")

			result = prepare

			refute_predicate result, :ok?
			assert_equal :unprepared, result.problem
		end

		# A YAML file that parses to something other than a mapping is not config.
		def test_a_config_file_that_is_not_a_mapping_is_ignored
			clone = place_clone('rep')
			commit_to_base(clone, '.mill.yml', "- one\n- two\n")

			assert_predicate prepare, :ok?
			assert_empty Mill::Repo.config(db, repo_id)
		end

		def test_an_unresolvable_clone_reports_rather_than_preparing
			place_clone('rep')
			place_clone('rep-again')

			result = prepare

			assert_equal :ambiguous_clone, result.problem
			assert_nil repo_id
		end
	end
end
