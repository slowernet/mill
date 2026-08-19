---
name: pr
description: Use when mill's pr stage opens the pull request - verify tests with fresh evidence, compose the body from what the run produced, push, and open it. mill never merges.
---

# Opening the pull request

The work is done and reviewed. Your job is to prove it still passes, describe it honestly, and open
the pull request. **mill never merges**, and stages never comment.

## 1. Verify, with fresh evidence

Run the full test suite. Read the exit code and the full output.

This is a gate, not a formality. You may not write "tests pass" because they passed for an earlier
stage, because the code looks right, or because you are confident. Identify the command that proves
the claim, run it, read all of the output, confirm it says what you think it says — and only then
make the claim.

**If anything fails, block.** Report the failing tests and their output in `questions`. Do not fix
them: the fixing stages have already run and been reviewed, and a fix you make here would go out
unreviewed. Nothing else happens until the suite is green.

## 2. Compose the body

Someone is going to read this pull request and decide whether to merge it. That is the only human
gate on everything mill produced, so write for them:

- **What this changes, and why** — from the spec, in a paragraph, not a list of file names.
- **How it was built** — the plan, if the run had one, linked by path.
- **What the reviewers raised, and what happened to it** — every objection, and whether it was fixed
  or argued down. Do not quietly drop the ones that were not acted on.
- **Test evidence** — the command and its output.
- **What it cost** — the per-stage token usage mill gave you.
- **An evidence sample table**, if this run required one.

Do not oversell it. A pull request body that reads as advocacy makes the reviewer's job harder,
because they then have to work out what you left out.

## 3. Push, and hand mill the pull request

Push the branch to origin. That is the only network call you make.

Then report `title` and `body` in your verdict. **mill opens the pull request with exactly what you
return**, so the body is not a draft and not a summary of a body — it is the pull request.

## Why you do not call the API yourself

Two reasons, and neither is that you are not trusted with it.

`gh` cannot verify TLS inside your sandbox: it asks macOS to evaluate the certificate chain, and
that path is blocked, while `curl` and `git push` reach the same host perfectly well. Measured
across three attempts before this was changed.

And it is the better shape anyway. Every GitHub call mill's side makes now goes through one place,
which is what makes the comment marker and the no-merge rule enforceable rather than remembered.
`gh pr merge` is not something you could reach even by accident. **mill never merges** — reading the
pull request is the human gate, and a factory that merges its own output is a dark factory.

## Do not report a pull request number

mill recovers it with `gh pr list --head <branch>`, which is idempotent. A crash between opening the
pull request and recording it reconciles rather than opening a second one. Reporting it would make
that reconciliation a guess.
