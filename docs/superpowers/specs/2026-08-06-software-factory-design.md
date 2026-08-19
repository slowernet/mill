# mill — a software factory

Design doc, begun 2026-08-06. Git holds the history of how it changed.

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
  - [Skills mill borrows, and skills mill owns](#skills-mill-borrows-and-skills-mill-owns)
  - [Finding the spec](#finding-the-spec)
  - [Stage prompts](#stage-prompts)
- [The stage contract](#the-stage-contract)
- [The attempt ledger](#the-attempt-ledger)
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

Every stage ends with a nonce-stamped verdict. When a reviewer raises a `high` or `critical`
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
   stage, correct invocation, correct nonce.
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

**Stack.** Ruby, Roda, Sequel, SQLite, Puma, Minitest, and Faraday for the OAuth exchange — stdlib
for everything else. mill runs on macOS and Linux; the OS-specific facts it needs sit behind one
platform module, listed in [Sleep and wake](#sleep-and-wake).

Surveyed and deliberately rejected, so it need not be re-argued: a **state machine gem** (AASM,
Statesman, MicroMachine) — the six run statuses are a case statement, and the stage graph is a
route with conditional re-entry rather than an FSM, so a DSL would obscure the two-strike and
rejection rules that are the interesting part; Statesman specifically would duplicate
`stage_attempts`, which already is the transition log. A **subprocess gem** (`process_executer`)
— healthy and its `MonitoredPipe` matches mill's tee well, but it documents no process-group
support and its timeout is elapsed rather than awake time, so it would cover the easy half of
`Mill::Claude` and split the pgroup lifecycle, awake clock, descendant reap, and boot-epoch check
across two codebases. **`sys-proctable`** for pid start times and descendant enumeration — last
released December 2022, and a stale native gem is the wrong dependency for the one path that must
be correct; `ps` and `pgrep` from the supervisor, which already shells out to git, are enough.
A **scheduler** and **concurrent-ruby** — mill has two threads and about three timers.

The one open call is **`retriable`** (actively maintained, tiny, randomised exponential backoff)
against a dozen-line `with_backoff` helper. mill needs backoff in roughly three places. Either is
defensible; pick one before Plan A rather than growing both.

**Paths.**

```
~/.mill/mill.db                                  state
~/.mill/settings/<stage>.json                    permission rulesets, outside every worktree
~/.mill/secrets/                                 stage token, per-repo env files
~/.mill/worktrees/<repo>/<run-id>/               one worktree per run
~/.mill/runs/<run-id>/verdict-<stage>-<invocation>.json   verdicts, written by mill
~/.mill/logs/<run-id>/<stage>-<invocation>.jsonl          raw stream-json per attempt
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
sweep every new issue onto the board.

`mill:doctor` should assert they are off, but **it is not yet known whether the Projects v2 API
exposes whether a built-in workflow is enabled**. Five minutes against the GraphQL schema settles
it, and that is a gate on Plan A. If the field does not exist, doctor cannot check it directly and
falls back to two things that are implementable: the setup runbook lists disabling the workflows as
a step you confirm, and mill notices after the fact — a Status it did not write, changing under a
run it owns, is reported as board interference rather than silently obeyed. A check the document
promises but nothing implements is worse than one that admits its limits, because months later you
re-enable "item closed → Done" and the sentinel that was supposed to catch it was never there.

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
| Comment opening with `mill:` on a mill PR | Iterate on the branch | comment poll |
| PR review comment | Address the feedback | review-comment poll |
| Required checks red on a mill PR | Fix the failure | check poll on open mill PRs |

**Two rules stop these from firing on each other.**

**Board Status decides which trigger a comment is.** A blocked run on a PR subject matches two
rows at once — the item is `Blocked` and it is also a mill PR. Status wins: while an item is
`Blocked`, every comment on it is an answer, and none of them starts a new run. Without this rule
your answer would try to start a second run, the uniqueness index would refuse it, the event would
retry until it died, and the blocked run would sit waiting for an answer that had already arrived.

**A plain PR comment starts nothing.** An iterate run needs a comment whose first line begins
`mill:` — everything after the marker is the instruction. Ordinary conversation on a mill PR is
ignored and logged. Without this, "LGTM, merging after lunch" starts a full pipeline that either
blocks and posts clarifying questions back at your compliment or goes off and implements it, and a
three-comment discussion spawns three runs. Review comments and red CI need no marker, because
neither is ambiguous: a review comment is already a request for a change, and a red check is a
fact.

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

**Triage defaults to blocking.** It has no reviewer, runs the cheapest model, and its decision
determines whether the pipeline runs at all. The prompt tells triage to
route to `fast` only when the issue is unambiguously a crash, a lint violation, or a dependency
bump — one narrow category with no judgment call. Anything uncertain blocks. This is mill's
general principle ("the line can always stop") made explicit for the one stage where a wrong
answer has the largest blast radius.

Triage also runs the scope check: a spec that describes several independent subsystems blocks
here, at Sonnet cost, with a suggestion to split — before an Opus plan stage is spent
discovering the same thing.

**Scale is steered upstream too.** One spec produces one plan, one run, one pull request, so an
epic becomes a *sequence* of specs — each independently shippable, each on its own issue and
branch, released in order. mill does not stack branches: a spec that depends on an unmerged PR
waits for the merge. There is deliberately no numeric task cap, because task sizes vary too much
for a count to mean anything; the planner blocks and proposes the split when a decomposition
would not fit one readable PR or implement's time budget. The size check lives in the spec
standard (`docs/reference/spec-standard.md`), where it costs seconds, rather than being
discovered downstream, where an oversized plan fails slowly — implement gets roughly two
30-minute launches before its strikes run out, so a plan too big for that window burns strikes
on healthy work.

Routes are keyed on **what the ticket already contains**, not on how large the change looks.
Size is only a proxy; what determines whether an agent can execute reliably is whether it
knows what to do.

### Stages, models, and skills

| Stage | Model | Toolset (`--tools`) | Mode | Skill invoked | Produces |
|---|---|---|---|---|---|
| `triage` | Sonnet | `Read,Glob,Grep` | default | none | route, actionability |
| `plan` | Opus | `Read,Glob,Grep,Write,Skill` | `acceptEdits` | `superpowers:writing-plans` | `docs/superpowers/plans/<date>-<slug>.md` |
| `review:plan` | Opus | `Read,Glob,Grep,Skill` | default | `adversarial-reviewer` | objections |
| `diagnose` | Opus | `Read,Glob,Grep,Bash,Skill` | default | `superpowers:systematic-debugging` | root cause, recorded in the PR body |
| `implement` | Opus | `Read,Glob,Grep,Write,Edit,Bash,Skill` | `acceptEdits` | `mill:implement` | code + tests |
| `implement:fast` | Opus | `Read,Glob,Grep,Write,Edit,Bash,Skill` | `acceptEdits` | `superpowers:test-driven-development` | code + tests |
| `review:code` | Opus | `Read,Glob,Grep,Bash,Skill` | default | `adversarial-reviewer` | objections |
| `pr` | Opus | `Read,Glob,Grep,Bash,Skill` | default | `mill:pr` | pull request |
| `push` | Opus | `Read,Bash` | default | none | pushed commits on an existing PR |

Sonnet for cheap mechanical passes, Opus for judgment and code. No user-facing toggle; you
change the map by editing config.

The toolset column is the fail-closed half of [Containment](#containment) layer 1, so it is
deliberately mean. Four stages get no write tool at all, which makes a whole class of deny rule
unnecessary for them: `review:plan` cannot modify the plan it is reviewing no matter what its
prompt says. `review:code` and `diagnose` get Bash because they need to run the test suite, and
that is where the command-level deny rules earn their place. Only `implement` and
`implement:fast` can both write files and run commands, and those two are where a reviewed
ruleset matters most.

**`Skill` is in every toolset that names a skill**, because `--tools` gates it like any other
tool. Measured 2026-08-19 on CLI 2.1.227: a stage run with `Read,Glob,Grep` reported it had no
Skill tool and named the three it did have, so it could not load `writing-plans`,
`adversarial-reviewer`, or anything else; adding `Skill` made it work first try. Without this
the design's whole skill-per-stage column was decorative — every stage would have improvised
from memory instead of following the skill, silently and at full cost. `triage` and `push` name
no skill, so they do not get the tool.

**The three stages that write files run `--permission-mode acceptEdits`.** In headless `-p` under
the default mode there is nobody to answer a write prompt, so *every* file write is refused —
measured on a file with no rule against it at all. Without the flag `implement`
could not have created a single line of code; it would have burned both strikes and blocked, on
every run. `acceptEdits` is not `bypassPermissions`: the same probe confirmed `Edit(.claude/**)`
and `Edit(.github/workflows/**)` still blocked while an ordinary file was edited, so deny rules
keep binding and the prohibition on `--dangerously-skip-permissions` stands untouched. Reads and
Bash need no such flag — both work under the default mode.

`implement` and `implement:fast` differ by whether a plan exists — `mill:implement` works through
one, `test-driven-development` does not need one. That distinction tracks the real difference
rather than a guess about change size.

mill passes every stage its predecessors' verdicts and artifact paths. It passes a reviewer the
artifact under review plus the diff to date, and passes `review:code` the plan as well, so that
reviewer can check the code against what the plan promised.

### Skills mill borrows, and skills mill owns

Five stages borrow an existing skill's text unchanged, because the skill does a self-contained job
that mill has no opinion about: `writing-plans` for `plan`, `systematic-debugging` for `diagnose`,
and `test-driven-development` for `implement:fast` — all three from Superpowers — plus the personal
`adversarial-reviewer` for both reviewer stages. Unchanged means the skill file itself: the stage
prompt wrapped around it may add mill-specific instructions, and the reviewer stages use exactly
that to add three extra lenses (buildability, simplicity, codebase alignment) without forking the
skill. The beat-by-beat extraction — what each stage does and which skill each practice comes
from — is `docs/superpowers/specs/2026-08-18-sdlc-beats.md`.

**Two stages need mill's own skill**, because the Superpowers versions are built to be driven by a
human sitting in a terminal and they collide with mill's graph rather than fitting inside it.

`implement` was to use `executing-plans`. That skill opens by telling the agent to use
`subagent-driven-development` instead whenever subagents are available, which in Claude Code they
are — so the stage would load a skill whose first instruction is to load a different one. It could
not follow that instruction anyway: dispatching subagents needs a tool `implement`'s toolset
deliberately withholds. The skill also begins by creating a worktree, which mill already created
and handed it, and ends by requiring `finishing-a-development-branch`, so `implement` would try to
open the pull request itself — before `review:code` had ever run. Taking the other fork is worse:
`subagent-driven-development` carries its own five-round fix loop and its own reviewer, so a single
mill stage would run a second retry ledger that mill's own ledger cannot see.

`pr` was to use `finishing-a-development-branch`. Its central step presents a menu, and the first
option on that menu is merging to the base branch locally. mill's first rule is that it never
merges. The skill also asks the operator to confirm the base branch, and its whole shape — verify,
present options, execute the human's choice — assumes the human that mill does not have. Nothing
in mill should hand a stage a menu containing the one action mill forbids and rely on the agent
declining it.

**What `mill:implement` keeps**, because these are the practices that make the Superpowers
versions good and none of them need a human:

- **One task at a time, from its own brief.** Exact values — signatures, magic strings, test cases
  — come from the plan text verbatim, and the stage does not re-read the whole plan for each task.
- **Test-driven per task**, on the same iron law `test-driven-development` states: no production
  code without a failing test first, and a test you did not watch fail proves nothing.
- **Evidence, not assertion.** A task is done when the report carries the covering tests, the
  command run, and its output. "Tests pass" without the output is the same failure as a stage that
  produces no verdict.
- **Self-review before reporting.** Cheap, and it catches the sloppiness that would otherwise cost
  a whole review stage and a strike.
- **A commit per task**, which gives mill a recovery map that survives anything the process does.
- **Stop, don't guess.** A blocker, an unclear instruction, or a plan gap ends the task in
  questions rather than an improvisation.

**What it drops:** creating a worktree, opening the pull request, dispatching subagents, running
its own review-and-fix loop, choosing models, and every gate that waits on a human. mill owns all
of those.

**The plan file is the ledger.** `mill:implement` runs one process across an entire plan, so its
context can compact halfway through — and an agent that has forgotten which tasks it finished is
the most expensive failure this shape has. `writing-plans` already emits tasks as checkboxes, so
`mill:implement` ticks each one off in the plan file in the same commit as the task's work. The
record is then in git, survives compaction and resume alike, needs no file outside the worktree,
and lands in the pull request showing exactly what was done.

**mill overrides the header `writing-plans` mandates.** Every plan that skill writes carries a line
telling its executor to use `subagent-driven-development` or `executing-plans` — so left alone,
mill's `plan` stage would produce a document instructing mill's `implement` stage to load the two
skills it must not. The `plan` stage prompt replaces that header with one naming `mill:implement`.

**How a stage receives its skill, and where mill's own two live.** `Skill` is itself a tool gated
by `--tools`, measured 2026-08-19: a stage without it cannot load any skill and says so. So every
stage that names a skill carries the tool, and `--settings` merging rather than replacing means
those stages also inherit the operator's `enabledPlugins`, so `superpowers:` names resolve without
mill enumerating anything.

The cost is real but acceptable: `Skill` can load *any* skill on the machine, including the two
this section removed, so the toolset no longer bounds what instructions a stage can pull in. Three
things make that a fair trade. Instructions are not capability — a skill telling `implement` to
dispatch subagents cannot make it happen when `Task` is absent from `--tools`. The stage prompt
names its skill explicitly. And verdict validation catches a stage that wandered off and produced
the wrong artifact. Baking skill text into prompts would keep the toolsets tighter at the cost of
forking every borrowed skill, which the non-goals rule out.

mill's own two live in a plugin directory inside the mill repo — version-controlled and reviewed
alongside the code, outside every worktree so a stage cannot edit the instructions it runs under,
and outside `~/.mill`. That also makes the `mill:` prefix real, since a plugin's name is its
prefix. Each is self-contained in a single `SKILL.md` rather than the multi-file shape Superpowers
uses, so a stage never has to Read a supporting file.

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
ships `mill-headless`, loaded by every stage, which redefines every interactive gate the
borrowed skills assume: where a skill would ask you and wait, it writes the question into the
verdict and stops.

That job is much smaller than it was. `brainstorming`'s per-section approval gates were the
hardest thing to simulate headlessly, and moving design upstream deletes the need entirely. What
remains is a handful of ordinary questions: `writing-plans` asking for critique of the design,
`test-driven-development` asking before it skips tests for generated or throwaway code, and
`systematic-debugging` asking when it cannot establish a root cause. Each maps onto block-and-ask
directly. The two skills whose gates could not be mapped this way — one that hands the operator an
integration menu, one that asks which of two executors should run — are the two mill replaced with
its own; see [Skills mill borrows, and skills mill owns](#skills-mill-borrows-and-skills-mill-owns).

The stage prompt owns the verdict envelope; `mill-headless` owns what goes in `questions`.

## The stage contract

Every attempt is one `claude -p` subprocess in its own process group. The first launch of a stage
is always a fresh session. A relaunch — whether triggered by a failure, a crash, or a reviewer's
objection — resumes the session with `claude --resume <session-id>`, so the agent remembers its own
work. The one exception is a verdict that failed validation: mill has no trustworthy account of
what happened, so it starts a fresh session. If `--resume` fails for any reason, mill falls back to
a fresh session with the prior context appended. [The attempt ledger](#the-attempt-ledger) says
what each of those endings costs.

**The verdict is the stage's last message, not a file it writes.** Stages run with
`--output-format stream-json`, `Mill::Claude` already parses that stream, and the verdict is the
final structured message on it. mill validates that message and then writes it itself to

```
~/.mill/runs/<run-id>/verdict-<stage>-<invocation>.json
```

so a crashed run is still readable afterwards. The agent never touches that path.

The first draft had the agent write the file. That made the toolset table and this contract
contradict each other: `triage` and `review:plan` hold only `Read`, `Glob`, and `Grep`, so neither
can create a file, and every route begins with `triage`. It also forced a hole in containment,
because a stage that can write into `~/.mill` can write to its own permission ruleset there. Moving
the verdict onto the stream closes both at once — no stage needs a write path outside the worktree,
and mill can deny `~/.mill` outright. The reason the verdict lives outside the repo is unchanged:
mill is the only writer, so no stage can commit a verdict and no later checkout can restore one.

```json
{
  "stage": "plan",
  "invocation": 1,
  "nonce": "8f3c1a…",
  "status": "ok" | "blocked" | "failed",
  "artifact": "docs/superpowers/plans/2026-08-06-foo.md",
  "route": "plan" | "fast" | null,
  "questions": ["Should deleted users keep their comments?"],
  "objections": [{ "severity": "critical|high|medium|low", "claim": "…", "notes": "…" }],
  "summary": "one paragraph for the log and the PR body"
}
```

mill validates before accepting:

- A stage that ends without a final structured message has failed. Silence is never success.
- `stage`, `invocation`, and `nonce` must match this spawn. mill generates a fresh nonce each
  time and passes it in the prompt.
- `artifact`, if present, must resolve inside the worktree, must not traverse a symlink, must
  match the stage's declared pattern, and must exist and be non-empty.
- `questions` must be non-empty iff `status` is `blocked`.
- `objections[].notes` is the reviewer's full argument — file paths, line numbers, reasoning.
  `claim` stays short for mill's own decision logic; `notes` is what the coding agent and you
  both read. mill posts each objection's notes as a PR comment through `Mill::Github` once the
  PR exists.
- mill accepts `route` only from `triage`. The `Evidence` directive is the board's alone; see
  [Evidence requirement](#evidence-requirement).

mill fails the attempt on any violation, and a failed validation is one of the endings that costs
a strike.

The first draft had every stage write to one fixed path, reused and never cleared. Two independent
reviewers found the consequence: when a stage died without writing, mill read its predecessor's
`{"status":"ok"}` and passed it, so a crashed adversarial reviewer looked as though it had
approved the code. The nonce is what makes that unrepresentable, and it does that work whether the
verdict arrives as a file or as a message — a stage cannot forge a nonce it was never given, and
cannot replay one from a previous launch.

The trade this makes: the stage's prompt must demand the verdict as the last thing it emits, and a
stage that adds a closing paragraph after its JSON fails validation. That is a loud, immediate
failure in the first minute of the first run rather than a quiet one months in, which is the right
way round.

`pr_number` is deliberately not in the verdict. mill recovers it with
`gh pr list --head <branch>`, which is idempotent, so a crash between `gh pr create` and the
state write reconciles instead of opening a second PR.

`Mill::Claude` accumulates four token counts from per-message `usage` as it tees, persisting
running totals so a killed attempt retains its partial count. mill tracks tokens across every part
of the graph — per attempt, per stage, and per run — so it can present historical averages and,
eventually, cost estimates for per-token billing.

**Record all four counts, not just in and out.** A trivial spike prompt reported `input_tokens: 3`
against `cache_read_input_tokens: 7182` — cache reads dominated real input by three orders of
magnitude. Recording only `tokens_in`/`tokens_out` would understate token flow by roughly 99% and
make any later cost model meaningless, because cached input is priced differently from fresh
input. The `result` line also carries a `total_cost_usd` figure, which is notional on a
subscription rather than something you are billed, but is a free input to an estimate model.

**Rate limits are the real ceiling, so record them.** The stream carries a `rate_limit_event`
message type. On a subscription the binding constraint is not money but throughput, and a stage
that stalls behind a rate limit looks exactly like a stage that is thinking. `Mill::Claude` stamps
`rate_limited_at` when it sees one, both the stall detector and the per-launch clock treat a
rate-limited attempt as waiting rather than wedged, and the UI surfaces it — otherwise mill would
kill a healthy stage that was only queued behind a limit.

## The attempt ledger

Every recovery path in mill ends here. This section is the single definition of what an attempt is
and who pays for one, because the 2026-08-13 review found the same hole from six directions: the
rules lived in fragments that disagreed, and the fragments are the control plane for the whole
pipeline.

**mill counts two separate things.**

**The invocation number** counts how many times mill has launched a stage during a run. It goes up
on every single launch, with no exceptions. It names the log file and the verdict file, and it is
the number stamped in the verdict envelope, so no two launches of one stage can be confused for
each other or overwrite each other's record.

**The strike count** is the two-strikes rule. It goes up only when the stage's own work was judged
bad. At two strikes the run blocks.

Keeping them apart is what makes the ordinary case expressible at all. `review:code` crashes,
gets relaunched, and finds a serious problem; `implement` fixes it; the code now has to be
reviewed again. Under one number the reviewer had already spent both its attempts and mill would
block a perfectly healthy run — and two clean reviews would both call themselves attempt 1 and
write to the same place. Under two numbers the reviewer is on invocation 3 with one strike, which
is exactly the truth.

**What each ending costs:**

| How the launch ended | Invocation | Strike |
|---|---|---|
| Stage reported `failed` | +1 | +1 |
| Stage crashed, or exited non-zero | +1 | +1 |
| No verdict, or one that failed validation | +1 | +1 |
| Artifact missing, empty, outside the worktree, or off-pattern | +1 | +1 |
| Reviewer raised a `high` or `critical` objection | +1 to the reviewed stage | +1 to the reviewed stage |
| Stage reported `blocked` with questions | +1 | none |
| Reviewer finished and raised nothing serious | +1 | none |
| Stall recovery killed and resumed it | +1 | none |
| `--resume` failed, so mill started fresh with the context appended | +1 | none |
| mill restarted and interrupted it | +1 | none |
| A stale git lock was cleared before it ran | n/a | none |
| It is waiting behind a rate limit | no launch | none |

The rule behind the table: **a strike means the work was wrong. Everything the machine did to a
stage is free.** A laptop that slept, a socket that died, a lock file left by a SIGKILL, and mill
restarting are all mill's problems, not the stage's, and charging the stage for them produces
exactly the failure that destroys trust — a run that dies for a reason you cannot reconstruct from
the log.

**Asking a question is free.** A stage that stops and asks is working correctly; that is the whole
point of "the line can always stop". If asking cost a strike, a stage that legitimately needed two
rounds of questions would exhaust itself by doing its job.

**Free is not unlimited.** Every strike-free path has its own cap, so nothing can loop forever:
stall recoveries are capped per launch, interruptions are capped per stage, and the total
invocations for one stage in one run are capped well above any legitimate sequence. Hitting any of
those caps blocks the run and says which cap it was.

**The reviewer has its own counters.** A reviewer that crashes or returns an unusable verdict is
the reviewer failing to review, and it strikes the reviewer. A reviewer that finds something
serious is the reviewer succeeding, and it strikes the stage it reviewed. Two serious objections
against `implement` means `implement` has used both its strikes and the run blocks. Without a rule
this explicit, one implementer rejects on any objection at all — and since the reviewer skill
assumes defects exist, nearly every run blocks — while another treats objections as advisory and
gates nothing.

**The one sanctioned third strike.** When a stage runs out of strikes, mill blocks and asks. If
you answer, mill resets that stage's strike count to zero and records that it did so for that
stage. Each stage may be reset once per run, so a run is never trapped by a reset it spent on some
earlier stage. If a stage runs out a second time, mill sets Status to `Failed` and stops. This is
the only path to a third strike, and it requires a human.

## Containment

mill **does not** use `--dangerously-skip-permissions`. That flag is
`--permission-mode bypassPermissions`, and since working directories and `--add-dir` are
permission-system concepts, skipping permissions leaves no filesystem confinement for Read,
Write, or Edit at all. Autonomy comes from an explicit ruleset instead, in four layers.

**1. The working directory, a restricted toolset, and deny rules.** This layer has three
mechanisms, and the 2026-08-19 probes established that they do very different amounts of work.

**The working directory is the filesystem boundary, and it is fail-closed.** A stage cannot read
or write outside the worktree it was given, whether or not any rule says so. Measured with an
*empty* deny list: a stage refused both to read and to write a file in `~`, reporting the path as
outside its allowed directory. This is the strongest thing in layer 1 and the design previously
credited it to the deny rules instead. It also means the `~/.ssh`, `~/.aws`, `~/.config/gh`, and
`~/.mill` protections are already in force before any ruleset is read.

`--tools` decides which built-in tools exist at all for a stage. A tool absent from the list
cannot be called — the agent reports it has no such tool and adapts. **Also fail-closed**, and
the reason four stages cannot modify anything no matter what their prompt says.

`--settings ~/.mill/settings/<stage>.json` carries **deny** rules that scope paths and commands
*within* the worktree and within the tools that remain. Deny rules work at command level
(`Bash(curl:*)` blocks curl while `echo` runs) and on worktree-relative paths. **This part is
fail-open** — anything not denied is permitted.

**Deny rules must be worktree-relative. An absolute path silently does nothing.** Measured in one
run, with `Bash(curl:*)` in the same file proving the file was loaded: `Read(/tmp/probe/a.txt)`
did not block, `Read(//tmp/probe/b.txt)` did not block, and `Read(c.txt)` blocked correctly. This
is the same failure shape as `Write(...)` versus `Edit(...)` — a rule that looks right, is
accepted without complaint, and enforces nothing. Nothing outside the worktree needs a rule
anyway, because the working directory already covers it; the danger is a future maintainer writing
an absolute deny and believing it protects something. `mill:doctor` rejects any absolute path in a
ruleset, and the boundary suite has a regression test for it.

An `allow` list does **not** confine. In headless `-p` it is advisory, pre-approving things so
they skip a prompt; a tool absent from `allow` and absent from `deny` runs anyway. Anyone reading
this ruleset should not mistake `allow` for a boundary.

So: **strip the toolset as far as each stage allows**, and treat deny rules as scoping *inside* an
already-closed box rather than as the box itself. The doc's own critique of denylists — that one
"measures only the bypasses its author imagined" — applies to this third mechanism. The first two
are boundaries; command and path scoping is a best effort.

Every stage denies the same things, all worktree-relative: `Edit(.claude/**)`, `Edit(.mill.yml)`,
`Edit(.github/workflows/**)`, `Edit(.github/actions/**)`, reads of `.env` and `.env.*`, and every
`gh` subcommand except the narrow set `pr` and `push` require. Both `Edit(.claude/**)` and
`Edit(.github/workflows/**)` were confirmed to block under `acceptEdits` while an ordinary file in
the same run was edited successfully.

**`~/.mill` needs no rule, and must not be given an absolute one.** No stage has any business
there — the verdict travels on the stream and mill writes it — and the working directory already
makes it unreachable. The settings file was moved out of the worktree precisely because an agent
that can write its own rules can disarm itself mid-session; what actually keeps it out of reach is
that it sits outside the worktree, not a deny rule naming it.

**Write file denies in the `Edit(...)` form, never `Write(...)`.** Claude Code matches file
permission checks against `Edit(path)` rules only, and `Edit` rules cover every file-editing
tool including Write. A `Write(.github/workflows/**)` rule silently does nothing — the spike
confirmed a workflow file was modified under exactly that rule, and blocked under the `Edit`
form. Claude Code emits a warning when it sees the wrong form; `mill:doctor` should treat that
warning as a failure.

**Every stage also runs with `--strict-mcp-config` and no `--mcp-config`.** `--tools` restricts
built-in tools only; without this flag a stage inherits whatever MCP servers the operator has
configured. On the machine this was spiked on, that included a Google Drive connector. mill's
stages need no MCP servers at all.

The settings file lives outside the worktree because a stage that could write `.claude/` would be
picked up by the settings watcher and could disarm its own restrictions *mid-session*. Being
outside the worktree is what enforces that, with `Edit(.claude/**)` as a second line inside it.

**`--settings` merges with your own settings; it does not replace them.** Measured: with a mill
ruleset passed, its `Bash(curl:*)` deny bound *and* the operator's `enabledPlugins` still applied,
so `superpowers:` skills resolved normally. That is what makes the skill-per-stage design work at
all — mill does not have to enumerate plugins. Two consequences worth knowing: a stage inherits
the operator's `SessionStart` hooks, including the Superpowers one that urges aggressive skill
hunting, and a change to `~/.claude/settings.json` can change stage behaviour. `mill:doctor`
records the resolved skill source and version per attempt so a verdict can be traced back to the
text that produced it.

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
resume mechanism used for a relaunch after a failure or a reviewer objection — the only
difference is what gets injected. Verified: `--resume` returns the *same* session id (a new one
requires `--fork-session`), and a transcript whose last record is a `tool_use` with no matching
`tool_result` — the state a SIGKILL produces — resumes successfully, because the CLI repairs
the dangling call. If `--resume` fails for any reason, mill re-runs the stage from scratch with
the full context appended; that costs an invocation and no strike.

**Some blocks happen before any stage has run**, and those resume differently. An unprepared repo,
a missing secrets file, more than one spec on the branch, or a branch already checked out
somewhere else all block the item before mill has launched anything, so there is no session to
resume. When you answer one of those, mill re-checks the condition and, if it now passes, starts
the run from the top of the graph. Nothing was lost, because nothing had happened yet.

A run that blocks because a stage **ran out of strikes** differs again: answering resets that
stage's strike count, under the rule in [The attempt ledger](#the-attempt-ledger).

## Back-pressure

**Two strikes per stage, then block.** When a stage fails, crashes, times out, or a reviewer
rejects it, mill resumes the session with the failure or the reviewer's notes injected. The agent
wakes up remembering its own work and reads what went wrong. If that goes badly too, mill posts
both and blocks. The one exception: when the verdict itself was untrustworthy, mill starts a fresh
session instead of resuming, because there is no reliable account of what the first launch did.
[The attempt ledger](#the-attempt-ledger) is the full accounting.

**What counts as rejection.** A reviewer returns `status: ok` with `objections`; it does not
fail. mill re-runs the reviewed stage iff any objection is `high` or `critical`, and records
lower severities in the PR body.

**Limits, config, with these defaults:**

| Limit | Default |
|---|---|
| Concurrent runs | 3 |
| Working time per launch | 30 min of awake time, excluding rate-limit waits |
| Silence before mill calls a stage wedged | 5 min of awake time, excluding time inside a running command |
| Ceiling on any single command | 45 min of awake time |
| Stall recoveries per launch | 2 |
| Interruptions per stage | 3 |
| Invocations per stage per run | 8 |
| Settle window after a wake | 90 s of awake time |
| CI fix runs per PR per failing commit | 2 |
| Runs per subject per 24h | 6 |

**A quiet stage is not necessarily a stuck stage.** A stage running a six-minute test suite emits
nothing at all while the suite runs, which looks identical to a stage frozen on a dead socket. The
five-minute silence window would kill it, kill it again on the resumed launch, and block the run —
so every repo with a slow suite would break at `implement` and `review:code` permanently, and the
detector meant to catch wedged stages would be reliably killing healthy ones instead.

The stream distinguishes them. A stage announces a command before it runs it and reports the
result when it finishes, so mill knows whether a command is outstanding. While one is, the silence
window is suspended and the per-command ceiling applies instead; with no command outstanding, five
minutes of silence still means wedged. **This needs one behavioural check during Plan A**: confirm
the tee sees the command announced as it starts, not only when it completes. If it does not, the
silence window has to be raised to the per-command ceiling for every stage holding `Bash`, and the
detector gets much weaker for those stages.

**A rate-limited stage is waiting, not working.** On a subscription the rate limit is the real
ceiling, and a stage queued behind one can sit far longer than half an hour. Both deadlines that
could kill it — the silence window and the working-time clock — stop counting while
`rate_limited_at` is current. Otherwise three concurrent Opus runs hitting the limit would time
each other out, twice each, and fail runs that were never unhealthy.

The per-launch clock uses `Process::CLOCK_UPTIME_RAW`, which is documented not to advance during
sleep, while `CLOCK_MONOTONIC` and wall clock both count it on Darwin. Closing the lid mid-stage
would otherwise reap a healthy attempt as a timeout — twice, on the only deployment target mill
supports. **That difference is an untested claim, and all of [Sleep and wake](#sleep-and-wake)
rests on it**; see the measurement gate in [Build order](#build-order).

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
   once and the Runner is deterministic Ruby that cannot judge similarity itself. Like every agent in the
   fan-out it returns a nonce-stamped structured message that mill validates, but it is not a
   full stage and has no strike count of its own. mill records its session id and tracks its
   tokens on the run, so it shows up in the UI and PR body alongside the finders and refuters.
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

**No agent ever reviews something it wrote**, and no refuter sees what its siblings found.
Authoring gives an agent a stake in the verdict, and reading a sibling's finding anchors the next
one. mill gets this for free, because a stage's session is gone by the time anything reviews its
artifact.

**When a sub-agent dies.** The fan-out is not exempt from "silence is never success", so each part
has a stated answer rather than whatever the implementer happened to code:

- **A finder dies.** Its facet produced nothing, which is not the same as finding nothing. mill
  relaunches it once; if it dies again, the review stage fails and takes a strike, because a
  review missing a facet is not the review that was asked for.
- **The deduplicator dies.** mill relaunches it once, then falls back to treating every finding as
  distinct. Duplicate objections are noisy but safe; dropping findings is not.
- **A refuter dies.** Its finding **survives** and becomes an objection. A refuter's job is to
  knock a finding down, and a refuter that never ran knocked nothing down. Erring the other way
  would let a crash quietly delete a real defect.

Each sub-agent gets the same per-launch clock and stall detection as a stage. None gets its own
strike count — they roll up into the review stage's, because the review stage is what mill retries.

**Refuters on `review:code` work in a throwaway copy.** A refuter has to write a failing test to
confirm a finding, which means it needs write tools that `review:code` deliberately lacks. It gets
them in a second worktree at the same commit, thrown away afterwards, so nothing it writes can
reach the run's branch and the no-reviewing-your-own-work rule still holds.

**Deep review has a ceiling.** A fan-out is roughly six Opus invocations per review stage, and it
can run again after a fix, so one run can spend a lot quietly. mill caps the fan-out at eight
sub-agents per review stage — the facet selector, at most four finders, the deduplicator, and
refuters — and when there are more findings than refuter slots it refutes the highest severities
first and records in the PR body how many went unrefuted. A cap that silently drops work would
read as "nothing else was found", which is the failure this whole section exists to avoid.

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

**The board field is the only thing that turns this on.** Triage used to be able to request
evidence in its verdict too, which meant two independent switches with no rule about which won —
and the guard below, which stops a sample being published from a public repo, keys on *your*
field. Triage setting the flag could therefore have published a sample the guard was meant to
gate. Directives are yours; triage decides the route and nothing else.

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
               strike_resets_json, desired_board_status, board_status_at,
               pr_number, created_at, finished_at
               -- unique index on (repo_id, subject_kind, subject_number)
               --   where status in ('running','blocked')

stage_attempts id, run_id, stage, invocation, model, session_id, nonce,
               status, strike_charged, verdict_json, tokens_in, tokens_out,
               cache_creation_tokens, cache_read_tokens, rate_limited_at,
               log_path, pid, pgid, pid_started_at, host_boot_at,
               last_output_at, pending_tool_at, stall_recoveries,
               started_at, finished_at

ci_fixes       repo_id, pr_number, head_sha, runs_started
               -- primary key (repo_id, pr_number, head_sha)

events         id, repo_id, kind, gh_node_id (unique), payload_json,
               attempts, last_error, state, created_at, processed_at
```

Run statuses: `running`, `blocked`, `done`, `failed`, `killed`. There is no `queued` — mill inserts
a run as `running` in the same transaction that claims the item, so nothing is ever queued, and the
concurrency cap counts `running` rows only.

`repos` is a cache of prepared state, not a watchlist — no `enabled` column, because nothing is
enabled or disabled.

`strike_resets_json` is a list of stage names, not one name, because the reset is once *per stage*.
A single column could record only one, which would silently fail a run whose `plan` was reset
earlier and whose `implement` later ran out with a reset it was entitled to.

`ci_fixes` is what stops a permanently red PR grinding forever. Each fix run is a whole new run
with its own fresh counters, so nothing inside a run can bound them; the count has to live outside
one, keyed to the PR and the commit that is failing. After two, mill comments that it cannot fix
the failure and stops. A new commit is a new key and gets a fresh budget. Without this the only
bound is six runs per subject per day, resetting daily — a flaky test or a missing CI secret would
buy six full Opus pipelines a day indefinitely, each one reporting success.

`desired_board_status` is what mill last decided the board should say, and `board_status_at` when
it last confirmed it. Setting Status is a network call that can fail, and nothing else re-drives
it: the poller only ever asks which items are `Ready`. So a run that blocks, finishes, or fails
while GitHub is briefly unreachable would show `Running` on the board forever, and — because a
comment's meaning depends on board Status — your answer to its questions would not be recognised
as an answer. mill retries any run whose board status it has not confirmed.

`blocked` is inside the uniqueness index: a blocked run must keep guarding its subject because
resume is comment-triggered. SQLite supports the partial unique index this needs.

`events` carries `attempts`, `last_error`, and a terminal `dead` state with a cap, and mill sets
`processed_at` in the same transaction that inserts the resulting run — otherwise an exception
raised after mill marks a comment processed drops your answer with no trace.

mill persists `pgid`, `pid`, `pid_started_at`, and `host_boot_at` when it spawns an attempt.
Three fields are needed rather than one because pids are recycled: after a reboot they restart
low, so a stored pgid of `431` may well be alive and belong to a system daemon. `host_boot_at`
comes from `sysctl -n kern.boottime` on macOS and `btime` in `/proc/stat` on Linux;
`pid_started_at` from the process table on either. Both go through the platform module in
[Sleep and wake](#sleep-and-wake) — this is the one code path where getting the wrong value means
signalling the wrong process.

The runner writes `heartbeat_at`; at boot and on a timer, mill checks every run marked `running`.

**Nothing gets signalled on the strength of the boot time alone.** `kern.boottime` on Darwin is
derived from the current clock, so an NTP correction shifts it — and NTP corrects the clock
routinely on waking from a long sleep. An exact comparison therefore reads a few seconds of clock
drift as a reboot. mill compares with a tolerance of a few minutes, and, whatever the boot time
says, **verifies `pid_started_at` against the live process before it signals anything**. Otherwise
a night with the lid shut ends with mill concluding the machine rebooted, deciding the old process
is "gone for certain", and starting a second stage in a worktree where the first one just thawed
and is still working — two agents in one worktree, reached through the branch built to prevent it.

Three branches, evaluated in this order:

- **No process group alive with a matching `pid_started_at`.** Whether the machine rebooted or the
  process simply died, the attempt is over. Signal nothing, mark it interrupted, re-enter the
  stage. The session id is still in the database, so the next launch can resume it.
- **A matching process group is alive, and mill did not spawn it this instance.** mill restarted
  and the stage kept running. Kill the group, mark the attempt interrupted, and re-enter — two
  agents in the same worktree is worse than losing partial work. At boot mill has no in-memory
  registry, so every live group it finds falls here.
- **A matching process group is alive, and mill spawned it this instance.** Normal operation —
  leave it alone. Only the periodic check reaches this branch.

An interruption costs an invocation and no strike, and is capped per stage. This is the same
evidence and the same treatment whether mill restarted or a runner thread died underneath a live
subprocess: the earlier design made those two cases differ, so an identical stale heartbeat with
no live process failed the run terminally in one telling and re-entered it for free in the other,
distinguished only by something the data does not record.

Heartbeat staleness is measured in awake time. Measuring it in wall time would fail every
healthy run after a night with the lid shut.

`Mill::Claude` writes `last_output_at` as it tees, and `stall_recoveries` counts how often mill
has already rescued that attempt from a dead socket. See [Sleep and wake](#sleep-and-wake).

**Retention.** mill deletes logs and verdicts for finished runs (`done`, `failed`, `killed`)
older than 14 days, and caps each attempt's log by byte count with a truncation marker. Blocked
runs are exempt — their worktrees, logs, and verdicts stay until you answer or kill the run.
`GET /` shows total disk used, and the worktree view (below) lets you clean up manually.

Processed and `dead` rows in `events` are deleted on the same schedule. Nothing else prunes them,
and a comment sweep that runs for months on an active repo would otherwise leave tens of thousands
of rows in the database with nothing in the UI explaining where the space went. The sweep itself is
bounded too: mill fetches comments only for subjects it has reason to care about — items on the
board and open mill PRs — not every issue in every repo the board touches.

## Web UI

Roda and Sequel. Puma defaults to `0.0.0.0`, so mill always binds explicitly, and the bind plus
the `Host` allowlist are config rather than constants because they differ by deployment. Every
POST requires a CSRF token via Roda's `route_csrf`, because the browser treats a cross-origin
form POST as a CORS simple request and does not preflight it.

**Two deployments, two access models.**

On a laptop mill binds `tcp://127.0.0.1:9494` and allows only `localhost:9494` and
`127.0.0.1:9494` as `Host`, which defeats DNS rebinding. Nothing else is needed: the loopback
interface is the boundary.

On a server the UI is reachable over the network, so it needs an identity check of its own.
mill uses Google OAuth with an email allowlist — the same shape as `~/code/rep`: an `AuthApp`
mounted at `/auth`, an `Authentication` helper exposing `current_user`, `logged_in?`, and
`require_login!`, and `MILL_ADMIN_EMAILS` as a comma-separated list checked against the verified
address. mill needs no user table; the verified email in the session is the whole model.

Four things follow, and none is optional:

- **Every route requires an allowlisted session except `/auth/*`.** The write paths are a kill
  switch and a worktree deleter, and `GET /runs/:id/log` streams repo contents.
- **TLS is mandatory**, because Google refuses a non-HTTPS redirect URI for anything but
  localhost. A reverse proxy terminates it; the runbook covers the certificate.
- **The `Host` allowlist gains the deployment hostname.** It is what defeats DNS rebinding, so
  it must be tightened to the real name rather than dropped.
- **The session cookie is `secure`, `httponly`, and `samesite=lax`**, with a stable secret from
  the environment, since a leaked session is a kill switch.

Faraday handles the token exchange and userinfo fetch, matching `rep`.

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
files under the gitdir for its own worktrees, and the ref lock for **whichever branch the run
holds** — not only `refs/heads/mill/*`. A SIGKILL during `git commit` leaves an index or ref lock
that git never cleans, so the next launch would fail instantly on the lock. Scoping the cleanup to
`mill/*` would have excluded the primary route entirely, because a `plan` run works on the branch
`gh issue develop` created and that branch keeps its own name.

**The branch may already be checked out in your clone.** The prescribed workflow leaves it that
way: you run `gh issue develop`, check the branch out, commit the spec, set Status to `Ready`, and
walk away with the branch still current in `~/code/<repo>`. `git worktree add` refuses a branch
that is checked out anywhere, including the clone's own HEAD, so mill's very first claim on its
main route would fail with a git error that fits no other row in the taxonomy — it is not a stale
admin entry, and prune does not touch a live checkout.

So the supervisor checks before claiming, against both `git worktree list` and the clone's HEAD.
If the branch is checked out, mill blocks the item and comments naming the clone and the branch;
you switch back to your base branch and reply. mill does not switch your clone for you and does
not force the worktree — two live checkouts of one branch means a commit of yours and a commit of
a stage's can silently diverge the ref, which is worse than a round trip. The runbook's closing
step for a design session is to switch off the branch before setting `Ready`.

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

**A skip is not silent.** A blocked run holds its branch indefinitely by design, so an item waiting
behind one can wait forever. mill comments once on the waiting subject naming the run that holds
the branch, and shows the item as waiting in the UI. Otherwise you comment a fix request on an old
PR, the item is skipped every tick because a `plan` run you never noticed is blocked on the same
branch, and from your side mill simply ignored you.

One in-process mutex serializes `git worktree add` and ref writes across runners, and retries
with backoff when it hits lock contention. **That mutex covers mill's own git commands only.**
Stages run git themselves, in worktrees that share one gitdir, and you use the same clone from your
terminal — so two stages fetching or committing at once, or you running `git fetch --prune` while a
stage commits, can still collide on `packed-refs`, the fetch lock, or a ref. mill treats a git
failure that names a `.lock` file as transient: it clears the age-checked stale lock, waits with
backoff, and retries the command rather than failing the stage, and only a repeated failure ends
the launch. `gc.auto=0` closes the garbage-collection case specifically and nothing else.

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

**Two platforms, one seam.** mill runs on macOS (a laptop) and Linux (a server), and the four
OS-specific facts it needs sit behind one small platform module rather than being spread through
the supervisor. The clock pair is the trap: the two systems name the *same* semantics with
*different* constants, so a copied line is not merely unportable, it computes sleep backwards.

| What mill needs | macOS | Linux |
|---|---|---|
| Clock that excludes sleep (the awake clock) | `CLOCK_UPTIME_RAW` | `CLOCK_MONOTONIC` |
| Clock that includes sleep (the continuous clock) | `CLOCK_MONOTONIC` | `CLOCK_BOOTTIME` |
| Boot time, for the reboot check | `sysctl -n kern.boottime` | `btime` in `/proc/stat` |
| Process start time, to confirm a pid | `ps -o lstart=` | field 22 of `/proc/<pid>/stat` |
| Keep the machine awake while a stage runs | `caffeinate` | `systemd-inhibit`, or nothing on a server |

A server never idle-sleeps, so most of this section is inert there — but the stall detector is
not, because a dead socket is a dead socket on any host, and it is the mechanism that catches a
wedged stage regardless of cause.

**Measuring the gap.** On Darwin `CLOCK_MONOTONIC` counts time spent asleep and
`CLOCK_UPTIME_RAW` does not, so the difference between their deltas across a tick is exactly how
long the machine slept, with no NTP drift mixed in. Both come from `Process.clock_gettime`, so
this costs nothing beyond the clock the per-launch timeout already reads.

**This is the one claim in the document that nothing has tested**, and this whole section depends
on it. The two clocks are documented to differ in exactly this way — that is why both exist — but
documented is not measured, and no spike has run. If they turn out to behave identically on this
machine, mill cannot detect sleep at all: the settle window never opens, every deadline silently
counts time asleep, and a night with the lid shut reaps every run in flight as timed out, with the
defence apparently in place and doing nothing. The measurement is ten lines and needs someone to
shut a laptop; it is a gate on Plan C in [Build order](#build-order).

Which clock a deadline reads is a correctness question:

| Deadline | Clock |
|---|---|
| Working time per launch | awake |
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
crash. It sits there until the per-launch clock reaps it as a timeout and charges it a strike.

`Mill::Claude` already tees stream-json, so it knows when each live attempt last emitted a line and
whether a command is still outstanding. mill persists those as `last_output_at` and
`pending_tool_at`, and when an attempt has been silent for the window **with no command
outstanding**, mill kills the process group and resumes the session with `--resume`. **That
recovery costs no strike**, for the reason a stale git lock does not: the work did not fail, the
machine did. mill counts recoveries in `stall_recoveries` and blocks once a launch hits the cap, so
a genuinely silent stage cannot recover forever.

**The recovery stays free even when the resume fails.** SIGKILL mid-stream is the likeliest moment
for a session transcript to end up unreadable, so the path that starts fresh with the context
appended is not an edge case here — it is the expected outcome some of the time. Charging a strike
for it would mean the machine failing takes the blame after all, through the back door, which is
what the whole rule exists to prevent. It costs an invocation, and the per-stage invocation cap is
what stops it looping.

Watching for silence rather than watching for sleep means mill needs no special case for waking
at all. It also catches every other way a stage wedges — a Wi-Fi change, a package manager
waiting on a prompt `mill-headless` never saw, a stalled API stream — which the per-launch
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

| Failure | What mill does | Strike |
|---|---|---|
| Stage returns `blocked` | Posts the questions to the subject, sets Status `Blocked`, stops, and resumes when you reply | no |
| Stage returns `failed`, crashes, or exits non-zero | Resumes the session with the failure injected; if that goes badly too, posts both and blocks | yes |
| Verdict missing, malformed, or envelope mismatch | Fails the attempt; the next launch starts a fresh session because mill cannot trust the old one | yes |
| Artifact missing, empty, outside the worktree, or off-pattern | Fails the attempt | yes |
| Reviewer returns a `high` or `critical` objection | Resumes the reviewed stage's session with the reviewer's notes injected; blocks if that happens twice. Posts the notes as a PR comment once the PR exists | yes, against the reviewed stage |
| Reviewer itself crashes or returns an unusable verdict | Relaunches the reviewer | yes, against the reviewer |
| Deep review finder dies twice | Fails the review stage — a review missing a facet is not the review that was asked for | yes |
| Deep review deduplicator dies twice | Treats every finding as distinct and continues | no |
| Deep review refuter dies | The finding survives and becomes an objection | no |
| Issue has no linked branch, or the branch adds no spec | Routes to `fast` if triage judges it hotfix-shaped, otherwise blocks | no |
| Linked branch adds more than one spec file | Blocks and asks which one is the spec | no |
| Spec describes several independent subsystems | Triage blocks and suggests splitting it | no |
| Plan would exceed one readable PR or implement's time budget | The planner blocks and proposes a sequence of smaller specs | no |
| Branch is checked out in your clone | Blocks the item, naming the clone and the branch | no |
| Launch exceeds its working-time cap | Kills the group and fails the attempt | yes |
| Stage emits nothing for the silence window, no command outstanding | Kills the group and resumes the session; capped per launch | no |
| A single command exceeds the per-command ceiling | Kills the group and fails the attempt | yes |
| Stage is rate-limited by Claude | Stamps `rate_limited_at`; both the silence window and the working-time clock stop counting, and the UI surfaces it | no |
| Run exceeds the daily-run limit | Blocks and reports token usage to date | n/a |
| Required checks red on a mill PR | Starts a fix run, at most twice per failing commit, then comments that it cannot fix it and stops | n/a |
| Repo unprepared or a prerequisite missing | Blocks that item, naming what is missing; resumes from the top of the graph when you fix it | no |
| mill restarts mid-stage, or a runner thread dies, process group alive | Verifies `pid_started_at`, kills the orphaned group, marks the attempt interrupted, and re-enters; blocks after 3 interruptions on one stage | no |
| Same, process group gone | Marks the attempt interrupted and re-enters; same cap | no |
| Boot time differs from the recorded one | Signals nothing on that evidence alone — compares with tolerance and verifies `pid_started_at` first, because an NTP step moves `kern.boottime` | no |
| Machine sleeps mid-stage | Measures the gap, opens a settle window, and holds off heartbeat reaping until it closes | no |
| Network unreachable inside the settle window | Treats it as transient and logs it, leaving repo health alone | no |
| Stale git lock in the worktree or on the run's branch ref | Removes it before the attempt | no |
| A git command fails on a lock held by another stage or by you | Clears the stale lock, backs off, and retries the command; only a repeated failure ends the launch | no |
| Descendants survive a kill | Reaps them before it reuses the worktree | n/a |
| Another active run already holds the branch | Skips the item, comments once naming the run that holds it, and shows it waiting in the UI | n/a |
| Branch or worktree admin entry already exists | Prunes it before claiming; blocks if it cannot | no |
| Worktree missing or conflicted | Aborts, blocks, and keeps the diff | no |
| Comment on a `Blocked` item | Always read as an answer, never as a new trigger | n/a |
| Plain comment on a mill PR without the `mill:` marker | Ignores it and logs it | n/a |
| Comment from a non-collaborator | Ignores it and logs it | n/a |
| Handling a comment event raises | Increments `events.attempts` and retries, marking it `dead` after the cap | n/a |
| Writing Status to the board fails | Leaves `desired_board_status` unconfirmed and retries until it lands | n/a |
| Board Status changes that mill did not write | Reports it as board interference rather than silently obeying | n/a |
| Web request without an allowlisted session (server deployment) | Redirects to the Google sign-in; no run state is readable or writable | n/a |
| Poller hits an auth failure or a 404 | Marks the repo unhealthy and surfaces it, distinct from rate limiting | n/a |
| GitHub rate-limits `gh` | Backs off to a ceiling and leaves the cursor alone, so it loses nothing | n/a |
| Poller or supervisor thread raises | Logs it, restarts the thread with backoff, and surfaces its health | n/a |
| Two runs on one subject | The unique partial index refuses the second | n/a |
| Disk full | The supervisor stops claiming and surfaces it | n/a |

## Testing

`Mill::Claude` and `Mill::Github` are the only components touching the outside world, and both
get fakes backed by recorded fixtures. Everything above them tests with no network and no
tokens.

- **Poller** — a pure function of (board state, cursors, comments) → work. Table tests for the
  collaborator rule, the marker-at-line-start rule against real quote-reply bodies, mill
  refusing a fork head, and cursor monotonicity.
- **Runner** — walks the graph against scripted verdicts: how it validates an envelope and an
  artifact, when it treats a review as a rejection, how it picks a route, how it finds the spec,
  and the one sanctioned strike reset.
- **The attempt ledger** — a table test with one case per row of the ledger's cost table,
  asserting what each ending does to the invocation number and to the strike count. This is the
  control plane every other subsystem routes its failures into, and its rules were the least
  pinned-down part of the design, so it gets the most direct test in the suite. Include the case
  the old rules could not express: a reviewer that crashes, then reviews cleanly, then reviews
  again after a fix — three invocations, one strike, and three distinct verdict records.
- **Supervisor** — worktree lifecycle against a scratch repo, preparing a repo on first touch,
  the concurrency cap, killing a process group whose child deliberately orphans itself, and
  removing stale locks.
- **Sleep and wake** — the clock pair is injectable, so a test simulates a night's sleep by
  advancing the continuous clock without advancing the awake clock. Assert that the settle
  window opens, that heartbeat reaping stays suppressed while it is open, and that a stage
  emitting nothing gets killed and resumed without taking a strike.
- **Permission ruleset** — the layer-1 boundary, and the only suite that must run against the
  real CLI, because it is the only one asserting a boundary rather than logic. Assert against a
  real `claude -p` running with the stage's argv and settings file:
  - A tool omitted from `--tools` cannot be called. Probe **behaviourally** — tell the stage to
    run a command and check that it reports the tool absent. Never ask the agent to enumerate
    its own tools; the spike showed that self-report is unreliable and contradicts observed
    behaviour.
  - `Edit(...)` denies hold: a file under a denied path is not modified. Use a **benign** edit —
    a request that looks like tampering gets refused on safety grounds before the permission
    layer is ever reached, which passes for the wrong reason.
  - Command-level Bash denies hold: a denied command is blocked while a sibling command runs.
  - **Read denies hold through Grep and Glob, not just Read.** The spike verified refusal only
    via the Read tool, and the `Write`-versus-`Edit` discovery proves this CLI can match rules
    against some tools and not others. If Grep can match content inside a denied path, the read
    half of layer 1 is partly inert and nothing would notice. Probe a denied path with all three
    tools.
  - **The working directory confines, with an empty ruleset.** Assert a stage cannot read or
    write a file in `~` when no deny rule mentions it. This is the strongest guarantee in layer 1
    and nothing else tests it.
  - **An absolute-path deny rule does not confine** — the regression test for the trap. Assert
    that `Read(/abs/path)` fails to block while a worktree-relative rule in the same file blocks,
    so nobody writes an absolute rule and believes it protects something.
  - **`Skill` is gated by `--tools`.** Assert a stage without it cannot load a skill, and one
    with it can. Every stage that names a skill depends on this.
  - **`acceptEdits` still honours deny rules.** Assert that under `--permission-mode acceptEdits`
    an ordinary file is edited while `Edit(.claude/**)` still blocks. If this ever stops holding,
    the three writing stages lose their in-worktree scoping.
  - **`--settings` merges rather than replaces.** Assert that a passed ruleset's deny binds while
    plugin skills still resolve.
  - `--strict-mcp-config` leaves no MCP tools reachable.
  - **A regression test against the wrong mental model:** assert that a tool present in neither
    `allow` nor `deny` still runs. It does, under every permission mode. Anyone who later
    "fixes" the ruleset by moving confinement from `--tools` into an `allow` list will turn
    layer 1 off, and this is the test that catches them.
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
This is why half the graph is review stages, why every stage has a hard strike cap, and why
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
- **Single machine, and on a laptop the factory stops when the lid shuts.** mill recovers
  whatever was in flight — see [Sleep and wake](#sleep-and-wake) — but nothing progresses while
  the machine is asleep. A server deployment avoids that entirely and is the expected home;
  the laptop remains supported for development, which is why the platform module exists.
- **No unattended path from a vague idea to a PR**, by design. If you have not thought it
  through, mill will not think it through for you.
- **The review loop may not converge.** The reviewer skill assumes defects exist, and a `high`
  or `critical` objection re-runs the reviewed stage. If the reviewer reliably escalates on
  every pass, every run burns both strikes and blocks — the cap turns an infinite loop into a
  system that never finishes. Steve Yegge reportedly scrapped his "Gas Town" system for exactly
  this: certain Opus versions would not converge, always finding issues, with the fix-review
  cycle oscillating rather than settling. mill's defences are the severity threshold (only `high`
  or `critical` triggers a re-run), the two-strike cap, and session resume (the coding agent
  remembers its own reasoning, so it is less likely to undo its fix to satisfy a new objection).
  If this shows up in practice, the responses to try in order: tighten the threshold to
  `critical` only; cap review-driven re-runs to one pass, so the second review lands in the PR
  body but never triggers another fix; or accept that some runs will block and treat that as the
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

**Settled 2026-08-19, against CLI 2.1.227.** Two questions that gated Plan B are now measured, and
both had consequences — see [Containment](#containment) and the toolset table for what changed.
`Skill` is gated by `--tools`, so every stage that names a skill now carries the tool. Headless
mode refuses *every* file write under the default permission mode, so the three writing stages
carry `--permission-mode acceptEdits`, which still honours deny rules. `--settings` merges with
the operator's settings rather than replacing them. Absolute-path deny rules silently do nothing.
And the working directory, not the deny list, is what keeps a stage out of `~`.

**Three measurements remain, and two need you at the machine.**

1. **Does the awake clock really stop during sleep?** Record
   `Process.clock_gettime(Process::CLOCK_MONOTONIC)` and
   `Process.clock_gettime(Process::CLOCK_UPTIME_RAW)`, shut the lid for ten minutes, wake, record
   both again. Equal deltas mean mill can never detect sleep and [Sleep and wake](#sleep-and-wake)
   needs rebuilding on a different signal. **Gate on Plan C.**
2. **Can the Projects v2 API report whether a built-in workflow is enabled?** Five minutes against
   the GraphQL schema. If not, doctor's promised check needs the fallback described in
   [The board is the queue](#the-board-is-the-queue). **Gate on Plan A.**
3. **Does `claude` authenticate headlessly on the Linux host against the subscription?** If it
   cannot, the server deployment does not work at all and mill is laptop-only after all. Ten
   minutes on the VPS. **Gate on deploying anywhere but the laptop.**

One more is cheapest to answer while building: **does the tee see a command announced when it
starts, or only when it finishes?** The stall detector's ability to tell a slow test suite from a
wedged stage depends on it — answer during Plan A.

**Write one plan at a time**, and execute it before writing the next — doing Plan A teaches things
that change Plan B, and a stale plan actively misleads. Each plan names the spec sections it
implements rather than expecting an agent to read all of this. mill works on mill only after Plan
D, when the kill switch and the log tail exist; before that, it is two unreliable things at once.

### Spike — the permission model

Not a plan. Throwaway code, standalone, first. **Run on 2026-08-13 against CLI 2.1.223**, and it
changed the design; the results are folded into [Containment](#containment) and the toolset
column above.

What held:

- A denied call is reported to the agent, not hung. A stage read an allowed file, refused a
  denied sibling, explained why, and exited cleanly in 13 seconds.
- Command-level Bash denies work: `Bash(curl:*)` blocked curl while `echo` ran.
- `--resume` carries context across a separate process invocation and returns the **same**
  session id, which is what every relaunch depends on.

What broke, and changed the design:

- **An `allow` list does not confine.** A tool in neither `allow` nor `deny` ran under every
  permission mode tried. Layer 1 was rewritten around `--tools`.
- **`Write(...)` deny rules silently do nothing.** Only `Edit(...)` is matched against file
  permission checks. A workflow file was modified under a `Write(...)` deny and blocked under
  the `Edit(...)` form.
- **MCP servers are inherited.** `--tools` restricts built-ins only; the stage still had the
  operator's Google Drive connector until `--strict-mcp-config` was passed.
- **Token accounting needed two more columns.** Cache reads dominated fresh input 7182 to 3.

Two methodology notes for whoever repeats this. Probe behaviourally rather than asking the agent
what tools it has — its self-report contradicted its own observed behaviour. And keep probe
requests benign: a request phrased to look like CI tampering was refused on safety grounds before
the permission layer was reached, which would have passed as a containment success for entirely
the wrong reason.

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

- Runner over the `plan` route against scripted verdicts: the attempt ledger, and when it
  treats a review as a rejection
- Finding the spec and adopting the branch: `linkedBranches`, the diff-based lookup
- Real stage prompts and `mill-headless` for `triage → plan → review:plan → implement →
  review:code → pr`, plus the two skills mill owns — `mill:implement` and `mill:pr`
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

## Sources

- [The Software Factory — alexop.dev](https://alexop.dev/posts/the-software-factory/)
- [Software Factories — Addy Osmani](https://addyosmani.com/blog/software-factories/)
- Claude Code quickstart v2.0 (local, `~/Downloads/Claude Code quickstart (3).md`)
- Vorflux landing page text — `tmp/vorflux-landing.md` (untracked scratch)
- Branch deploy options — `docs/reference/branch-deploy-options.md`
