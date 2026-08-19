module Mill
	# Finds the spec without anyone typing a path. The issue refers to a branch
	# natively; mill adopts that branch, and the spec is the file it introduced.
	# Nothing can be mistyped or go stale under a rename.
	module Spec
		PREFIX = 'docs/superpowers/specs/'.freeze

		# `problem` distinguishes two kinds of not-found. :no_branch and :no_spec
		# are ordinary — triage may still route the issue to `fast`, so they are
		# reported and not blocked on. The rest are genuinely ambiguous, and mill
		# declining to guess is the feature.
		BLOCKING = %i[many_branches many_specs branch_checked_out].freeze

		Located = Struct.new(:branch, :path, :problem, :detail, keyword_init: true) do
			def found? = problem.nil? && !path.nil?

			def blocked? = BLOCKING.include?(problem)

			def questions
				case problem
				when :many_branches
					["This issue has more than one linked branch (#{detail}). Which one should mill work on?"]
				when :many_specs
					["The branch #{branch} adds more than one file under #{PREFIX} (#{detail}). " \
						'Which one is the spec?']
				when :branch_checked_out
					["The branch #{branch} is checked out in #{detail}. mill will not force a second " \
						'checkout of one branch, because two live checkouts can silently diverge the ref. ' \
						'Switch that clone to another branch and reply here.']
				else
					[]
				end
			end
		end

		def self.locate(github:, repo:, number:, repo_path:, base:, git: Mill::Git)
			branches = Array(github.linked_branches(repo, number))
			return Located.new(problem: :no_branch) if branches.empty?
			return Located.new(problem: :many_branches, detail: branches.join(', ')) if branches.length > 1

			branch = branches.first
			# Checked before the diff: a branch mill cannot adopt is not worth
			# reading, and reporting :no_spec here would name the wrong problem.
			return Located.new(branch: branch, problem: :branch_checked_out, detail: repo_path) if
				git.checked_out_branches(repo_path).include?(branch)

			specs = git.added_files(repo_path, base, branch, PREFIX)
			return Located.new(branch: branch, problem: :no_spec) if specs.empty?
			return Located.new(branch: branch, problem: :many_specs, detail: specs.join(', ')) if
				specs.length > 1

			Located.new(branch: branch, path: specs.first)
		end
	end
end
