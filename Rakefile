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

		owner, name = args[:repo].split('/', 2)
		abort 'repo must be owner/name' if name.nil? || name.empty?

		clone = File.expand_path(args[:clone] || File.join('~/code', name))
		abort "#{clone} is not a git repository" unless Dir.exist?(File.join(clone, '.git'))

		# .mill.yml is read from the base branch in Plan 3; by hand, take the base
		# from the remote's default so a repo whose base is not `main` still works.
		base = Mill::Git.run(clone, 'symbolic-ref', 'refs/remotes/origin/HEAD').out.strip.split('/').last
		base = 'main' if base.nil? || base.empty?

		github = Mill::Github.new
		located = Mill::Spec.locate(github: github, repo: args[:repo], number: args[:number].to_i,
			repo_path: clone, base: base)
		unless located.found?
			puts "cannot start: #{located.problem}"
			located.questions.each { |q| puts "  ? #{q}" }
			exit 1
		end

		db = Mill.db
		Mill::DB.migrate!(db)
		db[:repos].insert_conflict(target: %i[owner name]).insert(
			owner: owner, name: name, local_path: clone, base_branch: base, created_at: Mill.now
		)
		repo_id = db[:repos].where(owner: owner, name: name).get(:id)

		run_id = db[:runs].insert(repo_id: repo_id, subject_kind: 'issue',
			subject_number: args[:number].to_i, route: 'plan', branch: located.branch,
			spec_path: located.path, status: 'running', created_at: Mill.now)

		worktree = File.join(Mill.home, 'worktrees', "#{owner}-#{name}", run_id.to_s)
		Mill::Git.worktree_add(clone, worktree, located.branch)
		db[:runs].where(id: run_id).update(worktree_path: worktree)
		puts "run #{run_id} on #{located.branch}, spec #{located.path}"
		puts "worktree #{worktree}\n\n"

		issue = github.issue(args[:repo], args[:number].to_i)
		launcher = lambda do |stage:, prompt:, invocation:, session_id:|
			log = File.join(Mill.home, 'logs', run_id.to_s,
				"#{Mill::Stages.slug(stage)}-#{invocation}.jsonl")
			puts "-> #{stage} (invocation #{invocation})#{session_id ? ' resuming' : ''}"
			Mill::Claude.new(stage).run(prompt, invocation: invocation, worktree: worktree,
				log_path: log, session_id: session_id)
		end

		runner = Mill::Runner.new(db: db, run_id: run_id, launcher: launcher, context: {
			issue: issue[:body], spec_path: located.path, branch: located.branch, base: base
		})
		outcome = runner.call

		puts "\n#{outcome}: #{runner.state[:reason]}"
		runner.state[:questions].each { |q| puts "  ? #{q}" }
		db[:stage_attempts].where(run_id: run_id).order(:id).each do |a|
			puts format('  %-16s inv %d  %-16s %s%s', a[:stage], a[:invocation], a[:status],
				a[:strike_charged] ? 'STRIKE' : '',
				a[:struck_stage] ? "struck #{a[:struck_stage]}" : '')
		end
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
				invocation: 1, worktree: worktree, log_path: log
			)

			puts "stage      #{attempt.stage} (invocation #{attempt.invocation}, nonce #{attempt.nonce})"
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
