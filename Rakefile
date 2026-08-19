require 'rake/testtask'

# Everything fixture-backed. No network, no tokens, no `claude`. This is CI.
Rake::TestTask.new(:test) do |t|
	t.libs << 'lib' << 'test'
	t.test_files = FileList['test/**/test_*.rb'].exclude('test/boundary/**/*')
	t.warning = false
end

namespace :test do
	desc 'Permission ruleset against the real claude CLI. Cannot run in CI.'
	task :boundary do
		files = FileList['test/boundary/test_*.rb']
		# An empty FileList passes silently, and CLAUDE.md tells you to run this
		# before merging a containment change. A green target that asserted nothing
		# is worse than no target at all.
		abort 'no boundary tests found under test/boundary/ — refusing to report a pass' if files.empty?

		ruby "-Ilib -Itest #{files.map { |f| "-r./#{f}" }.join(' ')} -e ''" or abort 'boundary suite failed'
	end
end

namespace :mill do
	desc 'Verify every precondition and name what is missing'
	task :doctor do
		require_relative 'lib/mill'
		doctor = Mill::Doctor.new.run
		puts doctor.report
		unless doctor.ok?
			puts "\nA red doctor blocks everything: most of what it checks is containment."
			exit 1
		end
	end

	desc 'Write the permission ruleset for every stage into ~/.mill/settings'
	task :settings do
		require_relative 'lib/mill'
		Mill::Rules.write!.each { |path| puts "wrote #{path}" }
	end

	desc 'Create or update the schema'
	task :migrate do
		require_relative 'lib/mill'
		db = Mill::DB.connect
		Mill::DB.migrate!(db)
		puts "migrated #{Mill::DB.path}"
	end

	desc 'Drive one issue through the plan route by hand: mill:run[owner/repo,42,~/code/repo]'
	task :run, %i[repo number clone] do |_t, args|
		require_relative 'lib/mill'
		abort 'usage: rake "mill:run[owner/repo,42,~/code/repo]"' unless args[:repo] && args[:number]

		Mill::DB.migrate!(Mill.db)
		clone = args[:clone] || File.join('~/code', args[:repo].split('/').last.to_s)
		run = Mill::Run.new(repo: args[:repo], number: args[:number], clone: clone).prepare

		unless run.prepared?
			puts "cannot start: #{run.problem}"
			run.questions.each { |q| puts "  ? #{q}" }
			exit 1
		end

		puts "run #{run.run_id} on #{run.branch}, spec #{run.spec_path}"
		puts "worktree #{run.worktree}\n\n"

		outcome = run.call do |stage, number, resuming|
			puts "-> #{stage} (number #{number})#{resuming ? ' resuming' : ''}"
		end

		puts "\n#{outcome}: #{run.runner.state[:reason]}"
		run.runner.state[:questions].each { |q| puts "  ? #{q}" }
		run.attempts.each do |a|
			puts format('  %-16s inv %d  %-16s %s%s', a[:stage], a[:number], a[:status],
				a[:strike_charged] ? 'STRIKE ' : '',
				a[:struck_stage] ? "struck #{a[:struck_stage]}" : '')
		end
		exit 1 unless outcome == :done
	end

	desc 'Answer a blocked run and resume it: mill:answer[2,"your answer"]'
	task :answer, %i[run answers] do |_t, args|
		require_relative 'lib/mill'
		abort 'usage: rake \'mill:answer[2,"your answer"]\'' unless args[:run] && args[:answers]

		answers = [args[:answers], *args.extras]
		puts "resuming run #{args[:run]} with #{answers.length} answer(s)\n\n"
		outcome = Mill::Run.resume(args[:run].to_i, answers) do |stage, number, resuming|
			puts "-> #{stage} (attempt #{number})#{resuming ? ' resuming' : ' fresh'}"
		end

		run = Mill.db[:runs].where(id: args[:run].to_i).first
		puts "\n#{outcome}"
		Mill.db[:stage_attempts].where(run_id: args[:run].to_i).order(:id).each do |a|
			puts format('  %-16s #%d  %-16s %s%s', a[:stage], a[:number], a[:status],
				a[:strike_charged] ? 'STRIKE ' : '', a[:struck_stage] ? "struck #{a[:struck_stage]}" : '')
		end
		puts "pr: #{run[:pr_number]}" if run[:pr_number]
		exit 1 unless outcome == :done
	end

	desc 'Spawn one real claude stage and report its verdict and token usage'
	task :probe, %i[stage] do |_t, args|
		require_relative 'lib/mill'
		require 'tmpdir'

		stage = args[:stage] || 'triage'
		Dir.mktmpdir('mill-probe') do |worktree|
			File.write(File.join(worktree, 'README.md'), "# probe\n\nA scratch tree with one file in it.\n")
			log = File.join(Mill.home, 'logs', 'probe', "#{Mill::Stages.slug(stage)}-1.jsonl")

			attempt = Mill::Claude.new(stage).run(
				'Read README.md in this directory and report what it says. Change nothing.',
				number: 1, worktree: worktree, log_path: log
			)

			puts "stage      #{attempt.stage} (number #{attempt.number}, nonce #{attempt.nonce})"
			puts "model      #{attempt.model}"
			puts "session    #{attempt.session_id}"
			puts "verdict    #{attempt.verdict.valid? ? attempt.verdict.status : 'INVALID'}"
			puts "tokens     #{attempt.tokens.map { |k, v| "#{k}=#{v.nil? ? 'unmeasured' : v}" }.join(' ')}"
			puts "log        #{attempt.log_path}"
			attempt.errors.each { |e| puts "problem    #{e}" }
			exit 1 unless attempt.ok?
		end
	end
end

task default: :test
