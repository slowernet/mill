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
	end
end
