require 'test_helper'

module Mill
	# Fixture-backed: never reaches the network, never runs gh.
	class TestGithub < Minitest::Test
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'gh')
		# Built from escapes rather than literals so this file stays ASCII and the
		# test cannot pass because an editor normalised something.
		EMOJI = "Ship it \u{1F6A2} \u2014 caf\u00E9, \u65E5\u672C\u8A9E, \u{1F469}\u{1F3FD}\u200D\u{1F680}".freeze

		def fixture(name) = File.read(File.join(FIXTURES, "#{name}.json"))

		# Records what was asked of gh so the arguments can be asserted too.
		def recording(response = '{}')
			calls = []
			gh = Mill::Github.new(runner: lambda { |args|
				calls << args
				response.respond_to?(:call) ? response.call(args) : response
			})
			[gh, calls]
		end

		def test_reads_linked_branches_without_creating_one
			gh, calls = recording(fixture('linked_branches'))

			assert_equal ['42-add-widget'], gh.linked_branches('slowernet/mill-scratch', 42)
			assert_equal %w[api graphql], calls.first.first(2)
			refute_includes calls.flatten.join(' '), 'issue develop'
		end

		def test_an_issue_with_no_linked_branch_yields_nothing
			gh, = recording('{"data":{"repository":{"issue":{"linkedBranches":{"nodes":[]}}}}}')

			assert_empty gh.linked_branches('slowernet/mill-scratch', 43)
		end

		# The board is Projects v2, which is GraphQL-only — never `gh issue list`.
		def test_the_board_is_never_read_with_issue_list
			gh, calls = recording(fixture('board_items'))
			items = gh.board_items(3, owner: 'slowernet')

			assert_equal 2, items.length
			assert_equal 'Ready', items.first[:status]
			assert_equal %w[project item-list], calls.first.first(2)
			refute_includes calls.flatten, 'issue'
		end

		# pr_number is recovered, not stored: a crash between `gh pr create` and the
		# state write must reconcile rather than open a second PR.
		def test_a_pr_is_recovered_by_head_branch
			gh, calls = recording("[#{fixture('pr_view')}]")

			assert_equal 50, gh.pr_for_branch('slowernet/mill-scratch', '42-fix-null')[:number]
			assert_includes calls.first, '--head'
		end

		def test_no_pr_for_a_branch_is_not_an_error
			gh, = recording(fixture('pr_list_empty'))

			assert_nil gh.pr_for_branch('slowernet/mill-scratch', 'nope')
		end

		# --- the rules that keep strangers out --------------------------------

		def test_only_collaborators_can_trigger_a_run
			comments = JSON.parse(fixture('comments'), symbolize_names: true)
			trusted = comments.select { |c| Mill::Github.trusted_author?(c) }

			assert_equal [1, 3, 4], trusted.map { |c| c[:id] }
			refute Mill::Github.trusted_author?(comments[1]), 'a stranger must not drive a stage'
		end

		def test_an_absent_or_junk_association_is_not_trusted
			[{}, { author_association: nil }, { author_association: 'NONE' },
			 { author_association: 'CONTRIBUTOR' }, nil, 'string'].each do |c|
				refute Mill::Github.trusted_author?(c), "#{c.inspect} must not be trusted"
			end
		end

		# GitHub's quote-reply copies the marker, so a whole-body search would
		# silently discard the operator's answer — the only channel that reaches a
		# human.
		def test_a_quoted_marker_is_the_operator_not_mill
			comments = JSON.parse(fixture('comments'), symbolize_names: true)
			mine = comments.find { |c| c[:id] == 3 }
			quote_reply = comments.find { |c| c[:id] == 4 }

			assert Mill::Github.own_comment?(mine[:body])
			refute Mill::Github.own_comment?(quote_reply[:body]),
				'a quote-reply carries the marker and must still be read as an answer'
		end

		def test_an_ordinary_comment_is_not_mine
			refute Mill::Github.own_comment?('please fix the null check')
			refute Mill::Github.own_comment?(nil)
			refute Mill::Github.own_comment?('')
		end

		def test_every_comment_mill_writes_is_stamped
			gh, calls = recording('')
			gh.comment('slowernet/mill-scratch', 42, "Blocked: which spec?\n")
			body = calls.first[calls.first.index('--body') + 1]

			assert body.start_with?(Mill::Github::MARKER), 'marker must be the first line'
			assert Mill::Github.own_comment?(body)
		end

		# Checking out a fork head executes a stranger's CLAUDE.md and bin/.
		def test_a_fork_head_is_refused
			same = JSON.parse(fixture('pr_view'), symbolize_names: true)
			fork = JSON.parse(fixture('pr_view_fork'), symbolize_names: true)

			assert Mill::Github.same_repo_head?(same, 'slowernet/mill-scratch')
			refute Mill::Github.same_repo_head?(fork, 'slowernet/mill-scratch')
		end

		def test_a_pr_with_no_head_owner_is_refused
			refute Mill::Github.same_repo_head?({}, 'slowernet/mill-scratch')
			refute Mill::Github.same_repo_head?({ headRepositoryOwner: nil }, 'slowernet/mill-scratch')
		end

		# --- failure handling --------------------------------------------------

		# The taxonomy distinguishes rate limiting from an unhealthy repo: backing
		# off is right for one and marking a repo unhealthy is right for the other.
		def test_failures_are_classified
			{
				'API rate limit exceeded' => Mill::Github::RateLimited,
				'Bad credentials (401)' => Mill::Github::Unauthorized,
				'Could not resolve to a Repository (404)' => Mill::Github::NotFound,
				'something else went wrong' => Mill::Github::Error
			}.each do |stderr, expected|
				gh = Mill::Github.new(runner: ->(args) { gh_fail(stderr, args) })

				assert_raises(expected) { gh.issue('slowernet/mill-scratch', 1) }
			end
		end

		def test_unparseable_output_is_an_error_not_a_nil
			gh, = recording('not json at all')

			assert_raises(Mill::Github::Error) { gh.issue('slowernet/mill-scratch', 1) }
		end

		def test_empty_output_is_not_an_error
			gh, = recording('')

			assert_nil gh.issue('slowernet/mill-scratch', 1)
		end

		# --- pagination, classification, and the board -------------------------

		# `--paginate` alone emits one JSON array per page, so a second page made
		# the response unparseable — and this endpoint pages at 30 by default. Any
		# subject with 31 comments broke the only channel that resumes a blocked run.
		def test_comments_survive_more_than_one_page
			gh, calls = recording(fixture('comments_slurped'))
			comments = gh.comments('slowernet/mill-scratch', 42)

			assert_equal [1, 2], comments.map { |c| c[:id] }
			assert_includes calls.first, '--slurp'
			assert_includes calls.first, '--paginate'
			assert(calls.first.any? { |a| a.to_s.include?('per_page=100') })
		end

		# Only a 404 means "no required checks configured". Rescuing every Error
		# made an expired token report a clean bill of health on every open PR.
		def test_an_auth_failure_reading_checks_is_not_a_clean_bill_of_health
			[Mill::Github::Unauthorized, Mill::Github::RateLimited].each do |failure|
				gh = Mill::Github.new(runner: ->(_args) { raise failure, 'boom' })

				assert_raises(failure) { gh.checks('slowernet/mill-scratch', 5) }
			end
		end

		def test_no_required_checks_configured_is_still_not_an_error
			gh = Mill::Github.new(runner: ->(_args) { raise Mill::Github::NotFound, '404' })

			assert_empty gh.checks('slowernet/mill-scratch', 5)
		end

		# mill must be the sole writer of Status. "Item closed → Done" would flip it
		# out from under a Running run, leaving the poller blind to a live stage.
		def test_the_board_reports_which_built_in_workflows_are_on
			gh, calls = recording(fixture('project_workflows'))
			on = gh.project_workflows(3, owner: 'slowernet').select { |w| w[:enabled] }

			assert_equal ['Item closed', 'Pull request merged'], on.map { |w| w[:name] }
			assert_equal %w[api graphql], calls.first.first(2)
		end

		# The owner arrives as an object from `gh pr view --json` and as a bare
		# login from a flattened projection. The second shape used to raise.
		def test_a_flattened_head_owner_does_not_raise
			assert Mill::Github.same_repo_head?({ headRepositoryOwner: 'slowernet' }, 'slowernet/mill-scratch')
			refute Mill::Github.same_repo_head?({ headRepositoryOwner: 'a-stranger' }, 'slowernet/mill-scratch')
			refute Mill::Github.same_repo_head?({ headRepositoryOwner: 42 }, 'slowernet/mill-scratch')
			refute Mill::Github.same_repo_head?(nil, 'slowernet/mill-scratch')
		end

		# mill has two comment sources: REST returns author_association, and
		# `gh issue view --json comments` returns authorAssociation. Understanding
		# only one meant every author read as untrusted through the other.
		def test_both_comment_shapes_are_understood
			assert Mill::Github.trusted_author?({ authorAssociation: 'OWNER' })
			assert Mill::Github.trusted_author?({ author_association: 'OWNER' })
			refute Mill::Github.trusted_author?({ authorAssociation: 'NONE' })
			refute Mill::Github.trusted_author?({ authorAssociation: nil })
		end

		# --- text mill did not write ------------------------------------------

		# Open3 tags output with Encoding.default_external, which is US-ASCII on a
		# host with no locale set -- the normal condition under systemd. An issue
		# body with an emoji in it then raised straight out of JSON.parse.
		def test_a_non_ascii_issue_body_survives_whatever_the_locale_says
			body = { number: 42, title: 'Fix the bug', body: EMOJI }.to_json

			[Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT].each do |tagged|
				gh = Mill::Github.new(runner: ->(_args) { body.dup.force_encoding(tagged) })

				assert_equal EMOJI, gh.issue('slowernet/mill-scratch', 42)[:body],
					"gh output tagged #{tagged} did not survive"
			end
		end

		def test_a_comment_with_emoji_is_still_read_as_an_answer
			payload = [[{ id: 1, body: "Use 30 seconds #{EMOJI}", author_association: 'OWNER' }]].to_json
			gh = Mill::Github.new(runner: ->(_args) { payload.dup.force_encoding(Encoding::US_ASCII) })
			comment = gh.comments('slowernet/mill-scratch', 42).first

			assert Mill::Github.trusted_author?(comment)
			assert_includes comment[:body], EMOJI
		end

		# A truly malformed byte is not a reason to lose the whole payload.
		def test_an_undecodable_byte_does_not_take_the_call_down
			payload = %({"number":1,"body":"caf\xC3"}).dup.force_encoding(Encoding::ASCII_8BIT)
			gh = Mill::Github.new(runner: ->(_args) { payload })

			assert_equal 1, gh.issue('slowernet/mill-scratch', 1)[:number]
		end

		private

		def gh_fail(stderr, args)
			Mill::Github.new.send(:raise_for, stderr, args)
		end
	end
end
