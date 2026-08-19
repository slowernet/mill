module Mill
	# The stage graph is data: each stage declares its model, toolset, permission
	# mode, skill, and expected artifact. Design doc: "Stages, models, and skills".
	module Stages
		OPUS = 'claude-opus-5'
		SONNET = 'claude-sonnet-5'

		READ_ONLY = %w[Read Glob Grep].freeze

		# `Skill` is gated by --tools like any other tool: measured 2026-08-19 on CLI
		# 2.1.227, a stage without it reports no Skill tool and cannot load one. Every
		# stage that names a skill carries it.
		ALL = {
			'triage' => {
				model: SONNET,
				tools: READ_ONLY,
				skill: nil
			},
			'plan' => {
				model: OPUS,
				tools: READ_ONLY + %w[Write Skill],
				permission_mode: 'acceptEdits',
				skill: 'superpowers:writing-plans',
				artifact: %r{\Adocs/superpowers/plans/[^/]+\.md\z}
			},
			'review:plan' => {
				model: OPUS,
				tools: READ_ONLY + %w[Skill],
				skill: 'adversarial-reviewer'
			},
			'diagnose' => {
				model: OPUS,
				tools: READ_ONLY + %w[Bash Skill],
				skill: 'superpowers:systematic-debugging'
			},
			'implement' => {
				model: OPUS,
				tools: READ_ONLY + %w[Write Edit Bash Skill],
				permission_mode: 'acceptEdits',
				skill: 'mill:implement'
			},
			'implement:fast' => {
				model: OPUS,
				tools: READ_ONLY + %w[Write Edit Bash Skill],
				permission_mode: 'acceptEdits',
				skill: 'superpowers:test-driven-development'
			},
			'review:code' => {
				model: OPUS,
				tools: READ_ONLY + %w[Bash Skill],
				skill: 'adversarial-reviewer'
			},
			'pr' => {
				model: OPUS,
				tools: READ_ONLY + %w[Bash Skill],
				skill: 'mill:pr'
			},
			'push' => {
				model: OPUS,
				tools: %w[Read Bash],
				skill: nil
			}
		}.freeze

		ROUTES = {
			'plan' => %w[triage plan review:plan implement review:code pr],
			'fast' => %w[triage diagnose implement:fast review:code pr],
			'iterate' => %w[triage implement:fast review:code push]
		}.freeze

		# A reviewer's objections re-run the stage that produced the artifact.
		REVIEWS = { 'review:plan' => 'plan', 'review:code' => 'implement' }.freeze

		def self.[](name)
			ALL[name] or raise Mill::Error, "unknown stage: #{name}"
		end

		def self.names = ALL.keys

		# Stage names carry a colon; paths must not.
		def self.slug(name) = name.tr(':', '-')

		def self.next_stage(route, current)
			stages = ROUTES[route] or raise Mill::Error, "unknown route: #{route}"
			stages[stages.index(current).to_i + 1] if stages.include?(current)
		end
	end
end
