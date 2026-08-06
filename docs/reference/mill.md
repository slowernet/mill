# Mill reference

Domain vocabulary and operational reference. Architecture, the stage graph, the failure
taxonomy, and scope decisions live in
`docs/superpowers/specs/2026-08-06-software-factory-design.md`.

## Contents

- [Label vocabulary](#label-vocabulary)
- [Key models](#key-models)

## Label vocabulary

Mill creates these in a repository on enablement, and swaps them as a run progresses:
`mill:ready` becomes `mill:running` when a run is claimed, `mill:blocked` when it stops
for input, `mill:done` when the PR opens. The labels are the queue — the state of a piece
of work is legible in GitHub without opening Mill.

| Label | Meaning |
|---|---|
| `mill:ready` | Release this issue to the factory |
| `mill:running` | A run has claimed it |
| `mill:blocked` | Stopped for your input; reply in a comment to resume |
| `mill:done` | PR opened |
| `mill:small` | Force the small route (skip design and plan) |
| `mill:evidence` | The PR must include a before/after sample of real output |

## Key models

- **Repo**: an enabled GitHub repository, its resolved local clone path, and per-repo config from `.mill.yml`
- **Run**: one issue moving through the pipeline in one worktree on one branch
- **Route**: which graph a run walks — `full` (design, plan, implement, with adversarial review after each) or `small` (implement and review only)
- **Stage**: a node in the graph; one `claude -p` invocation with a fixed model and a named skill
- **Attempt**: one execution of a stage. Two per stage maximum, then the run blocks.
- **Verdict**: `.mill/verdict.json`, written by every stage as its last action. Status is `ok`, `blocked`, or `failed`; carries the artifact path, questions, objections, and a summary.
- **Event**: a GitHub occurrence the poller has seen, keyed on node id so it is processed exactly once
- **Evidence requirement**: a flag on a run meaning the PR must include a before/after sample of real output, judged by a human rather than by a metric
