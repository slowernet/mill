# mill reference

Domain vocabulary and operational reference. The pipeline, the stage graph, containment, the
failure taxonomy, and scope decisions live in
`docs/superpowers/specs/2026-08-06-software-factory-design.md`.

First-time setup is a separate runbook: [setup.md](setup.md).

## Contents

- [The board](#the-board)
- [Releasing work](#releasing-work)
- [Key models](#key-models)
- [Identifier types](#identifier-types)
- [Query optimization](#query-optimization)

## The board

A single user-level GitHub Project spans every repo, and its fields are mill's entire
interface. Both issues and pull requests appear as items. **mill uses no labels.**

**Status** — the queue. mill is its sole writer.

| Status | Meaning |
|---|---|
| `Ready` | Released to the factory |
| `Running` | A run has claimed it |
| `Blocked` | Stopped for input; reply in a comment to resume |
| `Done` | PR opened |
| `Failed` | Terminal without a PR |

**Directives** — yours to set. Projects v2 has no boolean field type, so each is a
single-select with one option: set or unset.

| Field | Option | Meaning |
|---|---|---|
| `Evidence` | `Required` | The PR must include a before/after sample of real output |
| `Review` | `Deep` | Faceted fan-out plus refutation instead of a single reviewer |

Status is state and belongs to mill; the other two are directives and belong to you. Don't
hand-edit Status to steer a run — set it to `Ready` to release work, and use the kill switch
to stop one.

Field values belong to the project, not the issue, so an item's Status here is independent of
its status on any other board, and no other project's automation can reach it. The board's own
built-in workflows must stay disabled, because they write Status too — `mill:doctor` checks.

`Done` means "PR opened", not "finished". The three PR triggers operate after it.

## Releasing work

The normal path for a feature:

1. **Design it interactively.** `gh issue develop <n>` to create and link a branch, then a
   normal Claude Code session — `brainstorming`, argument, revision. It commits a spec to
   `docs/superpowers/specs/`.
2. **Push the branch.** The linked branch is how mill finds the spec; no path goes in the issue
   body.
3. **Set Status to `Ready`.** That act asserts the design is reviewed.

mill adopts the branch, plans, implements, reviews, and opens a PR with the spec, the plan, and
the code in one diff.

For a crash or a one-line fix, skip steps 1 and 2 — set Status to `Ready` on an issue with no
linked branch and triage will route it to the fast path. An issue with neither a spec nor a
hotfix shape will block and ask you to think it through.

## Key models

- **Repo**: a repository mill has prepared — resolved local clone path, git config applied, `.mill.yml` parsed from the base branch. Prepared lazily on first touch; not a watchlist. The repo allowlist is the stage token's selected-repositories list.
- **Subject**: the thing a run is about — an issue or a pull request, as `subject_kind` plus `subject_number`. PR-entry runs have no issue.
- **Run**: one subject moving through the pipeline on one branch, in one worktree
- **Route**: `plan` (a spec exists — plan, review, implement, review, PR), `fast` (no spec, hotfix-shaped — diagnose, implement, review, PR), or `iterate` (entry from a PR trigger, on the existing branch)
- **Spec**: the design you wrote, found as the file the linked branch adds under `docs/superpowers/specs/`. Exactly one; zero or many blocks.
- **Stage**: a node in the graph; one `claude -p` process group with a fixed model, a named skill, and its own permission ruleset
- **Attempt**: one execution of a stage. Two per stage, then the run blocks. Answering an exhaustion block resets that stage's counter once.
- **Verdict**: JSON written by every attempt to `~/.mill/runs/<run-id>/verdict-<stage>-<n>.json`, outside the repo. Must carry the stage, attempt, and nonce mill passed in; status is `ok`, `blocked`, or `failed`.
- **Objection**: a reviewer finding with a severity. `high` or `critical` re-runs the reviewed stage; lower severities land in the PR body.
- **Event**: a comment occurrence the poller has seen, keyed on node id, with a retry count and a terminal `dead` state. Board status is *not* an event — it is reconciled as state.

## Identifier types

GitHub numbers and GitHub ids are different things, and neither is globally unique in the way you
expect.

- **Issue and PR numbers** are integers, unique only within a repository. `#42` is meaningless
  without a repo. Always carry `repo_id` alongside.
- **Node ids** (`gh_node_id`) are opaque strings — never parse, order, or do arithmetic on them.
  They are the dedupe key for comment events precisely because they are stable and unique across
  the whole of GitHub.
- **Project item ids, field ids, and option ids** are three distinct opaque strings, all required
  to set a Status. mill resolves them at bootstrap and caches them; never hardcode one, and never
  assume you can derive an item id from the issue it wraps.
- **Session ids** from Claude Code are opaque strings, and the session file behind one may vanish.
  Any code path that resumes a session must have a fallback that re-runs the stage from scratch.
- **mill run ids** are local integers and mean nothing outside this database. Never put one in a
  GitHub comment as though the reader could look it up.

## Query optimization

When moving filtering from Ruby into a query — SQL, or a `gh` API search:

- **Ruby defaults mask missing data.** Accessors like `row[:field] || 'default'` make a NULL
  column or an absent JSON key behave as if it has a value. A query filtering on that column skips
  those rows entirely. Verify the field is populated on every row before depending on it
  server-side.
- **Trace all write paths.** Before depending on a field in a query, grep for every insert and
  update touching that table to confirm the field is always set. Backfill in a migration if it is
  not.
- **`gh` search is not a database.** GitHub's search index lags and is rate-limited. Filter on
  values you fetched directly, not on search results, when correctness matters.
