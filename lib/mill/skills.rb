require 'json'

module Mill
	# Resolves the skills the stage graph names to files on disk.
	#
	# A stage that names a skill it cannot load does not fail — it improvises from
	# memory, silently, at full cost. Nothing in the CLI reports that, so mill
	# checks before it runs anything and records what it resolved on every attempt.
	module Skills
		Resolved = Struct.new(:name, :kind, :path, :version, :detail, keyword_init: true) do
			def found? = !path.nil?
			def to_s = found? ? "#{name} (#{kind} #{version})" : "#{name}: #{detail}"
		end

		def self.config_dir = File.expand_path(ENV['CLAUDE_CONFIG_DIR'] || '~/.claude')

		def self.resolve(name, config_dir: self.config_dir)
			plugin, skill = name.split(':', 2)
			skill ? resolve_plugin(plugin, skill, config_dir) : resolve_personal(name, config_dir)
		end

		# Every skill the graph names, in stage order, deduped.
		def self.required(config_dir: self.config_dir)
			Mill::Stages::ALL.values.filter_map { |c| c[:skill] }.uniq
				.map { |name| resolve(name, config_dir: config_dir) }
		end

		def self.resolve_personal(name, dir)
			path = File.join(dir, 'skills', name, 'SKILL.md')
			return missing(name, :personal, "no skill at #{path}") unless File.exist?(path)

			Resolved.new(name: name, kind: :personal, path: path, version: 'local')
		end

		# A plugin skill resolves only through an *enabled* plugin: an installed but
		# disabled plugin provides nothing, and its files are still on disk.
		def self.resolve_plugin(plugin, skill, dir)
			install = enabled_install(plugin, dir)
			return missing("#{plugin}:#{skill}", :plugin, install) if install.is_a?(String)

			path = File.join(install[:path], 'skills', skill, 'SKILL.md')
			unless File.exist?(path)
				return missing("#{plugin}:#{skill}", :plugin,
					"plugin #{plugin} #{install[:version]} provides no skill '#{skill}'")
			end

			Resolved.new(name: "#{plugin}:#{skill}", kind: :plugin, path: path,
				version: install[:version], detail: install[:marketplace])
		end

		# Returns the install hash, or a string explaining why there isn't one.
		def self.enabled_install(plugin, dir)
			settings = read_json(File.join(dir, 'settings.json')) || {}
			installed = read_json(File.join(dir, 'plugins', 'installed_plugins.json')) || {}

			enabled = (settings[:enabledPlugins] || {}).select { |key, on| on && key.to_s.split('@').first == plugin }
			return "plugin '#{plugin}' is not enabled" if enabled.empty?

			key = enabled.keys.first.to_s
			entry = Array(installed.dig(:plugins, key.to_sym)).first
			return "plugin '#{key}' is enabled but not installed" if entry.nil?
			return "plugin '#{key}' has no install path" if entry[:installPath].nil?

			{ path: entry[:installPath], version: entry[:version], marketplace: key.split('@').last }
		end

		def self.missing(name, kind, detail) = Resolved.new(name: name, kind: kind, detail: detail)

		# `required` resolves five skills and each one reads settings.json and
		# installed_plugins.json, so without this doctor reads two small files ten
		# times. Cached on mtime rather than path alone: a plugin enabled between
		# two doctor runs in one process must not read as still disabled.
		def self.read_json(path)
			return nil unless File.exist?(path)

			key = [path, File.mtime(path).to_f, File.size(path)]
			@read_json ||= {}
			return @read_json[key] if @read_json.key?(key)

			@read_json[key] = begin
				JSON.parse(File.read(path), symbolize_names: true)
			rescue JSON::ParserError
				nil
			end
		end
	end
end
