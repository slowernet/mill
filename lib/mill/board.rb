module Mill
	# The writing side of the board, and the only thing that decides what Status
	# an item should carry.
	#
	# Every write is a network call that can fail, and nothing else re-drives one:
	# the poller only ever asks which items are Ready. So mill records what it
	# decided the board should say and when it last confirmed it, and a write that
	# never landed is retried until it does. Without that, a run that blocks while
	# the network is down shows Running forever — and because a comment's meaning
	# depends on Status, the answer to its questions is never read as an answer.
	class Board
		STATUS = {
			'running' => 'Running',
			'blocked' => 'Blocked',
			'done' => 'Done',
			'failed' => 'Failed',
			'killed' => 'Failed'
		}.freeze

		def initialize(db: Mill.db, github: nil, project: ENV['MILL_PROJECT'],
			owner: ENV['MILL_PROJECT_OWNER'])
			@db = db
			@github = github || Mill::Github.new
			@project = project
			@owner = owner
		end

		def configured? = !@project.to_s.empty? && !@owner.to_s.empty?

		def items = @github.board_items(@project, owner: @owner)

		# Records the decision first, then tries to make it true. The order
		# matters: a crash between the two leaves a decision redrive can act on,
		# where the reverse leaves a board mill believes it has already fixed.
		def want(run_id, status)
			label = STATUS.fetch(status.to_s) { raise Mill::Error, "no board status for #{status}" }
			@db[:runs].where(id: run_id).update(desired_board_status: label, board_status_at: nil)
			confirm(run_id)
		end

		def redrive
			return unless configured?

			@db[:runs].exclude(desired_board_status: nil).where(board_status_at: nil)
				.select_map(:id).each { |id| confirm(id) }
		end

		# True when the board says something mill did not put there, under a run
		# mill owns. That is a built-in workflow re-enabled after setup, and obeying
		# it would flip Status out from under a live subprocess.
		def interference?(item, run_row)
			return false if run_row[:desired_board_status].nil? || run_row[:board_status_at].nil?
			return false unless item[:id] == run_row[:board_item_id]

			item[:status].to_s != run_row[:desired_board_status]
		end

		private

		# The label is re-read here rather than passed in, and the stamp is
		# conditional on it not having changed. redrive runs in the poller thread
		# while run threads call `want`, so a label read a moment ago may already be
		# stale — and stamping board_status_at against a stale label is worse than
		# not writing at all, because that stamp is the only thing that would have
		# caused a retry.
		def confirm(run_id)
			return false unless configured?

			row = @db[:runs].where(id: run_id).first
			return false if row.nil? || row[:board_item_id].nil? || row[:desired_board_status].nil?

			label = row[:desired_board_status]
			option = ids[:options][label] or
				raise Mill::Error, "the project's Status field has no `#{label}` option"

			@github.set_status(project_id: ids[:project], item_id: row[:board_item_id],
				field_id: ids[:field], option_id: option)
			@db[:runs].where(id: run_id, desired_board_status: label)
				.update(board_status_at: Mill.now).positive?
		rescue Mill::Github::Error
			# Deliberately swallowed and deliberately not recorded as confirmed: the
			# unset board_status_at is the retry, and redrive is what performs it.
			# Only unreachability is swallowed. A board that is wrong rather than
			# unreachable is a configuration error and must not retry forever.
			false
		end

		def ids
			@ids ||= begin
				status = @github.project_fields(@project, owner: @owner)
					.find { |field| field[:name] == 'Status' } or
					raise Mill::Error, 'the project has no Status field'

				options = status.fetch(:options, []).to_h { |o| [o[:name], o[:id]] }
				missing = STATUS.values.uniq - options.keys
				raise Mill::Error, "the project's Status field is missing #{missing.join(', ')}" if
					missing.any?

				{ project: @github.project_id(@project, owner: @owner), field: status[:id],
					options: options }
			end
		end
	end
end
