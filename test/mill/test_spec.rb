require 'test_helper'

module Mill
	# Fixture-backed: a fake github and a fake git, no network and no repository.
	class TestSpec < Minitest::Test
		FakeGit = Struct.new(:added, :checked_out, keyword_init: true) do
			def added_files(*) = added
			def checked_out_branches(*) = checked_out
		end

		def github_with(branches)
			Class.new do
				define_method(:linked_branches) { |*| branches }
			end.new
		end

		def locate(branches: ['42-add-widget'], added: ['docs/superpowers/specs/a.md'], checked_out: [])
			Mill::Spec.locate(
				github: github_with(branches),
				git: FakeGit.new(added: added, checked_out: checked_out),
				repo: 'slowernet/mill-scratch', number: 42, repo_path: '/tmp/clone', base: 'main'
			)
		end

		def test_one_linked_branch_adding_one_spec_is_adopted
			located = locate

			assert_predicate located, :found?
			assert_equal '42-add-widget', located.branch
			assert_equal 'docs/superpowers/specs/a.md', located.path
			assert_nil located.problem
		end

		# An issue with no linked branch is not an error: triage may still route it
		# to fast if it is unambiguously hotfix-shaped.
		def test_no_linked_branch_is_reported_rather_than_blocked
			located = locate(branches: [])

			refute_predicate located, :found?
			refute_predicate located, :blocked?
			assert_equal :no_branch, located.problem
		end

		def test_a_branch_that_adds_no_spec_is_reported_rather_than_blocked
			located = locate(added: [])

			refute_predicate located, :blocked?
			assert_equal :no_spec, located.problem
			assert_equal '42-add-widget', located.branch
		end

		# Two specs on one branch is genuinely ambiguous, and mill declining to
		# guess is the feature.
		def test_more_than_one_spec_blocks_and_names_them
			located = locate(added: ['docs/superpowers/specs/a.md', 'docs/superpowers/specs/b.md'])

			assert_predicate located, :blocked?
			assert_equal :many_specs, located.problem
			assert_match(/a\.md/, located.detail)
			assert_match(/b\.md/, located.detail)
		end

		def test_more_than_one_linked_branch_blocks
			located = locate(branches: %w[42-add-widget 42-other])

			assert_predicate located, :blocked?
			assert_equal :many_branches, located.problem
		end

		# git worktree add refuses a branch checked out anywhere, and the design
		# session leaves it current in the clone. mill blocks rather than forcing
		# it: two live checkouts of one branch can silently diverge the ref.
		def test_a_branch_checked_out_in_the_clone_blocks
			located = locate(checked_out: ['main', '42-add-widget'])

			assert_predicate located, :blocked?
			assert_equal :branch_checked_out, located.problem
			assert_match(%r{/tmp/clone}, located.detail)
		end

		# The checkout guard runs before the spec lookup: diffing a branch mill
		# cannot adopt wastes the call and reports the wrong problem.
		def test_the_checkout_guard_runs_before_the_spec_lookup
			located = locate(checked_out: ['42-add-widget'], added: [])

			assert_equal :branch_checked_out, located.problem
		end

		def test_every_blocking_problem_carries_a_question_for_the_operator
			[locate(branches: %w[a b]),
			 locate(added: %w[docs/superpowers/specs/a.md docs/superpowers/specs/b.md]),
			 locate(checked_out: ['42-add-widget'])].each do |located|
				refute_empty located.questions, "#{located.problem} must give the operator something to answer"
			end
		end

		# The ordinary not-found cases are triage's business, not the operator's.
		def test_the_ordinary_cases_ask_nothing
			assert_empty locate(branches: []).questions
			assert_empty locate(added: []).questions
			assert_empty locate.questions
		end
	end
end
