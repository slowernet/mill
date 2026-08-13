# mill — a software factory

Design doc. 2026-08-06, revised three times — see [Revision history](#revision-history).

## Contents

- [What mill is](#what-mill-is)
  - [The pipeline, end to end](#the-pipeline-end-to-end)
  - [When there is no spec](#when-there-is-no-spec)
  - [Where the human is](#where-the-human-is)
- [Non-goals](#non-goals)
- [Principles](#principles)
- [Architecture](#architecture)
- [Ingress](#ingress)
  - [The board is the queue](#the-board-is-the-queue)
  - [The poller reconciles, it does not consume events](#the-poller-reconciles-it-does-not-consume-events)
  - [Triggers](#triggers)
  - [Who may trigger a run](#who-may-trigger-a-run)
  - [How mill avoids triggering itself](#how-mill-avoids-triggering-itself)
- [The stage graph](#the-stage-graph)
  - [Stages, models, and skills](#stages-models-and-skills)
  - [Finding the spec](#finding-the-spec)
  - [Stage prompts](#stage-prompts)
- [The stage contract](#the-stage-contract)
- [Containment](#containment)
- [How a run blocks, asks, and resumes](#how-a-run-blocks-asks-and-resumes)
- [Back-pressure](#back-pressure)
- [Deep review](#deep-review)
- [Evidence requirement](#evidence-requirement)
- [Setting up, and preparing a repo](#setting-up-and-preparing-a-repo)
- [Data model](#data-model)
- [Web UI](#web-ui)
- [Killing a run and tearing it down](#killing-a-run-and-tearing-it-down)
- [Sleep and wake](#sleep-and-wake)
- [Failure taxonomy](#failure-taxonomy)
- [Testing](#testing)
- [Why this shape](#why-this-shape)
- [Known limitations](#known-limitations)
- [Deferred](#deferred)
- [Build order](#build-order)
  - [Spike — the permission model](#spike--the-permission-model)
  - [Plan A — Seams and doctor](#plan-a--seams-and-doctor)
  - [Plan B — One run by hand — the keystone](#plan-b--one-run-by-hand--the-keystone)
  - [Plan C — Autonomy](#plan-c--autonomy)
  - [Plan D — Observe and interrupt](#plan-d--observe-and-interrupt)
  - [Plan E — Other routes](#plan-e--other-routes)
  - [Not yet planned](#not-yet-planned)
- [Revision history](#revision-history)
- [Sources](#sources)

## What mill is

mill is a Ruby/Roda application on your own machine that executes reviewed designs. You
decide *what* to build, in an interactive session where your judgment is worth the most.
mill does everything after that: planning, implementation, adversarial review at each step,
and a pull request for you to read.

### The pipeline, end to end

**1. You design, interactively.** A normal Claude Code session in your terminal —
`brainstorming`, argument, pushback, revision. It produces a spec committed to
`docs/superpowers/specs/` on a branch linked to the issue via `gh issue develop`. This part
is deliberately outside mill: designing needs taste and disagreement, and the skills that do
it well require a live human.

**2. You release it.** Set the issue's Status to `Ready` on mill's Project board. Setting it is
how you assert that you have reviewed the design — you don't release it until you're happy.

**3. mill claims it.** The poller reconciles the board, finds a `Ready` item with no active
run, adopts the linked branch, and reads the spec the branch introduced.

**4. mill runs the graph**, one `claude -p` process group per stage, each with a fixed model,
a named skill, and its own permission ruleset:

```
triage → plan → review:plan → implement → review:code → pr
```

Every stage writes a nonce-stamped verdict. When a reviewer raises a `high` or `critical`
objection, mill re-runs the stage it reviewed. When a stage fails twice, mill stops the line.

**5. mill opens a PR** — code, tests, the plan, and the spec in one diff — and sets Status to
`Done`.

**6. You read the PR.** This is the only human gate on the output, and mill never merges.

### When there is no spec

Not everything deserves a design session. Two other routes:

**Fast** — a crash, a lint violation, a dependency bump. There is nothing to design, only
something to find and fix, so `diagnose` uses `systematic-debugging` to establish root cause
before any code changes:

```
triage → diagnose → implement:fast → review:code → pr
```

**Iterate** — entry from an existing PR rather than an issue: a review comment, a comment, or
red CI. Works on the branch that already exists:

```
triage → implement:fast → review:code → push
```

An issue with no spec that isn't fast-shaped **blocks**, and the answer is usually "go have a
design session." mill declining to guess is a feature.

### Where the human is

| Stage of thought | Who |
|---|---|
| What to build, and why | You, interactively |
| Whether it's ready to build | You, by setting Status |
| How to build it, step by step | mill (`plan`) |
| Building it | mill (`implement`) |
| Whether it's correct | mill's adversarial reviewers, then CI |
| Whether to ship it | You, at the PR |

## Non-goals

- **mill does not design.** No `brainstorming` stage. mill executes decisions; it does not
  make them.
- **Not a chat UI.** Interactive work happens in your terminal.
- **Not a multi-source ingest.** GitHub only — no Slack, Linear, Jira, Figma, voice, video.
- **Not a deployment tool.** mill never deploys and never merges.
- **Not a team product.** Single operator, single machine.
- **Not a replacement for Superpowers.** mill sequences and gates the skills you already use.
- **Not safe against a hostile repository.** mill assumes every repo it touches, and that
  repo's `CLAUDE.md`, `.claude/`, and scripts, are yours.

## Principles

1. **GitHub holds the queue and the outcome. SQLite holds run state.** The board and the PR
   are the durable record. Run state — route, branch, worktree, stage, session id, attempt
   counts — exists only in SQLite and is *not* disposable.
2. **Silence is never success.** Every attempt must produce a verdict proving it ran: correct
   stage, correct attempt, correct nonce.
3. **The line can always stop.** Any stage may emit questions and block rather than guess.
4. **Fail closed.** An unrecognised tool call, an unmatched verdict, an unprepared repo, or an
   unreachable GitHub all halt. None proceeds on an assumption.
5. **Deterministic where it can be.** The graph, the model per stage, the attempt limits, and
   the permission rulesets are code and config, not agent discretion.
6. **Gates live outside mill where possible.** The token bounds which repos are reachable; the
   board bounds what work exists; branch protection bounds what can merge. A rule mill
   enforces on itself is the weakest kind.

## Architecture

Five components. Only two touch the outside world.

| Component | Responsibility | Knows about |
|---|---|---|
| `Mill::Poller` | Reconcile board state into runnable work | `Mill::Github` only |
| `Mill::Supervisor` | Claim work up to the cap, prepare repos, manage worktrees, reap process groups, hold the power assertion | the DB, git, the machine's power state |
| `Mill::Runner` | Walk the stage graph for one run | the graph, `Mill::Claude` |
| `Mill::Claude` | Build argv, spawn a process group, tee the log, accumulate cost, validate the verdict | Claude Code |
| `Mill::Github` | Every `gh` invocation, REST and GraphQL | GitHub |

`Mill::Github` is the single seam for **mill's own** GitHub access. It is not the only path:
the `pr` and `push` stages run `gh` inside the worktree with a deliberately narrow token. See
[Containment](#containment).

**Process shape.** One Puma process. The poller and supervisor are threads, and mill wraps each
in a supervising loop that logs the exception and restarts the thread with backoff;
`Thread.report_on_exception` stays at its default of true. Each writes a heartbeat, and `GET /`
reports an error when either goes stale.

**Stack.** Ruby, Roda, Sequel, SQLite, Puma, Minitest.

**Paths.**

```
~/.mill/mill.db                                  state
~/.mill/settings/<stage>.json                    permission rulesets, outside every worktree
~/.mill/secrets/                                 stage token, per-repo env files
~/.mill/worktrees/<repo>/<run-id>/               one worktree per run
~/.mill/runs/<run-id>/verdict-<stage>-<n>.json   verdicts, outside the repo
~/.mill/logs/<run-id>/<stage>-<n>.jsonl          raw stream-json per attempt
```

`~/.mill` is `0700`. Verdicts and settings live outside the worktree deliberately: both are
things the agent could otherwise rewrite.

Repo clones are *not* under `~/.mill`. mill uses the clone you already have.

## Ingress

mill runs locally, shells out to `gh`, and needs no GitHub App, webhook secret, or tunnel.

### The board is the queue

One user-level GitHub Project spans every repo. Both issues and PRs appear as items. Projects
v2 is GraphQL-only, so `Mill::Github` needs `gh api graphql`, and mill must resolve the project
id, each field id, and each option id when you set it up.

**Status** (single-select) is the queue:

| Status | Meaning |
|---|---|
| `Ready` | Released to the factory |
| `Running` | A run has claimed it |
| `Blocked` | Stopped for input; reply in a comment to resume |
| `Done` | PR opened |
| `Failed` | Terminal without a PR |

Two more single-selects carry directives. Projects v2 has no boolean field type, so each is a
single-select with one option — set or unset:

| Field | Option | Meaning |
|---|---|---|
| `Evidence` | `Required` | The PR must include a before/after sample of real output |
| `Review` | `Deep` | Replace one reviewer with a faceted fan-out, then refute every finding |

Everything mill reads lives on the board. **mill uses no labels**, so it never has to write to
a repo to prepare it.

**mill is the sole writer of Status**, so you must disable the board's built-in workflows —
Projects v2 automation writes Status too. "Item closed → Done" would flip Status out from under
a `Running` run, leaving the poller blind to a live subprocess; "Auto-add to project" would
sweep every new issue onto the board. `mill:doctor` asserts they are off.

Field values belong to the project, not the issue, so an item's Status here is independent of
its status on any other board, and no other project's automation can reach it.

### The poller reconciles, it does not consume events

Every tick the poller asks: **which items are `Ready` with no active run?** The question is
idempotent, needs no dedupe key, and heals itself when mill crashes mid-transition. The earlier
label-based design consumed label-change *events*, and four separate bugs came from that shape:
the poller permanently deduped a relabelled issue, an item could carry `Ready` and `Running` at
once, nothing cleared `Running` when you killed a run, and no label change moved an item to a
terminal state. A single-select cannot express any of them.

Comments genuinely are events, so the `events` table survives for those. The poller advances a
repo's cursor **only after it has inserted a fully paginated sweep, in the same transaction as
those inserts**. If a fetch stops partway, the poller writes no cursor.

### Triggers

| Trigger | Effect | Source |
|---|---|---|
| Item `Ready`, no active run | Start a run | the poller, reconciling the board |
| Comment on a `Blocked` item | Resume the blocked run | comment poll |
| Comment on a mill PR | Iterate on the branch | comment poll |
| PR review comment | Address the feedback | review-comment poll |
| Required checks red on a mill PR | Fix the failure | check poll on open mill PRs |

**PRs are board items too**, which is what gives PR-entry work a run identity — a Dependabot
PR has no issue, so questions need somewhere to go. `runs` carries `subject_kind`
(`issue` or `pr`) and `subject_number`, and blocking questions go to the subject.

Check state is read as current state off open mill PRs, not consumed as a stream, so it needs
no cursor. Branch protection on the base branch configures the required status checks; the
runbook sets them up and `mill:doctor` verifies them.

### Who may trigger a run

**Every comment-derived trigger requires `author_association` in `OWNER`, `MEMBER`, or
`COLLABORATOR`.** mill ignores and logs anything else. Three of five triggers are comments, and
comment text becomes prompt text; without this rule, a stranger commenting on a public repo
drives a subprocess holding your credentials.

**mill acts only on PRs whose head ref is in the same repository** — never a fork head.
Dependabot satisfies this. Trusted non-mill authors are an explicit `.mill.yml` allowlist
defaulting to `dependabot[bot]`. Checking out a fork head means executing a stranger's
`CLAUDE.md`, `.claude/`, and `bin/`.

### How mill avoids triggering itself

Every comment mill writes carries `<!-- mill:v1 -->` as the **first line**, and the poller
ignores a comment only when the marker appears at the start of a line that is not
blockquote-prefixed. mill also remembers the ids of comments it posted.

Searching the whole body for the marker fails: GitHub's quote-reply copies the source markdown
including HTML comments, so when you answer a blocked run the obvious way your reply carries
the marker, and the poller silently discards the only channel in the design that reaches a
human.

Stages cannot comment at all — mill denies `gh issue comment`, `gh pr comment`, and `gh api`.
Only `Mill::Github` comments, and it always stamps the marker.

## The stage graph

The graph is data. Each stage declares its name, prompt template, model, skill, expected
artifact pattern, and permission ruleset.

| Route | Entry condition | Stages |
|---|---|---|
| `plan` | Issue with a linked branch introducing a spec | `triage → plan → review:plan → implement → review:code → pr` |
| `fast` | Issue with no spec, triaged as hotfix-shaped | `triage → diagnose → implement:fast → review:code → pr` |
| `iterate` | Any PR trigger | `triage → implement:fast → review:code → push` |

An issue with no spec that triage does not judge fast-shaped blocks with questions.

**Triage defaults to blocking.** It is the only stage with no reviewer, running the cheapest
model, and its decision determines whether the pipeline runs at all. The prompt tells triage to
route to `fast` only when the issue is unambiguously a crash, a lint violation, or a dependency
bump — one narrow category with no judgment call. Anything uncertain blocks. This is mill's
general principle ("the line can always stop") made explicit for the one stage where a wrong
answer has the largest blast radius.

Routes are keyed on **what the ticket already contains**, not on how large the change looks.
Size is only a proxy; what determines whether an agent can execute reliably is whether it
knows what to do.

### Stages, models, and skills

| Stage | Model | Skill invoked | Produces |
|---|---|---|---|
| `triage` | Sonnet | none | route, evidence flag, actionability |
| `plan` | Opus | `superpowers:writing-plans` | `docs/superpowers/plans/<date>-<slug>.md` |
| `review:plan` | Opus | `adversarial-reviewer` | objections |
| `diagnose` | Opus | `superpowers:systematic-debugging` | root cause, recorded in the PR body |
| `implement` | Opus | `superpowers:executing-plans` | code + tests |
| `implement:fast` | Opus | `superpowers:test-driven-development` | code + tests |
| `review:code` | Opus | `adversarial-reviewer` | objections |
| `pr` | Opus | `superpowers:finishing-a-development-branch` | pull request |
| `push` | Opus | none | pushed commits on an existing PR |

Sonnet for cheap mechanical passes, Opus for judgment and code. No user-facing toggle; you
change the map by editing config.

`implement` and `implement:fast` differ by whether a plan exists — `executing-plans` requires
one, `test-driven-development` does not. That distinction now tracks the real difference
rather than a guess about change size.

mill passes every stage its predecessors' verdicts and artifact paths. It passes a reviewer the
artifact under review plus the diff to date, and passes `review:code` the plan as well, so that
reviewer can check the code against what the plan promised.

### Finding the spec

No path is pasted anywhere. The issue refers to a **branch**, natively:

1. Your design session runs `gh issue develop <n>`, which links a branch to the issue and
   shows it in the issue's Development section.
2. mill reads `linkedBranches` on the issue and adopts that branch — it does not create one.
3. The spec is the file that branch adds under `docs/superpowers/specs/`, found with
   `git diff --name-only <base>...<branch> -- docs/superpowers/specs/`.

Exactly one file is the spec. If the branch adds none, mill routes to `fast` or blocks; if it
adds more than one, mill blocks.

You type no path, so nothing can be mistyped or go stale under a rename, and mill finds the
spec deterministically instead of asking an LLM to read prose for a link. `writing-plans` keeps
its own filename convention because mill never looks at filenames, only at which file a branch
introduced. The artifact and the work end up on one branch, so the eventual PR shows the spec,
the plan, and the code together.

`iterate` adopts an existing branch by the same code path.

### Stage prompts

mill owns a thin prompt per stage that invokes its skill explicitly by name, so Claude Code
never has to guess which skill to load — the quickstart warns about that guessing. mill also
ships `mill-headless`, loaded by every stage, which redefines the one interactive gate the
remaining skills assume: where a skill would ask you and wait, it writes the questions into the
verdict and stops.

That job is much smaller than it was. `brainstorming`'s per-section approval gates were the
hardest thing to simulate headlessly, and moving design upstream deletes the need entirely.
`writing-plans`' single gate — "any questions or critique of the design?" — maps onto
block-and-ask directly.

The stage prompt owns the verdict envelope; `mill-headless` owns what goes in `questions`.

## The stage contract

Every attempt is one `claude -p` subprocess in its own process group, writing a verdict to a
path mill passes in. Attempt 1 of a stage is always a fresh session. Attempt 2 — whether
triggered by a failure, a crash, or a reviewer's objection — resumes the session from attempt 1
with `claude --resume <session-id>`, so the agent remembers its own work. The one exception is a
verdict that failed validation: mill has no trustworthy account of what happened, so it starts a
fresh session. If `--resume` fails for any reason, mill falls back to a fresh session with the
prior context appended, and that fallback is what consumes the attempt.

The verdict path:

```
~/.mill/runs/<run-id>/verdict-<stage>-<attempt>.json
```

```json
{
  "stage": "plan",
  "attempt": 1,
  "nonce": "8f3c1a…",
  "status": "ok" | "blocked" | "failed",
  "artifact": "docs/superpowers/plans/2026-08-06-foo.md",
  "route": "plan" | "fast" | null,
  "evidence_required": true,
  "questions": ["Should deleted users keep their comments?"],
  "objections": [{ "severity": "critical|high|medium|low", "claim": "…", "notes": "…" }],
  "summary": "one paragraph for the log and the PR body"
}
```

mill validates before accepting:

- The file must exist, and `stage`, `attempt`, and `nonce` must match this spawn. mill unlinks
  it first and generates a fresh nonce each time.
- `artifact`, if present, must resolve inside the worktree, must not traverse a symlink, must
  match the stage's declared pattern, and must exist and be non-empty.
- `questions` must be non-empty iff `status` is `blocked`.
- `objections[].notes` is the reviewer's full argument — file paths, line numbers, reasoning.
  `claim` stays short for mill's own decision logic; `notes` is what the coding agent and you
  both read. mill posts each objection's notes as a PR comment through `Mill::Github` once the
  PR exists.
- mill accepts `route` and `evidence_required` only from `triage`.

mill fails the attempt on any violation.

The first draft used one fixed path, reused by every stage and never cleared. Two independent
reviewers found the consequence: when a stage died without writing, mill read its predecessor's
`{"status":"ok"}` and passed it, so a crashed adversarial reviewer looked as though it had
approved the code. The nonce makes a stale or replayed verdict unrepresentable, and keeping the
file out of the repo means no stage can commit it and no later checkout can restore it.

`pr_number` is deliberately not in the verdict. mill recovers it with
`gh pr list --head <branch>`, which is idempotent, so a crash between `gh pr create` and the
state write reconciles instead of opening a second PR.

Stages run with `--output-format stream-json`. `Mill::Claude` accumulates `tokens_in` and
`tokens_out` from per-message `usage` as it tees, persisting a running total so a killed
attempt retains its partial count. mill tracks tokens across every part of the graph — per
attempt, per stage, and per run — so it can present historical averages and, eventually,
cost estimates for per-token billing.

## Containment

mill **does not** use `--dangerously-skip-permissions`. That flag is
`--permission-mode bypassPermissions`, and since working directories and `--add-dir` are
permission-system concepts, skipping permissions leaves no filesystem confinement for Read,
Write, or Edit at all. Autonomy comes from an explicit ruleset instead, in four layers.

**1. An allow/deny ruleset per stage, from outside the worktree.** Each stage runs with
`--settings ~/.mill/settings/<stage>.json` listing the tools and Bash commands that stage
needs. Claude Code denies anything unmatched rather than prompting, which in headless mode
means it tells the agent no; the agent adapts or blocks. Fail-closed; a denylist is fail-open.

Every stage denies the same things: writes to `.claude/**`, `.mill.yml`,
`.github/workflows/**`, and `.github/actions/**`; reads of `~/.ssh/**`, `~/.aws/**`,
`~/.config/gh/**`, and `**/.env*`; and every `gh` subcommand except the narrow set `pr` and
`push` require.

The settings file lives outside the worktree because `bypassPermissions` permits writes to
`.claude/` and the settings watcher picks them up — so an agent could disarm its own
restrictions *mid-session*.

mill denies `.github/workflows/**` because when a stage pushes a branch that modifies a
workflow, GitHub runs the modified workflow with repository secrets in scope. If a stage
legitimately needs to change CI, it blocks and asks.

**2. The Bash sandbox, enabled.** `sandbox.enabled` with `filesystem.denyRead` on `~` and
`allowRead` on the worktree. Defence in depth, not the boundary: it covers Bash and not the
file tools, and fails open if it cannot start.

**3. A scoped GitHub token.** mill sets `GH_TOKEN` for each stage to a fine-grained PAT
covering only selected repositories, with Contents and Pull requests read/write and nothing
else, and scrubs your `gh` keyring config from the stage environment. mill does its own board
and comment work in-process under your login, where the agent cannot reach it.

**This token is also the repo allowlist** — if it does not cover a repo, no bug in mill can
push there.

**4. A `PreToolUse` hook**, written from outside the worktree, blocking pushes to the base
branch, `commit --amend`, `reset --hard`, `gh pr merge`, and `rm -rf` above the worktree root.

**The hook is explicitly not a security boundary.** It guards against model error. A command
denylist falls to one level of indirection — `bash -c`, or a committed `bin/setup` containing
the forbidden command — and a suite of "commands that must be refused" measures only the
bypasses its author imagined. Layers 1–3 are the boundary.

**mill never merges.** Nothing in the codebase calls `gh pr merge`.

**Accepted risks:**

- **Network access inside a stage is unrestricted.**
- **Layer 1 is only as good as its rules**, and `implement` legitimately needs a wide one.
- **mill is not safe against a hostile repository.**

## How a run blocks, asks, and resumes

A stage that cannot proceed emits questions; mill posts them to the subject with the marker,
sets Status to `Blocked`, and halts. You reply in a comment, and that comment triggers the
resume.

mill resumes with `claude --resume <session-id>` and injects your answers. This is the same
resume mechanism used for attempt 2 after a failure or a reviewer objection — the only
difference is what gets injected. Verified: `--resume` returns the *same* session id (a new one
requires `--fork-session`), and a transcript whose last record is a `tool_use` with no matching
`tool_result` — the state a SIGKILL produces — resumes successfully, because the CLI repairs
the dangling call. If `--resume` fails for any reason, mill re-runs the stage from scratch with
the full context appended, and that re-run consumes an attempt.

A run that blocks because a stage **ran out of attempts** differs from one that blocks on a
question: when you answer, mill resets that stage's counter to zero, once, and records on the
run that it did. If the same stage runs out again, mill sets Status to `Failed` and stops. This
is the one sanctioned path to a third attempt, and it requires a human.

## Back-pressure

**Two attempts per stage, then block.** When a stage fails, crashes, times out, or a reviewer
rejects it, mill resumes the session from attempt 1 with the failure or the reviewer's notes
injected. The agent wakes up remembering its own work and reads what went wrong. If the resumed
attempt fails too, mill posts both attempts and blocks. The one exception: when the verdict
itself was untrustworthy (failed validation), mill starts a fresh session instead of resuming,
because there is no reliable account of what the first attempt did.

**What counts as rejection.** A reviewer returns `status: ok` with `objections`; it does not
fail. mill re-runs the reviewed stage iff any objection is `high` or `critical`, and records
lower severities in the PR body. Without a rule this explicit, one implementer rejects on any
objection — and since the reviewer skill assumes defects exist, nearly every run blocks — while
another treats objections as advisory and gates nothing.

**Whose counter goes up.** A successful review that produces objections costs no attempt to
anyone — the reviewer did its job. It triggers a re-run of the reviewed stage, and that re-run
uses the reviewed stage's counter. Two rejections of `implement` means `implement` has used both
its attempts (the original and the fix-after-review), and mill blocks. The reviewer has its own
separate counter for its own failures — a crash, a timeout, or a verdict mill could not
validate. Those are the reviewer failing to review, not the reviewer finding something wrong.

**Limits, config, with these defaults:**

| Limit | Default |
|---|---|
| Concurrent runs | 3 |
| Wall clock per attempt | 30 min of awake time |
| Silence before mill calls a stage wedged | 5 min of awake time |
| Stall recoveries per attempt | 2 |
| Settle window after a wake | 90 s of awake time |
| Runs per subject per 24h | 6 |

The per-attempt clock uses `Process::CLOCK_UPTIME_RAW`, which does not advance during sleep.
`CLOCK_MONOTONIC` and wall clock both count sleep on Darwin, so closing the lid mid-stage
would otherwise reap a healthy attempt as a timeout and charge it a strike — twice, on the
only deployment target mill supports. [Sleep and wake](#sleep-and-wake) extends that reasoning
to every other deadline mill keeps.

**There is no global daily ceiling, deliberately.** The board bounds what work exists, and mill
never adds items to it — you do. A global cap would only duplicate the board.

When a run exceeds the time cap or the daily-run limit, mill kills it and blocks it. Token
counts are telemetry, not a ceiling — mill records them per attempt and surfaces them in the
UI and the PR body, but does not kill a run for using too many tokens. Dollar-denominated spend
caps are deferred until mill supports per-token billing; the token history will power them.

## Deep review

When you set the board's `Review` field to `Deep`, mill replaces a single reviewer stage with a
fan-out. You opt in per item, because it runs roughly six Opus invocations per review stage.

1. **One agent picks the facets.** It reads the artifact and chooses 2–4 review facets suited
   to *this* artifact, with a rationale. It chooses them rather than reading them from config,
   because which facets matter is a property of the document, not the repo.
2. **One finder per facet.** Each gets the artifact and its own facet, sees nothing its
   siblings found, and is told the author is unavailable, so an unstated assumption counts as
   a defect.
3. **A separate agent deduplicates.** The Runner invokes it because it needs every finding at
   once and the Runner is deterministic Ruby that cannot judge similarity itself. This agent is
   not a full stage — it has no nonce and no attempt counter — but mill records its session id
   and tracks its tokens on the run, so it shows up in the UI and PR body alongside the finders
   and refuters.
4. **A fresh agent tries to refute each finding.** It gets the claim and the artifact but
   **not** the sibling findings, and mill tells it to refute, and to call a finding refuted
   when it cannot decide. On `review:code` it must refute empirically: a finding survives only
   if the refuter can write a failing test that reproduces it. Each refuter's tokens are tracked
   individually.
5. **mill writes the verdict.** Only the findings that survive become objections, and the
   ordinary high-or-critical rule decides whether the reviewed stage re-runs.

Every agent in the fan-out — the facet selector, each finder, the deduplicator, and each
refuter — has its tokens recorded on the run. The UI shows a per-agent breakdown so you can see
where deep review spends its budget and how that changes over time.

**Invariant: no agent may appear in the review path for an artifact it produced.** An author
never refutes its own work, and no refuter sees what its siblings found — authoring creates a
stake, and sibling findings anchor. mill gets this structurally, because a stage's session is
gone by the time anything reviews its artifact.

Refuting is not decoration. Reviewing this document, it killed 26 of 62 claims; a stage that
reported all 62 would have taught you to ignore reviews. It also supplies the rule the ordinary
path uses to decide when a reviewer rejects.

Known weakness: an LLM deduplicates, and that is the step most likely to go badly. Refuting
code empirically is immune to the deeper problem — a refuter agreeing with a finder for the
same wrong reason — because a test either fails or it does not.

## Evidence requirement

When you set the board's `Evidence` field to `Required`, mill adds one deliverable: a
before/after sample of real output in `docs/superpowers/samples/<date>-<slug>.md`, with a
summary table inlined in the PR body. It changes no route and adds no stage. mill builds the
work to production standard either way, so if you merge on the strength of a sample, you are
merging production-ready code.

- **Show the items, do not summarize them.** "Surfaces more diverse content" cannot be judged;
  a table of the actual fifty things it picked can.
- **Before and after, same inputs through both paths.**
- **A deterministic slice the agent did not choose**, plus the cases that moved most in *both*
  directions, with commit sha, seed, and exact command recorded.

**The sample must come from a committed fixture, never a live database**, and mill refuses
`Evidence` on a public repo unless `.mill.yml` sets `evidence_public: true`. The `pr` stage
publishes without asking, so a sample drawn from production would be public before you saw it —
and for ranking or curation work "the actual fifty things" are user records.

This rule is currently enforced only by the stage prompt — the agent is told not to use live
data. `review:code` adds a legibility check ("could someone judge this from what is in the
PR?"), which would catch some violations. Stronger enforcement is deferred until the evidence
deliverable is built, when real samples will show what a check needs to look for.

`review:code` gains a legibility check on these runs: could someone judge this from what is in
the PR?

You decide whether to merge, and the reviewers do not gate that. They confirm the code is
production-ready; the sample lets you decide whether the idea is any good.

## Setting up, and preparing a repo

**One-time, and you run it:** `docs/reference/setup.md`. Two steps resist automation — GitHub
offers no API for minting a fine-grained PAT, and no script should silently choose which repos
a token may touch. The runbook covers `project` scope, creating the board and its
three fields, disabling the board's built-in workflows, minting the stage token, branch
protection with required status checks, and per-repo secrets files.

**There is no repo watchlist and no picker.** The board yields items from any repo, so mill has
no per-repo polling loop to bound, and consenting per item is stronger than consenting per repo
— an item enters mill only because you put it on the board. GitHub already enforces the repo
allowlist: the token covers selected repositories only.

**mill prepares a repo lazily.** When an item arrives from a repo mill has not prepared, the
supervisor prepares it on first touch:

1. **Resolve the clone.** Scan `~/code` for a repo whose `origin` matches. If the match is
   ambiguous or missing, mill says so rather than guessing.
2. **Set `gc.auto=0` and `maintenance.auto=0`** so a stage's commit cannot trigger a gc that
   rewrites shared refs while other runs hold them.
3. **Read `.mill.yml`** from the base branch into `repos.config_json`: base branch, test
   command, gating CI workflow, trusted PR authors, `evidence_public`, secret variable names.
4. **Verify** the token covers the repo and `~/.mill/secrets/<owner>-<repo>.env` exists.

If anything is missing, mill blocks **that item** and comments naming exactly what. mill writes
nothing to the repo — it uses no labels — so it only reads, apart from setting local git
config.

mill reads `.mill.yml` only from the base branch, never from the worktree HEAD, and pins the
resolved config onto the run. An agent can edit `.mill.yml` in its worktree; that edit must not
weaken the next run.

**mill injects secrets.** A fresh worktree holds tracked files only, so `.env` and
`config/master.key` are missing, and a suite that needs them would fail identically on both
attempts — so the pipeline could never finish on an ordinary Rails or Node repo. mill reads
`~/.mill/secrets/<owner>-<repo>.env` into the stage environment as variables, never writes them
into the worktree, and keeps those values out of the tee'd log.

**`rake mill:doctor`** verifies every precondition and names what is missing: `gh` auth and
`project` scope; the board's three fields and their options; that you disabled the built-in
workflows; the stage token's permissions, expiry, and file mode; `~/.mill` modes; the permission
rulesets' deny rules; and, for every repo the board currently references, that it can resolve
the clone, that `gc.auto` is set, that `.mill.yml` parses, that branch protection requires
checks, and that the named secret variables exist. Most of what it checks is critical to
containment, so a red doctor blocks everything.

**Off switch:** remove items from the board, or drop the repo from the token's repository list.

## Data model

```
repos          id, owner, name, local_path, base_branch, ci_workflow,
               config_json, prepared_at, comments_cursor,
               review_comments_cursor

runs           id, repo_id, subject_kind, subject_number, route,
               evidence_required, deep_review, branch, spec_path,
               worktree_path, status, current_stage, pgid, heartbeat_at,
               counter_reset_stage, pr_number, created_at, finished_at
               -- unique index on (repo_id, subject_kind, subject_number)
               --   where status in ('queued','running','blocked')

stage_attempts id, run_id, stage, attempt, model, session_id, nonce,
               status, verdict_json, tokens_in, tokens_out,
               log_path, pid, pgid, last_output_at, stall_recoveries,
               started_at, finished_at

events         id, repo_id, kind, gh_node_id (unique), payload_json,
               attempts, last_error, state, created_at, processed_at
```

Run statuses: `queued`, `running`, `blocked`, `done`, `failed`, `killed`.

`repos` is a cache of prepared state, not a watchlist — no `enabled` column, because nothing is
enabled or disabled.

mill inserts a run as `running` in the same transaction that claims the item, and the cap counts
`queued` and `running` together, so it cannot drift.

`blocked` is inside the uniqueness index: a blocked run must keep guarding its subject because
resume is comment-triggered. SQLite supports the partial unique index this needs.

`events` carries `attempts`, `last_error`, and a terminal `dead` state with a cap, and mill sets
`processed_at` in the same transaction that inserts the resulting run — otherwise an exception
raised after mill marks a comment processed drops your answer with no trace.

mill persists `pgid` and `pid` so it can still kill a stage after a restart, and verifies pgid
plus start time before it signals — never a bare pid, which the OS can recycle.

The runner writes `heartbeat_at`; at boot and on a timer, mill checks every run marked
`running`. Three branches:

- **Process group gone** (machine rebooted, or the stage exited while mill was down): mark the
  attempt interrupted and re-enter the stage. The session id is still in the database, so
  attempt 2 can resume it.
- **Process group alive but no runner thread owns it** (mill restarted, stage kept going): kill
  the group first, then mark interrupted and re-enter. Two agents in the same worktree is
  worse than losing partial work.
- **Process group alive and a runner thread owns it**: leave it alone — this is normal
  operation.

Heartbeat staleness is measured in awake time. Measuring it in wall time would fail every
healthy run after a night with the lid shut.

`Mill::Claude` writes `last_output_at` as it tees, and `stall_recoveries` counts how often mill
has already rescued that attempt from a dead socket. See [Sleep and wake](#sleep-and-wake).

**Retention.** mill deletes logs and verdicts for finished runs (`done`, `failed`, `killed`)
older than 14 days, and caps each attempt's log by byte count with a truncation marker. Blocked
runs are exempt — their worktrees, logs, and verdicts stay until you answer or kill the run.
`GET /` shows total disk used, and the worktree view (below) lets you clean up manually.

## Web UI

Roda and Sequel. mill binds `tcp://127.0.0.1:9494` explicitly — Puma defaults to `0.0.0.0`,
which would expose log tails and the kill switch to the local network. mill rejects any request
whose `Host` is not `localhost:9494` or `127.0.0.1:9494`, which defeats DNS rebinding. Every
POST requires a CSRF token via Roda's `route_csrf`, because the browser treats a cross-origin
form POST as a CORS simple request and does not preflight it.

```
GET  /                 run list: subject, route, stage, status, tokens, disk, health
GET  /runs/:id         stage timeline, per-stage token breakdown, artifacts, verdicts, log tail
GET  /runs/:id/log     JSON tail, offset-paginated
POST /runs/:id/kill    kill the process group, mark killed, set Status
POST /pause            stop claiming new work; running stages continue
POST /resume           claim again
GET  /repos            read-only diagnostics: prepared state, resolved clones, prerequisites
GET  /worktrees        list all worktrees: run, branch, status, disk used
POST /worktrees/:id/delete  remove a worktree manually
```

Killing, pausing, and worktree deletion are the write paths. Pausing exists because mill cannot
see you
about to shut the lid. Everything else actionable — releasing work, answering questions, setting
directives, reviewing the PR — happens in GitHub. mill shows what GitHub cannot: what an agent
is doing now, how many tokens it has used, and whether the factory is alive.

The run detail page shows tokens in and out for every attempt, broken down by stage. When deep
review runs, the breakdown includes each agent individually — every finder, the deduplicator,
and every refuter — so you can see where the tokens go. The run list shows the total per run.
Over time these numbers establish what each stage normally uses, so an unusual run stands out,
and when mill adds per-token billing the history is already there.

Front-end conventions — the layout contract, design tokens, the component catalog, and how the
log tail polls — are in `docs/reference/admin-ui-frontend.md`.

## Killing a run and tearing it down

mill spawns stages with `pgroup: true`. To kill one it sends `SIGTERM` to the group, `SIGKILL`
after a grace period, then confirms no descendant survives before it reuses or removes the
worktree. If mill killed the `claude` pid alone, test runners, package managers, and dev
servers would keep holding the worktree and its ports, and would fail the next attempt for
reasons the log does not show.

When mill kills a run, it sets Status to `Failed` and comments why.

**Stale git locks.** Before every attempt and at boot, mill removes age-checked stale `*.lock`
files under the gitdir for its own worktrees and `refs/heads/mill/*`. A SIGKILL during
`git commit` leaves an index or ref lock that git never cleans, so attempt 2 would fail
instantly on the lock and burn the second strike for a reason unrelated to the work.

**Branch and worktree collisions.** mill names the branches it creates
`mill/<subject>-<run-id>`, so two runs on one subject cannot collide. Adopted branches keep
their existing names. Before it claims an item, the supervisor checks whether any active run
(running or blocked) already has that branch checked out. If one does, the supervisor skips the
item this tick and tries again later — the existing run either finishes and frees the branch, or
gets reaped. Without this check, an `iterate` run triggered by a PR comment would collide with a
blocked `plan` run that holds the same branch, and `git worktree add` would refuse with a
confusing error. The supervisor also prunes stale worktree administrative entries before
claiming — `git worktree add` refuses a branch whose admin entry survives even after you delete
its directory.

One in-process mutex serializes `git worktree add` and ref writes across runners, and retries
with backoff when it hits lock contention.

**mill tears a run down** when the run reaches `done` and the PR is open, and when it reaches
`failed` or `killed` once mill has kept a compressed diff, the verdicts, and the logs. A
`blocked` run keeps its worktree indefinitely — mill needs it to resume, and a timer should not
destroy the thing you need to answer a question. If you never answer, you kill the run manually,
and then the reaper picks it up.

## Sleep and wake

macOS sleep kills nothing. It freezes every process and restores it on wake — idle sleep, a
closed lid, and standby alike — so a `claude -p` subprocess comes back exactly where it was.
Nothing needs saving across a sleep, and mill gets no warning before one, because a pre-sleep
callback needs IOKit, which is a native dependency for a single notification.

Two things break instead: every socket that was open, and every deadline mill measures in wall
time.

**Measuring the gap.** On Darwin `CLOCK_MONOTONIC` counts time spent asleep and
`CLOCK_UPTIME_RAW` does not, so the difference between their deltas across a tick is exactly how
long the machine slept, with no NTP drift mixed in. Both come from `Process.clock_gettime`, so
this costs nothing beyond the clock the per-attempt timeout already reads.

Which clock a deadline reads is a correctness question:

| Deadline | Clock |
|---|---|
| Wall clock per attempt | awake |
| Heartbeat staleness | awake |
| Silence before mill calls a stage wedged | awake |
| Settle window after a wake | awake |
| Retention of finished runs (14 days) | wall |

Retention measures how long something has sat, so counting sleep is right. Every other deadline
measures how long a stage worked, so counting sleep is a bug — and the expensive one is
heartbeat staleness, which would fail every healthy run after a night with the lid shut.

**The stall detector.** The case that matters is a stage mid-stream when the lid closes. On wake
it holds a half-open socket, and a blocked read on one can hang far longer than the attempt is
worth: macOS does not send its first TCP keepalive probe for about two hours. The stage does not
crash. It sits there until the per-attempt clock reaps it as a timeout and charges it a strike.

`Mill::Claude` already tees stream-json, so it knows when each live attempt last emitted a line.
mill persists that as `last_output_at`, and when an attempt has emitted nothing for the stall
window, mill kills the process group and resumes the session with `--resume`. **That recovery
does not consume an attempt**, for the reason a stale git lock does not: the work did not fail,
the machine did. mill counts recoveries per attempt in `stall_recoveries` and blocks once an
attempt hits the cap, so a genuinely silent stage cannot recover forever.

Watching for silence rather than watching for sleep means mill needs no special case for waking
at all. It also catches every other way a stage wedges — a Wi-Fi change, a package manager
waiting on a prompt `mill-headless` never saw, a stalled API stream — which the per-attempt
clock can only catch at minute 30.

**The settle window.** When the clocks show that mill slept, the supervisor stops claiming, the
poller waits out the settle window, and mill probes GitHub once before either resumes. Wi-Fi
takes seconds to associate after a wake and the resolver may be stale, so the first tick would
otherwise hit a network that is not up — and the failure taxonomy reads that as an auth failure
or a 404, which would mark a repo unhealthy every time you open the lid. Inside the window mill
treats a refused connection, a DNS failure, and a timeout as transient, logs them, and leaves
repo health alone; only a 401 or a 404 after the probe succeeds marks anything unhealthy.

mill also holds off heartbeat reaping until the window closes, because the runner threads wake
in no particular order and one may not have written a heartbeat yet.

**Not sleeping in the first place.** While a stage is running on AC power, the supervisor holds
a `caffeinate` power assertion, which prevents idle sleep — the common case, where you start
work and walk away. It does not prevent a closed lid, so it complements the stall detector
rather than replacing it. mill does not hold it on battery, because draining a battery to finish
a review stage is not a trade mill should make for you. The supervisor holds the assertion,
alongside the git commands it already runs.

**Pausing on purpose.** mill cannot see a lid close coming, but you can. `POST /pause` stops the
supervisor claiming new work and leaves running stages alone; `POST /resume` undoes it. Pausing
before you shut the lid means mill has nothing in flight to recover.

## Failure taxonomy

Every row resolves to `blocked` or `failed`. None resolves to silent success.

| Failure | What mill does |
|---|---|
| Stage returns `blocked` | Posts the questions to the subject, sets Status `Blocked`, stops, and resumes when you reply |
| Stage returns `failed`, crashes, or exits non-zero | Resumes the session with the failure injected; if the resumed attempt also fails, posts both and blocks |
| Verdict missing, malformed, or envelope mismatch | Fails the attempt; attempt 2 starts a fresh session because mill cannot trust the old one |
| Artifact missing, empty, outside the worktree, or off-pattern | Fails the attempt |
| Reviewer returns a `high` or `critical` objection | Resumes the reviewed stage's session with the reviewer's notes injected; blocks if that happens twice. Posts the notes as a PR comment once the PR exists |
| Issue has no linked branch, or the branch adds no spec | Routes to `fast` if triage judges it hotfix-shaped, otherwise blocks |
| Linked branch adds more than one spec file | Blocks and asks which one is the spec |
| Attempt exceeds 30 min awake time | Kills the group and fails the attempt; the two-strike rule applies |
| Run exceeds the daily-run limit | Blocks and reports token usage to date |
| Repo unprepared or a prerequisite missing | Blocks that item, naming what is missing |
| Required checks red on a mill PR | Starts a new attempt on the same branch, twice at most, then blocks |
| mill restarts mid-stage, process group alive | Kills the orphaned group, marks the attempt interrupted, re-enters without burning a strike; blocks after 3 interruptions on one stage |
| mill restarts mid-stage, process group gone | Marks the attempt interrupted, re-enters without burning a strike; same cap |
| Machine sleeps mid-stage | Measures the gap, opens a settle window, and holds off heartbeat reaping until it closes |
| Stage emits nothing for the stall window | Kills the group and resumes the session; costs no strike, capped per attempt |
| Network unreachable inside the settle window | Treats it as transient and logs it, leaving repo health alone |
| Stale git lock in the worktree or on a `mill/*` ref | Removes it before the attempt; it costs no strike |
| Descendants survive a kill | Reaps them before it reuses the worktree |
| Another active run already holds the branch | Skips the item this tick and retries later |
| Branch or worktree admin entry already exists | Prunes it before claiming; blocks if it cannot |
| Worktree missing or conflicted | Aborts, blocks, and keeps the diff |
| Run heartbeat stale in awake time and process group gone | Fails the run |
| Comment from a non-collaborator | Ignores it and logs it |
| Handling a comment event raises | Increments `events.attempts` and retries, marking it `dead` after the cap |
| Poller hits an auth failure or a 404 | Marks the repo unhealthy and surfaces it, distinct from rate limiting |
| GitHub rate-limits `gh` | Backs off to a ceiling and leaves the cursor alone, so it loses nothing |
| Poller or supervisor thread raises | Logs it, restarts the thread with backoff, and surfaces its health |
| Two runs on one subject | The unique partial index refuses the second |
| Disk full | The supervisor stops claiming and surfaces it |

## Testing

`Mill::Claude` and `Mill::Github` are the only components touching the outside world, and both
get fakes backed by recorded fixtures. Everything above them tests with no network and no
tokens.

- **Poller** — a pure function of (board state, cursors, comments) → work. Table tests for the
  collaborator rule, the marker-at-line-start rule against real quote-reply bodies, mill
  refusing a fork head, and cursor monotonicity.
- **Runner** — walks the graph against scripted verdicts: the two-strike rule, how it validates
  an envelope and an artifact, when it treats a review as a rejection, how it picks a route, how
  it finds the spec, and the one sanctioned counter reset.
- **Supervisor** — worktree lifecycle against a scratch repo, preparing a repo on first touch,
  the concurrency cap, killing a process group whose child deliberately orphans itself, and
  removing stale locks.
- **Sleep and wake** — the clock pair is injectable, so a test simulates a night's sleep by
  advancing the continuous clock without advancing the awake clock. Assert that the settle
  window opens, that heartbeat reaping stays suppressed while it is open, and that an attempt
  emitting nothing gets killed and resumed without consuming an attempt.
- **Permission ruleset** — the layer-1 boundary. Assert that a real `claude -p`, running with
  the stage's settings file, actually refuses to read `~/.ssh`, to write `.claude/`, and to
  call `gh api`. The only suite that must run against the real CLI, because it is the only one
  asserting a boundary rather than logic.
- **End to end** — one full run against a scratch repo, by hand, not in CI.

**Two rake targets, because one cannot run in CI.**

| Target | Contents | Where |
|---|---|---|
| `rake test` | Everything fixture-backed. No network, no tokens, no `claude`. | `.github/workflows/ci.yml` |
| `rake test:boundary` | The permission suite, against the real `claude` CLI | Locally, before merging anything touching containment |

The boundary suite needs Claude Code authentication and asserts a real refusal, so it cannot run
on a GitHub runner. Keeping it in `rake test` would make CI permanently red; leaving it
undistinguished would mean it quietly never ran.

mill working on mill is therefore also the smoke test for the CI-failure trigger.

## Why this shape

The design is a bet on a few specific claims, mostly from Addy Osmani's *Software Factories* and
the alexop.dev piece of the same name.

**A loop, a harness, a factory.** Osmani's decomposition: a *loop* is one agent doing one job on
repeat; a *harness* is the sandbox, tools, memory, and exit conditions around it; a *factory* is
many harnessed loops fed by a queue and filtered through a review gate. mill is the harness and
the factory; the loops are Claude Code invocations. The framing is why the stage graph's
*structure* is data — you can see every step and its configuration in one place — while mill's
Ruby runs the control flow over it, deciding when to
retry, when to resume, and when to stop.

**Verification is the bottleneck, not generation.** "Back pressure is the rule that you can only
hand a loop as much autonomy as you can cheaply and reliably verify, and not one inch more."
This is why half the graph is review stages, why every stage has a hard attempt cap, and why
`fail closed` is a principle. It is also why deep review exists: when the cheap check is not
enough, buy a more expensive one deliberately rather than trusting a longer loop.

**Graphs, not free-form loops.** Osmani observes the field moving from open-ended agentic loops
toward explicit directed graphs, where nodes are steps and edges are conditions, because that
makes failure points legible and checks mandatory at transitions. mill's routes are that graph.
The corollary — shorter loops stay verifiable, 20+ steps degrade — is why there are three short
routes rather than one long one.

**Lit, not dark.** A dark factory ships code no human reads. Osmani's warning is *comprehension
debt*: the widening gap between how much code exists and how much anyone still understands, with
a documented case of four months' unreviewed automation ending in painstaking manual debugging.
The lit version "doesn't tack review onto the end but moves the point of human judgment
upstream." That single sentence is why the design changed shape: the first draft put the only
human gate at the PR, which is downstream. Now you design, and you release. mill executes.

**Where this design departs from the ambition.** alexop.dev describes agents that watch support
tickets, cluster complaints, and generate their own backlog — a self-feeding factory. mill
deliberately cannot do that. Everything it works on, you put on the board. That is a smaller
machine than the articles imagine, and I made the trade knowingly: an adversarial review of the
first draft found the headless design stages to be the least trustworthy part of the pipeline,
so the design drops them rather than hardening them.

**Where it departs from the commercial version.** Vorflux ships the cloud form of this idea, and
two of its claims are worth naming. It promises adversarial review by "a second model, from a
different lab" — mill drives Claude Code, so its reviewers share the author's model family, and
what it can honestly offer is fresh context plus a hostile persona. And its `Verify` phase has
QA agents drive a real browser and record video proof, which is the strongest idea on their page
given that verification is the bottleneck. mill defers it; see [Deferred](#deferred).

## Known limitations

- **The adversarial reviewer shares the author's model family.** Fresh context and a hostile
  persona catch sloppiness, not shared blind spots. Deep review answers this partly for code, by
  making a refuter write a failing test; for plan review the limitation stands. Design escapes it
  because you review the design yourself. The seam, if it matters, is the stage's model field.
- **Agents are a second GitHub seam.** `pr` and `push` run `gh` inside the worktree, so
  `Mill::Github` is the single seam for mill's own calls only. A GitHub App migration would have
  to reckon with agent-side calls too — not a one-file change.
- **Attribution.** mill's commits, comments, and PRs appear as you. The `mill/` prefix and the
  comment marker are the only signals.
- **The permission ruleset is the boundary, and `implement` needs a wide one.** Layers 2–4
  narrow the consequences; they do not make a stage harmless.
- **Local only.** When your laptop sleeps, the factory stops. mill recovers whatever was in
  flight — see [Sleep and wake](#sleep-and-wake) — but nothing progresses while the lid is shut.
- **No unattended path from a vague idea to a PR**, by design. If you have not thought it
  through, mill will not think it through for you.
- **The review loop may not converge.** The reviewer skill assumes defects exist, and a `high`
  or `critical` objection re-runs the reviewed stage. If the reviewer reliably escalates on
  every pass, every run burns both attempts and blocks — the cap turns an infinite loop into a
  system that never finishes. Steve Yegge reportedly scrapped his "Gas Town" system for exactly
  this: certain Opus versions would not converge, always finding issues, with the fix-review
  cycle oscillating rather than settling. mill's defences are the severity threshold (only `high`
  or `critical` triggers a re-run), the two-attempt cap, and session resume (the coding agent
  remembers its own reasoning, so it is less likely to undo its fix to satisfy a new objection).
  If this shows up in practice, the responses to try in order: tighten the threshold to
  `critical` only; cap review-driven re-runs to one pass (attempt 2's review lands in the PR
  body but never triggers attempt 3); or accept that some runs will block and treat that as the
  reviewer doing its job.
- **Comprehension debt.** mill's only defence is that you read every PR. If you stop, it becomes
  a dark factory and the debt accrues silently.

## Deferred

- **Branch/preview deploys.** Researched in `docs/reference/branch-deploy-options.md`. Fly review
  apps plus a Neon database branch per PR, driven by a workflow **in the target repo, not in
  mill**. mill's involvement is one field: read the deployment URL off the PR and pass it to a
  verify stage as `MILL_PREVIEW_URL`.
- **Browser verify stage.** `chrome-devtools-mcp` is installed, so the cost is a stage plus a
  per-repo opt-in. Most valuable against a deployed preview, which is itself deferred; would
  degrade to running the app locally. Revisit immediately after v1.
- **Holistic code quality** — collapsing duplication, cutting complexity, refactoring. Everything
  mill currently reviews is diff-scoped, so it cannot see that a method a stage just wrote already
  exists three files away. Researched; deferred to keep v1's surface small. The thinking, so
  nobody has to rediscover it:

  *Measure deterministically, judge with an agent.* "Find all duplication in 40k lines" is a
  token-counting problem an LLM does badly; "here are 14 candidate clones, which are worth
  collapsing" is judgment it does well. Ruby tooling: `flay` (structural similarity, so it catches
  renamed clones), `flog` (ABC complexity), `reek` (smells), `debride` (dead code), `rubycritic`
  (per-file grades), and `skunk`, which folds churn *and* coverage into one score.
  Language-agnostic: `jscpd`, `semgrep`, `ast-grep`. Prior art for the orchestration:
  [fastruby/tech-debt-skill](https://github.com/fastruby/tech-debt-skill).

  *Prioritise on churn × complexity*, which is CodeScene's model. A complex file nobody touches
  costs nothing; refactoring hot complex code compounds. Raw smell counts are the wrong ranking.

  Three integration points, in value order:

  1. **Duplication introduced by the change, checked in `review:code`.** Run `flay` on the base
     tree and the head tree and diff the results; a newly-introduced clone is an objection. Needs
     no new route, and it stops the factory manufacturing debt.
  2. **A `refactor` route gated on coverage.** Behaviour-preserving work is the only kind where
     the *existing* test suite is a real oracle, which makes it among the safest things to
     automate — but only where coverage exists, which is why `skunk` scores it. Success is
     falsifiable rather than aesthetic: tests pass unchanged **and** a metric moved. Needs a hard
     diff cap and the metric delta stated in the PR body.
  3. **A periodic survey adding board items with no Status set.** The poller only claims `Ready`,
     so unset items are candidates you promote. **Open question:** this moves the non-goal above —
     mill would propose work rather than only execute it. Proposing while you dispose is arguably
     consistent, but the line should be moved deliberately, not by accident.

  *Risk to carry forward:* refactoring PRs are the worst kind to review — large diffs, no
  behaviour change, expensive to read. A factory producing refactor PRs you skim makes
  comprehension debt worse while appearing to reduce it. One concern per issue.

- **Directives as labels.** Currently board fields. Labels would be two clicks from an issue page
  without opening the board, at the cost of creating labels in every repo mill prepares.
- **Browser chat UI.** Session ids and log paths are stored per attempt.
- **Nightly cron** for one-anti-pattern PRs — largely covered by mill working on mill.
- **GitHub App identity.** See the second-seam limitation for what it involves.
- **Hostile-repository safety.** Fork PRs, untrusted `CLAUDE.md`, untrusted `bin/`.

## Build order

**Prerequisite: a scratch repo.** mill pushes real branches and opens real PRs, so the build needs
a target nobody cares about. A private `slowernet/mill-scratch`: real enough to plan against — a
test suite, a CI workflow reporting a `test` check, files with actual structure — and disposable
enough to reset after every rehearsal, since the same scenario gets run many times. On the board,
with branch protection, so those mechanics are exercised too. It also needs a fixture scenario for
Plan B: an issue, `gh issue develop`, and a committed spec on the linked branch, or the `plan`
route arrives to find nothing to adopt.

**Write one plan at a time**, and execute it before writing the next — doing Plan A teaches things
that change Plan B, and a stale plan actively misleads. Each plan names the spec sections it
implements rather than expecting an agent to read all of this. mill works on mill only after Plan
D, when the kill switch and the log tail exist; before that, it is two unreliable things at once.

### Spike — the permission model

Not a plan. Throwaway code, standalone, first.

Verify that when `claude -p` denies a tool call in non-interactive mode it tells the agent so
rather than hanging, and that a stage cannot write `.claude/` when a `--settings` file outside the
worktree denies it. Every layer-1 claim in [Containment](#containment) rests on this, and a
negative result changes the design — so build nothing on top of it until it confirms.

### Plan A — Seams and doctor

- Schema and migrations
- `Mill::Github` over REST and GraphQL, fixture-backed
- `Mill::Claude`: process-group spawn, tee stream-json, accumulate token counts, capture
  session id, validate the verdict envelope
- `rake mill:doctor`, and the setup runbook exercised for real

*Demonstrable:* doctor green against a real board; a rake task spawns `claude`, validates a
nonce-stamped verdict, and reports its token usage.

This boundary is deliberate: those two classes are the only ones touching the outside world, so
from here on every plan tests with no network and no tokens.

### Plan B — One run by hand — **the keystone**

- Runner over the `plan` route against scripted verdicts: the two-strike rule, and when it
  treats a review as a rejection
- Finding the spec and adopting the branch: `linkedBranches`, the diff-based lookup
- Real stage prompts and `mill-headless` for `triage → plan → review:plan → implement →
  review:code → pr`
- `rake mill:run`

*Demonstrable:* a real PR on `mill-scratch` from a real spec.

No board, no poller, no supervisor, no UI. This retires every integration risk at once while the
system is still small enough to debug by reading stdout. Everything before it is scaffolding;
everything after is automation wrapped around a working core.

### Plan C — Autonomy

- Supervisor: prepares a repo on first touch, manages the worktree lifecycle, removes stale
  locks, enforces the concurrency cap, kills a process group
- Poller: reconciles the board, checks who commented, advances comment cursors, applies the
  marker rule
- Sleep and wake: the awake-time clock pair, the settle window, the stall detector, the
  `caffeinate` assertion

*Demonstrable:* set Status to `Ready`, walk away, come back to a PR. Close the lid mid-stage and
the run recovers instead of burning a strike.

### Plan D — Observe and interrupt

- Roda UI: run list with health and spend, run detail, log endpoint, kill, pause and resume,
  repo diagnostics
- How a run blocks, asks, and resumes, including the sanctioned counter reset

*Demonstrable:* kill a run mid-stage and confirm nothing was orphaned; an underspecified issue
blocks, your comment resumes it, the run finishes.

### Plan E — Other routes

- `fast` route with `diagnose`
- `iterate` route and the PR triggers

### Not yet planned

Evidence deliverable and deep review. Both are the most likely to change once mill has actually
been used, so planning them now would be guessing.

## Revision history

**Revision 3 — sleep and wake.** mill runs on a laptop, so sleep is a normal operating condition
rather than an exception. Sleep kills nothing, so nothing needs saving; what it breaks is open
sockets and wall-clock deadlines. Every deadline now declares which clock it reads, and mill
measures how long it slept by differencing the continuous and awake clocks. A stall detector
watches stream-json for silence and rescues a stage left holding a dead socket, without charging
it a strike. A settle window stops the first poll after a wake from marking every repo unhealthy.
`POST /pause` lets you stop the line before you shut the lid.

**Revision 2 — plan quality, board ingress, honest containment.** mill no longer designs: you
produce a reviewed spec interactively, and mill keys routes on what the ticket already contains
rather than on how big the change looks. A Project board read as state replaces labels. The repo
watchlist and the picker are gone — the token allowlists repos, the board queues the work, and
mill prepares a repo on first touch. Fresh per-finding agents now do deep review's refuting,
under an explicit invariant that no agent reviews an artifact it produced. Osmani's framing moved
out of the opening and into [Why this shape](#why-this-shape), so the doc defines the pipeline
before it justifies it.

**Revision 1 — the adversarial review.** A three-lens review, plus a pass that tried to refute
every claim, produced 62: 14 confirmed, 22 partial, 26 refuted. They traced to four root causes,
and this revision fixes each at the root. Containment was fictional, because
`--dangerously-skip-permissions` provides no filesystem confinement. Labels are events, and every
swap had a crash window. Every stage wrote the verdict to one shared mutable path, so a crashed
stage inherited its predecessor's `ok`. And three of five triggers had no route, no identity, and
no cursors.

## Sources

- [The Software Factory — alexop.dev](https://alexop.dev/posts/the-software-factory/)
- [Software Factories — Addy Osmani](https://addyosmani.com/blog/software-factories/)
- Claude Code quickstart v2.0 (local, `~/Downloads/Claude Code quickstart (3).md`)
- Vorflux landing page text — `tmp/vorflux-landing.md` (untracked scratch)
- Branch deploy options — `docs/reference/branch-deploy-options.md`
