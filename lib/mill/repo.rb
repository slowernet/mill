require 'fileutils'

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

		def self.ambiguous(owner, name, matches)
			Result.new(problem: :ambiguous_clone, questions: [
				"#{owner}/#{name} matches more than one working copy: #{matches.join(', ')}. " \
				'mill will not choose between them, because the choice commits the whole run to ' \
				'one checkout. Move or remove all but one, then reply here.'
			])
		end
	end
end
