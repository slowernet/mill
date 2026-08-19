require 'fileutils'
require 'json'
require 'yaml'

module Mill
	# Finding, or making, the working copy a run happens in.
	#
	# On a laptop mill uses a clone you already keep, because working against the
	# same checkout you use is the point of running it there. A server keeps none,
	# so mill clones into its own directory. Those are one code path with a
	# different answer to "did anything match".
	module Repo
		Result = Struct.new(:path, :problem, :questions, keyword_init: true) do
			def ok? = problem.nil?
		end

		def self.roots
			raw = ENV['MILL_CLONES'].to_s
			return raw.split(':').reject(&:empty?).map { |path| File.expand_path(path) } unless
				raw.empty?

			Mill::Clock::DARWIN ? [File.expand_path('~/code')] : []
		end

		def self.clone_dir = File.join(Mill.home, 'clones')

		def self.default_url(owner, name) = "https://github.com/#{owner}/#{name}.git"

		# owner/name, lowercased, whatever form the remote was written in.
		def self.slug(url)
			url.to_s.strip.sub(/\.git\z/, '')[%r{[:/]([^/:]+/[^/:]+)\z}, 1]&.downcase
		end

		def self.resolve(owner, name, git: Mill::Git, url: nil)
			matches = candidates("#{owner}/#{name}".downcase, git)

			return Result.new(path: matches.first) if matches.length == 1
			return ambiguous(owner, name, matches) if matches.length > 1

			path = File.join(clone_dir, "#{owner}-#{name}")
			return Result.new(path: path) if Dir.exist?(File.join(path, '.git'))

			Result.new(path: git.clone(url || default_url(owner, name), path))
		rescue Mill::Git::Error => e
			Result.new(problem: :clone_failed,
				questions: ["mill could not clone #{owner}/#{name}: #{e.message}"])
		end

		def self.candidates(wanted, git)
			roots.flat_map { |root| Dir.glob(File.join(root, '*')) }
				.select { |path| Dir.exist?(File.join(path, '.git')) }
				.select { |path| slug(git.origin(path)) == wanted }
				.sort
		end

		# Lazy and per-item: the first time an item from a repo reaches the board.
		# Everything here is a read or a local git config write — mill writes
		# nothing to the repository itself, which is what lets it use no labels.
		#
		# Anything missing blocks that one item and names it. Nothing here raises
		# at the caller: an exception would wedge the poller loop in a retry cycle
		# over one badly configured repo.
		def self.prepare(db:, owner:, name:, git: Mill::Git, url: nil)
			row = db[:repos].where(owner: owner, name: name).first
			return Result.new(path: row[:local_path]) if row && row[:prepared_at]

			resolved = resolve(owner, name, git: git, url: url)
			return resolved unless resolved.ok?

			path = resolved.path
			git.run!(path, 'config', 'gc.auto', '0')
			git.run!(path, 'config', 'maintenance.auto', '0')

			base = base_branch(path, git)
			config = read_config(path, base, git)
			missing = missing_secrets(owner, name, config)
			return missing if missing

			upsert(db, owner, name, path, base, config)
			Result.new(path: path)
		rescue Mill::Git::Error => e
			Result.new(problem: :unprepared,
				questions: ["mill could not prepare #{owner}/#{name}: #{e.message}"])
		end

		def self.config(db, repo_id)
			raw = db[:repos].where(id: repo_id).get(:config_json)
			raw ? JSON.parse(raw, symbolize_names: true) : {}
		end

		def self.base_branch(path, git)
			result = git.run(path, 'symbolic-ref', 'refs/remotes/origin/HEAD')
			ref = result.ok ? result.out.strip.split('/').last : nil
			ref.nil? || ref.empty? ? 'main' : ref
		end

		# From the base branch, never from a checkout. `git show` reads the
		# committed blob, so nothing has to be checked out and no worktree can
		# influence what mill reads.
		def self.read_config(path, base, git)
			git.run(path, 'fetch', 'origin', base)
			%W[origin/#{base} #{base}].each do |ref|
				result = git.run(path, 'show', "#{ref}:.mill.yml")
				next unless result.ok

				parsed = YAML.safe_load(result.out, symbolize_names: true)
				return parsed.is_a?(Hash) ? parsed : {}
			end
			{}
		rescue Psych::Exception => e
			# Psych::SyntaxError for a malformed file, DisallowedClass for an
			# unquoted date. Both are the operator's to fix, and both must block the
			# item rather than escaping into the poller loop.
			raise Mill::Git::Error, ".mill.yml on #{base} could not be read: #{e.message}"
		end

		def self.missing_secrets(owner, name, config)
			named = Array(config[:secrets]).map(&:to_s)
			return nil if named.empty?

			absent = named - Mill::Secrets.for_repo(owner, name).keys
			return nil if absent.empty?

			Result.new(problem: :missing_secrets, questions: [
				"#{Mill::Secrets.path_for(owner, name)} is missing #{absent.join(', ')}, which " \
				"#{owner}/#{name}'s .mill.yml names. A suite without them fails the same way on " \
				'both attempts, which reads as the stage being wrong. Add them and reply here.'
			])
		end

		def self.upsert(db, owner, name, path, base, config)
			db[:repos].insert_conflict(target: %i[owner name]).insert(
				owner: owner, name: name, local_path: path, base_branch: base,
				config_json: config.to_json, prepared_at: Mill.now, created_at: Mill.now
			)
			db[:repos].where(owner: owner, name: name).update(
				local_path: path, base_branch: base, config_json: config.to_json,
				prepared_at: Mill.now
			)
		end

		def self.ambiguous(owner, name, matches)
			Result.new(problem: :ambiguous_clone, questions: [
				"#{owner}/#{name} matches more than one working copy: #{matches.join(', ')}. " \
				'mill will not choose between them, because the choice commits the whole run to ' \
				'one checkout. Move or remove all but one, then reply here.'
			])
		end
	end
end
