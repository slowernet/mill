# mill SDLC — every beat, every source

What each stage does, step by step, and where each practice comes from. This is the
extraction document — the raw material for the stage prompts, `mill:implement`, `mill:pr`,
and `mill-headless`.

Notation: **(SP:skill)** means the practice comes from a Superpowers skill, **(P:skill)**
from a personal skill, **(mill)** from the design doc. Practices marked **(drop)** are in the
source skill but deliberately excluded, with the reason.

## The sequence at a glance

| # | Step | Who | Skill / tool | Stock or mill's own | Can block? |
|---|---|---|---|---|---|
| 0 | Spec writing | You, interactively | `superpowers:brainstorming` | Stock | n/a (you're there) |
| 0b | Spec self-review for mill | You, interactively | spec standard checklist | Mill's own (reference doc) | n/a (you're there) |
| 0c | Release to mill | You | Switch your clone off the branch, set Status to `Ready` | n/a | n/a |
| 1 | Triage (incl. scope check) | mill (Sonnet) | none (fixed prompt) | Mill's own | Yes — unclear issue, or multi-subsystem spec |
| 2 | Plan | mill (Opus) | `superpowers:writing-plans` | Stock; stage prompt overrides the header | Yes — spec gaps (batched), or an epic-sized spec |
| 3 | Review: plan | mill (Opus) | `adversarial-reviewer` | Stock (personal); stage prompt adds 3 lenses | Rarely — objections re-run plan |
| 4a | Diagnose (fast route only) | mill (Opus) | `superpowers:systematic-debugging` | Stock | Yes — after 3 failed hypotheses |
| 4b | Implement (plan route) | mill (Opus) | `mill:implement` | Mill's own | Exceptional — plan gap |
| 4c | Implement: fast (fast + iterate routes) | mill (Opus) | `superpowers:test-driven-development` | Stock | Rare — asking to skip tests |
| 5 | Review: code | mill (Opus) | `adversarial-reviewer` | Stock (personal); stage prompt adds plan-alignment and consistency lenses | Rarely — objections re-run implement |
| 6a | PR (plan/fast routes) | mill (Opus) | `mill:pr` | Mill's own | Only if tests fail |
| 6b | Push (iterate route) | mill (Opus) | none (fixed prompt) | Mill's own | Only if tests fail |

**Three routes through the graph:**

| Route | Entry condition | Stages |
|---|---|---|
| `plan` | Issue with a spec on the linked branch | triage → plan → review:plan → implement → review:code → pr |
| `fast` | Issue with no spec, triaged as hotfix-shaped | triage → diagnose → implement:fast → review:code → pr |
| `iterate` | Comment/review/red CI on an existing mill PR | triage → implement:fast → review:code → push |

**Reading the routes:** reviewer objections loop back to the stage that produced the artifact,
not to the human — the reviewer's notes are injected and the stage re-runs under mill's ledger.
The only transitions that cost you wall time are the ones ending at Blocked. Answering a block
resumes the blocked stage's own session with your answer injected — it does not restart the
pipeline; only blocks that happened before any stage ran (unprepared repo, branch checked out,
missing secrets) restart from the top.

**Portability note:** the spec standard checklist (step 0b) and the three review lenses mill
adds to `adversarial-reviewer` (step 3, 5) currently live inside this repo. For mill to work
on other repos without per-repo scaffolding, these need to travel with mill rather than being
committed to each target repo. The spec standard could become part of mill's onboarding
runbook or a prompt mill injects during your design session; the review lenses are already
part of mill's stage prompts, not the target repo. What remains repo-specific is `.mill.yml`
(test command, base branch, CI workflow) — that's the only file mill needs in a target repo.

---

## 0. Spec writing — before mill touches anything

**Who:** you, interactively, using `superpowers:brainstorming`. **Where:** your terminal,
not mill. This is deliberately outside the pipeline.

The spec is the single document the entire pipeline rests on. Mill cannot ask you to
clarify it mid-run without blocking, and each block costs hours of wall time plus every
Opus invocation that ran before it. A spec that is complete for a human reader ("handle
errors gracefully") is incomplete for a machine reader — the planner has to invent the error
handling strategy and might guess wrong, and if it blocks to ask, you pay a round trip for a
decision you could have made in the design session.

**What brainstorming already does well:**
- Explores project context (files, docs, recent commits) before asking questions
- Asks clarifying questions one at a time, preferring multiple choice
- Proposes 2-3 approaches with trade-offs and a recommendation
- Presents the design in sections with approval after each
- Self-reviews for placeholders, contradictions, scope, ambiguity
- YAGNI ruthlessly

**What it doesn't check, and what mill needs:**

### Machine-buildable specs

Every requirement in the spec will be read by an agent that writes a plan from it, then by
another agent that writes code from that plan, then by another agent that reviews that code.
None of them can ask you what you meant. The spec needs to be complete enough that they
don't have to.

| What to check | Why it matters | Example of the gap |
|---|---|---|
| **Exact values at every decision point** | If the planner has to invent a number, it either guesses or blocks. Every threshold, timeout, limit, and default should be in the spec | "rate-limit the poller" → how long between ticks? "cap concurrent runs" → at what number? |
| **Concrete error handling** | "Handle errors gracefully" is a design decision the spec defers to the planner. The planner may guess wrong or block | "When a GitHub API call fails, retry with backoff up to three times, then block the item and comment with the error" |
| **Where it fits in the existing code** | The spec describes what to build; the planner needs to know where it goes. Not exact paths (that's the plan's job), but which components and how they relate to existing ones | "Add a supervisor" — as a thread in the Roda app? A separate process? A new class in `lib/mill/`? |
| **Mechanically testable requirements** | An agent can verify "the run list shows subject, route, stage, status, and tokens." It cannot verify "the UI should look clean." Untestable requirements either get skipped or block | Rewrite qualitative requirements as observable behaviors with specific outputs |
| **Explicit non-requirements** | Spec silence is ambiguous: does it mean "don't do this" or "I forgot"? When the planner encounters something the spec doesn't address, it either skips (risky), includes (overbuilds), or blocks (costly) | "Do NOT add pagination in the first version." "The poller does not consume events — it reconciles state" |
| **Edge cases and boundary conditions** | "Import users from a CSV" — what if it's empty? What if a row is malformed? What if there are duplicates? Each unaddressed edge case is a potential block or a guess | Name the important edge cases and say what should happen for each |
| **Dependencies and sequencing** | "This needs the GitHub board to be set up first" — is that a precondition the spec assumes, or something the plan should include? | State preconditions explicitly: what must already exist, what the spec creates |
| **Sized for one readable PR** | An epic-sized spec produces a plan implement cannot finish inside its strike budget (roughly two 30-minute launches) and a PR nobody reads in one sitting | Split "billing system" into a sequence released in order: plans table → checkout → invoices. Each spec its own issue and branch; a dependent spec waits for its predecessor's merge — mill does not stack branches |

### Spec self-review for mill

After brainstorming's existing self-review (placeholders, contradictions, scope, ambiguity),
add one pass specifically for mill:

**"Could a planner write the exact code from this spec, without asking me anything?"**

For each section of the spec, imagine the planner reading it cold and writing a task. Would
the planner know:
- What to build? (the requirement)
- How to build it? (the approach, at least at the component level)
- What exact values to use? (thresholds, limits, defaults, formats)
- What to do when things go wrong? (error handling, edge cases)
- What NOT to build? (scope boundaries)
- How to test it? (observable behavior with specific outputs)
- Where it goes in the codebase? (which component, how it relates to existing code)

If any answer is "no, they'd have to guess or ask me," that's a gap to fill now rather than
a round trip to pay later.

This pass is NOT about adding detail for its own sake. A spec that says "use the standard
Sequel migration pattern" is fine — the planner can read the codebase and find it. A spec
that says "handle errors appropriately" is NOT fine — "appropriately" is a judgment call the
planner shouldn't make. The test is whether the planner would have to make a *decision* the
spec should have made.

---

## 1. `triage` — decide what this is

**Model:** Sonnet. **Tools:** Read, Glob, Grep. **Skill:** none.

mill passes triage the issue body, the linked branch (if any), and the list of files the
branch adds under `docs/superpowers/specs/`.

| Beat | What happens | Source |
|---|---|---|
| 1 | Read the issue body and any linked spec | (mill) |
| 2 | Scope check: if a spec exists and it covers multiple independent subsystems, block and ask whether to split — this catches the multi-subsystem case at Sonnet cost rather than after loading Opus for plan | (SP:writing-plans "Scope Check", moved earlier) |
| 3 | Decide the route: `plan` if a spec exists on the branch, `fast` if no spec and the issue is unambiguously a crash/lint/dependency bump, or block with questions if uncertain | (mill) |
| 4 | If blocking, write clear questions about what is missing or ambiguous | (mill) |
| 5 | Emit the verdict: route (or blocked + questions), summary | (mill) |

**What triage does NOT do:** set the evidence flag (the board owns that), design anything,
or guess a route when the answer is unclear. Blocking is the correct output for an
underspecified issue. **(mill: "triage defaults to blocking")**

**No skill invoked** — triage is pure routing logic with a fixed prompt.

---

## 2. `plan` — turn the spec into buildable tasks

**Model:** Opus. **Tools:** Read, Glob, Grep, Write, Skill. **Mode:** `acceptEdits`. **Skill:** `superpowers:writing-plans`.

mill passes the plan stage the spec path, the issue body, and the triage verdict.

**Throughput principle: the plan stage is where every question should surface.** Each time
`implement` blocks for human input, it costs hours of wall time and wastes every Opus
invocation that ran before it. The planner's job is to make that rare by asking every
question the pipeline will ever need to ask, in one batch, before it finishes.

### Understanding the codebase

| Beat | What happens | Source |
|---|---|---|
| 1 | Read the spec in full | (SP:writing-plans) |
| 2 | **Read the codebase for patterns and conventions.** Use Grep and Read to find: how existing tests are structured, what naming conventions the code uses, how errors are handled, what the test command is and what passing output looks like. Look for the patterns implement will need to follow — not just rules from CLAUDE.md, but concrete examples from the actual code | (mill: front-load context) |
| 3 | **Read the test infrastructure.** What command runs the tests? What does passing output look like? Is the suite slow enough to need the focused-test-first strategy? Does it need setup (database, fixtures, environment variables from `.mill.yml`)? | (mill: front-load context) |
| 4 | If the spec covers multiple independent subsystems and triage didn't catch it, block and ask whether to split | (SP:writing-plans "Scope Check") |

### Writing the plan

| Beat | What happens | Source |
|---|---|---|
| 5 | Map out the file structure — which files will be created or modified, what each is responsible for. Check whether a simpler decomposition exists: does the codebase already have a file where this belongs? Is a new abstraction actually needed, or does an existing pattern cover it? | (SP:writing-plans "File Structure") + (mill: simplicity check) |
| 6 | Design units with clear boundaries. Prefer smaller, focused files. Files that change together should live together. Follow the existing codebase's patterns, not an ideal you'd impose on a greenfield project | (SP:writing-plans "File Structure") |
| 7 | Right-size tasks: each task is the smallest unit carrying its own test cycle and worth a reviewer's gate. Fold setup/scaffolding into the task that needs it. Split only where a reviewer could reject one while approving the other | (SP:writing-plans "Task Right-Sizing") |
| 8 | Write the plan header: goal, architecture, tech stack. **Replace the `REQUIRED SUB-SKILL` line with one naming `mill:implement`** | (SP:writing-plans "Plan Document Header") + (mill) |
| 9 | **Write the Global Constraints section.** This is the most important section for throughput. Include: (a) exact values from the spec, copied verbatim, (b) codebase conventions with concrete examples — not "follow existing patterns" but `error handling uses rescue StandardError => e; log_error(e); raise` and `test files mirror source paths: lib/mill/foo.rb → test/mill/test_foo.rb`, (c) the test command and expected passing output, (d) any setup the suite needs | (SP:writing-plans "Plan Document Header") + (mill: front-load conventions) |
| 10 | Write each task with: files (create/modify/test with exact paths), interfaces (consumes/produces with exact signatures), and bite-sized checkbox steps — write failing test, verify it fails, write minimal code, verify it passes, commit | (SP:writing-plans "Task Structure") |
| 11 | Every step must contain actual code, actual commands, actual expected output. No placeholders: no "TBD", no "add validation", no "similar to Task N" (repeat the code), no references to undefined types | (SP:writing-plans "No Placeholders") |

### Buildability test

| Beat | What happens | Source |
|---|---|---|
| 12 | **Buildability test, per task.** For every task just written, ask: can I write the exact failing test right now, from what the spec and the codebase give me? Can I write the exact implementation? If not, what's missing — a gap in the spec, or a gap in my understanding of the codebase? Spec gaps become questions; codebase gaps become investigation (Grep, Read) | (mill: front-load questions) |
| 13 | **Interface verification against the codebase.** If a task says "call `User.find(id)`", check whether that method exists. If another task creates it, verify the signature matches in both places. If it already exists in the codebase, check that the real signature matches what the plan assumes | (SP:writing-plans "Self-Review" — type consistency, extended to codebase) |
| 14 | **Batch all questions.** If the buildability test and interface verification found gaps that trace back to the spec, collect them ALL and block once with the full list. One round trip, not N | (mill: batch questions) |

### Self-review

| Beat | What happens | Source |
|---|---|---|
| 15 | **Spec coverage:** skim every section/requirement in the spec. Point to the task that implements it. List any gaps | (SP:writing-plans "Self-Review") |
| 16 | **Placeholder scan:** search the plan for red-flag patterns from the "No Placeholders" list. Fix them | (SP:writing-plans "Self-Review") |
| 17 | **Type and signature consistency:** do the types, method signatures, and property names used in later tasks match what earlier tasks defined? | (SP:writing-plans "Self-Review") |
| 18 | **Simplicity check:** for each new file or abstraction the plan introduces, is it the simplest way to do this? Does the codebase already have a pattern that covers this? Would adding to an existing file be cleaner than creating a new one? | (mill: prevent unnecessary complexity) |
| 19 | **Size check:** would this plan's PR be readable in one sitting, and does the decomposition fit implement's time budget with room for one review-driven re-run? If not, block and propose the split: name each sub-spec and the release order. Deliberately a judgment call, not a numeric cap — task sizes vary too much for a count to mean anything | (mill: spec-standard check 8) |
| 20 | Save to `docs/superpowers/plans/<date>-<slug>.md` | (SP:writing-plans) |
| 21 | Emit the verdict with the plan path as the artifact | (mill) |

**Dropped from writing-plans:**
- **(drop)** Execution handoff ("which approach?") — mill decides, not the stage
- **(drop)** The `REQUIRED SUB-SKILL` header pointing at executing-plans or subagent-driven — mill overrides this to name `mill:implement`
- **(drop)** Worktree creation context ("should have been created via using-git-worktrees") — mill already made it
- **(drop)** Scope check — moved to triage, where it runs at Sonnet cost

**Kept from writing-plans-for-teams (P:writing-plans-for-teams):**
- The dependency metadata (Depends on / Produces) is valuable for interface verification across
  tasks, even without parallel execution.
- Wave analysis is deferred; mill currently runs tasks serially within one implement process.

---

## 3. `review:plan` — adversarial review of the plan

**Model:** Opus. **Tools:** Read, Glob, Grep, Skill. **Skill:** `adversarial-reviewer` (personal).

mill passes the plan artifact, the spec, and the diff to date.

| Beat | What happens | Source |
|---|---|---|
| 1 | Read ALL the plan and spec before writing anything. Form a mental model of what the plan promises to build | (P:adversarial-reviewer "Process" step 1) |
| 2 | Trace the unhappy paths — what happens when things go wrong? | (P:adversarial-reviewer "Process" step 2) |
| 3 | Look for implicit assumptions — what does the plan believe about the codebase that isn't enforced? | (P:adversarial-reviewer "Process" step 3) |
| 4 | Check boundaries between components — where does trust transfer happen? | (P:adversarial-reviewer "Process" step 4) |
| 5 | Work through the adversarial checklist in order: logic errors, edge cases, error handling, state/concurrency, security, data integrity, resource management | (P:adversarial-reviewer "Review Checklist") |
| 6 | **Buildability check: can an agent execute each task without asking a human?** Are the interfaces specified with exact signatures? Does every step have actual code, not placeholders? If a task says "add appropriate error handling," that's a finding — implement WILL block on it | (mill: prevent downstream blocks) |
| 7 | **Simplicity check: is this the simplest decomposition?** Does the plan introduce files, abstractions, or patterns the codebase doesn't need? Would a simpler approach work? Does anything duplicate what already exists? A plan that is correct but unnecessarily complex produces code that is correct but unnecessarily complex | (mill: prevent accumulated complexity) |
| 8 | **Codebase alignment: does the plan follow the conventions it claims to?** Do the example patterns in Global Constraints actually match the codebase? Are the file paths consistent with how the project is structured? | (mill: catch convention drift) |
| 9 | For each finding: file:line, category, severity (CRITICAL/HIGH/MEDIUM/LOW), what's wrong, concrete trigger scenario, minimal fix | (P:adversarial-reviewer "Output Format") |
| 10 | Ordered by severity, CRITICAL first. If nothing found, say "No bugs found" and stop — don't manufacture issues | (P:adversarial-reviewer) |
| 11 | Emit the verdict with objections | (mill) |

**The adversarial-reviewer skill text is unchanged; mill's stage prompt adds the three
extra lenses** (buildability, simplicity, codebase alignment). The adversarial persona is
untouched: no compliments, guilty until proven innocent, prove it with concrete scenarios.
The three lenses catch the class of plan defects the adversarial checklist misses — a plan
with no bugs but that cannot be executed, or one that is correct but unnecessarily complex.
No fork to maintain; when the skill improves upstream, both reviewers get it.

---

## 4. `diagnose` — find root cause (fast route only)

**Model:** Opus. **Tools:** Read, Glob, Grep, Bash, Skill. **Skill:** `superpowers:systematic-debugging`.

mill passes the issue body and the triage verdict.

| Beat | What happens | Source |
|---|---|---|
| **Phase 1: Root cause investigation** | | |
| 1 | Read error messages carefully — don't skip past them. Note line numbers, file paths, error codes | (SP:systematic-debugging Phase 1 step 1) |
| 2 | Reproduce consistently. Exact steps, does it happen every time? If not reproducible, gather more data — don't guess | (SP:systematic-debugging Phase 1 step 2) |
| 3 | Check recent changes: git diff, recent commits, new dependencies, config changes, environmental differences | (SP:systematic-debugging Phase 1 step 3) |
| 4 | In multi-component systems: add diagnostic instrumentation at each component boundary. Log what enters and exits. Run once to gather evidence showing WHERE it breaks, THEN investigate that component | (SP:systematic-debugging Phase 1 step 4) |
| 5 | Trace data flow: where does the bad value originate? What called this with the bad value? Trace up to the source. Fix at source, not symptom | (SP:systematic-debugging Phase 1 step 5) |
| **Phase 2: Pattern analysis** | | |
| 6 | Find working examples of similar code in the codebase | (SP:systematic-debugging Phase 2 step 1) |
| 7 | Compare against references — read reference implementations completely, not skimmed | (SP:systematic-debugging Phase 2 step 2) |
| 8 | Identify every difference between working and broken, however small | (SP:systematic-debugging Phase 2 step 3) |
| 9 | Map dependencies: other components, settings, config, environment, assumptions | (SP:systematic-debugging Phase 2 step 4) |
| **Phase 3: Hypothesis and testing** | | |
| 10 | Form a single hypothesis: "I think X is the root cause because Y." Be specific | (SP:systematic-debugging Phase 3 step 1) |
| 11 | Test with the smallest possible change. One variable at a time | (SP:systematic-debugging Phase 3 step 2) |
| 12 | If it didn't work, form a NEW hypothesis — don't pile more fixes on top | (SP:systematic-debugging Phase 3 step 3) |
| 13 | If you don't know, say so. Don't pretend | (SP:systematic-debugging Phase 3 step 4) |
| 14 | Emit the verdict with root cause recorded for the PR body | (mill) |

**Phase 4 (implementation) is dropped** — that's `implement:fast`'s job in mill's graph.

**The "3+ fixes failed, question the architecture" gate** maps onto block-and-ask: if the
stage can't establish root cause after three hypotheses, it emits questions rather than
guessing.

---

## 5. `implement` — build the plan (plan route)

**Model:** Opus. **Tools:** Read, Glob, Grep, Write, Edit, Bash, Skill. **Mode:** `acceptEdits`. **Skill:** `mill:implement`.

mill passes the plan artifact, the spec, the triage verdict, the review:plan verdict, and
any reviewer objections that were addressed.

This is mill's own skill, synthesized from:
- (SP:subagent-driven-development) — task briefs, the four-status report contract, evidence
  rules, the ledger, self-review
- (SP:executing-plans) — review plan critically before starting, follow steps exactly, stop
  when blocked
- (SP:test-driven-development) — the red-green-refactor cycle, the iron law
- (SP:verification-before-completion) — evidence before claims
- (P:agent-team-driven-development) — persistent context across tasks, dependency metadata

**Throughput principle: by the time implement starts, the plan should be so complete that
blocking is genuinely exceptional — a real surprise, not a predictable gap.** The plan stage
asked every question, review:plan checked buildability, and the plan has exact code, exact
signatures, exact test commands. If implement still can't proceed, the plan failed its job —
but implement blocks for human input rather than guessing, because a wrong implementation is
more expensive than a round trip.

### Per-plan setup

| Beat | What happens | Source |
|---|---|---|
| 1 | Read the plan once. Note the global constraints — these carry the codebase conventions, the test command, and the exact values from the spec | (SP:executing-plans "Step 1", SP:subagent-driven-development "Setup") |
| 2 | Check for the plan's ledger state: read the plan file's checkboxes. Any task already ticked `[x]` is done — confirm via git log and skip it. Resume at the first unticked task. This is the compaction-recovery mechanism | (SP:subagent-driven-development "Setup" — ledger recovery) |
| 3 | Scan the plan once for obvious conflicts: tasks that contradict each other or the global constraints. If found, block with all conflicts described at once | (SP:subagent-driven-development "Setup" — pre-flight scan) |

### Per-task loop

| Beat | What happens | Source |
|---|---|---|
| 4 | **Read the task.** Note the files, interfaces, and steps. Exact values — signatures, magic strings, test cases — come from the plan text verbatim | (SP:subagent-driven-development "implementer-prompt" — task brief) |
| 5 | **If the task is too vague to execute — a step has no code, an interface has no signature, the test command is missing — block with a description of what's missing.** This should be rare; the plan stage's buildability test and review:plan's buildability check exist to prevent it. When it happens, it means the plan has a gap that review:plan missed | (mill: plan failure, not routine gate) |
| 6 | **RED — Write the failing test.** One minimal test showing what should happen. Clear name, tests real behavior, one thing. Real code, not mocks unless unavoidable | (SP:test-driven-development "RED") |
| 7 | **Verify RED — Watch it fail.** Run the test. Confirm it fails for the right reason (feature missing, not typo). If it passes, you're testing existing behavior — fix the test. If it errors, fix the error | (SP:test-driven-development "Verify RED") |
| 8 | **GREEN — Write minimal code.** Simplest code to pass the test. Don't add features, don't refactor, don't "improve" beyond the test. No YAGNI violations | (SP:test-driven-development "GREEN") |
| 9 | **Verify GREEN — Watch it pass.** Run the test. Confirm it passes, other tests still pass, output is pristine (no errors, warnings) | (SP:test-driven-development "Verify GREEN") |
| 10 | **REFACTOR.** After green only. Remove duplication, improve names, extract helpers. Keep tests green. Don't add behavior | (SP:test-driven-development "REFACTOR") |
| 11 | Repeat the RED-GREEN-REFACTOR cycle for each step in the task | (SP:test-driven-development "Repeat") |
| 12 | **Follow existing codebase patterns.** The plan's Global Constraints carry concrete examples — error handling style, naming conventions, file structure. Match them. If the codebase has five methods using symbols for hash keys, the sixth should too. Do not introduce patterns the codebase doesn't use | (mill: codebase consistency) |
| 13 | **Run the full test suite once** before committing, not after every edit. While iterating, run the focused test for what you're changing | (SP:subagent-driven-development "implementer-prompt" — test strategy) |
| 14 | **Self-review before reporting.** Completeness (did I implement everything the task asked for? miss any requirements? edge cases?), quality (best work? names clear? code clean?), discipline (avoid overbuilding? only what was requested? follow existing patterns?), testing (tests verify real behavior? TDD followed? output pristine?) | (SP:subagent-driven-development "implementer-prompt" — "Self-Review") |
| 15 | **Evidence, not assertion.** The task is done when the report carries the covering tests, the command run, and its output. "Tests pass" without the output is the same failure as a stage that produces no verdict | (SP:verification-before-completion "The Iron Law", "The Gate Function") |
| 16 | **Commit the task's work.** One commit per task, with the test files and implementation together | (SP:writing-plans "Bite-Sized Task Granularity") |
| 17 | **Tick the checkbox in the plan file** in the same commit. This is the ledger — if context compacts or the session resumes, the ticked plan plus git log is the recovery map | (mill: "the plan file is the ledger") |
| 18 | **If stuck or in over your head**, stop. Report what you attempted, what you're stuck on, what you've tried. Block with questions rather than producing bad work. Escalating is always correct; bad work is always worse than no work | (SP:subagent-driven-development "implementer-prompt" — "When You're in Over Your Head") |

### After all tasks

| Beat | What happens | Source |
|---|---|---|
| 19 | Run the full test suite one final time | (SP:verification-before-completion) |
| 20 | Verify every checkbox in the plan is ticked | (mill) |
| 21 | Emit the verdict. If any task blocked, the verdict is `blocked` with questions. If all tasks completed, `ok` with the list of commits | (mill) |

**Dropped from subagent-driven-development:**
- **(drop)** Dispatching subagents — mill runs implement as one process; review is a separate stage
- **(drop)** The five-round fix loop with escalation — mill's ledger and review:code handle retries
- **(drop)** Task briefs as separate files — the plan file IS the brief; tasks are read from it directly
- **(drop)** Report files — the verdict carries the summary; the tee'd log carries the detail
- **(drop)** Model selection per dispatch — mill picks the model in the stage table
- **(drop)** Worktree creation — mill already created it
- **(drop)** The final code review — mill's `review:code` stage handles it
- **(drop)** `finishing-a-development-branch` — mill's `pr` stage handles it
- **(drop)** Progress ledger as a separate file — the plan file's checkboxes serve this role
- **(drop)** The controller/implementer separation — there's one process, not two

**Dropped from executing-plans:**
- **(drop)** `finishing-a-development-branch` at the end
- **(drop)** Worktree creation at the start
- **(drop)** The redirect to subagent-driven-development

**Kept from verification-before-completion:**
- The iron law: no completion claims without fresh verification evidence
- The gate function: identify what command proves the claim, run it, read full output, verify it confirms the claim, only then make the claim
- Rationalisation prevention: "should work now", "I'm confident", "partial check is enough" are all failures

---

## 6. `implement:fast` — build without a plan (fast and iterate routes)

**Model:** Opus. **Tools:** Read, Glob, Grep, Write, Edit, Bash, Skill. **Mode:** `acceptEdits`. **Skill:** `superpowers:test-driven-development`.

On the fast route, mill passes the diagnose verdict (with root cause), the issue body, and
the triage verdict. On the iterate route there is no diagnose — mill passes the triggering
comment, review comment, or failing check instead.

| Beat | What happens | Source |
|---|---|---|
| 1 | Read the root cause from the diagnose verdict (fast route) or the trigger (iterate route) | (mill) |
| 2 | **RED** — Write a failing test that reproduces the bug. The bug's reproduction IS the failing test | (SP:test-driven-development "RED", SP:systematic-debugging Phase 4 step 1) |
| 3 | **Verify RED** — Watch it fail for the right reason | (SP:test-driven-development "Verify RED") |
| 4 | **GREEN** — Write minimal code to fix the root cause. One change, at the source, not the symptom. No "while I'm here" improvements, no bundled refactoring | (SP:test-driven-development "GREEN", SP:systematic-debugging Phase 4 step 2) |
| 5 | **Verify GREEN** — Test passes, other tests still pass, output pristine | (SP:test-driven-development "Verify GREEN") |
| 6 | **REFACTOR** — Clean up after green. Keep tests green | (SP:test-driven-development "REFACTOR") |
| 7 | Run the full test suite | (SP:test-driven-development "Verification Checklist") |
| 8 | Commit | (mill) |
| 9 | Emit the verdict | (mill) |

**The skill is used unchanged.** Its one human gate — asking before skipping tests for
throwaway code — maps onto `mill-headless`'s block-and-ask.

---

## 7. `review:code` — adversarial review of the code

**Model:** Opus. **Tools:** Read, Glob, Grep, Bash, Skill. **Skill:** `adversarial-reviewer` (personal).

mill passes the code diff, the plan artifact (if plan route), the spec, the implement
verdict, and all predecessor verdicts.

| Beat | What happens | Source |
|---|---|---|
| 1 | Read ALL the code diff, the plan (if plan route), and the spec before writing anything | (P:adversarial-reviewer "Process" step 1) |
| 2 | Trace the unhappy paths — what happens when things go wrong? | (P:adversarial-reviewer "Process" step 2) |
| 3 | Look for implicit assumptions — what does the code believe about its inputs that isn't enforced? | (P:adversarial-reviewer "Process" step 3) |
| 4 | Check boundaries between components — where does trust transfer happen? | (P:adversarial-reviewer "Process" step 4) |
| 5 | Work through the adversarial checklist: logic errors, edge cases, error handling, state/concurrency, security, data integrity, resource management | (P:adversarial-reviewer "Review Checklist") |
| 6 | **Plan alignment (plan route only).** Does the code build what the plan asked for? Are the interfaces the ones the plan specified, with the right signatures? Did implement add things the plan didn't ask for, or skip things the plan required? Deviations are findings, not silent improvements | (SP:requesting-code-review "code-reviewer" — "Plan alignment") + (mill) |
| 7 | **Codebase consistency.** Does the new code match the conventions in the plan's Global Constraints? Same hash-key style, same error handling pattern, same file structure? Does it look like it belongs in this codebase, or like it was written by someone who didn't read the neighboring files? | (mill: prevent style drift) |
| 8 | **Test quality.** Do tests verify real behavior, not mocks? Name the production change that would make each test fail — if you can't, the test proves nothing. Edge cases covered? Test output pristine? | (SP:requesting-code-review "code-reviewer" — "Testing", SP:test-driven-development "Good Tests") |
| 9 | **Run the test suite** to verify claims rather than trusting the implement verdict. review:code has Bash | (mill) |
| 10 | On evidence-required runs: legibility check — could someone judge this from what is in the PR? | (mill: "Evidence requirement") |
| 11 | For each finding: file:line, category, severity, what's wrong, concrete trigger scenario, minimal fix. Ordered by severity, CRITICAL first | (P:adversarial-reviewer "Output Format") |
| 12 | Emit the verdict with objections | (mill) |

**What review:code synthesizes from three sources:**

From the adversarial-reviewer (P): the hostile persona (guilty until proven innocent, no
compliments, prove it with concrete scenarios), the seven-category checklist, silence means
approval.

From the code-reviewer template (SP:requesting-code-review): plan alignment as a distinct
check, severity calibration (not everything is Critical), be specific with file:line
references.

From the task-reviewer template (SP:subagent-driven-development): "do not trust the
report" — treat implement's verdict as unverified; verify against the diff and the test
output. Spec compliance as a distinct axis: missing, extra, or misunderstood requirements.

**What review:code does differently from the source skills** (all of it in the stage prompt —
the adversarial-reviewer skill file itself is unchanged):
- Uses the adversarial persona, not the balanced code-reviewer persona
- Runs the test suite via Bash to verify claims, rather than trusting the report
- Checks codebase consistency as a distinct lens — the source skills don't cover style drift
- Has no "read-only on this checkout" constraint — it can run tests, but cannot write files

---

## 8. `pr` — open the pull request (plan and fast routes)

**Model:** Opus. **Tools:** Read, Glob, Grep, Bash, Skill. **Skill:** `mill:pr`.

mill passes all predecessor verdicts, the spec, the plan (if any), the branch name, and
the base branch.

This is mill's own skill, synthesized from:
- (SP:finishing-a-development-branch) — verify tests before finishing
- (SP:verification-before-completion) — evidence before claims

| Beat | What happens | Source |
|---|---|---|
| 1 | Run the full test suite. If tests fail, report failures and block — nothing else happens until green | (SP:finishing-a-development-branch "Step 1: Verify Tests") |
| 2 | Verify fresh evidence: exit code, failure count, full output. "Tests pass" without having run them is a verdict violation | (SP:verification-before-completion "The Gate Function") |
| 3 | Compose the PR body: the spec summary, the plan summary (if plan route), the per-stage token breakdown, any reviewer objections and how they were addressed, the evidence sample table (if evidence-required) | (mill) |
| 4 | Push the branch to origin | (mill) |
| 5 | Open the PR with `gh pr create` against the base branch | (mill) |
| 6 | Emit the verdict. `pr_number` is deliberately not in it — mill recovers it with `gh pr list --head <branch>`, which is idempotent, so a crash between `gh pr create` and the state write reconciles instead of opening a second PR | (mill) |

**After the stage finishes, mill itself posts each reviewer objection's notes as PR comments
through `Mill::Github`.** The stage cannot do this — stages are denied every commenting path,
and only `Mill::Github` comments, always with the marker.

**Dropped from finishing-a-development-branch:**
- **(drop)** The three-option menu (merge locally, push and PR, keep as-is) — mill always opens a PR, never merges
- **(drop)** Detecting whether it's a worktree — mill always knows
- **(drop)** Asking to confirm the base branch — mill knows the base branch from the repo config
- **(drop)** Worktree cleanup — the supervisor handles teardown after the run finishes

---

## 9. `push` — push commits on an existing PR (iterate route)

**Model:** Opus. **Tools:** Read, Bash. **Skill:** none.

mill passes the review:code verdict, the existing PR branch, and the triggering comment or
review comment. **The changes were already made by `implement:fast` and reviewed by
`review:code`** — push has no write tools (Read and Bash only) and writes no code.

| Beat | What happens | Source |
|---|---|---|
| 1 | Read the review:code verdict confirming the reviewed commits are what goes out | (mill) |
| 2 | Run the test suite and verify green with fresh evidence | (SP:verification-before-completion) |
| 3 | Push to origin | (mill) |
| 4 | Emit the verdict | (mill) |

---

## `mill-headless` — the adapter for every stage

Loaded alongside every skill. Redefines every interactive gate the borrowed skills assume.

| Borrowed skill gate | What mill-headless does | Source |
|---|---|---|
| `writing-plans` asking for critique of the design | Writes questions into the verdict and blocks | (mill) |
| `test-driven-development` asking before skipping tests for generated code | Writes questions into the verdict and blocks | (mill) |
| `systematic-debugging` asking after 3+ failed hypotheses ("question the architecture") | Writes questions into the verdict and blocks | (mill) |
| `systematic-debugging` asking when root cause is not found ("I don't know") | Writes questions into the verdict and blocks | (mill) |

`mill:implement` and `mill:pr` have no interactive gates by construction — they were written
headless from the start.

---

## Cross-cutting practices (apply to every stage)

| Practice | What it means | Source |
|---|---|---|
| Evidence before assertions | No completion claim without fresh verification output. "Should work" is a failure | (SP:verification-before-completion) |
| Stop, don't guess | A blocker, an unclear instruction, or a gap means block with questions, not improvise | (SP:subagent-driven-development, SP:executing-plans, SP:systematic-debugging) |
| Self-review before reporting | Check completeness, quality, discipline, testing before emitting the verdict | (SP:subagent-driven-development "implementer-prompt" — "Self-Review") |
| One thing at a time | One hypothesis, one fix, one test, one commit. Never multiple changes at once | (SP:systematic-debugging, SP:test-driven-development) |
| Tests verify real behavior | No mocks unless unavoidable. Test output must be pristine. Name the production change that would make the test fail — if you can't, the test proves nothing | (SP:test-driven-development "Good Tests") |
| Follow existing codebase patterns | Match the style, naming, structure, and error handling in the neighboring code. The plan's Global Constraints carry concrete examples; implement follows them; review:code checks them | (mill) |
| No placeholders | Every instruction must contain actual content, not "add validation" or "similar to Task N" | (SP:writing-plans "No Placeholders") |
| The verdict is the last message | Every stage ends with a nonce-stamped JSON verdict. Prose after it is a validation failure | (mill) |

---

## Throughput design: where questions surface

The pipeline is designed so that questions concentrate early, where they're cheap, and
become rare later, where they're expensive.

| Where | Cost of a block | How often it should block |
|---|---|---|
| Spec writing (you, interactively) | Free — you're right there | **This is the cheapest place to make decisions.** Every judgment call left for the planner to make is a potential block or a wrong guess |
| `triage` | Cheap — Sonnet, first stage, nothing wasted | Whenever the issue is unclear. This is the right time to ask |
| `plan` | Moderate — one Opus invocation, but nothing downstream has run | **The last good place for questions.** The buildability test catches remaining spec gaps; one batch, one round trip |
| `review:plan` | Moderate — two Opus invocations total | Rarely for questions; usually for objections that re-run plan without a human |
| `implement` | Expensive — plan + review:plan already ran | **Genuinely exceptional.** A block here means the spec, the plan, AND the plan review all missed a gap. Still correct to block rather than guess |
| `review:code` | Very expensive — the whole pipeline ran | Almost never for questions; objections re-run implement without a human |
| `pr` | Very expensive | Only when tests fail |

**Every block in implement or later is a signal that plan or review:plan failed to do their
job.** When it happens, it's worth asking: what question should the planner have asked? Can
the plan stage prompt be improved to catch this class of gap? The pipeline should get better
at front-loading questions over time, not just on each run.

---

## Pitfalls of mostly-automated execution

Things the SDLC should defend against but cannot fully prevent.

**Comprehension debt accelerates quietly.** Mill can open several PRs a day. Each one
looks reasonable. When you start approving without reading deeply — and you will, because
the fifth PR of the day arrives when you're tired — the factory goes dark without any
visible transition. No stage can prevent this; it's a human discipline problem. What mill
CAN do: surface PR complexity (files changed, test count, token spend) so you can see
which PRs deserve a slow read.

**Style drift across PRs.** Each stage runs in a fresh session. Over ten PRs the code can
drift in ways where no individual PR is wrong but the codebase feels like it was written by
ten different people. The defense is in the plan: Global Constraints carry concrete examples
from the codebase, not abstract rules. And review:code checks codebase consistency as a
distinct lens. But drift across PRs is harder to catch than drift within one — the reviewer
sees only its own diff.

**Tests that pass but prove nothing.** TDD says write a failing test first, but an agent
can write a test that passes, exercises the code path, and asserts something true, but tests
the implementation detail rather than the behavior. Over time you accumulate a suite that is
green but brittle. The defense: review:code checks test quality with the "name the
production change that would make this test fail" rule from `writing-good-tests.md`.

**Plans that are correct but unnecessarily complex.** The plan passes adversarial review,
every task has code, implement builds it without asking. But the plan introduced an
abstraction the codebase doesn't need, or split work across files when one would do. Over
months, correct-but-complex plans produce a codebase that is locally correct and globally
tangled. The defense: review:plan now has a simplicity lens, and the plan stage has a
simplicity self-check. But the strongest defense is the spec — you control the scope.

**Context loss across stages.** The planner understood why it chose a particular
decomposition. Implement starts fresh and rebuilds context from the plan text alone. When the
plan says "create `lib/auth/token.rb`", the planner knew it was because `lib/auth/session.rb`
already exists — implement doesn't know that unless the plan says so. The defense: the plan's
Global Constraints section and per-task file context. But every fact the planner carries that
it doesn't write down is a fact implement has to rediscover.

**Accumulation of correct-but-mediocre code.** The holistic code quality problem the design
doc defers. Each PR passes tests and review, but over months the codebase grows ten slightly
different patterns for the same thing, utility functions that overlap, files that grew one
task at a time. No individual stage catches this because each one sees only its own diff.
The deferred `refactor` route and periodic survey are the planned responses.

---

## What is NOT in any stage

These appear in the source skills but have no place in mill's pipeline:

| Practice | Why it's excluded |
|---|---|
| Dispatching subagents from within a stage | mill runs each stage as one process; parallelism is mill's job, not the stage's |
| Creating worktrees | The supervisor creates the worktree before the stage starts |
| Opening or merging PRs from implement | The `pr` stage handles this after review:code has gated it |
| Choosing models | The stage table fixes the model; stages don't choose |
| The five-round fix loop | mill's ledger and re-review handle retries at the graph level |
| Presenting option menus to a human | There is no human; gates become block-with-questions |
| "Finishing a development branch" from within implement | The PR is mill's last stage, separated by a review |
| The `using-superpowers` startup hook | It tells every session to hunt for skills aggressively; stages should follow their assigned skill only |
| Wave-based parallel execution | Deferred; mill runs tasks serially within one implement process |
