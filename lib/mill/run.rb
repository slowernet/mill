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
		def call(launcher: nil, &announce)
			raise Mill::Error, 'call prepare first' unless prepared?

			runner(launcher: launcher, &announce).call
		end

		def runner(launcher: nil, &announce)
			@runner ||= Mill::Runner.new(db: @db, run_id: @run_id,
				launcher: launcher || default_launcher(&announce),
				context: { issue: issue_body, spec_path: @spec_path, branch: @branch, base: base })
		end

		def attempts = @db[:stage_attempts].where(run_id: @run_id).order(:id).all

		# An endless method with a trailing `if` defines the method conditionally,
		# not the body — so this one stays a normal def.
		def teardown
			@git.worktree_remove(@clone, @worktree) if @worktree && Dir.exist?(@worktree)
		end

		private

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

		def issue_body = @issue_body ||= @github.issue(@repo, @number)[:body].to_s

		def default_launcher(&announce)
			lambda do |stage:, prompt:, number:, session_id:|
				announce&.call(stage, number, !session_id.nil?)
				log = File.join(Mill.home, 'logs', @run_id.to_s,
					"#{Mill::Stages.slug(stage)}-#{number}.jsonl")
				@claude.new(stage).run(prompt, number: number, worktree: @worktree,
					log_path: log, session_id: session_id)
			end
		end
	end
end
