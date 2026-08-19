module Mill
	# The thin prompt mill wraps around each stage's skill. The skill text does the
	# job; this says which job, on which artifacts, under which harness.
	#
	# Mill::Claude#envelope appends the verdict contract, so nothing here repeats it.
	module Prompts
		DIR = File.join(Mill::ROOT, 'prompts')

		def self.for(stage, context = {})
			config = Mill::Stages[stage]		# raises on an unknown stage
			[preamble(stage, config, context), render(template(Mill::Stages.slug(stage)), context)]
				.join("\n\n")
		end

		def self.template(slug)
			path = File.join(DIR, "#{slug}.md")
			raise Mill::Error, "no prompt template at #{path}" unless File.exist?(path)

			File.read(path)
		end

		# Named once, at the top of every stage. The inherited SessionStart hook
		# tells a stage to hunt for skills before doing anything, and a stage
		# holding no Skill tool reads that as an attack, says so, and spends tokens
		# on it — measured on a real triage launch, 2026-08-19.
		# Answers live here rather than in a stage template because any stage can
		# block, and a resumed stage must see the reply wherever it happens to be.
		def self.preamble(stage, config, context = {})
			skill = config[:skill]
			render(template('_preamble'), context.merge(
				stage: stage,
				skill_line: skill ? "Load exactly one skill: `#{skill}`. Do not load any other." :
					'This stage loads no skill. Do not go looking for one.'
			))
		end

		# Deliberately not ERB or format(): a prompt is prose with braces and
		# backticks in it, and a template engine turns a stray one into a crash.
		# An absent key renders its stated fallback, never an empty string — a
		# stage told "the plan is: " will invent one.
		def self.render(body, context)
			body.gsub(/\{\{(\w+)(?:\|([^}]*))?\}\}/) do
				name = Regexp.last_match(1)
				fallback = Regexp.last_match(2)
				value = format_value(context[name.to_sym])
				value.nil? || value.empty? ? (fallback || '(not applicable on this route)') : value
			end
		end

		def self.format_value(value)
			case value
			when nil then nil
			when String then value
			when Array then value.map { |v| "- #{v.is_a?(Hash) ? hash_line(v) : v}" }.join("\n")
			else value.to_s
			end
		end

		def self.hash_line(hash) = hash.map { |k, v| "**#{k}**: #{v}" }.join(' — ')
	end
end
