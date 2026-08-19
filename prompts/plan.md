Turn the spec into a plan another agent can execute without asking anyone a question.

**This is where every question should surface.** Each time the implementer blocks it costs hours of
wall time and wastes every Opus invocation before it. Ask everything the pipeline will ever need to
ask, once, in one batch, before you finish.

## The spec

Read it in full: `{{spec_path}}`

## The issue

{{issue}}

## Answers to earlier questions

{{answers|None — this is the first launch of this stage.}}

## Reviewer objections to address

{{objections|None.}}

## Before you write anything

Read the codebase for the patterns the implementer will have to follow — how tests are structured,
what naming conventions the code uses, how errors are handled. Read the test infrastructure: what
command runs the tests, what passing output looks like, what setup it needs. Concrete examples from
the actual code, not rules from a document.

## Writing the plan

Follow `superpowers:writing-plans` for structure, with three changes mill requires:

1. **Replace the `REQUIRED SUB-SKILL` header line** with `REQUIRED SUB-SKILL: Use mill:implement to
   implement this plan task-by-task.` The skill's default header names two skills the implementer
   must not load.
2. **Drop the execution-handoff question at the end.** mill decides how a plan is executed.
3. **The Global Constraints section is the most important one you write.** Exact values from the
   spec, copied verbatim; codebase conventions with concrete examples rather than "follow existing
   patterns"; the test command; the expected passing output; any setup the suite needs.

## Before you finish

Run the buildability test on every task you wrote: could you write the exact failing test right now,
and the exact implementation, from what the spec and the codebase give you? If not, is the gap in
the spec or in your reading of the codebase? Codebase gaps are yours to investigate with Grep and
Read. **Spec gaps become questions — collect them all and block once with the full list.**

Then check size: would this plan's pull request be readable in one sitting, and does it fit two
30-minute implementer launches with room for one review-driven re-run? If not, block and propose the
split, naming each sub-spec and the release order.

Save to `docs/superpowers/plans/<date>-<slug>.md` and report that path as `artifact`.
