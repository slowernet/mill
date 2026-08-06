# Mill — a software factory for Claude Code

Design doc. 2026-08-06, revised twice — see [Revision history](#revision-history).

## What Mill is

Mill is a Ruby/Roda application on your own machine that executes reviewed designs. You
decide *what* to build, in an interactive session where your judgment is worth the most.
Mill does everything after that: planning, implementation, adversarial review at each step,
and a pull request for you to read.

### The pipeline, end to end

**1. You design, interactively.** A normal Claude Code session in your terminal —
`brainstorming`, argument, pushback, revision. It produces a spec committed to
`docs/superpowers/specs/` on a branch linked to the issue via `gh issue develop`. This part
is deliberately outside Mill: designing needs taste and disagreement, and the skills that do
it well require a live human.

**2. You release it.** Set the issue's Status to `Ready` on Mill's Project board. That act is
the assertion that the design is reviewed — you don't release it until you're happy.

**3. Mill claims it.** The poller reconciles the board, finds a `Ready` item with no active
run, adopts the linked branch, and reads the spec the branch introduced.

**4. Mill runs the graph**, one `claude -p` process group per stage, each with a fixed model,
a named skill, and its own permission ruleset:

```
triage → plan → review:plan → implement → review:code → pr
```

Every stage writes a nonce-stamped verdict. A reviewer's `high` or `critical` objection
re-runs the stage it reviewed. Two failed attempts at anything stops the line.

**5. Mill opens a PR** — code, tests, the plan, and the spec in one diff — and sets Status to
`Done`.

**6. You read the PR.** This is the only human gate on the output, and Mill never merges.

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
design session." Mill declining to guess is a feature.

### Where the human is

| Stage of thought | Who |
|---|---|
| What to build, and why | You, interactively |
| Whether it's ready to build | You, by setting Status |
| How to build it, step by step | Mill (`plan`) |
| Building it | Mill (`implement`) |
| Whether it's correct | Mill's adversarial reviewers, then CI |
| Whether to ship it | You, at the PR |

## Non-goals

- **Mill does not design.** No `brainstorming` stage. Mill executes decisions; it does not
  make them.
- **Not a chat UI.** Interactive work happens in your terminal.
- **Not a multi-source ingest.** GitHub only — no Slack, Linear, Jira, Figma, voice, video.
- **Not a deployment tool.** Mill never deploys and never merges.
- **Not a team product.** Single operator, single machine.
- **Not a replacement for Superpowers.** Mill sequences and gates the skills you already use.
- **Not safe against a hostile repository.** Mill assumes every repo it touches, and that
  repo's `CLAUDE.md`, `.claude/`, and scripts, are yours.

## Principles

1. **GitHub holds the queue and the outcome. SQLite holds run state.** The board and the PR
   are the durable record. Run state — route, branch, worktree, stage, session id, attempt
   counts — exists only in SQLite and is *not* disposable.
2. **Silence is never success.** Every attempt must produce a verdict proving it ran: correct
   stage, correct attempt, correct nonce.
3. **The line can always stop.** Any stage may emit questions and block rather than guess.
4. **Fail closed.** An unrecognised tool call, an unmatched verdict, a missing cost figure, an
   unprepared repo, or an unreachable GitHub all halt. None proceeds on an assumption.
5. **Deterministic where it can be.** The graph, the model per stage, the attempt limits, and
   the permission rulesets are code and config, not agent discretion.
6. **Gates live outside Mill where possible.** The token bounds which repos are reachable; the
   board bounds what work exists; branch protection bounds what can merge. A rule Mill
   enforces on itself is the weakest kind.

## Architecture

Five components. Only two touch the outside world.

| Component | Responsibility | Knows about |
|---|---|---|
| `Mill::Poller` | Reconcile board state into runnable work | `Mill::Github` only |
| `Mill::Supervisor` | Claim work up to the cap, prepare repos, manage worktrees, reap process groups | the DB, git |
| `Mill::Runner` | Walk the stage graph for one run | the graph, `Mill::Claude` |
| `Mill::Claude` | Build argv, spawn a process group, tee the log, accumulate cost, validate the verdict | Claude Code |
| `Mill::Github` | Every `gh` invocation, REST and GraphQL | GitHub |

`Mill::Github` is the single seam for **Mill's own** GitHub access. It is not the only path:
the `pr` and `push` stages run `gh` inside the worktree with a deliberately narrow token. See
[Containment](#containment).

**Process shape.** One Puma process. The poller and supervisor are threads, each wrapped in a
supervising loop that logs and restarts with backoff; `Thread.report_on_exception` stays at
its default of true. Each persists a heartbeat, and `GET /` becomes an error state when either
goes stale.

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

Repo clones are *not* under `~/.mill`. Mill uses the clone you already have.

## Ingress

Mill runs locally, shells out to `gh`, and needs no GitHub App, webhook secret, or tunnel.

### The board is the queue

One user-level GitHub Project spans every repo. Both issues and PRs appear as items. Projects
v2 is GraphQL-only, so `Mill::Github` needs `gh api graphql`, and setup must resolve the
project id, each field id, and each option id.

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
| `Review` | `Deep` | Replace single reviewers with faceted fan-out plus refutation |

Everything Mill reads lives on the board. **Mill uses no labels**, which means preparing a
repo requires no writes to it.

**Mill is the sole writer of Status**, so the board's built-in workflows must be disabled —
Projects v2 automation writes Status too. "Item closed → Done" would flip Status out from
under a `Running` run, leaving the reconciler blind to a live subprocess; "Auto-add to
project" would sweep every new issue onto the board. `mill:doctor` asserts they are off.

Field values belong to the project, not the issue, so an item's Status here is independent of
its status on any other board, and no other project's automation can reach it.

### Reconciliation, not events

Every tick the poller asks: **which items are `Ready` with no active run?** That is idempotent,
needs no dedupe key, and self-heals a crash mid-transition. The earlier label-based design
consumed label-change *events*, and four separate bugs came from that shape — a relabelled
issue was permanently deduped, `Ready` and `Running` could both be set, `Running` was never
cleared on a kill, and terminal states had no transition at all. A single-select cannot
represent any of them.

Comments genuinely are events, so the `events` table survives for those, with per-repo cursors
advanced **only after a fully paginated sweep has been inserted, in the same transaction as
the inserts**. A partial fetch writes no cursor.

### Triggers

| Trigger | Effect | Source |
|---|---|---|
| Item `Ready`, no active run | Start a run | board reconciliation |
| Comment on a `Blocked` item | Resume the blocked run | comment poll |
| Comment on a Mill PR | Iterate on the branch | comment poll |
| PR review comment | Address the feedback | review-comment poll |
| Required checks red on a Mill PR | Fix the failure | check poll on open Mill PRs |

**PRs are board items too**, which is what gives PR-entry work a run identity — a Dependabot
PR has no issue, so questions need somewhere to go. `runs` carries `subject_kind`
(`issue` or `pr`) and `subject_number`, and blocking questions go to the subject.

Check state is read as current state off open Mill PRs, not consumed as a stream, so it needs
no cursor. Required status checks are configured by branch protection on the base branch; the
runbook sets them up and `mill:doctor` verifies them.

### Author gating

**Every comment-derived trigger requires `author_association` in `OWNER`, `MEMBER`, or
`COLLABORATOR`.** Anything else is ignored and logged. Three of five triggers are comments,
and comment text becomes prompt text; without this, a stranger's comment on a public repo
drives a subprocess holding your credentials.

**Mill acts only on PRs whose head ref is in the same repository** — never a fork head.
Dependabot satisfies this. Trusted non-Mill authors are an explicit `.mill.yml` allowlist
defaulting to `dependabot[bot]`. Checking out a fork head means executing a stranger's
`CLAUDE.md`, `.claude/`, and `bin/`.

### Self-trigger prevention

Every comment Mill writes carries `<!-- mill:v1 -->` as the **first line**, and the poller
ignores a comment only when the marker appears at the start of a line that is not
blockquote-prefixed. Mill also remembers the ids of comments it posted.

A substring test on the whole body fails: GitHub's quote-reply copies the source markdown
including HTML comments, so answering a blocked run the obvious way would produce a body
containing the marker and the poller would silently discard the only human-in-the-loop channel
in the design.

Stages cannot post comments at all — `gh issue comment`, `gh pr comment`, and `gh api` are
denied. Only `Mill::Github` comments, and it always stamps the marker.

## The stage graph

The graph is data. Each stage declares its name, prompt template, model, skill, expected
artifact pattern, and permission ruleset.

| Route | Entry condition | Stages |
|---|---|---|
| `plan` | Issue with a linked branch introducing a spec | `triage → plan → review:plan → implement → review:code → pr` |
| `fast` | Issue with no spec, triaged as hotfix-shaped | `triage → diagnose → implement:fast → review:code → pr` |
| `iterate` | Any PR trigger | `triage → implement:fast → review:code → push` |

An issue with no spec that triage does not judge fast-shaped blocks with questions.

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

Sonnet for cheap mechanical passes, Opus for judgment and code. No user-facing toggle;
changing the map is a config edit.

`implement` and `implement:fast` differ by whether a plan exists — `executing-plans` requires
one, `test-driven-development` does not. That distinction now tracks the real difference
rather than a guess about change size.

Every stage receives its predecessors' verdicts and artifact paths. Reviewer stages receive the
artifact under review plus the diff to date; `review:code` also receives the plan, so it can
check the code against what was promised.

### Finding the spec

No path is pasted anywhere. The issue refers to a **branch**, natively:

1. Your design session runs `gh issue develop <n>`, which links a branch to the issue and
   shows it in the issue's Development section.
2. Mill reads `linkedBranches` on the issue and adopts that branch — it does not create one.
3. The spec is the file that branch adds under `docs/superpowers/specs/`, found with
   `git diff --name-only <base>...<branch> -- docs/superpowers/specs/`.

Exactly one file is the spec. Zero means no spec (so `fast` or block); more than one blocks.

Nothing is typed, so nothing can be mistyped or go stale under a rename, and the presence
check is deterministic rather than an LLM reading prose for a link. `writing-plans` keeps its
own filename convention because Mill never looks at filenames, only at which file a branch
introduced. The artifact and the work end up on one branch, so the eventual PR shows the spec,
the plan, and the code together.

`iterate` adopts an existing branch by the same code path.

### Stage prompts

Mill owns a thin prompt per stage invoking its skill explicitly by name, removing the
probabilistic activation the quickstart warns about. Mill also ships `mill-headless`, loaded by
every stage, which redefines the one interactive gate the remaining skills assume: where a
skill would ask the user and wait, write the questions into the verdict and stop.

That job is much smaller than it was. `brainstorming`'s per-section approval gates were the
hardest thing to simulate headlessly, and moving design upstream deletes the need entirely.
`writing-plans`' single gate — "any questions or critique of the design?" — maps onto
block-and-ask directly.

The stage prompt owns the verdict envelope; `mill-headless` owns what goes in `questions`.

## The stage contract

Every attempt is one `claude -p` subprocess in its own process group, writing a verdict to a
path Mill passes in:

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
  "objections": [{ "severity": "critical|high|medium|low", "claim": "…" }],
  "summary": "one paragraph for the log and the PR body"
}
```

Mill validates before accepting:

- The file must exist, and `stage`, `attempt`, and `nonce` must match this spawn. Mill unlinks
  it first and generates a fresh nonce each time.
- `artifact`, if present, must resolve inside the worktree, must not traverse a symlink, must
  match the stage's declared pattern, and must exist and be non-empty.
- `questions` must be non-empty iff `status` is `blocked`.
- `route` and `evidence_required` are accepted only from `triage`.

Any violation is `failed`.

The first draft used one fixed path reused by every stage and never cleared it. Two independent
reviewers found the consequence: a stage that died without writing was passed on its
predecessor's `{"status":"ok"}`, so a crashed adversarial review was recorded as an approval.
The nonce makes a stale or replayed verdict unrepresentable, and keeping the file out of the
repo means it can never be committed and restored by a later checkout.

`pr_number` is deliberately not in the verdict. Mill recovers it with
`gh pr list --head <branch>`, which is idempotent, so a crash between `gh pr create` and the
state write reconciles instead of opening a second PR.

Stages run with `--output-format stream-json`. `Mill::Claude` accumulates per-message `usage`
as it tees, persisting a running `cost_cents`, so a killed attempt retains its partial spend.

## Containment

Mill **does not** use `--dangerously-skip-permissions`. That flag is
`--permission-mode bypassPermissions`, and since working directories and `--add-dir` are
permission-system concepts, skipping permissions leaves no filesystem confinement for Read,
Write, or Edit at all. Autonomy comes from an explicit ruleset instead, in four layers.

**1. An allow/deny ruleset per stage, from outside the worktree.** Each stage runs with
`--settings ~/.mill/settings/<stage>.json` listing the tools and Bash commands that stage
needs. Anything unmatched is denied rather than prompted, which in headless mode means the
agent is told no and adapts or blocks. Fail-closed; a denylist is fail-open.

Deny rules for every stage: writes to `.claude/**`, `.mill.yml`, `.github/workflows/**`, and
`.github/actions/**`; reads of `~/.ssh/**`, `~/.aws/**`, `~/.config/gh/**`, and `**/.env*`;
and every `gh` subcommand except the narrow set `pr` and `push` require.

The settings file lives outside the worktree because under `bypassPermissions` writes to
`.claude/` are permitted and the settings watcher picks them up — so an agent could disarm its
own restrictions *mid-session*.

`.github/workflows/**` is denied because pushing a branch that modifies a workflow makes
GitHub run the modified workflow with repository secrets in scope. A legitimate CI change is a
block-and-ask.

**2. The Bash sandbox, enabled.** `sandbox.enabled` with `filesystem.denyRead` on `~` and
`allowRead` on the worktree. Defence in depth, not the boundary: it covers Bash and not the
file tools, and fails open if it cannot start.

**3. A scoped GitHub token.** Stages get `GH_TOKEN` set to a fine-grained PAT covering only
selected repositories, with Contents and Pull requests read/write and nothing else, and the
operator's `gh` keyring config scrubbed from the stage environment. Mill's own board, comment,
and label-free work happens in-process under your login, where the agent cannot reach it.

**This token is also the repo allowlist** — if it does not cover a repo, no bug in Mill can
push there.

**4. A `PreToolUse` hook**, written from outside the worktree, blocking pushes to the base
branch, `commit --amend`, `reset --hard`, `gh pr merge`, and `rm -rf` above the worktree root.

**The hook is explicitly not a security boundary.** It guards against model error. A command
denylist falls to one level of indirection — `bash -c`, or a committed `bin/setup` containing
the forbidden command — and a suite of "commands that must be refused" measures only the
bypasses its author imagined. Layers 1–3 are the boundary.

**Mill never merges.** Nothing in the codebase calls `gh pr merge`.

**Accepted risks:**

- **Network access inside a stage is unrestricted.**
- **Layer 1 is only as good as its rules**, and `implement` legitimately needs a wide one.
- **Mill is not safe against a hostile repository.**

## Blocking, questions, and resume

A stage that cannot proceed emits questions; Mill posts them to the subject with the marker,
sets Status to `Blocked`, and halts. Your reply is a comment, which is a trigger.

Mill resumes with `claude --resume <session-id>`, answers injected. Verified: `--resume`
returns the *same* session id (a new one requires `--fork-session`), and a transcript whose
last record is a `tool_use` with no matching `tool_result` — the state a SIGKILL produces —
resumes successfully, because the CLI repairs the dangling call. If resume fails for any
reason, Mill re-runs the stage from scratch with the full Q&A thread appended, and that
fallback consumes an attempt.

A run blocked by **attempt exhaustion** differs from one blocked by a question: answering it
resets that stage's counter to zero, once, recorded on the run. A second exhaustion on the
same stage is terminal and sets Status to `Failed`. This is the one sanctioned path to a third
attempt and it requires a human.

## Back-pressure

**Two attempts per stage, then block.** A stage that fails, crashes, times out, or is rejected
gets one retry with the failure or the objections in context. The second failure posts both
attempts and blocks.

**Rejection is defined.** A reviewer returns `status: ok` with `objections`; it does not fail.
The reviewed stage re-runs iff any objection is `high` or `critical`. Lower severities are
recorded and land in the PR body. Without this, one implementer rejects on any objection — and
since the reviewer skill assumes defects exist, nearly every run blocks — while another treats
objections as advisory and gates nothing.

**Limits, config, with these defaults:**

| Limit | Default |
|---|---|
| Concurrent runs | 3 |
| Wall clock per attempt | 30 min of awake time |
| Spend per run | $10 |
| Spend per subject, lifetime | $30 |
| Runs per subject per 24h | 6 |
| Spend per deep-review stage | $40 |

The per-attempt clock uses `Process::CLOCK_UPTIME_RAW`, which does not advance during sleep.
`CLOCK_MONOTONIC` and wall clock both count sleep on Darwin, so closing the lid mid-stage
would otherwise reap a healthy attempt as a timeout and charge it a strike — twice, on the
only deployment target Mill supports.

**There is no global daily ceiling, deliberately.** Total exposure is the per-subject ceiling
times the number of subjects, and Mill never adds items to the board — you do. The board is
already the bound, so a global cap would only duplicate it.

A run hitting any ceiling is killed and blocked with its spend reported. A NULL cost fails
closed.

## Deep review

Setting the board's `Review` field to `Deep` replaces a single reviewer stage with a fan-out.
It is opt-in because it costs roughly six Opus invocations per review stage.

1. **Facet selection.** One pass reads the artifact and chooses 2–4 review facets appropriate
   to *this* artifact, with a rationale. Facets are chosen dynamically rather than configured,
   because the useful facets are a property of the document, not the repo.
2. **Parallel finders.** One agent per facet, each given the artifact and its facet, blind to
   the others, told the author is unavailable so an unstated assumption counts as a defect.
3. **Deduplication.** Its own agent, invoked by the Runner, because it needs every finding at
   once. The Runner is deterministic Ruby and cannot do this itself.
4. **Refutation.** One fresh agent per finding, given the claim and the artifact but **not**
   its sibling findings, instructed to refute and to default to refuted when uncertain. For
   `review:code`, refutation is **empirical**: a finding survives only if the refuter can write
   a failing test reproducing it.
5. **Verdict.** Only survivors become objections, and the ordinary high-or-critical rule
   decides rejection.

**Invariant: no agent may appear in the review path for an artifact it produced.** Refutation
is never done by the author and never by an agent holding the other findings — authorship
creates a stake, and sibling findings create anchoring. Mill satisfies this structurally, since
a stage's session is gone by the time its artifact is reviewed.

The refutation pass is not decoration. On this document's own review it killed 26 of 62 claims;
a stage reporting all 62 would have trained the operator to ignore reviews. It also supplies
the rejection predicate the ordinary path needs.

Known weakness: deduplication is an LLM pass and is the part most likely to be done badly.
Empirical refutation for code is immune to the deeper problem — a refuter agreeing with a
finder for the same wrong reason — because a test either fails or it does not.

## Evidence requirement

The board's `Evidence` field set to `Required` adds one deliverable: a before/after sample of
real output in `docs/superpowers/samples/<date>-<slug>.md`, summary table inlined in the PR
body. It changes no route and adds no stage. The work is built to production standard either
way, so merging on the strength of a sample means merging production-ready code.

- **Show the items, do not summarize them.** "Surfaces more diverse content" cannot be judged;
  a table of the actual fifty things it picked can.
- **Before and after, same inputs through both paths.**
- **A deterministic slice the agent did not choose**, plus the cases that moved most in *both*
  directions, with commit sha, seed, and exact command recorded.

**The sample must come from a committed fixture, never a live database**, and `Evidence` is
refused on a public repo unless `.mill.yml` sets `evidence_public: true`. The `pr` stage
publishes automatically, so a production-derived sample would be public before you saw it —
and for ranking or curation work "the actual fifty things" are user records.

`review:code` gains a legibility check on these runs: could someone judge this from what is in
the PR?

The merge decision here is yours and is not gated by the reviewers. They confirm the code is
production-ready; the sample lets you decide whether the idea is any good.

## Setup and preparation

**One-time, human-run:** `docs/reference/setup.md`. Two steps cannot be automated — minting a
fine-grained PAT has no API, and choosing which repos a token may touch is not a decision a
script should make silently. The runbook covers `project` scope, creating the board and its
three fields, disabling the board's built-in workflows, minting the stage token, branch
protection with required status checks, and per-repo secrets files.

**There is no repo watchlist and no picker.** The board yields items from any repo, so there is
no per-repo polling loop to bound, and per-item consent is stronger than per-repo consent —
an item enters Mill only because you put it on the board. The repo allowlist already exists and
is enforced by GitHub: the token covers selected repositories only.

**Preparation is lazy.** An item arrives from a repo Mill has not prepared, so the supervisor
prepares it on first touch:

1. **Resolve the clone.** Scan `~/code` for a repo whose `origin` matches. Ambiguous or missing
   matches are surfaced, never guessed.
2. **Set `gc.auto=0` and `maintenance.auto=0`** so a stage's commit cannot trigger a gc that
   rewrites shared refs while other runs hold them.
3. **Read `.mill.yml`** from the base branch into `repos.config_json`: base branch, test
   command, gating CI workflow, trusted PR authors, `evidence_public`, secret variable names.
4. **Verify** the token covers the repo and `~/.mill/secrets/<owner>-<repo>.env` exists.

Anything missing blocks **that item** with a comment naming exactly what is missing. Nothing
is written to the repo — Mill uses no labels — so preparation is read-only apart from local
git config.

`.mill.yml` is read only from the base branch, never from the worktree HEAD, and the resolved
config is pinned onto the run. An agent can edit `.mill.yml` in its worktree; that edit must
not weaken the next run.

**Secret provisioning.** A fresh worktree has tracked files only, so `.env` and
`config/master.key` are absent and an env-dependent suite would fail identically on both
attempts — meaning the pipeline could never complete on a normal Rails or Node repo. Mill
injects `~/.mill/secrets/<owner>-<repo>.env` into the stage environment as variables, never
writing them into the worktree, and excludes those values from the tee'd log.

**`rake mill:doctor`** verifies every precondition and names what is missing: `gh` auth and
`project` scope; the board's three fields and their options; that built-in workflows are
disabled; the stage token's permissions, expiry, and file mode; `~/.mill` modes; the permission
rulesets' deny rules; and for every repo the board currently references, clone resolution,
`gc.auto`, `.mill.yml` parse, branch protection with required checks, and named secret
variables. Most of what it checks is load-bearing for containment, so a red doctor is a blocker.

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
               status, verdict_json, tokens_in, tokens_out, cost_cents,
               log_path, pid, pgid, started_at, finished_at

events         id, repo_id, kind, gh_node_id (unique), payload_json,
               attempts, last_error, state, created_at, processed_at
```

Run statuses: `queued`, `running`, `blocked`, `done`, `failed`, `killed`.

`repos` is a cache of prepared state, not a watchlist — no `enabled` column, because nothing is
enabled or disabled.

A run is inserted as `running` in the same transaction as the claim, and the cap counts `queued`
and `running` together, so it cannot drift.

`blocked` is inside the uniqueness index: a blocked run must keep guarding its subject because
resume is comment-triggered. SQLite supports the partial unique index this needs.

`events` carries `attempts`, `last_error`, and a terminal `dead` state with a cap, and
`processed_at` is set in the same transaction as the resulting run insert — otherwise an
exception after marking a comment processed drops your answer with no trace.

`pgid` and `pid` are persisted so a kill works after a restart, and Mill verifies pgid plus
start time before signalling — never a bare pid, which can be recycled.

`heartbeat_at` is written by the runner; boot-time and periodic reconciliation fails runs whose
heartbeat is stale and whose process group is gone.

**Retention.** Logs and verdicts for runs finished more than 14 days ago are deleted, each
attempt's log is byte-capped and truncated with a marker, and `GET /` shows disk used.

## Web UI

Roda and Sequel. Binds `tcp://127.0.0.1:9494` explicitly — Puma's default is `0.0.0.0`, which
would expose log tails and the kill switch to the local network. Requests whose `Host` is not
`localhost:9494` or `127.0.0.1:9494` are rejected, defeating DNS rebinding. The POST requires a
CSRF token via Roda's `route_csrf`, since a cross-origin form POST is a CORS simple request and
is not preflighted.

```
GET  /                 run list: subject, route, stage, status, spend, disk, health
GET  /runs/:id         stage timeline, artifacts, verdicts, log tail
GET  /runs/:id/log     JSON tail, offset-paginated
POST /runs/:id/kill    kill the process group, mark killed, set Status
GET  /repos            read-only diagnostics: prepared state, resolved clones, prerequisites
```

Kill is the only write path. Everything actionable — releasing work, answering questions,
setting directives, reviewing the PR — happens in GitHub. Mill shows what GitHub cannot: what
an agent is doing now, what it cost, and whether the factory is alive.

## Killing and teardown

Stages are spawned with `pgroup: true`. Killing means `SIGTERM` to the group, `SIGKILL` after a
grace period, then confirming no descendant survives before the worktree is reused or removed.
Killing the `claude` pid alone leaves test runners, package managers, and dev servers holding
the worktree and its ports, which then fail the next attempt for reasons invisible in the log.

A killed run sets Status to `Failed` and comments why.

**Stale git locks.** Before every attempt and at boot, Mill removes age-checked stale `*.lock`
files under the gitdir for its own worktrees and `refs/heads/mill/*`. A SIGKILL during
`git commit` leaves an index or ref lock that git never cleans, so attempt 2 would fail
instantly on the lock and burn the second strike for a reason unrelated to the work.

**Branch and worktree collisions.** Mill-created branches are `mill/<subject>-<run-id>`, so two
runs on one subject cannot collide. Adopted branches keep their existing names. Before claiming,
Mill prunes stale worktree administrative entries — `git worktree add` refuses a branch whose
admin entry survives even after its directory is deleted.

`git worktree add` and ref writes are serialized across runners by one in-process mutex, with
retry and backoff on lock contention.

**Teardown** happens on `done` after the PR opens, and on `failed` and `killed` after retaining
a compressed diff, the verdicts, and the logs. A `blocked` run keeps its worktree because resume
needs it; blocked longer than 14 days, it is reaped to the same compressed form.

## Failure taxonomy

Every row resolves to `blocked` or `failed`. None resolves to silent success.

| Failure | Handling |
|---|---|
| Stage returns `blocked` | Questions to the subject, Status `Blocked`, stop. Resume on reply. |
| Stage returns `failed`, crashes, or exits non-zero | Retry once with the failure in context; second failure blocks with both attempts posted |
| Verdict missing, malformed, or envelope mismatch | `failed` |
| Artifact missing, empty, outside the worktree, or off-pattern | `failed` |
| Reviewer returns a `high` or `critical` objection | Re-run the reviewed stage; twice blocks |
| Issue has no linked branch, or the branch adds no spec | `fast` if triage judges it hotfix-shaped, else block |
| Linked branch adds more than one spec file | Block, ask which |
| Attempt exceeds 30 min awake time | Kill the group, `failed`, two-strike rule applies |
| Any spend ceiling exceeded | Kill, block, report spend |
| Cost unknown for an attempt | Fail closed |
| Repo unprepared or a prerequisite missing | Block that item, naming what is missing |
| Required checks red on a Mill PR | New attempt on the same branch, max two, then block |
| Mill restarted mid-stage | Counts as a crash: re-enters the stage, consumes an attempt |
| Stale git lock in the worktree or on a `mill/*` ref | Removed before the attempt; not an attempt failure |
| Orphaned descendants after a kill | Reaped before the worktree is reused |
| Branch or worktree admin entry already exists | Pruned before claim; failure to prune blocks |
| Worktree missing or conflicted | Abort, block, retain the diff |
| Run heartbeat stale and process group gone | Reconciled to `failed` |
| Comment from a non-collaborator | Ignored and logged |
| Comment event processing raises | `events.attempts` incremented, retried, `dead` after the cap |
| Poller auth failure or 404 | Repo marked unhealthy and surfaced; distinct from rate limiting |
| `gh` rate-limited | Backoff with a ceiling; cursor unchanged, so nothing is lost |
| Poller or supervisor thread raises | Logged, restarted with backoff, health surfaced |
| Two runs on one subject | Unique partial index |
| Disk full | Supervisor pauses claiming and surfaces it |

## Testing

`Mill::Claude` and `Mill::Github` are the only components touching the outside world, and both
get fakes backed by recorded fixtures. Everything above them tests with no network and no
tokens.

- **Poller** — a pure function of (board state, cursors, comments) → work. Table tests for
  author gating, the marker-at-line-start rule against real quote-reply bodies, fork-head
  rejection, and cursor monotonicity.
- **Runner** — graph walk against scripted verdicts: the two-strike rule, envelope validation,
  artifact validation, the rejection predicate, route selection, spec discovery, and the one
  sanctioned counter reset.
- **Supervisor** — worktree lifecycle against a scratch repo, lazy preparation, concurrency cap,
  process-group kill with a deliberately orphaning child, stale lock removal.
- **Permission ruleset** — the layer-1 boundary. Assert that a denied read of `~/.ssh`, a denied
  write to `.claude/`, and a denied `gh api` are actually refused when a real `claude -p` runs
  with the stage's settings file. The only suite that must run against the real CLI, because it
  is the only one asserting a boundary rather than logic.
- **End to end** — one full run against a scratch repo, by hand, not in CI.

**Two rake targets, because one cannot run in CI.**

| Target | Contents | Where |
|---|---|---|
| `rake test` | Everything fixture-backed. No network, no tokens, no `claude`. | `.github/workflows/ci.yml` |
| `rake test:boundary` | The permission suite, against the real `claude` CLI | Locally, before merging anything touching containment |

The boundary suite needs Claude Code authentication and asserts a real refusal, so it cannot run
on a GitHub runner. Keeping it in `rake test` would make CI permanently red; leaving it
undistinguished would mean it quietly never ran.

Mill working on Mill is therefore also the smoke test for the CI-failure trigger.

## Why this shape

The design is a bet on a few specific claims, mostly from Addy Osmani's *Software Factories* and
the alexop.dev piece of the same name.

**A loop, a harness, a factory.** Osmani's decomposition: a *loop* is one agent doing one job on
repeat; a *harness* is the sandbox, tools, memory, and exit conditions around it; a *factory* is
many harnessed loops fed by a queue and filtered through a review gate. Mill is the harness and
the factory; the loops are Claude Code invocations. The framing is why the stage graph is data
rather than control flow — the harness's job is to be legible about where a loop starts, stops,
and gets checked.

**Verification is the bottleneck, not generation.** "Back pressure is the rule that you can only
hand a loop as much autonomy as you can cheaply and reliably verify, and not one inch more."
This is why half the graph is review stages, why every stage has a hard attempt cap, and why
`fail closed` is a principle. It is also why deep review exists: when the cheap check is not
enough, buy a more expensive one deliberately rather than trusting a longer loop.

**Graphs, not free-form loops.** Osmani observes the field moving from open-ended agentic loops
toward explicit directed graphs, where nodes are steps and edges are conditions, because that
makes failure points legible and checks mandatory at transitions. Mill's routes are that graph.
The corollary — shorter loops stay verifiable, 20+ steps degrade — is why there are three short
routes rather than one long one.

**Lit, not dark.** A dark factory ships code no human reads. Osmani's warning is *comprehension
debt*: the widening gap between how much code exists and how much anyone still understands, with
a documented case of four months' unreviewed automation ending in painstaking manual debugging.
The lit version "doesn't tack review onto the end but moves the point of human judgment
upstream." That single sentence is why the design changed shape: the first draft put the only
human gate at the PR, which is downstream. Now you design, and you release. Mill executes.

**Where this design departs from the ambition.** alexop.dev describes agents that watch support
tickets, cluster complaints, and generate their own backlog — a self-feeding factory. Mill
deliberately cannot do that. Everything it works on, you put on the board. That is a smaller
machine than the articles imagine, and the trade is bought knowingly: an adversarial review of
the first draft found the headless design stages to be the least trustworthy part of the
pipeline, so they were removed rather than hardened.

**Where it departs from the commercial version.** Vorflux ships the cloud form of this idea, and
two of its claims are worth naming. It promises adversarial review by "a second model, from a
different lab" — Mill drives Claude Code, so its reviewers share the author's model family, and
what it can honestly offer is fresh context plus a hostile persona. And its `Verify` phase has
QA agents drive a real browser and record video proof, which is the strongest idea on their page
given that verification is the bottleneck. Mill defers it; see [Deferred](#deferred).

## Known limitations

- **The adversarial reviewer shares the author's model family.** Fresh context and a hostile
  persona catch sloppiness, not shared blind spots. Deep review's empirical refutation is the
  partial answer for code; for plan review the limitation stands. Design is exempt because you
  review it. The seam if it matters is the stage's model field.
- **Agents are a second GitHub seam.** `pr` and `push` run `gh` inside the worktree, so
  `Mill::Github` is the single seam for Mill's own calls only. A GitHub App migration would have
  to reckon with agent-side calls too — not a one-file change.
- **Attribution.** Mill's commits, comments, and PRs appear as you. The `mill/` prefix and the
  comment marker are the only signals.
- **The permission ruleset is the boundary, and `implement` needs a wide one.** Layers 2–4
  narrow the consequences; they do not make a stage harmless.
- **Local only.** Your laptop sleeping stops the factory. Runs resume; they do not progress.
- **No unattended path from a vague idea to a PR**, by design. If you have not thought it
  through, Mill will not think it through for you.
- **Comprehension debt.** Mill's only defence is that you read every PR. If you stop, it becomes
  a dark factory and the debt accrues silently.

## Deferred

- **Branch/preview deploys.** Researched in `docs/reference/branch-deploy-options.md`. Fly review
  apps plus a Neon database branch per PR, driven by a workflow **in the target repo, not in
  Mill**. Mill's involvement is one field: read the deployment URL off the PR and pass it to a
  verify stage as `MILL_PREVIEW_URL`.
- **Browser verify stage.** `chrome-devtools-mcp` is installed, so the cost is a stage plus a
  per-repo opt-in. Most valuable against a deployed preview, which is itself deferred; would
  degrade to running the app locally. Revisit immediately after v1.
- **Holistic code quality** — deduplication, complexity reduction, refactoring. Everything Mill
  currently reviews is diff-scoped, so it cannot see that a method a stage just wrote already
  exists three files away. Researched; deferred to keep v1's surface small. The thinking, so it
  need not be rediscovered:

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
     Mill would propose work rather than only execute it. Proposing while you dispose is arguably
     consistent, but the line should be moved deliberately, not by accident.

  *Risk to carry forward:* refactoring PRs are the worst kind to review — large diffs, no
  behaviour change, expensive to read. A factory producing refactor PRs you skim makes
  comprehension debt worse while appearing to reduce it. One concern per issue.

- **Directives as labels.** Currently board fields. Labels would be two clicks from an issue page
  without opening the board, at the cost of per-repo label creation during preparation.
- **Browser chat UI.** Session ids and log paths are stored per attempt.
- **Nightly cron** for one-anti-pattern PRs — largely covered by Mill working on Mill.
- **GitHub App identity.** See the second-seam limitation for what it involves.
- **Hostile-repository safety.** Fork PRs, untrusted `CLAUDE.md`, untrusted `bin/`.

## Build order

**Prerequisite: a scratch repo.** Mill pushes real branches and opens real PRs, so the build needs
a target nobody cares about. A private `slowernet/mill-scratch`: real enough to plan against — a
test suite, a CI workflow reporting a `test` check, files with actual structure — and disposable
enough to reset after every rehearsal, since the same scenario gets run many times. On the board,
with branch protection, so those mechanics are exercised too. It also needs a fixture scenario for
Plan B: an issue, `gh issue develop`, and a committed spec on the linked branch, or the `plan`
route arrives to find nothing to adopt.

**Write one plan at a time**, and execute it before writing the next — doing Plan A teaches things
that change Plan B, and a stale plan actively misleads. Each plan names the spec sections it
implements rather than expecting an agent to read all of this. Mill works on Mill only after Plan
D, when the kill switch and the log tail exist; before that, it is two unreliable things at once.

### Spike — the permission model

Not a plan. Throwaway code, standalone, first.

Verify that a denied tool call in `claude -p` non-interactive mode is refused and reported to the
agent rather than hanging, and that a stage cannot write `.claude/` when denied from a `--settings`
file outside the worktree. Every layer-1 claim in [Containment](#containment) rests on this, and a
negative result changes the design — so nothing is built on top of it until it is confirmed.

### Plan A — Seams and doctor

- Schema and migrations
- `Mill::Github` over REST and GraphQL, fixture-backed
- `Mill::Claude`: process-group spawn, tee stream-json, accumulate cost, capture session id,
  validate the verdict envelope
- `rake mill:doctor`, and the setup runbook exercised for real

*Demonstrable:* doctor green against a real board; a rake task spawns `claude`, validates a
nonce-stamped verdict, and reports what it cost.

This boundary is deliberate: those two classes are the only ones touching the outside world, so
from here on every plan tests with no network and no tokens.

### Plan B — One run by hand — **the keystone**

- Runner over the `plan` route against scripted verdicts: two-strike rule, rejection predicate
- Spec discovery and branch adoption: `linkedBranches`, the diff-based lookup
- Real stage prompts and `mill-headless` for `triage → plan → review:plan → implement →
  review:code → pr`
- `rake mill:run`

*Demonstrable:* a real PR on `mill-scratch` from a real spec.

No board, no poller, no supervisor, no UI. This retires every integration risk at once while the
system is still small enough to debug by reading stdout. Everything before it is scaffolding;
everything after is automation wrapped around a working core.

### Plan C — Autonomy

- Supervisor: lazy preparation, worktree lifecycle, stale lock removal, concurrency cap,
  process-group kill
- Poller: board reconciliation, author gating, comment cursors, marker rule

*Demonstrable:* set Status to `Ready`, walk away, come back to a PR.

### Plan D — Observe and interrupt

- Roda UI: run list with health and spend, run detail, log endpoint, kill, repo diagnostics
- Blocking, questions, and resume, including the sanctioned counter reset

*Demonstrable:* kill a run mid-stage and confirm nothing was orphaned; an underspecified issue
blocks, your comment resumes it, the run finishes.

### Plan E — Other routes

- `fast` route with `diagnose`
- `iterate` route and the PR triggers

### Not yet planned

Evidence deliverable and deep review. Both are the most likely to change once Mill has actually
been used, so planning them now would be guessing.

## Revision history

**Revision 2 — plan quality, board ingress, honest containment.** Design moved out of Mill
entirely: you produce a reviewed spec interactively, and routes are keyed on what the ticket
already contains rather than on how big the change looks. Labels replaced by a Project board read
as state. The repo watchlist and picker removed — the token is the repo allowlist, the board is
the queue, and preparation is lazy. Deep review's refutation attributed to fresh per-finding
agents with an explicit no-author-in-the-review-path invariant. Osmani's framing moved out of the
opening and into [Why this shape](#why-this-shape), so the pipeline is defined before it is
justified.

**Revision 1 — the adversarial review.** A three-lens review plus a refutation pass produced 62
claims: 14 confirmed, 22 partial, 26 refuted. Four root causes, each fixed at the root:
containment was fictional (`--dangerously-skip-permissions` provides no filesystem confinement);
labels are events and every swap had a crash window; the verdict file was a shared mutable path,
so a crashed stage inherited its predecessor's `ok`; and three of five triggers had no route, no
identity, and no cursors.

## Sources

- [The Software Factory — alexop.dev](https://alexop.dev/posts/the-software-factory/)
- [Software Factories — Addy Osmani](https://addyosmani.com/blog/software-factories/)
- Claude Code quickstart v2.0 (local, `~/Downloads/Claude Code quickstart (3).md`)
- Vorflux landing page text — `tmp/vorflux-landing.md` (untracked scratch)
- Branch deploy options — `docs/reference/branch-deploy-options.md`
