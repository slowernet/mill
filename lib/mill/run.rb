module Mill
	# One run, started by hand: resolve the base branch, find the spec, claim the
	# subject, and put a worktree on the adopted branch. Then walk the route.
	#
	# Plan 3's supervisor replaces the preparing half of this — lazily preparing a
	# repo, enforcing the concurrency cap, clearing stale locks — and keeps the
	# launcher. It lives in lib rather than the Rakefile so both halves are
	# testable and so that replacement is a change to one class.
	class Run
		attr_reader :run_id, :worktree, :branch, :spec_path, :problem, :questions

		def initialize(repo:, number:, clone:, db: Mill.db, github: nil, git: Mill::Git,
			claude: Mill::Claude)
			@owner, @name = repo.split('/', 2)
			raise Mill::Error, "repo must be owner/name, got #{repo.inspect}" if @name.nil? || @name.empty?

			@repo = repo
			@number = number.to_i
			@clone = File.expand_path(clone)
			@db = db
			@github = github || Mill::Github.new
			@git = git
			@claude = claude
			@questions = []
		end

		# .mill.yml is read from the base branch in Plan 3. By hand, take the base
		# from the remote's default, so a repo whose base is not `main` still works.
		def base
			@base ||= begin
				ref = @git.run(@clone, 'symbolic-ref', 'refs/remotes/origin/HEAD').out.strip.split('/').last
				ref.nil? || ref.empty? ? 'main' : ref
			end
		end

		def prepare
			return fail_with(:not_a_clone, ["#{@clone} is not a git repository"]) unless
				Dir.exist?(File.join(@clone, '.git'))

			located = Mill::Spec.locate(github: @github, repo: @repo, number: @number,
				repo_path: @clone, base: base, git: @git)
			return fail_with(located.problem, located.questions) unless located.found?

			@branch = located.branch
			@spec_path = located.path
			claim
			self
		end

		def prepared? = @problem.nil? && !@run_id.nil?

		# The block, if given, is called with (stage, number, resuming) as each
		# launch starts — which is what `rake mill:run` prints. It wraps the real
		# launcher rather than replacing it, so watching a run cannot change it.
		# Answering a blocked run. Nothing restarts: the blocked stage resumes its
		# own session with the answers injected, and the route carries on from
		# there. Plan 3 triggers this from a comment; by hand it is rake mill:answer.
		def self.resume(run_id, answers, db: Mill.db, claude: Mill::Claude, &announce)
			row = db[:runs].where(id: run_id).first or raise Mill::Error, "no run #{run_id}"
			repo = db[:repos].where(id: row[:repo_id]).first

			run = allocate
			run.send(:initialize_resumed, row, repo, db, claude, Array(answers))
			run.call(&announce)
		end

		def call(launcher: nil, &announce)
			raise Mill::Error, 'call prepare first' unless prepared?

			runner(launcher: launcher, &announce).call
		end

		def runner(launcher: nil, &announce)
			@runner ||= begin
				r = Mill::Runner.new(db: @db, run_id: @run_id,
					launcher: launcher || default_launcher(&announce),
					context: { issue: issue_body, spec_path: @spec_path, branch: @branch, base: base,
						answers: @answers })
				@resumed ? r.restore : r
			end
		end

		def attempts = @db[:stage_attempts].where(run_id: @run_id).order(:id).all

		# An endless method with a trailing `if` defines the method conditionally,
		# not the body — so this one stays a normal def.
		def teardown
			@git.worktree_remove(@clone, @worktree) if @worktree && Dir.exist?(@worktree)
		end

		private

		# A resumed run already knows its branch, spec, and worktree — they are
		# columns. Nothing is re-resolved, so answering cannot pick a different
		# branch than the one the run has been working on.
		def initialize_resumed(row, repo, db, claude, answers)
			@db = db
			@claude = claude
			@git = Mill::Git
			@run_id = row[:id]
			@branch = row[:branch]
			@spec_path = row[:spec_path]
			@worktree = row[:worktree_path]
			@base = repo[:base_branch]
			@clone = repo[:local_path]
			@owner = repo[:owner]
			@name = repo[:name]
			@number = row[:subject_number]
			@repo = "#{repo[:owner]}/#{repo[:name]}"
			@answers = answers
			@questions = []
			@resumed = true
		end

		def fail_with(problem, questions)
			@problem = problem
			@questions = questions
			self
		end

		def claim
			@db[:repos].insert_conflict(target: %i[owner name]).insert(
				owner: @owner, name: @name, local_path: @clone, base_branch: base, created_at: Mill.now
			)
			repo_id = @db[:repos].where(owner: @owner, name: @name).get(:id)

			@run_id = @db[:runs].insert(repo_id: repo_id, subject_kind: 'issue', subject_number: @number,
				route: 'plan', branch: @branch, spec_path: @spec_path, status: 'running',
				created_at: Mill.now)

			@worktree = File.join(Mill.home, 'worktrees', "#{@owner}-#{@name}", @run_id.to_s)
			@git.worktree_add(@clone, @worktree, @branch)
			@db[:runs].where(id: @run_id).update(worktree_path: @worktree)
		end

		def issue_body
			@issue_body ||= (@github || Mill::Github.new).issue(@repo, @number)[:body].to_s
		rescue Mill::Github::Error => e
			# A resumed run should not die because GitHub is briefly unreachable;
			# the issue body is context, not the thing being worked on.
			"(mill could not re-read the issue: #{e.message})"
		end

		def default_launcher(&announce)
			lambda do |stage:, prompt:, number:, session_id:|
				announce&.call(stage, number, !session_id.nil?)
				log = File.join(Mill.home, 'logs', @run_id.to_s,
					"#{Mill::Stages.slug(stage)}-#{number}.jsonl")
				@claude.new(stage).run(prompt, number: number, worktree: @worktree,
					log_path: log, session_id: session_id, env: Mill::Rules.env_for(stage))
			end
		end
	end
end
