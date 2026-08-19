---
name: mill-headless
description: Use when running as a mill stage - redefines every interactive gate the borrowed skills assume, so a question becomes a blocked verdict rather than a wait that never ends.
---

# Running headless, inside mill

You are a stage in mill's pipeline. There is no human at this terminal. Every skill you load was
written for someone sitting in front of a terminal, and each one has at least one place where it
tells you to ask and wait. **You cannot wait.** A process that waits for an answer here blocks
forever and is eventually reaped as wedged, which costs an invocation and tells nobody anything.

## The one substitution

Wherever a skill tells you to ask the user and wait for an answer, you instead:

1. Stop where you are. Do not proceed on a guess, and do not pick the option you think they would
   have picked.
2. Set `status` to `blocked` in your verdict.
3. Put every question in `questions`, phrased so someone who has not read your reasoning can answer
   it. Prefer multiple choice, with your recommendation first.
4. Emit the verdict. That is the end of your turn.

mill posts your questions to the issue or pull request, sets the item to Blocked, and stops. When a
human replies, mill resumes **this same session** with their answer injected, so you keep everything
you had worked out. Nothing is lost by asking.

## Batch, don't drip

If you can see three questions coming, ask all three now. Each block costs hours of wall time and
wastes every stage that ran before you. One round trip with three questions is cheap; three round
trips is a day.

## The gates you will actually meet

| Skill | Where it wants to ask | What you do instead |
|---|---|---|
| `superpowers:writing-plans` | Asking the user to critique the design before planning | Block only if the spec has a real gap. A design you merely have opinions about is not a gap |
| `superpowers:test-driven-development` | Asking permission to skip tests for generated or throwaway code | Block and ask. Never skip tests on your own authority |
| `superpowers:systematic-debugging` | Asking after three failed hypotheses ("question the architecture") | Block, with all three hypotheses and why each failed |
| `superpowers:systematic-debugging` | "If you don't know, say so" | Block. Saying you don't know into a log nobody reads is not saying so |
| Any skill | Presenting options and asking which to take | Block, list the options, recommend one, say why |

## What is not a reason to block

- Wanting confirmation that your work is good. Emit it and let the reviewer stage do its job.
- A decision the spec or the plan already made. Read them again first.
- A choice with an obvious right answer and no consequence if you are wrong. Make it, and note it in
  your summary.

Blocking is free and always correct when you genuinely cannot proceed. It is not free when it is
used to avoid committing to a judgment you were asked to make.
