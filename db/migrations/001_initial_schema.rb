# Timestamps are UTC epoch integers throughout (Time.now.utc.to_i).

Sequel.migration do
	change do
		create_table(:repos) do
			primary_key :id
			String :owner, null: false
			String :name, null: false
			String :local_path
			String :base_branch
			String :ci_workflow
			String :config_json
			Integer :prepared_at
			String :comments_cursor
			String :review_comments_cursor
			Integer :created_at, null: false

			unique %i[owner name]
		end

		create_table(:runs) do
			primary_key :id
			foreign_key :repo_id, :repos, null: false
			String :subject_kind, null: false		# issue | pr
			Integer :subject_number, null: false
			String :route								# plan | fast | iterate
			TrueClass :evidence_required, default: false, null: false
			TrueClass :deep_review, default: false, null: false
			String :branch
			String :spec_path
			String :worktree_path
			String :status, null: false				# running blocked done failed killed
			String :current_stage
			Integer :pgid
			Integer :heartbeat_at
			String :strike_resets_json				# JSON array of stage names, reset once each
			String :desired_board_status			# what mill last decided the board should say
			Integer :board_status_at				# when it was last confirmed; NULL = unconfirmed
			Integer :pr_number
			Integer :created_at, null: false
			Integer :finished_at

			index %i[repo_id status]
		end

		# A subject may have only one live run. Terminal runs are excluded so the
		# same issue can be worked again later; `blocked` is included because a
		# blocked run must keep guarding its subject until a comment resumes it.
		run <<~SQL
			CREATE UNIQUE INDEX runs_active_subject
			ON runs (repo_id, subject_kind, subject_number)
			WHERE status IN ('running', 'blocked')
		SQL

		create_table(:stage_attempts) do
			primary_key :id
			foreign_key :run_id, :runs, null: false
			String :stage, null: false
			Integer :invocation, null: false		# every launch; names the log and verdict
			TrueClass :strike_charged, default: false, null: false	# only when the work was wrong
			String :model
			String :session_id
			String :nonce, null: false
			String :status							# ok | blocked | failed
			String :verdict_json
			String :skill_source					# resolved skill path, for traceability
			String :skill_version
			Integer :tokens_in, default: 0, null: false
			Integer :tokens_out, default: 0, null: false
			Integer :cache_creation_tokens, default: 0, null: false
			Integer :cache_read_tokens, default: 0, null: false
			Integer :rate_limited_at
			String :log_path
			Integer :pid
			Integer :pgid
			Integer :pid_started_at
			Integer :host_boot_at
			Integer :last_output_at
			Integer :pending_tool_at				# set while a tool call is outstanding
			Integer :stall_recoveries, default: 0, null: false
			Integer :started_at, null: false
			Integer :finished_at

			unique %i[run_id stage invocation]
			index %i[run_id stage]
		end

		# Bounds a permanently red PR: each fix run is a fresh run with fresh
		# counters, so the cap has to live outside any one run.
		create_table(:ci_fixes) do
			foreign_key :repo_id, :repos, null: false
			Integer :pr_number, null: false
			String :head_sha, null: false
			Integer :runs_started, default: 0, null: false
			Integer :created_at, null: false

			primary_key %i[repo_id pr_number head_sha]
		end

		create_table(:events) do
			primary_key :id
			foreign_key :repo_id, :repos, null: false
			String :kind, null: false
			String :gh_node_id, null: false, unique: true
			String :payload_json
			Integer :attempts, default: 0, null: false
			String :last_error
			String :state, null: false, default: 'pending'	# pending | processed | dead
			Integer :created_at, null: false
			Integer :processed_at

			index %i[state created_at]
		end
	end
end
