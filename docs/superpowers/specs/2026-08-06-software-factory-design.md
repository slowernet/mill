# Mill — a software factory for Claude Code

Design doc. 2026-08-06.

## What Mill is

Mill is a Ruby/Roda application that drives Claude Code through a fixed agentic SDLC —
design, review, plan, review, implement, review, PR — for work that arrives as GitHub activity. It watches the repos you enable, runs the
pipeline in an isolated git worktree, and opens a pull request. You judge the PR.

The design follows Addy Osmani's framing: a *loop* is one agent doing one job, a
*harness* is the environment it runs inside, and a *factory* is many harnessed loops fed
by a queue and filtered through a review gate. Mill is the harness and the factory. The
loops are Claude Code invocations.

Two of Osmani's conclusions shape everything below. **Verification is the bottleneck,
not generation** — so the pipeline spends most of its stages checking rather than
producing. And **back-pressure is the rule that you only grant a loop as much autonomy
as you can cheaply verify** — so every stage has a hard attempt limit and an explicit
way to stop the line.

## Non-goals

Written down so they don't creep:

- **Not a chat UI.** Interactive dialogue with Claude happens in your terminal. Mill
  starts when work reaches GitHub.
- **Not a multi-source ingest.** No Slack, Linear, Jira, Figma, voice, or video. GitHub
  events only.
- **Not a deployment tool.** Mill never deploys and never merges.
- **Not a team product.** Single operator, single machine, your GitHub identity.
- **Not a replacement for Superpowers.** Mill sequences and gates the skills you already
  use; it does not reimplement them.

## Principles

1. **GitHub is the database.** Work state lives in GitHub as labels, comments, and PRs.
   Mill's SQLite holds only what GitHub cannot express. Delete Mill's database and you
   lose observability, not work.
2. **Silence is never success.** Every stage must produce an explicit verdict. A missing
   or malformed verdict is a failure, not a pass. This is the structural answer to
   completion theater.
3. **The line can always stop.** Any stage may emit questions and block rather than
   guess at an underspecified issue.
4. **One human gate: the PR.** Judgment moves upstream (writing the issue) and
   downstream (reading the PR), not into the middle of the pipeline.
5. **Deterministic where it can be.** The graph, the model per stage, the attempt limits,
   and the safety hooks are code and config, not agent discretion.

## Architecture

Five components. Only two touch the outside world.

| Component | Responsibility | Knows about |
|---|---|---|
| `Mill::Poller` | Turn GitHub activity into rows in `events` | `Mill::Github` only |
| `Mill::Supervisor` | Claim runnable work up to the cap, manage worktrees, reap runners | the DB, git |
| `Mill::Runner` | Walk the stage graph for one run | the graph, `Mill::Claude` |
| `Mill::Claude` | Build argv, spawn `claude`, tee the log, read the verdict | Claude Code |
| `Mill::Github` | Every `gh` invocation | GitHub |

`Mill::Github` is deliberately the single seam through which all GitHub access passes. If
Mill ever moves off your laptop and needs a GitHub App identity, that is a one-file
change.

**Process shape.** One Puma process. The poller and supervisor are threads started at
boot. A restart kills in-flight `claude` subprocesses; runs survive because
`runs.current_stage` and the stored session id let a killed run re-enter its stage on the
next supervisor tick.

**Stack.** Ruby, Roda, Sequel, SQLite, Puma, Minitest.

**Paths.**

```
~/.mill/mill.db                      state
~/.mill/worktrees/<repo>/<run-id>/   one worktree per run
~/.mill/logs/<run-id>/<stage>-<n>.jsonl   raw stream-json per stage attempt
```

Repo clones are *not* under `~/.mill`. Mill uses the clone you already have.

## Ingress

Mill runs locally and needs no GitHub App, no webhook secret, and no tunnel. It shells
out to `gh`, which is already authenticated as you. A background thread polls every 30
seconds per enabled repo.

Five triggers, all of them GitHub events on issues or PRs:

| Trigger | Effect |
|---|---|
| Issue labeled `mill:ready` | Start a run |
| Comment on a blocked issue | Resume the blocked run with the answer |
| Comment on a Mill PR | Iterate on the branch |
| PR review comment | Address the feedback on the branch |
| Failing checks on a Mill PR | Fix the failure on the branch |

Dependabot needs no special handling: it opens the PR, CI fails, and the existing
PR-CI-failure path picks it up. The only requirement is that Mill acts on PRs it did not
author.

**Label lifecycle.** Mill swaps `mill:ready` for `mill:running` when it claims an issue,
`mill:blocked` when a run stops for input, and `mill:done` when the PR opens. The labels
are the queue: the state of a piece of work is legible in GitHub without opening Mill.

**Sentry is upstream of Mill and requires no Mill code.** Sentry's free Developer tier
cannot open GitHub issues — manual issue management needs Team or above and *automatic*
issue management needs Business or Enterprise. So on the free tier Sentry emails you, you
open an issue with the Sentry link, and label it. The agent pulls error detail through
Sentry's MCP server (`mcp.sentry.dev`) rather than the API. Upgrading later changes
nothing in Mill, because a Sentry-derived issue is just an issue.

### The self-trigger problem

Because Mill posts comments under your identity, it can wake itself up. There is no bot
author to filter on. Every comment Mill writes therefore carries an HTML marker:

```
<!-- mill:v1 -->
```

The poller discards any comment containing it. This is the one place the no-GitHub-App
decision costs real care, and it is worth a dedicated test.

Polling also re-sees the same comment repeatedly. The `events` table keys on GitHub's own
node id with a unique index, which is what stops Mill from answering a question twice.

## The stage graph

The graph is data, not control flow. Each stage declares its name, prompt template,
model, the skill it invokes, and the artifact it must produce.

**Full route** — features and anything non-trivial:

```
triage → design → review:design → plan → review:plan → implement → review:code → pr
```

**Small route** — one-file fixes, lint violations, dependency bumps:

```
triage → implement → review:code → pr
```

Triage picks the route; the `mill:small` label forces it. The small route exists because
the quickstart's own scaling rule says a one-liner does not need a design doc, and
because Osmani's loop-length guidance (3–10 steps stays verifiable, 20+ degrades) argues
against an eight-stage pipeline for trivial work.

### Stages, models, and skills

| Stage | Model | Skill invoked | Produces |
|---|---|---|---|
| `triage` | Sonnet | none | route, evidence flag, actionability verdict |
| `design` | Opus | `superpowers:brainstorming` | `docs/superpowers/specs/<date>-<slug>-design.md` |
| `review:design` | Opus | `adversarial-reviewer` | objections |
| `plan` | Opus | `superpowers:writing-plans` | `docs/superpowers/plans/<date>-<slug>.md` |
| `review:plan` | Opus | `adversarial-reviewer` | objections |
| `implement` | Opus | `superpowers:executing-plans` (TDD) | code + tests |
| `review:code` | Opus | `adversarial-reviewer` | objections |
| `pr` | Opus | `superpowers:finishing-a-development-branch` | pull request |

The model map is hardcoded: Sonnet for cheap mechanical passes, Opus for judgment and
code. There is no user-facing toggle. Changing the map is a config edit.

Artifacts are committed to the branch and land in the PR diff, so the reviewer sees the
reasoning next to the code. The small route produces neither a design nor a plan.

### Stage prompts

Mill owns a thin prompt per stage that invokes its skill **explicitly by name**, removing
the probabilistic activation the quickstart warns about. Mill also ships one skill of its
own, `mill-headless`, which redefines the interactive gates the Superpowers skills assume:

- Instead of asking the user a question and waiting, write the questions to the verdict
  and stop.
- Instead of requesting approval after each design section, proceed and record the
  decisions in the artifact.
- Write artifacts to the Superpowers default paths.

Keeping the discipline in the skills rather than in Mill means interactive sessions and
factory runs stay behaviourally aligned, and upstream skill improvements arrive for free.
The accepted risk is that an upstream change can surprise Mill; the mitigation is that
stage behaviour is asserted in tests against recorded fixtures.

## The stage contract

Every stage is one `claude -p` subprocess whose final instruction is identical: write
`.mill/verdict.json` in the worktree.

```json
{
  "status": "ok" | "blocked" | "failed",
  "artifact": "docs/superpowers/specs/2026-08-06-foo-design.md",
  "questions": ["Should deleted users keep their comments?"],
  "objections": [{ "severity": "high", "claim": "..." }],
  "summary": "one paragraph for the log and the PR body"
}
```

Mill reads the file rather than parsing prose from stdout. Stages run with
`--output-format stream-json` so the web can tail progress live, and Mill lifts
`session_id` from the init message and stores it per attempt.

A missing or malformed verdict is `failed`.

## Blocking, questions, and resume

When a stage cannot proceed — an underspecified issue, an ambiguous requirement, a
decision that is not the agent's to make — it emits questions and Mill:

1. Posts them as an issue comment, marker included.
2. Labels the issue `mill:blocked`.
3. Halts the run at that stage.

Your reply is a comment, which is already a trigger. Mill resumes by calling
`claude --resume <session-id>` with the answers injected, preserving the agent's
in-progress reasoning. If the session file is gone, Mill falls back to re-running the
stage from scratch with the full question-and-answer thread appended to the prompt. A
blocked run can therefore never become unresumable.

## Back-pressure

**Two attempts per stage, then block.** A stage that fails, crashes, times out, or is
rejected by its adversarial reviewer gets exactly one retry with the failure or the
objections in context. The second failure posts both attempts to the issue, labels it
`mill:blocked`, and stops.

This is Stripe's guardrail, and it does two jobs: it prevents the whack-a-mole spiral the
quickstart calls regression aggression, and it gives every run a hard token ceiling.

**Limits, all config with these defaults:** three concurrent runs, 30-minute wall clock
per stage attempt, and a $10 spend ceiling per run. A run that hits the spend ceiling is
killed and blocked with its spend reported, rather than being allowed to converge
expensively on something subtly wrong.

## Evidence requirement

Some work is judged by looking at its output rather than by its tests — a new curation
algorithm, a different ranking method. For these, the `mill:evidence` label adds one
deliverable to the PR. It does **not** change the route, add a stage, or add a reviewer
persona.

The work is built to production standard either way. If you merge on the strength of the
sample, you are merging production-ready code.

The deliverable is a before/after sample in `docs/superpowers/samples/<date>-<slug>.md`,
with its summary table inlined in the PR body. Three requirements:

- **Show the items, do not summarize them.** "Surfaces more diverse content" cannot be
  judged. A table of the actual fifty things it picked can.
- **Before and after, same inputs through both paths.** "Does this look right?" has no
  answer without "compared to what it does now?"
- **A deterministic slice the agent did not choose**, plus explicitly the cases that
  moved most in *both* directions. Fixed seed and fixed input snapshot, with the commit
  sha and exact command recorded, so re-running gives the same rows and two attempts are
  comparable. Left to its own devices an agent shows you its five best examples.

`review:code` gains one line for these runs — a legibility check: could someone actually
judge this from what is in the PR? That is a line in an existing prompt, not a stage.

The merge decision on this work is entirely yours and is not gated by the reviewers. The
adversarial reviews confirm the code is production-ready; the sample table exists so you
can decide whether the idea is any good. Two questions, and only one is automatable.

## Repo enablement

A repo picker in the web UI, populated by `gh repo list <owner> --json nameWithOwner`.
Enabling a repo writes to the `repos` table and runs bootstrap:

1. **Resolve the clone.** Mill scans `~/code` for a repo whose `origin` remote matches
   the picked name and uses it, hanging worktrees off it. The picker displays the
   resolved path so there is no guessing about which checkout it found. If nothing
   matches, it offers to clone into `~/code/<name>`.
2. **Create labels** idempotently: `mill:ready`, `mill:running`, `mill:blocked`,
   `mill:done`, `mill:small`, `mill:evidence`.
3. **Read `.mill.yml`** if present, for per-repo overrides: base branch, test command,
   gating CI workflow.

Bootstrap failures surface in the picker immediately rather than on the next poll.

Removing the repo from the watchlist is the off switch. No uninstall, no token
revocation, and a stray label in an unlisted repo does nothing.

The picker is the only write path in the UI besides the kill switch. This is a deliberate
exception to "GitHub owns the state": a watchlist is *configuration*, not run state, so it
cannot drift out of sync with GitHub's labels the way an in-app "release this issue"
button could.

## Data model

```
repos            id, owner, name, local_path, default_branch, ci_workflow,
                 config_json, enabled, bootstrapped_at,
                 issues_cursor, comments_cursor

runs             id, repo_id, issue_number, route, evidence_required,
                 branch, worktree_path, status, current_stage,
                 pr_number, created_at, finished_at
                 -- unique index on (repo_id, issue_number) where status is active

stage_attempts   id, run_id, stage, attempt, model, session_id, status,
                 verdict_json, tokens_in, tokens_out, cost_cents,
                 log_path, started_at, finished_at

events           id, repo_id, kind, gh_node_id (unique), payload_json,
                 created_at, processed_at
```

Run statuses: `queued`, `running`, `blocked`, `done`, `failed`, `killed`.

An experiment PR that is never merged is not a failure state — it is a normal PR you
closed, which is why no `reported` status exists.

## Web UI

Roda, five routes, no framework beyond Sequel.

```
GET  /                    run list: repo, issue, route, stage, status, spend
GET  /runs/:id            stage timeline, live log tail, artifacts, verdicts
POST /runs/:id/kill       kill the subprocess, mark killed
GET  /repos               repo picker
POST /repos/:id/toggle    enable/disable
```

Everything actionable — releasing work, answering questions, reviewing the PR — happens
in GitHub. Mill shows only what GitHub cannot: what an agent is doing right now, and what
it has cost.

## Safety

Unattended runs mean `--dangerously-skip-permissions`. There is no version of this that
runs to completion while prompting for approval. Containment is therefore structural:

- Every stage runs with `cwd` inside its own worktree and no `--add-dir`. The blast radius
  is one branch in one repo.
- Mill writes a `PreToolUse` hook into the worktree's `.claude/settings.json` blocking:
  pushes to the default branch, `git commit --amend`, `git reset --hard`, any git write
  outside the worktree path, `gh pr merge`, and `rm -rf` above the worktree root. The
  quickstart's own reasoning applies — CLAUDE.md gets ignored, hooks do not.
- **Mill never merges.** Nothing in the codebase calls `gh pr merge`.
- Worktrees are torn down after the PR opens, except on abort, where they are left for
  inspection.

**Accepted risk:** network access inside a stage is unrestricted, and there is no cheap
fix. An agent can reach any host your machine can.

## Failure taxonomy

Every row resolves to `blocked` or `failed`. None resolves to silent success.

| Failure | Handling |
|---|---|
| Stage returns `blocked` | Questions to the issue, `mill:blocked`, stop. Resume on reply. |
| Stage returns `failed`, crashes, or exits non-zero | Retry once with the failure in context; second failure blocks with both attempts posted |
| `.mill/verdict.json` missing or malformed | Treated as `failed` |
| Reviewer returns objections | Re-run the reviewed stage with the objections; twice blocks |
| Stage exceeds wall clock (default 30 min) | Kill, `failed`, two-strike rule applies |
| Run exceeds token ceiling | Kill, block, report spend |
| CI red on a Mill PR | New attempt on the same branch, max two, then block |
| Mill restarted mid-stage | Run re-enters its stage next tick via the stored session id |
| Worktree conflicted or dirty | Abort, block, leave the worktree for inspection |
| `gh` rate-limited or offline | Poller backs off; events are idempotent, nothing is lost |
| Two runs on one issue | Unique index on (repo, issue, active) |

## Testing

`Mill::Claude` and `Mill::Github` are the only components that touch the outside world,
and both get fakes backed by recorded fixtures — `stream-json` transcripts and `gh` JSON
respectively. Everything above them tests with no network and no tokens.

- **Poller** — a pure function of (payload, cursor) → events. Table tests, including the
  `<!-- mill:v1 -->` filter and node-id dedupe.
- **Runner** — graph walk against scripted verdicts. The two-strike rule, block and
  resume, route selection, and evidence-flag behaviour are all covered here at zero cost.
- **Supervisor** — worktree create and tear down against a scratch repo; concurrency cap.
- **Safety hook** — its own test file with a fixture list of commands that must be
  refused. This is the only component whose failure is unbounded, so it is held to a
  stricter bar than the rest.
- **End to end** — one full run against a scratch GitHub repo, exercised by hand, not in
  CI.

## Known limitations

Stated rather than papered over:

- **The adversarial reviewer shares the author's model family.** Vorflux's pitch is "a
  second model, from a different lab, reviews every plan." Mill drives Claude Code, so
  what it can honestly offer is a fresh context and a hostile persona — which catches
  sloppiness but not shared blind spots. The seam if this ever matters is the stage's
  model field.
- **Attribution.** Mill's commits, comments, and PRs appear as you. There is no bot
  avatar distinguishing factory output from your own; the branch prefix `mill/` and the
  labels are the only signal.
- **Local only.** Your laptop sleeping stops the factory. Runs resume; they do not
  progress while it is asleep.
- **Comprehension debt.** Osmani's central warning applies directly: the gap between how
  much code exists and how much you still understand. Mill's only defence is that you
  read every PR. If you stop reading them, Mill becomes a dark factory and the debt
  accrues silently.

## Deferred

- **Branch/preview deploys** for human and machine validation. Researched separately in
  `docs/reference/branch-deploy-options.md`. The shape when it lands: Fly review apps plus a Neon
  database branch per PR, driven by a GitHub Actions workflow **in the target repo, not
  in Mill**. Mill's entire involvement is one field — read the deployment URL off the PR
  and pass it to a verify stage as `MILL_PREVIEW_URL`.
- **Browser verify stage.** Vorflux's `Verify` phase — QA agents drive a real browser and
  record proof — is the highest-value idea on their page, since both source articles
  agree verification is the bottleneck. `chrome-devtools-mcp` is already installed, so the
  cost is a stage plus a per-repo opt-in. Deferred because it is most valuable against a
  deployed preview, which is itself deferred; it would degrade to running the app locally
  in the worktree. Revisit immediately after v1.
- **Browser chat UI.** Session id and transcript path are already stored per stage, so a
  chat view could be added without redesign.
- **Nightly cron** for one-anti-pattern PRs. Osmani's concrete recommendation and a good
  daily smoke test of the whole pipeline. Cut from v1 for scope.
- **GitHub App identity.** Wanted only if Mill moves to a server, serves other people, or
  needs bot attribution. `Mill::Github` is the seam.

## Build order

Rough sequence for the implementation plan. Each step should be demonstrable on its own.

1. Schema, migrations, and the `Mill::Github` wrapper with fixture-backed tests.
2. `Mill::Claude`: spawn, tee stream-json, read verdict, capture session id and cost.
3. Runner over a two-stage toy graph, driven by scripted verdicts.
4. Supervisor: worktree lifecycle, concurrency cap, kill.
5. Poller: the five triggers, marker filter, node-id dedupe, cursors.
6. Safety hook and its test suite.
7. `mill-headless` skill and the real stage prompts, one stage at a time, starting with
   triage and the small route — the shortest path to an end-to-end PR.
8. Full route.
9. Roda UI: run list, run detail with log tail, kill, repo picker.
10. Blocking, questions, and resume.
11. Evidence deliverable.

## Sources

- [The Software Factory — alexop.dev](https://alexop.dev/posts/the-software-factory/)
- [Software Factories — Addy Osmani](https://addyosmani.com/blog/software-factories/)
- Claude Code quickstart v2.0 (local, `~/Downloads/Claude Code quickstart (3).md`)
- Vorflux landing page text — `tmp/vorflux-landing.md` (untracked scratch)
- Branch deploy options — `docs/reference/branch-deploy-options.md`
