---
name: implement
description: Use when building a plan mill has handed you - one task at a time, test first, a commit per task, ticking the plan's checkboxes as the ledger.
---

# Building a plan, headlessly

You have one plan and one process. You will work through it task by task until every checkbox is
ticked, or until you hit something you genuinely cannot resolve.

**The iron law: no production code without a failing test first.** A test you did not watch fail
proves nothing — it may be passing because the feature already exists, or because the test is wrong.

## Before the first task

1. **Read the plan once, end to end.** Note the Global Constraints: they carry the codebase
   conventions, the test command, and the exact values from the spec. You will not re-read the whole
   plan for each task, so take what you need now.
2. **Read the checkboxes.** Any task already ticked `[x]` is done. Confirm against `git log` that its
   commit exists, then skip it and resume at the first unticked task. This is how you recover from a
   compacted context or a resumed session — the plan file is the ledger.
3. **Scan for conflicts once.** Tasks that contradict each other, or the Global Constraints. If you
   find any, block with all of them described at once rather than discovering them one at a time.

## The per-task loop

**Read the task.** Files, interfaces, steps. Exact values — signatures, magic strings, test cases —
come from the plan text verbatim. Do not re-derive what the plan already decided; the planner made
those choices for reasons you cannot see from here.

**If the task is too vague to execute** — a step with no code, an interface with no signature, a
missing test command — block and say precisely what is missing. This should be rare. The plan stage
ran a buildability test and a reviewer checked it, so if you are here the plan has a gap. Do not
paper over it.

Then, for each step:

1. **RED.** Write one minimal test showing what should happen. A clear name, real behaviour, one
   thing. Real code, not mocks, unless a mock is genuinely unavoidable.
2. **Verify RED.** Run it. Confirm it fails, and read the failure — it must fail because the feature
   is missing, not because you mistyped. If it passes, you are testing something that already works;
   fix the test.
3. **GREEN.** Write the simplest code that passes. No extra features, no refactoring, no
   improvements beyond what the test demands.
4. **Verify GREEN.** Run it. Confirm it passes, that the other tests still pass, and that the output
   is pristine — no stray warnings, no incidental errors.
5. **REFACTOR.** Only once green. Remove duplication, improve names, extract helpers. Keep the tests
   green. Do not add behaviour.

**Match the codebase.** The Global Constraints carry concrete examples. If five methods use symbol
keys, the sixth does too. Do not introduce a pattern this codebase does not already use, however
much you prefer it.

**Run the focused test while iterating; run the full suite once before committing.**

## Finishing a task

**Self-review before you report.** Four questions, honestly:

- *Completeness* — did I implement everything the task asked for? Any requirement skipped? Any edge
  case the task named and I did not cover?
- *Quality* — is this my best work? Are the names clear? Would I be happy to find this code?
- *Discipline* — did I build only what was asked? Did I follow the existing patterns rather than
  imposing mine?
- *Testing* — do the tests verify real behaviour? Did I actually watch each one fail first? Is the
  output clean?

**Evidence, not assertion.** The task is done when you can show the covering tests, the command you
ran, and its output. "Tests pass" without the output is the same failure as producing no verdict.

**Commit the task's work** — implementation and tests together, one commit per task — **and tick the
checkbox in the plan file in that same commit.** The ticked plan plus `git log` is the only thing
that survives a compacted context, and it lands in the pull request showing exactly what was done.

## When you are in over your head

Stop. Report what you attempted, what you are stuck on, and what you have already tried. Block with
questions rather than producing work you do not believe in. Escalating is always correct. Bad work is
always worse than no work, because someone has to find it first.

## When every task is ticked

Run the full test suite one final time. Verify every checkbox is ticked. Then emit your verdict: `ok`
with the list of commits and the test output, or `blocked` with questions if any task could not be
finished.

## What this skill deliberately does not do

Creating a worktree (mill made it and handed it to you), dispatching subagents (you hold no such
tool, and an instruction is not a capability), running your own review-and-fix loop (mill's
`review:code` stage does that, and a second retry ledger mill cannot see would corrupt the first),
opening a pull request (mill's `pr` stage, after review), and choosing models (mill's stage table).
