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
- [6. Branch protection](#6-branch-protection)
- [7. Per-repo secrets](#7-per-repo-secrets)
- [8. Verify](#8-verify)

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

## 6. Branch protection

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

## 7. Per-repo secrets

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

## 8. Verify

```
bundle exec rake mill:doctor
```

It checks, and names anything missing:

- `gh` authenticated, with `project` scope
- the project resolves and has `Status`, `Evidence`, and `Review` with the expected options
- every built-in workflow on the project is disabled
- the stage token exists, is readable only by you, is unexpired, and has exactly the two expected
  permissions
- `~/.mill` and `~/.mill/secrets` are `0700`
- the permission ruleset files in `~/.mill/settings/` exist and deny the paths the design doc
  requires
- for every repo the board currently references: the clone resolves, `origin` matches, `gc.auto`
  and `maintenance.auto` are `0`, `.mill.yml` parses, its `ci_workflow` resolves to a real
  workflow whose checks are required on the base branch, and every secret variable it names is
  present

Treat a red doctor as a blocker. Most of what it checks is critical to containment rather than
a convenience.
