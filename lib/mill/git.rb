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

		def self.run(repo_path, *args)
			out, err, status = Open3.capture3('git', '-C', repo_path.to_s, *args.map(&:to_s))
			Result.new(out: utf8(out), err: utf8(err), ok: status.success?)
		rescue SystemCallError => e
			Result.new(out: '', err: e.message, ok: false)
		end

		def self.run!(repo_path, *args)
			result = run(repo_path, *args)
			raise Error, "git #{args.first(2).join(' ')} failed: #{result.err.strip[0, 300]}" unless result.ok

			result.out
		end

		# Same reason as Mill::Github#utf8: Open3 tags its output with
		# Encoding.default_external, and a branch name, a path, or a commit message
		# can carry anything. mill pins the default at load too; this is the seam.
		def self.utf8(text)
			text = text.dup.force_encoding(Encoding::UTF_8)
			text.valid_encoding? ? text : text.scrub('')
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

		def self.current_branch(repo_path)
			result = run(repo_path, 'rev-parse', '--abbrev-ref', 'HEAD')
			return nil unless result.ok

			name = result.out.strip
			name == 'HEAD' ? nil : name
		end
	end
end
