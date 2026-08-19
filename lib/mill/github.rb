require 'json'
require 'open3'

module Mill
	# Every `gh` call mill makes, REST and GraphQL. Nothing else in the
	# codebase shells out to gh — that is what makes the collaborator rule, the
	# comment marker, and the board-writer rule enforceable in one place.
	#
	# Stages are a second, separate path: `pr` and `push` run gh inside the
	# worktree under a deliberately narrow token. This class is mill's own access,
	# under the operator's login.
	class Github
		class Error < Mill::Error; end
		class RateLimited < Error; end
		class Unauthorized < Error; end
		class NotFound < Error; end

		# Stamped as the first line of every comment mill writes. The poller ignores
		# a comment only when the marker starts a line that is not blockquoted:
		# GitHub's quote-reply copies the source markdown including HTML comments,
		# so a whole-body search would discard the operator's own reply.
		MARKER = '<!-- mill:v1 -->'.freeze

		# Comment-derived triggers are only honoured from these. Three of five
		# triggers are comments and comment text becomes prompt text, so without
		# this a stranger on a public repo drives a subprocess holding real
		# credentials.
		TRUSTED = %w[OWNER MEMBER COLLABORATOR].freeze

		def initialize(runner: method(:run_gh))
			@runner = runner
		end

		# --- reads -------------------------------------------------------------

		def issue(repo, number)
			json('issue', 'view', number.to_s, '--repo', repo, '--json',
				'number,title,body,state,author,comments,url')
		end

		def project_id(project, owner:)
			json('project', 'view', project.to_s, '--owner', owner, '--format', 'json')[:id]
		end

		# Field and option ids are opaque and belong to the project, so mill has to
		# resolve them rather than guess at them from the names it knows.
		def project_fields(project, owner:)
			json('project', 'field-list', project.to_s, '--owner', owner, '--format', 'json')
				.fetch(:fields, [])
		end

		# Projects v2 is GraphQL-only, so the board is never read with `gh issue list`.
		def board_items(project, owner:)
			json('project', 'item-list', project.to_s, '--owner', owner, '--format', 'json')
				.fetch(:items, [])
		end

		# The issue refers to a branch natively; mill adopts it and never creates one.
		def linked_branches(repo, number)
			query = <<~GQL
				query($owner: String!, $name: String!, $number: Int!) {
					repository(owner: $owner, name: $name) {
						issue(number: $number) {
							linkedBranches(first: 10) { nodes { ref { name } } }
						}
					}
				}
			GQL
			owner, name = repo.split('/', 2)
			data = graphql(query, owner: owner, name: name, number: number)
			data.dig(:data, :repository, :issue, :linkedBranches, :nodes)
				&.filter_map { |n| n.dig(:ref, :name) } || []
		end

		# `--paginate` alone emits one JSON array per page — "Each page is a separate
		# JSON array or object", per gh's own help — so a second page made the whole
		# response unparseable. This endpoint pages at 30 by default, so any subject
		# with 31 comments broke the only channel that resumes a blocked run.
		# `--slurp` wraps the pages in an outer array; flatten it back to comments.
		# Settled 2026-08-19 by schema introspection: ProjectV2Workflow exposes
		# `enabled: Boolean`, so doctor can check the built-in workflows directly
		# rather than falling back to a sentinel. mill must be the sole writer of
		# Status — "Item closed → Done" would flip it out from under a running run.
		def project_workflows(project, owner:)
			query = <<~GQL
				query($owner: String!, $number: Int!) {
					user(login: $owner) {
						projectV2(number: $number) {
							workflows(first: 50) { nodes { name enabled } }
						}
					}
				}
			GQL
			data = graphql(query, owner: owner, number: project.to_i)
			data.dig(:data, :user, :projectV2, :workflows, :nodes) || []
		end

		# `since` is why the cursor exists. Without it every sweep re-fetches every
		# comment on every live subject: a run blocked for a week on a 300-comment
		# issue is ten paginated pages every tick, which ends in a secondary rate
		# limit that wedges the poller. It is inclusive of the boundary second, so
		# a comment created in the same second comes back again — which is what the
		# caller's own filter and the unique index on gh_node_id are for.
		def comments(repo, number, since: nil)
			path = "repos/#{repo}/issues/#{number}/comments?per_page=100"
			path += "&since=#{since}" if since
			pages = json('api', path, '--paginate', '--slurp')
			Array(pages).flatten(1)
		end

		def pull_request(repo, number)
			json('pr', 'view', number.to_s, '--repo', repo, '--json',
				'number,title,body,state,headRefName,headRepositoryOwner,author,url')
		end

		# Recovered rather than stored: idempotent, so a crash between `gh pr
		# create` and the state write reconciles instead of opening a second PR.
		def pr_for_branch(repo, branch)
			json('pr', 'list', '--repo', repo, '--head', branch, '--state', 'all',
				'--json', 'number,state,url').first
		end

		# Only a 404 means "no required checks configured". Rescuing Error caught
		# RateLimited and Unauthorized too, so an expired token made every open PR
		# report a clean bill of health: no fix run started, and the repo was never
		# marked unhealthy. A rescue must never turn a failure into a pass.
		def checks(repo, number)
			json('pr', 'checks', number.to_s, '--repo', repo, '--json',
				'name,state,bucket,link', '--required')
		rescue NotFound
			[]
		end

		# --- writes ------------------------------------------------------------

		# The marker goes on the first line, always. Nothing else in mill may
		# comment, so nothing else can forget it.
		def comment(repo, number, body)
			run('issue', 'comment', number.to_s, '--repo', repo, '--body', stamp(body))
		end

		def stamp(body) = "#{MARKER}\n#{body}"

		# mill is the sole writer of Status. This is the only method that writes
		# one, which is what makes that rule enforceable rather than aspirational.
		def set_status(project_id:, item_id:, field_id:, option_id:)
			run('project', 'item-edit', '--id', item_id, '--project-id', project_id,
				'--field-id', field_id, '--single-select-option-id', option_id)
		end

		# mill opens the pull request, not the stage. The stage composes the body and
		# pushes the branch — both of which work inside the sandbox — and mill makes
		# the API call from out here.
		#
		# This is why: `gh` verifies TLS through the macOS Security framework, which
		# the Bash sandbox blocks, measured across three attempts on 2026-08-19 while
		# `curl` and `git push` reached the same host over the same allowlist. But it
		# is the better shape regardless. `Mill::Github` is now the single seam for
		# every call mill's side makes, which was previously only true of mill's own
		# calls — and `gh pr merge` becomes unreachable by construction rather than
		# by a deny rule that has to be remembered.
		#
		# Idempotent by recovery, not by flag: a crash between creating the pull
		# request and recording its number reconciles on the next look rather than
		# opening a second one.
		def create_pull_request(repo, head:, base:, title:, body:)
			existing = pr_for_branch(repo, head)
			return existing if existing

			run('pr', 'create', '--repo', repo, '--head', head, '--base', base,
				'--title', title, '--body', body)
			pr_for_branch(repo, head) or
				raise Error, "gh pr create reported success but no pull request exists for #{head}"
		end

		# --- rules -------------------------------------------------------------

		# mill is the sole writer of Status, and a comment is only a trigger when
		# its author is trusted.
		#
		# Both key forms are read because mill has two comment sources: the REST
		# endpoint returns `author_association`, while `gh issue view --json
		# comments` returns `authorAssociation`. Understanding only one meant every
		# author read as untrusted through the other, silently.
		def self.trusted_author?(comment)
			return false unless comment.is_a?(Hash)

			TRUSTED.include?((comment[:author_association] || comment[:authorAssociation]).to_s)
		end

		# True when the body is one mill wrote. A quote-reply reproduces the marker
		# behind '>' , so a blockquoted marker is the operator talking, not mill.
		def self.own_comment?(body)
			return false if body.nil?

			body.to_s.lines.any? { |line| line.start_with?(MARKER) }
		end

		# Checking out a fork head means executing a stranger's CLAUDE.md and bin/.
		#
		# The owner arrives as an object from `gh pr view --json` and as a bare
		# login from a flattened projection. Reaching for `.dig` first raised a
		# TypeError on the second shape rather than falling through to it.
		def self.same_repo_head?(pr, repo)
			owner = pr.is_a?(Hash) ? pr[:headRepositoryOwner] : nil
			owner = owner[:login] if owner.is_a?(Hash)
			return false if owner.nil? || !owner.is_a?(String)

			repo.split('/', 2).first == owner
		end

		private

		def json(*args)
			out = run(*args)
			return nil if out.strip.empty?

			JSON.parse(out, symbolize_names: true)
		rescue JSON::ParserError => e
			raise Error, "gh returned unparseable JSON: #{e.message}"
		end

		def graphql(query, **vars)
			args = ['api', 'graphql', '-f', "query=#{query}"]
			vars.each { |k, v| args += [v.is_a?(Integer) ? '-F' : '-f', "#{k}=#{v}"] }
			json(*args)
		end

		# Every runner funnels through here, the injected ones in tests included, so
		# this is where text mill did not write becomes text mill can parse. Open3
		# tags its output with Encoding.default_external, so on a host with no locale
		# set an issue body containing an emoji arrives tagged US-ASCII and raises
		# out of JSON.parse before anything can handle it.
		def run(*args) = Mill.utf8(@runner.call(args))

		# The one place mill shells out to gh.
		def run_gh(args)
			out, err, status = Open3.capture3('gh', *args)
			return out if status.success?

			raise_for(Mill.utf8(err), args)
		end


		def raise_for(err, args)
			message = "gh #{args.first(2).join(' ')} failed: #{err.strip[0, 300]}"
			case err
			when /rate limit|secondary rate/i then raise RateLimited, message
			when /401|Bad credentials|gh auth login/i then raise Unauthorized, message
			when /404|Not Found|Could not resolve/i then raise NotFound, message
			else raise Error, message
			end
		end
	end
end
