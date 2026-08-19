require 'fileutils'
require 'open3'

module Mill
	# Every git command mill runs. Stages run git themselves inside their worktree;
	# this is mill's own access, and keeping it in one place is what makes the rules
	# about forcing a checkout and clearing stale locks enforceable rather than
	# aspirational.
	module Git
		class Error < Mill::Error; end

		Result = Struct.new(:out, :err, :ok, keyword_init: true)

		# Open3 tags its output with Encoding.default_external, and a branch name, a
		# path, or a commit message can carry anything.
		def self.run(repo_path, *args)
			out, err, status = Open3.capture3('git', '-C', repo_path.to_s, *args.map(&:to_s))
			Result.new(out: Mill.utf8(out), err: Mill.utf8(err), ok: status.success?)
		rescue SystemCallError => e
			Result.new(out: '', err: e.message, ok: false)
		end

		def self.run!(repo_path, *args)
			result = run(repo_path, *args)
			raise Error, "git #{args.first(2).join(' ')} failed: #{result.err.strip[0, 300]}" unless result.ok

			result.out
		end

		# Cloning has no repository to run inside, so it cannot go through `run`.
		# It stays here anyway: this module is the only place mill runs git.
		def self.clone(url, path)
			FileUtils.mkdir_p(File.dirname(path))
			_out, err, status = Open3.capture3('git', 'clone', url.to_s, path.to_s)
			raise Error, "git clone failed: #{Mill.utf8(err).strip[0, 300]}" unless status.success?

			path
		end

		# Only tests need this; it lives here so that they, too, run no git of
		# their own.
		def self.clone_init(path)
			FileUtils.mkdir_p(path)
			run!(path, 'init', '--initial-branch=main')
			run!(path, 'config', 'user.email', 'test@example.com')
			run!(path, 'config', 'user.name', 'Test')
			path
		end

		def self.origin(repo_path)
			result = run(repo_path, 'remote', 'get-url', 'origin')
			result.ok ? result.out.strip : nil
		end

		# The spec is the file the branch *adds* under the prefix, found by diffing
		# rather than by reading a path out of prose. `base...branch` is the
		# three-dot form: what the branch added since it diverged, not everything
		# that differs between the two tips.
		def self.added_files(repo_path, base, branch, prefix)
			out = run!(repo_path, 'diff', '--name-only', '--diff-filter=A',
				"#{base}...#{branch}", '--', prefix)
			out.split("\n").map(&:strip).reject(&:empty?)
		end

		# Includes the clone's own HEAD, not only linked worktrees: `git worktree
		# add` refuses a branch checked out anywhere, and the prescribed design
		# workflow leaves the branch current in the clone.
		def self.checked_out_branches(repo_path)
			out = run!(repo_path, 'worktree', 'list', '--porcelain')
			out.scan(%r{^branch refs/heads/(.+)$}).flatten
		end

		# mill adopts a branch; on the plan route it never creates one, because the
		# branch came from `gh issue develop` and carries the spec.
		def self.worktree_add(repo_path, tree_path, branch)
			FileUtils.mkdir_p(File.dirname(tree_path))
			run!(repo_path, 'worktree', 'add', tree_path, branch)
			tree_path
		end

		def self.worktree_remove(repo_path, tree_path)
			run!(repo_path, 'worktree', 'remove', '--force', tree_path)
		end

		def self.current_branch(repo_path)
			result = run(repo_path, 'rev-parse', '--abbrev-ref', 'HEAD')
			return nil unless result.ok

			name = result.out.strip
			name == 'HEAD' ? nil : name
		end
	end
end
