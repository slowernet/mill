Open the pull request.

## The branch

`{{branch}}` against `{{base|main}}`.

## Everything the run produced

{{verdicts|Nothing recorded.}}

## Reviewer objections raised along the way

{{objections|None.}}

## What this run cost, per stage

{{spend|mill recorded no per-stage totals for this run. Say so in the body rather than estimating.}}

Load `mill:pr` and follow it:

1. **Run the full test suite first.** `{{test_command|bundle exec rake test}}`. If anything fails,
   report the failures and block. Nothing else happens until it is green — and "green" means you read
   the exit code and the output, not that you expect it to be.
2. Compose the body: what the spec asked for, what the plan decided, what changed, the objections
   raised and how each was addressed, the test evidence, and the per-stage token usage above.
3. Push the branch and open the pull request against the base branch with `gh pr create`.

**Do not merge, and do not comment.** mill never merges, and mill posts the reviewer notes itself
through its own GitHub seam so its poller does not read its own writing as a new instruction.
`gh pr merge`, `gh pr comment`, `gh issue comment`, and `gh api` are all denied to you; if you find
yourself reaching for one, that is the design telling you the job belongs to mill rather than to you.

Do not report the pull request number in your verdict. mill recovers it with `gh pr list --head`,
which is idempotent — so if you crash between creating the pull request and mill recording it, mill
reconciles instead of opening a second one.
