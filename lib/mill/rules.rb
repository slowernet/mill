require 'fileutils'
require 'json'

module Mill
	# The permission rulesets, as data. One definition, written to
	# ~/.mill/settings/<stage>.json by `rake mill:settings` and checked by doctor,
	# so what the runbook creates and what doctor demands cannot drift apart.
	#
	# These are layer 1's *fail-open* third mechanism: they scope paths and commands
	# inside a box the working directory and `--tools` have already closed. Read
	# Containment in the design doc before adding one.
	module Rules
		# Every rule is worktree-relative. An absolute path is accepted without
		# complaint and enforces nothing, so one naming ~/.ssh would look like
		# protection while providing none — doctor rejects any rule containing one.
		#
		# File denies use the Edit(...) form, never Write(...): Claude Code matches
		# file permission checks against Edit rules only, and Edit covers every
		# file-editing tool including Write. A Write(.github/workflows/**) rule was
		# measured modifying the file it claimed to protect.
		REQUIRED_DENY = [
			'Edit(.claude/**)',
			'Edit(.mill.yml)',
			'Edit(.github/workflows/**)',
			'Edit(.github/actions/**)',
			'Read(.env)',
			'Read(.env.*)',
			'Bash(gh issue comment:*)',
			'Bash(gh pr comment:*)',
			'Bash(gh api:*)'
		].freeze

		# Stages cannot comment at all — only Mill::Github comments, and it always
		# stamps the marker. Nothing here may merge: mill never merges.
		EXTRA_DENY = [
			'Bash(gh pr merge:*)',
			'Bash(gh project:*)',
			'Bash(gh auth:*)'
		].freeze

		def self.deny = REQUIRED_DENY + EXTRA_DENY

		# The Bash sandbox denies outbound network by default, and takes a domain
		# allowlist. Measured 2026-08-19: with these two hosts allowed, api.github.com
		# answered 200 and example.com came back `X-Proxy-Error: blocked-by-allowlist`.
		#
		# So only the two stages that must reach GitHub can, and the other seven
		# reach nothing at all. That is stronger than the design's original accepted
		# risk of "network access inside a stage is unrestricted", and it was found
		# the way everything else here was: the pr stage hit the wall on the first
		# real run and asked rather than guessing.
		# Only github.com, because these two stages push a branch and nothing more —
		# mill makes every API call from outside the sandbox. Dropping
		# api.github.com fell out of moving pull-request creation to Mill::Github.
		NETWORK = { 'pr' => %w[github.com], 'push' => %w[github.com] }.freeze

		# No `allow` key, ever. An allow list is advisory in headless mode — a tool
		# in neither allow nor deny runs anyway — so confinement placed there turns
		# layer 1 off while looking like it tightened something. `sandbox.network`
		# is a different mechanism and does confine: it is a proxy, not advice.
		def self.for_stage(stage)
			{
				permissions: { deny: deny },
				sandbox: { enabled: true, network: { allowedDomains: NETWORK.fetch(stage, []) } }
			}
		end

		# Where the platform keeps its CA bundle, first one that exists.
		CA_BUNDLES = %w[
			/etc/ssl/cert.pem
			/etc/ssl/certs/ca-certificates.crt
			/etc/pki/tls/certs/ca-bundle.crt
		].freeze

		def self.ca_bundle = CA_BUNDLES.find { |path| File.exist?(path) }

		# The environment every stage runs with: the CA bundle, the repo's own
		# secrets, and — for the two stages that push — the narrow token.
		#
		# SSL_CERT_FILE is set for the benefit of anything a stage runs that reads
		# a CA file — and **not** for `gh`, which it does not fix. Measured across
		# two resumed attempts on 2026-08-19: inside the Bash sandbox `curl` and
		# `git push` both reach api.github.com over the allowlist, while `gh` fails
		# with `x509: OSStatus -26276`. That is Go on macOS calling SecTrustEvaluate
		# through the Security framework, which the sandbox blocks; Go ignores
		# SSL_CERT_FILE on this platform, and `GODEBUG=x509usefallbackroots=1` was
		# probed directly and made no difference either. The fix is architectural,
		# not environmental — see the pr stage.
		def self.env_for(stage, owner: nil, name: nil)
			env = {}
			bundle = ca_bundle
			env['SSL_CERT_FILE'] = bundle if bundle
			env.merge!(Mill::Secrets.for_repo(owner, name))
			token = Mill::Secrets.token if Mill::Secrets::PUSHING.include?(stage)
			env['GH_TOKEN'] = token if token
			env
		end

		def self.write!(home: Mill.home)
			dir = File.join(home, 'settings')
			FileUtils.mkdir_p(dir)
			FileUtils.chmod(0o700, home)
			FileUtils.chmod(0o700, dir)

			Mill::Stages.names.map do |stage|
				path = File.join(dir, "#{Mill::Stages.slug(stage)}.json")
				File.write(path, JSON.pretty_generate(for_stage(stage)))
				FileUtils.chmod(0o600, path)
				path
			end
		end
	end
end
