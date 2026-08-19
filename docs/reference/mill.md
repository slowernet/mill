# mill reference

Domain vocabulary and operational reference. The pipeline, the stage graph, containment, the
failure taxonomy, and scope decisions live in
`docs/superpowers/specs/2026-08-06-software-factory-design.md`.

First-time setup is a separate runbook: [setup.md](setup.md).

**Some of this vocabulary describes work that is not built yet**, and those passages are marked
**(not built)** inline rather than removed — the words are what you will want when they land, and a
reference that quietly omits them is harder to read than one that says which is which. The single
inventory of what exists is the design doc's
[Where this stands](../superpowers/specs/2026-08-06-software-factory-design.md#where-this-stands);
this file defers to it and does not keep a second list.

## Contents

- [The board](#the-board)
- [Talking to a run](#talking-to-a-run)
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
| `Evidence` | `Required` | The PR must include a before/after sample of real output **(not built)** |
| `Review` | `Deep` | Faceted fan-out plus refutation instead of a single reviewer **(not built)** |

Both fields exist on the board and doctor checks for them. mill reads neither yet, so setting one
changes nothing today.

Status is state and belongs to mill; the other two are directives and belong to you. Don't
hand-edit Status to steer a run — set it to `Ready` to release work, and use the kill switch
to stop one.

Field values belong to the project, not the issue, so an item's Status here is independent of
its status on any other board, and no other project's automation can reach it. The board's own
built-in workflows must stay disabled, because they write Status too — `mill:doctor` checks.

`Done` means "PR opened", not "finished". The three PR triggers operate after it.

## Talking to a run

**To answer a blocked run, just reply in a comment.** While an item is `Blocked`, every comment on
it is read as an answer. No marker, no syntax.

**To ask mill to change something on a PR it opened, start the comment with `mill:`. (not built)**
Anything after the marker is the instruction, and a comment without it is ignored, so ordinary
conversation on a mill PR costs nothing:

```
mill: the null check in Session#expire is in the wrong branch
```

Two things need no marker. A **PR review comment** is already a request for a change, and a **red
required check** is a fact — mill will act on both by itself, giving up after two fix runs against
the same failing commit and saying so on the PR. **(not built)**

All three of those need the `iterate` route, which has no prompts yet. Today mill sweeps such
comments, recognises them, records them with state `no_route`, and logs that it had nowhere to send
them. Answering a blocked run is the one comment trigger that works.

**Before you set Status to `Ready`, switch your clone off the branch.** git refuses to check a
branch out in two places, so a branch left current in the clone mill resolves blocks the item until
you move off it. mill names the clone and the branch in the comment.

## Releasing work

The normal path for a feature:

1. **Design it interactively.** `gh issue develop <n>` to create and link a branch, then a
   normal Claude Code session — `brainstorming`, argument, revision. It commits a spec to
   `docs/superpowers/specs/`.
2. **Push the branch, then switch off it.** The linked branch is how mill finds the spec; no path
   goes in the issue body. Leaving it checked out in your clone blocks the item, because git
   refuses to check one branch out twice.
3. **Set Status to `Ready`.** That act asserts the design is reviewed.

mill adopts the branch, plans, implements, reviews, and opens a PR with the spec, the plan, and
the code in one diff.

**An epic is a sequence of specs, not one spec.** One issue and one branch each, released in
order, each after its predecessor's PR merges — mill does not stack branches. The size test and
the rest of the spec checklist: [spec-standard.md](spec-standard.md).

**(not built)** For a crash or a one-line fix, skip steps 1 and 2 — set Status to `Ready` on an
issue with no linked branch and triage will route it to the fast path. An issue with neither a spec
nor a hotfix shape will block and ask you to think it through.

Until the `fast` route has prompts, `plan` is the only route mill claims. An item with no linked
branch gets a comment telling you to run `gh issue develop` and commit a spec — so the shortcut
above does the opposite of what it says today. Follow steps 1 to 3 for everything.

## Key models

- **Repo**: a repository mill has prepared — a working copy, git config applied, `.mill.yml` parsed from the base branch, and the secrets it names confirmed present. Prepared lazily on first touch; not a watchlist. The repo allowlist is the stage token's selected-repositories list. **Finding the working copy**: mill scans the directories in `MILL_CLONES` for one whose `origin` matches — defaulting to `~/code` on macOS and to nothing on a server — and clones into `~/.mill/clones/<owner>-<repo>` when it finds none. Two matches block the item rather than choosing, because the choice commits the whole run to a checkout you did not pick.
- **Subject**: the thing a run is about — an issue or a pull request, as `subject_kind` plus `subject_number`. PR-entry runs have no issue.
- **Run**: one subject moving through the pipeline on one branch, in one worktree
- **Route**: `plan` (a spec exists — plan, review, implement, review, PR), `fast` (no spec, hotfix-shaped — diagnose, implement, review, PR) **(not built)**, or `iterate` (entry from a PR trigger, on the existing branch) **(not built)**. All three exist as data in the stage graph; only `plan` has prompts, and only `plan` is ever claimed.
- **Spec**: the design you wrote, found as the file the linked branch adds under `docs/superpowers/specs/`. Exactly one is the spec; more than one blocks; none routes to `fast` if triage judges the issue hotfix-shaped, otherwise blocks.
- **Stage**: a node in the graph; one `claude -p` process group with a fixed model, a named skill, and its own permission ruleset. Most stages borrow a Superpowers skill unchanged; `implement` and `pr` use mill's own `mill:implement` and `mill:pr`, because the Superpowers equivalents assume a human at a terminal and would open the PR early or offer to merge.
- **Attempt**: one execution of a stage. mill counts two things about them. The **attempt number** goes up on every launch and names the log and verdict. The **strike count** goes up only when the work was judged bad — a crash, a failure, an unusable verdict, or a serious objection — and two strikes blocks the run. Anything the machine did to a stage costs an attempt and no strike. Answering an exhaustion block resets that stage's strikes once.
- **Verdict**: the structured output a stage ends with, its shape constrained by `--json-schema` so the CLI returns it already parsed rather than as text a stage could wrap in prose. mill validates it and records it in `stage_attempts.verdict_json`; no stage writes it anywhere. Must carry the stage, attempt, and nonce mill passed in — the schema cannot know which launch this is, so that check stays mill's. Status is `ok`, `blocked`, or `failed`.
- **Objection**: a reviewer finding with a severity. `high` or `critical` re-runs the reviewed stage; lower severities land in the PR body.
- **Event**: a comment occurrence the poller has seen, keyed on node id, with a retry count and two terminal states — `dead` when handling it kept raising, and `no_route` when mill recognised it but has nowhere to send it yet. Board status is *not* an event — it is reconciled as state.

## Identifier types

GitHub numbers and GitHub ids are different things, and neither is globally unique in the way you
expect.

- **Issue and PR numbers** are integers, unique only within a repository. `#42` is meaningless
  without a repo. Always carry `repo_id` alongside.
- **Node ids** (`gh_node_id`) are opaque strings — never parse, order, or do arithmetic on them.
  They are the dedupe key for comment events precisely because they are stable and unique across
  the whole of GitHub.
- **A project has both a number and a node id, and mill wants the number.** `MILL_PROJECT` is the
  small integer in the project's URL; `gh project view <number> --owner <you>` and the workflow
  query mill runs both take it. The node id (`PVT_…`) names the same project and is not
  interchangeable — you cannot derive one from the other, and passing a node id gets you a 404 with
  nothing to suggest which of the two was wanted. To go from one to the other:
  `gh api graphql -f query='query($id: ID!){ node(id: $id){ ... on ProjectV2 { number } } }' -f id=PVT_…`
- **Project item ids, field ids, and option ids** are three distinct opaque strings, all required
  to set a Status. mill resolves them the first time it writes and memoises them for that process;
  never hardcode one, and never assume you can derive an item id from the issue it wraps.
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
