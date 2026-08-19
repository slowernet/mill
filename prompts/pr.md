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
2. **Push the branch** to origin. That is the only network call you make.
3. **Report `title` and `body` in your verdict.** mill opens the pull request itself, with exactly
   what you return — so the body is not a draft or a summary of a body, it is the pull request.
   Someone is going to read it and decide whether to merge.

**You do not call the GitHub API, and that is not a restriction you should work around.** `gh`
cannot verify TLS inside your sandbox, and mill has a working path from outside it. Every API call
mill's side makes now goes through one seam, which is also why `gh pr merge` is not something you
could reach even by accident. mill never merges.

Do not report a pull request number. mill recovers it with `gh pr list --head`, which is
idempotent — so a crash between opening the pull request and recording it reconciles rather than
opening a second one.
