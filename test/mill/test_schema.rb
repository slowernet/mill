require 'test_helper'

module Mill
	class TestSchema < Mill::TestCase
		def test_migration_creates_every_table
			%i[repos runs stage_attempts ci_fixes events].each do |table|
				assert_includes db.tables, table
			end
		end

		def test_foreign_keys_are_enforced
			assert_raises(Sequel::ForeignKeyConstraintViolation) do
				create_run(repo_id: 9999)
			end
		end

		# The design's rule: one live run per subject. Terminal runs must not
		# guard the subject, or an issue could never be worked twice.
		def test_one_active_run_per_subject
			repo = create_repo
			create_run(repo_id: repo, subject_number: 42)

			assert_raises(Sequel::UniqueConstraintViolation) do
				create_run(repo_id: repo, subject_number: 42)
			end
		end

		def test_blocked_run_still_guards_its_subject
			repo = create_repo
			create_run(repo_id: repo, subject_number: 42, status: 'blocked')

			assert_raises(Sequel::UniqueConstraintViolation) do
				create_run(repo_id: repo, subject_number: 42)
			end
		end

		def test_terminal_run_releases_its_subject
			repo = create_repo

			%w[done failed killed].each_with_index do |status, i|
				number = 100 + i
				create_run(repo_id: repo, subject_number: number, status: status)
				assert create_run(repo_id: repo, subject_number: number),
					"a #{status} run must not guard its subject"
			end
		end

		# An issue and a PR can share a number in the same repo, so subject_kind
		# has to be part of the key.
		def test_issue_and_pr_with_the_same_number_coexist
			repo = create_repo
			create_run(repo_id: repo, subject_number: 7, subject_kind: 'issue')

			assert create_run(repo_id: repo, subject_number: 7, subject_kind: 'pr')
		end

		def test_repos_are_unique_by_owner_and_name
			create_repo(owner: 'slowernet', name: 'mill')

			assert_raises(Sequel::UniqueConstraintViolation) do
				create_repo(owner: 'slowernet', name: 'mill')
			end
		end

		# The number number names the log and the verdict, so two launches of
		# one stage can never collide.
		def test_stage_attempts_are_numbered_uniquely_per_run
			repo = create_repo
			run = create_run(repo_id: repo)
			attempt = { run_id: run, stage: 'plan', number: 1, nonce: 'abc', started_at: Mill.now }

			db[:stage_attempts].insert(**attempt)

			assert_raises(Sequel::UniqueConstraintViolation) do
				db[:stage_attempts].insert(**attempt)
			end
		end

		def test_a_stage_may_be_relaunched_under_a_new_number
			repo = create_repo
			run = create_run(repo_id: repo)

			db[:stage_attempts].insert(run_id: run, stage: 'plan', number: 1, nonce: 'a', started_at: Mill.now)

			assert db[:stage_attempts].insert(run_id: run, stage: 'plan', number: 2, nonce: 'b', started_at: Mill.now)
		end

		# Free paths cost an number and no strike; only bad work strikes.
		def test_attempts_default_to_no_strike_and_no_tokens
			repo = create_repo
			run = create_run(repo_id: repo)
			id = db[:stage_attempts].insert(run_id: run, stage: 'triage', number: 1, nonce: 'n', started_at: Mill.now)
			row = db[:stage_attempts][id: id]

			refute row[:strike_charged]
			assert_equal 0, row[:tokens_in]
			assert_equal 0, row[:cache_read_tokens]
			assert_equal 0, row[:stall_recoveries]
		end

		# The stream carries no running output total, so a killed attempt has no
		# honest figure. NULL means unmeasured; 0 would make it look free.
		def test_output_tokens_may_be_unmeasured
			repo = create_repo
			run = create_run(repo_id: repo)
			id = db[:stage_attempts].insert(run_id: run, stage: 'plan', number: 1, nonce: 'n',
				started_at: Mill.now, tokens_in: 5, tokens_out: nil)

			assert_nil db[:stage_attempts][id: id][:tokens_out]
			assert_equal 5, db[:stage_attempts][id: id][:tokens_in]
		end

		def test_the_other_three_counts_stay_required
			repo = create_repo
			run = create_run(repo_id: repo)

			assert_raises(Sequel::NotNullConstraintViolation) do
				db[:stage_attempts].insert(run_id: run, stage: 'plan', number: 9, nonce: 'n',
					started_at: Mill.now, cache_read_tokens: nil)
			end
		end

		def test_events_dedupe_on_node_id
			repo = create_repo
			db[:events].insert(repo_id: repo, kind: 'comment', gh_node_id: 'IC_1', created_at: Mill.now)

			assert_raises(Sequel::UniqueConstraintViolation) do
				db[:events].insert(repo_id: repo, kind: 'comment', gh_node_id: 'IC_1', created_at: Mill.now)
			end
		end

		# The CI fix cap is keyed to the failing commit, so a new commit gets a
		# fresh budget while a stuck one stops costing pipelines.
		def test_ci_fixes_are_keyed_per_failing_commit
			repo = create_repo
			db[:ci_fixes].insert(repo_id: repo, pr_number: 5, head_sha: 'aaa', created_at: Mill.now)

			assert db[:ci_fixes].insert(repo_id: repo, pr_number: 5, head_sha: 'bbb', created_at: Mill.now)
			assert_raises(Sequel::UniqueConstraintViolation) do
				db[:ci_fixes].insert(repo_id: repo, pr_number: 5, head_sha: 'aaa', created_at: Mill.now)
			end
		end
	end
end
