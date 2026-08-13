# mill reference

Domain vocabulary and operational reference. The pipeline, the stage graph, containment, the
failure taxonomy, and scope decisions live in
`docs/superpowers/specs/2026-08-06-software-factory-design.md`.

First-time setup is a separate runbook: [setup.md](setup.md).

## Contents

- [The board](#the-board)
- [Releasing work](#releasing-work)
- [Key models](#key-models)

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
