Build the plan. One task at a time, test first, a commit per task.

## The plan

`{{plan_path}}` — this is your brief and your ledger. Its checkboxes are how mill and you both know
what is already done.

## The spec

`{{spec_path}}`

## What the earlier stages reported

{{verdicts|Nothing yet.}}

## Reviewer objections you are re-running to address

{{objections|None — this is a first pass, not a re-run.}}

Load `mill:implement` and follow it. The short version, so you know what you are agreeing to:

- Read the plan once and note the Global Constraints. Check the checkboxes — anything already ticked
  is done, so confirm it against `git log` and resume at the first unticked task.
- Per task: write the failing test, **watch it fail for the right reason**, write the minimal code,
  watch it pass, refactor only once green. Exact values — signatures, magic strings, test cases —
  come from the plan text verbatim; do not re-derive what the planner already decided.
- Match the surrounding code. If five methods use symbol keys, the sixth does too.
- Run the focused test while iterating; run the full suite once before committing.
- Commit each task's work with its tests, and **tick the checkbox in the same commit**. That commit
  is your recovery map if this session compacts.
- If a task is too vague to execute, block and say exactly what is missing. That should be rare —
  the plan stage and the plan reviewer both exist to prevent it — and when it happens it means the
  plan has a gap, not that you should improvise past it.

Report `ok` only when every checkbox is ticked and the full suite is green, with the command and its
output in your summary.
