# mill

A software factory: an orchestrator that drives Claude Code through a fixed software
development pipeline. Feed it a feature or bugfix spec, get a pull request.

You design interactively, in a normal terminal session. mill does everything after that - planning, adversarial review, implementation, more review - and opens a PR for you to read. It never merges; reading the PR is the gate.

Work arrives as GitHub activity: an issue with a spec on a linked branch, a comment on a
PR, a red CI check. A GitHub Project board is the queue. One Ruby process on your own
machine runs the whole thing.

**Status: the `plan` route works, end to end.** An issue with a spec on a linked branch goes in;
a pull request comes out. First real one on 2026-08-19: eighteen minutes, six stages, no strikes.

What does not exist yet is the automation around that core — no board polling, no supervisor, no
web UI, and only one of the three routes. The design doc's
[Where this stands](docs/superpowers/specs/2026-08-06-software-factory-design.md#where-this-stands)
is the honest inventory; the rest of that document is written in the present tense and describes
where this is going.

```
rake mill:doctor                 # every precondition, and what is missing
rake mill:run[owner/repo,42,~/code/repo]     # drive one issue through by hand
rake mill:answer[2,"..."]        # answer a blocked run and resume it
```

## Design docs

- [The design doc](docs/superpowers/specs/2026-08-06-software-factory-design.md) — the
  architecture, the stage graph, containment, the failure taxonomy, and why it's shaped
  this way.
- [The SDLC, beat by beat](docs/superpowers/specs/2026-08-18-sdlc-beats.md) — every step
  of every stage, and which existing agent skill each practice uses or was extracted from.
- [The spec standard](docs/reference/spec-standard.md) — what a spec must contain before
  an unattended pipeline can build from it without stopping to ask questions.

## Reference

- [Domain vocabulary and operational reference](docs/reference/mill.md)
- [Setup runbook](docs/reference/setup.md) — the board, the tokens, the permission rulesets,
  and a scratch repo to rehearse against

## Stack

Ruby, Roda, Sequel, SQLite, Puma, Minitest, vanilla JS, stdlib for nearly everything else.
mill drives [Claude Code](https://claude.com/claude-code), which has to be installed and
authenticated on whatever machine mill runs on.

## Built on

**[Superpowers](https://github.com/obra/superpowers)** by Jesse Vincent (MIT), and mill does not
work without it. Three stages load a Superpowers skill when they run — `plan` uses
`superpowers:writing-plans`, `diagnose` uses `superpowers:systematic-debugging`, and
`implement:fast` uses `superpowers:test-driven-development` — so the plugin must be installed for
those stages to do anything. `docs/superpowers/specs/` and `docs/superpowers/plans/` are its path
convention, which mill deliberately does not fork: mill writes to the same paths in every repo it
works in.

mill adds two things around those skills rather than changing them. `mill-headless` redefines the
interactive gates they assume, so a question becomes a verdict that blocks the run instead of a
wait that never ends. And each stage prompt adds what the skill cannot know — for the reviewers,
that the plan's own constraints are part of what is under review. The skills themselves are
unmodified, so they improve upstream without mill maintaining a fork.
[The SDLC, beat by beat](docs/superpowers/specs/2026-08-18-sdlc-beats.md) attributes every practice
to the skill it came from, and says which ones mill deliberately drops and why.

The idea of a software factory came from
[alexop.dev](https://alexop.dev/posts/the-software-factory/) and
[Addy Osmani](https://addyosmani.com/blog/software-factories/). What they describe is the shape;
the failure taxonomy, the attempt ledger, and the containment model are mill's answer to actually
running one unattended.
