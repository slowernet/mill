# mill setup runbook

One-time, account-level setup. Per-repo preparation is **lazy** — mill resolves the clone,
applies git config, and reads `.mill.yml` the first time an item from that repo reaches the
board. There is no repo watchlist and nothing to enable.

These steps are a runbook rather than a script because two of them cannot be automated:
minting a fine-grained PAT has no API, and choosing which repos a token may touch is a
decision a script should not make silently.

After each section, `bundle exec rake mill:doctor` will tell you what is still missing. Prefer
running it over trusting this document — it checks reality.

## Contents

- [1. Two tokens, two jobs](#1-two-tokens-two-jobs)
- [2. Project scope on your gh login](#2-project-scope-on-your-gh-login)
- [3. Create the board](#3-create-the-board)
- [4. Disable the board's built-in workflows](#4-disable-the-boards-built-in-workflows)
- [5. Mint the stage token](#5-mint-the-stage-token)
- [6. Permission rulesets](#6-permission-rulesets)
- [7. Branch protection](#7-branch-protection)
- [8. Per-repo secrets](#8-per-repo-secrets)
- [9. Server deployment (optional)](#9-server-deployment-optional)
- [10. Verify](#10-verify)
- [11. A scratch repo for rehearsals](#11-a-scratch-repo-for-rehearsals)

## 1. Two tokens, two jobs

mill uses two separate credentials, and keeping them separate is the point.

| Credential | Used by | Needs |
|---|---|---|
| Your `gh` login | `Mill::Github` — board reads, Status writes, comments | `project` scope, plus your normal repo access |
| A fine-grained PAT | Stages, as `GH_TOKEN` | Contents and Pull requests, read/write, on selected repos only |

The stage token is deliberately weaker. Stages push branches and open PRs; they never touch the
board, never post comments, and never need access to any repo but their own. mill does the board
and comment work under your login, in-process, where the agent cannot reach it.

**The stage token is also mill's repo allowlist.** If it does not cover a repo, no bug in mill
can push there. Keep its repository list short and revisit it when you start work somewhere new.

## 2. Project scope on your gh login

Projects v2 is GraphQL-only and needs an explicit scope your default login may not have:

```
gh auth refresh -s project,read:project
gh auth status
```

## 3. Create the board

```
gh project create --owner @me --title "mill"
```

Note the project number it prints.

mill reads three fields and writes one. Check what exists first — a project may arrive with a
default `Status` field whose options are `Todo` / `In Progress` / `Done`, which are not mill's:

```
gh project field-list <number> --owner @me --format json
```

If a `Status` field exists with the wrong options, delete and recreate it — there is no command
to edit an existing single-select's options:

```
gh project field-delete --id <field-id>

gh project field-create <number> --owner @me --name Status \
  --data-type SINGLE_SELECT \
  --single-select-options "Ready,Running,Blocked,Done,Failed"
```

Then the two directive fields. Projects v2 has no boolean field type, so each is a single-select
with one option — set or unset:

```
gh project field-create <number> --owner @me --name Evidence \
  --data-type SINGLE_SELECT --single-select-options "Required"

gh project field-create <number> --owner @me --name Review \
  --data-type SINGLE_SELECT --single-select-options "Deep"
```

Tell mill which board it is. Doctor fails rather than skipping its board check when these are
unset:

```
export MILL_PROJECT=<number>
export MILL_PROJECT_OWNER=<your github login>
```

Record the field ids and every option id:

```
gh project field-list <number> --owner @me --format json
```

Item id, field id, and option id are three distinct opaque strings and all three are required to
set a value. mill caches them; do not hardcode them anywhere.

mill uses no labels, so there is nothing to create in any repository.

## 4. Disable the board's built-in workflows

**mill is the sole writer of the Status field.** Projects v2 ships automation that also writes
it, and a new project may arrive with some of it enabled.

In the project's **Workflows** settings, turn off every built-in workflow — including "Item
closed", "Item reopened", "Pull request merged", "Code review approved", "Auto-add to project",
and "Auto-archive items".

Two are actively harmful rather than merely redundant:

- **"Item closed → Done"** flips Status out from under a `Running` run, so the reconciler stops
  seeing the item as active while the worktree and subprocess carry on.
- **"Auto-add to project"** would sweep every new issue in a repo onto the board. Since the board
  is the queue, that is a mass trigger.

Nobody else's project automation can touch mill's board — fields belong to the project, not the
issue — so this is only ever about mill's own project.

## 5. Mint the stage token

No API exists for this. In the web UI:

1. **Settings → Developer settings → Personal access tokens → Fine-grained tokens**, create a
   new token.
2. **Repository access:** *Only select repositories*. Add only repos you intend mill to work in.
3. **Repository permissions:** `Contents` read and write, `Pull requests` read and write.
   Nothing else. In particular do not grant Actions, Secrets, Administration, or Workflows — a
   stage that could write workflows could exfiltrate repository secrets by pushing a branch.
4. Set an expiry you will actually notice.

Store it where only you can read it:

```
mkdir -p ~/.mill/secrets
chmod 0700 ~/.mill ~/.mill/secrets
printf '%s' '<token>' > ~/.mill/secrets/stage-token
chmod 0600 ~/.mill/secrets/stage-token
```

## 6. Permission rulesets

Each stage runs under its own ruleset in `~/.mill/settings/<stage>.json`. These live outside every
worktree deliberately: a stage that could write `.claude/` would be picked up by the settings
watcher and could disarm its own restrictions mid-session.

Write them from mill's own definition rather than by hand, so what you create and what doctor
demands cannot drift:

```
bundle exec rake mill:settings
```

Three things about these rules are easy to get wrong, and each produces a file that reads as
protection while enforcing nothing. Doctor rejects all three:

- **Worktree-relative paths only.** An absolute path is accepted silently and enforces nothing.
  Nothing outside the worktree needs a rule anyway — the working directory already covers it.
- **`Edit(...)`, never `Write(...)`.** Claude Code matches file permission checks against `Edit`
  rules only, and `Edit` covers every file-editing tool including Write.
- **No `allow` list.** In headless mode an allow list is advisory: a tool in neither `allow` nor
  `deny` runs anyway. Confinement lives in `--tools`, and moving it into `allow` turns the
  strongest half of layer 1 off.

## 7. Branch protection

mill's CI trigger fires on **required** checks going red, so the base branch needs branch
protection with required status checks. This also makes CI a real merge gate for you, not just a
signal for mill.

Per repo, once:

```
gh api --method PUT repos/<owner>/<repo>/branches/<base>/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["test"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

`contexts` must match the job name your workflow reports — `test` for the `ci.yml` in this repo.
A name that matches nothing means the check is never required, so the trigger silently never
fires; `mill:doctor` checks that the configured `ci_workflow` in `.mill.yml` resolves to a real
workflow and that its checks are required.

`enforce_admins: false` leaves you able to merge past a red check deliberately. Set it to `true`
if you would rather not have that option.

## 8. Per-repo secrets

A fresh worktree contains tracked files only, so `.env` and `config/master.key` are absent and an
env-dependent test suite would fail on both attempts. For each repo whose tests need them:

```
~/.mill/secrets/<owner>-<repo>.env
```

Plain `KEY=value` lines. mill injects these into the stage environment as variables, never writes
them into the worktree, and excludes their values from the tee'd log. List the variable names in
that repo's `.mill.yml` so `mill:doctor` can check they are present.

Use test-scoped values, not production ones. Nothing prevents an agent from printing an
environment variable into a log it is allowed to write.

## 9. Server deployment (optional)

Skip this on a laptop, where mill binds loopback and needs no identity check.

On a server the UI is reachable over the network, so it needs Google OAuth with an email
allowlist. You need a hostname you control (a subdomain of a domain you already own is enough),
TLS in front of Puma, and an OAuth client:

1. **DNS and TLS.** Point a hostname at the box and terminate TLS with a reverse proxy. Google
   refuses a plain-HTTP redirect URI for anything but localhost, so this is a precondition, not
   a nicety.
2. **OAuth client.** In Google Cloud Console, create an OAuth 2.0 Client ID of type *Web
   application*, with the authorised redirect URI `https://<host>/auth/google_oauth2/callback`.
3. **Environment.** Set `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, a stable
   `SESSION_SECRET`, and `MILL_ADMIN_EMAILS` as a comma-separated allowlist. Set the bind address
   and the `Host` allowlist to the real hostname.
4. **Verify `claude` authenticates on the box.** Run one `claude -p` there before trusting the
   deployment. If a headless host cannot authenticate against your subscription, the server
   deployment does not work and mill is laptop-only.

Anything on the network can reach the sign-in page, and the allowlist is what stands between it
and a kill switch. Binding to a private network — Tailscale or a VPN — instead of the public
internet is a reasonable second layer, and Google will still accept the redirect URI provided the
name resolves publicly and carries a valid certificate.

## 10. Verify

```
bundle exec rake mill:doctor
```

It checks, and names anything missing:

- `gh` authenticated, with `project` scope
- the project resolves and has `Status`, `Evidence`, and `Review` with the expected options
- every built-in workflow on the project is disabled. Doctor reads the board from
  `MILL_PROJECT` and `MILL_PROJECT_OWNER` and fails when they are unset, rather than passing a
  check it did not make. mill also reports a Status it did not write as board interference, which
  catches a workflow re-enabled later
- the stage token exists, is readable only by you, is unexpired, and has exactly the two expected
  permissions
- `~/.mill` and `~/.mill/secrets` are `0700`
- the permission ruleset files in `~/.mill/settings/` exist and carry every deny rule the design
  doc requires, **with no absolute paths and no `Write(...)` rules**, and put no confinement in
  an `allow` list — each of those three is accepted silently and enforces nothing
- every stage that names a skill has `Skill` in its toolset, and the three writing stages carry
  `--permission-mode acceptEdits`
- on a server: the OAuth variables, the session secret, a non-empty `MILL_ADMIN_EMAILS`, and a
  `Host` allowlist that is not the loopback default
- for every repo the board currently references: the clone resolves, `origin` matches, `gc.auto`
  and `maintenance.auto` are `0`, `.mill.yml` parses, its `ci_workflow` resolves to a real
  workflow whose checks are required on the base branch, and every secret variable it names is
  present

Treat a red doctor as a blocker. Most of what it checks is critical to containment rather than
a convenience.

## 11. A scratch repo for rehearsals

mill pushes real branches and opens real pull requests, so building it needs a target nobody cares
about. The same scenario gets run many times, so it has to be disposable — reset it after every
rehearsal rather than accumulating state you then have to reason about.

```
gh repo create slowernet/mill-scratch --private --clone
cd mill-scratch
```

It needs enough structure to plan against — a test suite that really runs, and files with actual
shape rather than placeholders:

```
mkdir -p lib test .github/workflows docs/superpowers/specs

cat > Gemfile <<'RUBY'
source 'https://rubygems.org'
gem 'minitest'
gem 'rake'
RUBY

cat > Rakefile <<'RUBY'
require 'rake/testtask'
Rake::TestTask.new(:test) do |t|
	t.libs << 'lib' << 'test'
	t.test_files = FileList['test/**/test_*.rb']
end
task default: :test
RUBY

cat > lib/inventory.rb <<'RUBY'
# A deliberately small domain with room for a feature to be added to it.
class Inventory
	Item = Struct.new(:sku, :name, :count, keyword_init: true)

	def initialize = @items = {}

	def add(sku:, name:, count: 0)
		@items[sku] = Item.new(sku: sku, name: name, count: count)
	end

	def count(sku) = @items[sku]&.count || 0

	def restock(sku, by:)
		item = @items[sku] or raise KeyError, "no such sku: #{sku}"
		item.count += by
	end
end
RUBY

cat > test/test_inventory.rb <<'RUBY'
require 'minitest/autorun'
require 'inventory'

class TestInventory < Minitest::Test
	def setup = @inventory = Inventory.new

	def test_an_added_item_can_be_counted
		@inventory.add(sku: 'A1', name: 'Widget', count: 3)
		assert_equal 3, @inventory.count('A1')
	end

	def test_an_unknown_sku_counts_zero
		assert_equal 0, @inventory.count('nope')
	end

	def test_restocking_raises_for_an_unknown_sku
		assert_raises(KeyError) { @inventory.restock('nope', by: 1) }
	end
end
RUBY

cat > .github/workflows/ci.yml <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
      - run: bundle exec rake test
YAML

cat > .mill.yml <<'YAML'
base_branch: main
test_command: bundle exec rake test
ci_workflow: ci.yml
trusted_authors:
  - dependabot[bot]
evidence_public: false
secrets: []
YAML

git add -A && git commit -m "Scaffold the scratch repo" && git push -u origin main
```

The CI job is named `test`, which is the name branch protection must require. Set that up with
section 7's command, using `contexts: ["test"]`.

### The rehearsal fixture

mill's `plan` route starts from an issue with a spec on a linked branch, so create one:

```
gh issue create --repo slowernet/mill-scratch \
  --title 'Track low-stock items' --body-file - <<'MD'
Inventory has no way to answer "what needs reordering?". See the spec on the linked branch.
MD

gh issue develop <number> --repo slowernet/mill-scratch --checkout
```

Write the spec on that branch to the standard in `docs/reference/spec-standard.md`, commit it, and
push. Then **switch your clone off the branch** — `git worktree add` refuses a branch that is
checked out anywhere, including your clone's own HEAD, and mill blocks rather than forcing it:

```
git add docs/superpowers/specs/ && git commit -m "Spec: track low-stock items" && git push
git switch main
```

### Resetting between rehearsals

Delete the pull request and the branch, then re-run `gh issue develop`:

```
gh pr close <pr> --repo slowernet/mill-scratch --delete-branch
git push origin --delete <branch> 2>/dev/null || true
git worktree prune
```
