require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Drives real git against a scratch repository built in a tmpdir. No network.
	class TestGit < Minitest::Test
		def setup
			@repo = Dir.mktmpdir('mill-git')
			git('init', '--initial-branch=main')
			git('config', 'user.email', 'test@example.com')
			git('config', 'user.name', 'Test')
			write('README.md', "# scratch\n")
			git('add', '-A')
			git('commit', '-m', 'first')
		end

		def teardown = FileUtils.remove_entry(@repo, true)

		def git(*args) = Mill::Git.run!(@repo, *args)

		def write(path, body)
			full = File.join(@repo, path)
			FileUtils.mkdir_p(File.dirname(full))
			File.write(full, body)
		end

		# A branch name or commit message can carry anything, and Open3 tags its
		# output with whatever the locale says.
		def test_non_ascii_output_survives_the_locale
			subject = "spec: café \u{1F6A2}"
			git('switch', '-c', 'feature')
			write('notes.md', "x\n")
			git('add', '-A')
			git('commit', '-m', subject)

			log = Mill::Git.run!(@repo, 'log', '-1', '--pretty=%s')

			assert_equal Encoding::UTF_8, log.encoding
			assert_includes log, subject
		end

		def test_a_failing_command_is_reported_not_raised
			result = Mill::Git.run(@repo, 'rev-parse', 'no-such-ref')

			refute result.ok
			refute_empty result.err
		end

		def test_run_bang_raises_with_the_stderr
			error = assert_raises(Mill::Git::Error) { Mill::Git.run!(@repo, 'rev-parse', 'no-such-ref') }

			assert_match(/no-such-ref/, error.message)
		end

		# The spec is the file the branch adds under docs/superpowers/specs/. mill
		# never reads a pasted path, so nothing can be mistyped or go stale.
		def test_added_files_finds_what_a_branch_introduced
			git('switch', '-c', '42-add-widget')
			write('docs/superpowers/specs/2026-08-19-widget.md', "# widget\n")
			write('lib/unrelated.rb', "# not a spec\n")
			git('add', '-A')
			git('commit', '-m', 'spec')

			added = Mill::Git.added_files(@repo, 'main', '42-add-widget', 'docs/superpowers/specs/')

			assert_equal ['docs/superpowers/specs/2026-08-19-widget.md'], added
		end

		# A file the branch only *modified* is not the spec it introduced.
		def test_added_files_ignores_a_modified_file
			write('docs/superpowers/specs/old.md', "# old\n")
			git('add', '-A')
			git('commit', '-m', 'pre-existing spec')
			git('switch', '-c', 'branch-2')
			write('docs/superpowers/specs/old.md', "# old, edited\n")
			git('add', '-A')
			git('commit', '-m', 'edit')

			assert_empty Mill::Git.added_files(@repo, 'main', 'branch-2', 'docs/superpowers/specs/')
		end

		def test_added_files_is_empty_when_the_branch_adds_none
			git('switch', '-c', 'no-spec')
			write('lib/thing.rb', "# code\n")
			git('add', '-A')
			git('commit', '-m', 'code only')

			assert_empty Mill::Git.added_files(@repo, 'main', 'no-spec', 'docs/superpowers/specs/')
		end

		# git worktree add refuses a branch checked out anywhere, including the
		# clone's own HEAD — and the prescribed workflow leaves it that way.
		def test_the_clones_own_head_counts_as_checked_out
			git('switch', '-c', 'held')

			assert_includes Mill::Git.checked_out_branches(@repo), 'held'
			assert_equal 'held', Mill::Git.current_branch(@repo)
		end

		def test_a_worktree_branch_counts_as_checked_out
			Dir.mktmpdir do |elsewhere|
				tree = File.join(elsewhere, 'wt')
				git('worktree', 'add', '-b', 'in-a-worktree', tree)

				assert_includes Mill::Git.checked_out_branches(@repo), 'in-a-worktree'
			ensure
				Mill::Git.run(@repo, 'worktree', 'remove', '--force', tree)
			end
		end

		def test_a_worktree_is_created_on_an_existing_branch
			git('branch', 'work-here')
			Dir.mktmpdir do |elsewhere|
				tree = File.join(elsewhere, 'wt')
				Mill::Git.worktree_add(@repo, tree, 'work-here')

				assert_path_exists File.join(tree, 'README.md')
				assert_includes Mill::Git.checked_out_branches(@repo), 'work-here'

				Mill::Git.worktree_remove(@repo, tree)

				refute_includes Mill::Git.checked_out_branches(@repo), 'work-here'
			end
		end

		# git worktree add refuses a branch checked out anywhere. mill surfaces that
		# as its own error rather than a raw git message, because the taxonomy has a
		# row for it and none for "git said something".
		def test_adding_a_worktree_for_a_held_branch_fails_loudly
			git('switch', '-c', 'held')
			Dir.mktmpdir do |elsewhere|
				assert_raises(Mill::Git::Error) do
					Mill::Git.worktree_add(@repo, File.join(elsewhere, 'wt'), 'held')
				end
			end
		end
	end
end
