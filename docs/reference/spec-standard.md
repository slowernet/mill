# Spec standard for mill

A spec committed to this repo will be read by a planner that writes tasks from it, an
implementer that writes code from those tasks, and a reviewer that checks that code — all
running unattended. None of them can ask you what you meant. Every judgment call left in the
spec is a potential block (hours of wall time) or a wrong guess (a wasted pipeline run).

This is not about adding detail for its own sake. "Use the standard Sequel migration pattern"
is fine — the planner reads the codebase and follows it. "Handle errors appropriately" is not
— "appropriately" is a judgment call the planner shouldn't make. The test is whether the
planner would have to make a *decision* the spec should have made.

## The eight checks

Run these after brainstorming's own self-review (placeholders, contradictions, scope,
ambiguity), before committing the spec.

### 1. Exact values at every decision point

Every threshold, timeout, limit, default, and format should be in the spec. If the planner
has to invent a number, it either guesses or blocks.

- Bad: "rate-limit the poller"
- Good: "the poller ticks every 60 seconds"
- Bad: "cap concurrent runs"
- Good: "at most 3 concurrent runs"

### 2. Concrete error handling

Name what happens when things go wrong. "Handle errors gracefully" forces the planner to
invent an error strategy.

- Bad: "handle GitHub API errors"
- Good: "when a GitHub API call fails, retry with backoff up to three times, then block the
  item and comment with the error"

### 3. Where it fits in the existing code

Not exact file paths (that's the plan's job), but which components the work touches and how
they relate to what already exists.

- Bad: "add a supervisor"
- Good: "add a supervisor as a thread in the Puma process, alongside the poller thread, in a
  new `Mill::Supervisor` class"

### 4. Mechanically testable requirements

An agent can verify "the run list shows subject, route, stage, status, and tokens for each
run." It cannot verify "the UI should look clean." Each qualitative requirement needs to be
rewritten as an observable behavior with a specific output.

- Bad: "the dashboard should be informative"
- Good: "GET / returns a table with one row per run, showing subject, route, current stage,
  status, and total tokens"

### 5. Explicit non-requirements

Spec silence is ambiguous. "I didn't mention pagination" could mean "don't add it" or "I
forgot." Naming what's out prevents the planner from overbuilding, guessing, or blocking.

- Bad: (no mention of pagination)
- Good: "do NOT add pagination; the run list is small enough to render in full"

### 6. Edge cases and boundary conditions

Each unaddressed edge case is a planner guess or a block. Name the important ones and say
what should happen.

- Bad: "import users from a CSV"
- Good: "import users from a CSV. If the file is empty, return an error. If a row is
  malformed, skip it and log a warning. If two rows have the same email, keep the last one"

### 7. Dependencies and sequencing

State what must already exist versus what the spec creates. A precondition the spec assumes
without stating is a block waiting to happen.

- Bad: "write status to the board"
- Good: "write Status to the GitHub Project board. The board, its fields, and their option
  ids must already exist — setup is a separate runbook, not part of this work"

### 8. Sized for one readable PR

One spec produces one plan, one run, one pull request. If the work is an epic, split it
before mill sees it: a sequence of specs, each independently shippable, each on its own
issue with its own linked branch, released in order. mill does not stack branches, so
release a dependent spec only after its predecessor's PR merges.

Two reasons beyond reviewability. `implement` gets roughly two 30-minute launches before
its strikes run out, so an oversized plan does not fail fast — it fails slowly, burning
strikes on healthy work. And review convergence degrades with diff size: more findings per
pass, more re-runs, more blocks.

- Bad: one spec titled "billing system"
- Good: "billing: plans and prices table", then "billing: checkout flow", then "billing:
  invoices and receipts" — three specs, three PRs, released in order

There is deliberately no numeric task cap — task sizes vary too much for a count to mean
anything. The test: would you read the resulting PR in one sitting? Would the plan fit
implement's time budget with room for one review-driven re-run?

## The finishing question

After the seven checks, read the whole spec one more time and ask:

**"Could a planner write the exact code from this, without asking me anything?"**

For each section, would the planner know:
- Is it one PR's worth? (an epic is a sequence of specs, not one spec)
- What to build? (the requirement)
- How to build it? (the approach, at least at the component level)
- What exact values to use? (thresholds, limits, defaults, formats)
- What to do when things go wrong? (error handling for each failure mode)
- What NOT to build? (scope boundaries)
- How to test it? (observable behavior, specific outputs)
- Where it goes? (which component, how it relates to existing code)

If any answer is "no, they'd have to guess or ask me," fill the gap now. Ten seconds in your
terminal versus hours of wall time waiting for a block to clear.
