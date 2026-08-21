# Plan 3a — review triage and work queue

Four hostile reviewers went over `plan-3a-autonomy` vs `main` on 2026-08-20, after PR #1 was
opened, and reported 57 findings. This is those findings sorted into root causes and ordered into
work, plus one blocker the reviewers could not see. The raw untriaged report was
`tmp/2026-08-20-3a-adversarial-review.md`, which is gitignored; everything worth keeping is here.

**Working rule for this queue: one root cause per session.** Failing test first, then the fix, then
a fresh subagent reviewer on that fix before starting the next. Batching is what produced these
findings — see "What this says about the process" at the end.

## Contents

- [Where things stand](#where-things-stand)
- [Blocker zero: CI has never been green](#blocker-zero-ci-has-never-been-green--fixed-2026-08-20)
  - [Still open: mill gives its own clones no identity either](#still-open-mill-gives-its-own-clones-no-identity-either)
- [Done: the four tests that passed for the wrong reason](#done-the-four-tests-that-passed-for-the-wrong-reason)
- [The eight CRITICAL findings are six root causes](#the-eight-critical-findings-are-six-root-causes)
- [HIGH findings that block a merge](#high-findings-that-block-a-merge)
- [HIGH findings that do not block](#high-findings-that-do-not-block)
- [MEDIUM](#medium)
- [LOW](#low)
- [Open design questions](#open-design-questions)
- [Suggested session order](#suggested-session-order)
- [What this says about the process](#what-this-says-about-the-process)

## Where things stand

PR #1 is open and `MERGEABLE`. Its CI check is red and will stay red until the three remaining
deliberately-red tests below have their bugs fixed.

Committed on the branch, 2026-08-20:

- The four honest tests, in `test_spawn.rb`, `test_supervisor.rb`, `test_poller.rb` and
  `test_ledger.rb`. Three are still red on purpose; the ledger one now passes.
- `CLAUDE.md` — the signalling invariant scoped to *stored* pgids, with `announce_spawn` named as
  the one exception. This was needed before anyone could act on the spawn test.
- `test_repo.rb` — blocker zero, below.

**Check `git status` before starting: work may be sitting uncommitted.** As of 2026-08-21 the
rate-limit fix (`ledger.rb` and its two test files) and two documentation changes were finished and
verified but not committed. The design doc and this note each carry two unrelated topics in that
state, so splitting them means staging by hunk rather than by file.

Suite: 488 runs, 3 failures, 0 errors, on the laptop and on the runner alike. `ledger.rb` is the only
file under `lib/` that has been touched; every other bug in this queue is still present.

## Blocker zero: CI has never been green — FIXED 2026-08-20

Not in the review. All four reviewers ran on the author's laptop, so none of them could see it.

Six `TestRepo` tests errored on a clean runner with `fatal: empty ident name`. `git clone` copies no
config, so a clone has no identity of its own, and `commit_to_base` committed into one. It passed
locally only because git invents an identity from the macOS account record; the CI `runner` account
has an empty GECOS field, so git had nothing to invent from.

Affected: `test_a_config_file_that_does_not_parse_blocks_the_item`,
`test_a_config_file_that_is_not_a_mapping_is_ignored`,
`test_a_config_file_with_a_disallowed_class_blocks_the_item`,
`test_a_named_secret_that_is_absent_blocks_the_item`,
`test_a_named_secret_that_is_present_does_not_block`,
`test_reads_the_config_from_the_base_branch_only`.

All six commit into a clone the test's own `place_clone` made — not, as first written here, one
that `Mill::Repo.prepare` produced. The fix gives the identity to the tests that commit, via an
`identify` helper called from `place_clone` and `commit_to_base`, and `TestRepo#setup` now disables
git's identity invention so the laptop reproduces the runner instead of hiding it.

**This does not turn the CI check green**, and the earlier wording here was too loose. `rake test`
still exits non-zero on the deliberately-red tests below, so the badge stays red until those bugs
are fixed. What it restores is *signal*: the failure list is now known bugs and nothing else, where
before it was those bugs plus six errors that said nothing about the code.

### Still open: mill gives its own clones no identity either

Same cause, different scope, and not fixed. `Mill::Repo.prepare` writes `gc.auto` and
`maintenance.auto` to the clone (`repo.rb:71`) and no identity. Stages commit inside worktrees of
that clone, and `prompts/implement.md` tells the implement stage to make a commit per task. On a
server whose account has no `~/.gitconfig` — the `ubuntu-latest` shape mill's own CI runs on, and
the deployment target the design doc describes — that first commit fails, the stage is charged a
strike, and the run burns its attempts on something the machine did to it. Nothing tests this and
`Mill::Doctor` does not check it.

**Decided 2026-08-20, written up in the design doc under "Setting up, and preparing a repo".** The
identity is mill's own setting, not a `.mill.yml` key, because that file lives in the repo being
worked on and its base branch decides what name your credentials would push under. You are the
author and mill is the committer, named `mill` at the author's address, set through
`GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` in `Mill::Rules.env_for` (`rules.rb:89`). Unset, the
author falls back to the machine's git config, so a laptop needs nothing — and `rake mill:doctor`
fails when nothing resolves, so a bare server is caught at setup rather than mid-run.

Not implemented. It needs `Repo.prepare` to write the identity beside `gc.auto` (`repo.rb:72`), the
two committer variables in `env_for`, a doctor check, and a test that a prepared clone commits with
the right author and committer. It sits below the critical bugs in the queue: mill works on a laptop
today, and the criticals do not.

Note this leaves every commit mill has made so far authored as the operator, indistinguishable in
`git log` and `git blame` from work typed by hand.

## Done: the four tests that passed for the wrong reason

Each was rewritten to fail for the reason its bug actually causes. Each is red now, and each is
proven to go green under a correct fix. The bugs themselves are all still present.

**`test_the_group_dies_even_when_the_boot_time_is_unreadable`** — `spawn.rb:182`.
`announce_spawn`'s rescue calls `Spawn.reap`, which returns `:unknown_boot` without signalling when
the host cannot read its own boot time. The group is orphaned and the raise parks behind the child
for 30 seconds. The old test passed only because this machine can read `kern.boottime`.
Verified fix: have `announce_spawn` signal the group it just created. `Spawn.reap`'s boot gate must
NOT be loosened — `Supervisor#reap` feeds it pgids straight out of the database, and
`test_hostile_input` pins it at `:unknown_boot`. Confirmed: the contained fix turns the spawn file
green and leaves `test_hostile_input` passing, and the file drops from 13s to 7.6s.

**`test_an_interrupted_run_is_started_again`** — `supervisor.rb:184`. `restart` checks `at_cap?`,
which counts running rows, and the interrupted run being restarted is itself one of them. The guard
can only ever refuse; it never has capacity to protect. The old test passed only because the default
cap of 2 left headroom for its single run — it now sets `MILL_CONCURRENCY=1`.
Fix: remove `return if at_cap?` from `restart`. Verified green with no collateral.

**`test_a_failed_start_leaves_the_answer_to_be_retried`** — `poller.rb:110`. `start` flips the run
to `running` inside `resumed` and only then tells the board, so a project whose Status field has no
matching option raises after the row has already moved. The retry then finds no blocked run, the
event goes to `no_route`, and the answer is lost. The old test used a fake whose `start` raised
before touching the row, so it proved nothing about the real supervisor.
The rewrite drives the real `Mill::Supervisor` with a board that raises, and asserts both that the
event is pending and that the run is still `blocked`. Both repair sites were tried and both turn it
green: restore-on-raise inside `Supervisor#start`, or restore in the poller's rescue. Deliberately
fix-location-agnostic — the first draft of this test pinned the repair to the poller and would have
stayed red under the more natural supervisor-side fix.

**`test_a_throttled_stage_that_still_finished_keeps_its_work`** — `ledger.rb:66`. FIXED 2026-08-21,
see item 2 in the session order. `classify` read the rate-limit flag before anything else. Every
existing rate-limit test paired `rate_limited: true` with `success: false`, so none could see it.
The fix is `return :rate_limited if attempt.rate_limited? && !attempt.verdict.valid?` — the verdict
decides, not the exit status. It must stay ahead of `resume_failed?` or
`test_the_limit_outranks_a_failed_resume` breaks.

Two wrong turns on the way, recorded so nobody takes them again. Gating on `!attempt.result.success?`
looks equivalent and is not: nothing in mill has measured what a refused launch exits with, the
file's own cited incident is a window closing *mid-run* (so a non-zero exit from a launch that did
run), and gating that way drops the rate-limit wait for any refusal that exits cleanly — turning a
free outcome into a strike plus an immediate relaunch into a closed window. Then, charging the
adjacent case a strike is tempting and also wrong; see the open questions below.

Note the review described `Stream#rate_limited?` as a sticky stamp. It is not: `on_rate_limit`
clears it on an `allowed` heartbeat (`stream.rb:141`). The bug is real anyway — the reachable case
is a refusal that is the last rate-limit event before the result line arrives, with no heartbeat in
between to clear it.

## The eight CRITICAL findings are six root causes

Three reviewers independently reported the two-walker race and two reported the rate-limit
misclassification, which is the strongest signal in the set.

1. **`classify` read the rate-limit flag before anything else** — `ledger.rb:66`, `runner.rb:139`,
   `stream.rb:75`. A stage that was throttled, recovered and finished had its verdict discarded.
   `COST[:rate_limited]` inserts no row, so `next_attempt` does not advance and the relaunch reuses
   the log filename, destroying the successful run's log.
   **HALF FIXED 2026-08-21.** A throttled stage that finished now keeps its work. A launch that ran,
   hit the window partway and handed back nothing is still priced as though it never launched, and
   still loses its log and its session — that half is item 2b in the session order.

2. **`reap` discards what `Spawn.reap` returned** — `supervisor.rb:135`. `Supervisor#identify`
   accepts ±2s of clock drift; `Spawn.identify` requires exact equality. One second of disagreement
   means the supervisor orders a kill that Spawn refuses as `:recycled`, and the supervisor never
   looks at the answer — it interrupts and restarts on top of a stage that is still running. Same
   outcome via `:no_pgid`, `:unverified` and `:survived`. On Linux that second is free, because
   `/proc/stat` btime jitters after an NTP step.

3. **`interrupt` raises when `current_stage` is NULL** — `supervisor.rb:139`. The `Mill::Error`
   escapes `filter_map` and aborts the whole sweep, the row is never repaired, and it raises again
   every tick forever — for every run, not just that one. A run claimed but not yet started is
   exactly that state. So is a run left `running` by the failed-start bug above.

   Before writing the fix, decide what a `running` row with no `current_stage` *means*, because the
   three plausible fixes disagree about it. Charging nothing and moving on keeps the sweep alive but
   silently tolerates a bookkeeping failure, and the existing test
   `test_a_running_run_with_no_stage_is_an_error_rather_than_a_no_op` says that is deliberately not
   wanted. Repairing the row — setting the stage to the route's first — invents a fact mill does not
   know. Keeping the raise but containing it, so one bad row is skipped and reported while the sweep
   finishes, preserves both the loud failure and the other runs. The third looks right, but note it
   changes what `reap` returns and the existing test asserts the raise reaches the caller. Whichever
   way, the fix must not swallow the condition: a claimed run that never started is a real fault and
   the point is that it stops being a *fatal* one.

4. **`start` flips the row to `running` before registering its thread** — `supervisor.rb:76`,
   `workers.rb:56`. The window spans a GraphQL mutation. Inside it `identify` returns `:gone`, so
   the reaper charges an interruption nobody earned and spawns a second walker: two `claude`
   processes under `--permission-mode acceptEdits` in one worktree, two ledger writers, and
   whichever finishes first tears the worktree down under the other. Three unearned interruptions
   blocks the run citing interruptions that never happened.

5. **Comment fetch is scoped to a repo-wide cursor** — `poller.rb:145`. `fetch` scopes by
   `repo[:comments_cursor]`, not by anything belonging to the run. On a repo whose cursor is nil —
   every repo on day one — `trigger?` accepts every trusted comment ever written on the subject, and
   `dispatch` orders by id so the oldest wins. Reproduced: `delivered answer = ["lgtm, ship it"]`
   with the real answer marked `no_route`. That text becomes prompt text for a subprocess holding
   real credentials.

6. **An item mill refuses to start is re-commented every tick, forever** — `poller.rb:204`.
   `block_item` and `no_spec` post a comment and write no Status — they cannot, because `Board#want`
   keys on a run id and no run exists. `active?` stays false, the item stays `Ready`, and it is
   re-picked next tick. Reproduced at 10 comments in five ticks, plus a `git clone` or `git fetch`
   retry per tick.

## HIGH findings that block a merge

- **`stop` then `start` leaves both threads permanently dead** — `workers.rb:62`. `@stopping` is
  never cleared, so `loop_thread`'s `until @stopping` exits immediately. Verbatim:
  `after start: true/true`, `after restart: false/false`.
- **`start` twice runs two poller loops and two reap loops** — `workers.rb:52`. The orphans are
  invisible to `health` and `stop`. The file's premise is one of each.
- **A misconfigured board stops the comment sweep and dispatch entirely** — `poller.rb:32`.
  `@board.redrive` raises first in `tick`. Proven: `comment fetches attempted = 0`, every tick.
- **Doctor certifies a public bind on an env var nothing reads** — `doctor.rb:230`.
  `MILL_ADMIN_EMAILS` appears in exactly two places, this check and its own test. `app.rb` has no
  authentication at all. The loopback test is also a substring match.
- **`claim` orphans a run row and worktree when the board write fails** — `supervisor.rb:69`.
  `@board&.want` is outside the transaction and outside the `discard` rescue. Proven:
  `rows=1 status=running stage=nil worktree=true`, holding a cap slot for the life of the database.
  Note the orphan is also root cause 3's poison row.
- **`finish` raising turns a finished run into a failed one and posts both stories** —
  `supervisor.rb:79`. Proven: `status=failed worktree_left=true comments=2`. GitHub gets "Opened #7"
  and then "This run failed", and teardown never runs.
- **`restore` and the sanctioned strike reset are unreachable in production** — `runner.rb:48`,
  `supervisor.rb:76`. `resumed` sets `running` before `Run.adopt` reads the status, so every
  poller-driven resume takes `reload`. A stage out of strikes re-blocks with the identical message
  on every answer, forever. Only `rake mill:answer` still reaches `restore`. Fixing root cause 4
  may fix this too — check.
- **`Repo.slug` throws the host away** — `repo.rb:31`. Reproduced:
  `git@gitlab.com:slowernet/mill.git`, `https://evil.example.com/...` and `/Users/eliot/code/mill`
  all collapse toward the same local clone.

## HIGH findings that do not block

- A comment created in the same second as the cursor is discarded forever — `poller.rb:167`.
  `> cursor` is strictly greater at second granularity while `since` is inclusive. The filter is
  redundant, since the unique index already dedupes, so it only ever loses data.
- One cursor per repo strands comments on every other subject — `poller.rb:158`. Same root as
  critical 5; likely fixed by the same change.
- A stale board write that lands late is stamped unrecoverable — `board.rb:78`.
- The `running?` guard does not stop two walkers — `poller.rb:108`.
- A refused launch destroys the stage's session id — `runner.rb:129`. The `@sessions` assignment
  runs before the `case`. Tests miss it because `scripted` hardcodes `session: 'sess-1'`.
- `reload` restores sessions the runner deliberately discarded, and discards an interrupted stage's
  — `runner.rb:67`.
- A slow `git worktree add` inside `claim`'s transaction fails healthy concurrent runs —
  `supervisor.rb:59`, `runner.rb:94`. Measured: `second write RAISED after 6.2s: BusyException`.
- A chmod-drifted secrets file raises out of `Repo.prepare` and stops the whole poller —
  `repo.rb:81`. `prepare` rescues `Mill::Git::Error`; `check_mode!` raises its parent `Mill::Error`.
  The method's own comment claims this cannot happen.
- `.mill.yml` falls back to a local ref a stage can move — `repo.rb:102`.

## MEDIUM

- A stage that already succeeded is charged an interruption and re-run — `supervisor.rb:190`.
- `clear_stale_locks` deletes locks belonging to a live git process — `supervisor.rb:283`. Also
  `Dir[]` treats `[`, `{`, `*` in the path as glob syntax, so such a clone clears nothing silently.
- A failed teardown wedges the branch with nothing to retry it — `supervisor.rb:104`.
- The second half of a two-part answer is silently discarded — `poller.rb:107`.
- `interference?` has no production callers — `board.rb:51`. The design doc, the failure taxonomy
  and the runbook all say mill reports a Status it did not write. It does not.
- An unrecoverable board failure retries forever with no log line — `board.rb:80`.
- An event skipped by `running?` is skipped forever with nothing recorded — `poller.rb:108`.
- `INSERT OR IGNORE` swallows every constraint violation while the cursor advances — `poller.rb:171`.
- `@rate_limit_waits` is a per-run budget spent by every stage, and reset by any restart —
  `runner.rb:162`.
- Nothing can raise from the `rescue` clause without killing the loop for good — `workers.rb:101`.
- A hung `gh` parks a loop forever and `health` calls it alive — `workers.rb:72`.
- `health` cannot distinguish "workers off" from "both threads died" — `workers.rb:53`.
- `stop` is dead code, and would not stop the run threads if called — `config.ru:3`.
- `base_branch` truncates any default branch containing a slash — `repo.rb:93`.
- A missing `origin/HEAD` silently becomes `main` — `repo.rb:94`.
- `missing_secrets` accepts a key with an empty value — `repo.rb:121`.
- A leftover directory at the clone target wedges a repo permanently — `repo.rb:41`.
- Doctor never checks `Ready`, the one Status the queue depends on — `doctor.rb:254`.
- `read_config` ignores whether the fetch worked, and caches the result forever — `repo.rb:101`.

## LOW

- The "waiting" notice is suppressed for the life of the process — `supervisor.rb:249`.
- The cursor stores `created_at` but `since` filters `updated_at` — `poller.rb:154`.
- An item with no repository or number is dropped with no trace — `poller.rb:196`.
- `no_route` is a fourth event state the schema does not document — `poller.rb:126`.
- `want` writes a decision an unconfigured board can never act on — `board.rb:37`.
- `MILL_BIND=` binds nowhere — `config/puma.rb:4`.
- The rate-limit block message is off by one and names the wrong stage — `runner.rb:163`.
- `require './app'` creates `~/.mill` and opens the database — `app.rb:20`.
- A trailing slash on `origin` makes a clone invisible — `repo.rb:31`.
- `rate_limit_pause` calls `.to_i` on an unvalidated field — `runner.rb:183`.

## Open design questions

Cases where the obvious fix quietly decides something nobody has decided. Each should be settled
deliberately and pinned with a test, whichever way it goes.

- ~~An attempt with `success: true`, `rate_limited: true` and an **invalid** verdict.~~ **Settled
  2026-08-21: it stays free.** Charging it a strike needs a premise nothing has measured — that a
  refusal exits non-zero — and charging on an unproven premise is exactly how a stage gets blocked
  for a door mill could not open, which is the bug item 2 fixed. Revisit only with a recorded
  refusal transcript. Note this is the same state as item 2b, so pricing it correctly and fixing 2b
  are one job, not two.
- Lowering `MILL_CONCURRENCY` from 2 to 1 while two runs are live leaves both rows `running` at cap
  1. Today neither restarts. Removing the `at_cap?` guard restarts both, giving two walkers at cap
  1. Counting everyone-but-me deadlocks again. There is no obviously right answer.

## Suggested session order

Roughly fourteen sessions at one root cause each. The first four are ordered so that each one makes
the next easier to see.

1. ~~CI git identity~~ — done 2026-08-20. Restores signal, not a green check; the badge
   stays red until 2–10 land. Left behind: mill's own clones still carry no identity.
2. ~~Rate-limit misclassification (critical 1)~~ — done 2026-08-21. `classify` now asks the verdict
   rather than the flag, so a throttled stage that finished keeps its work. **Half of critical 1
   remains and is now item 2b.**
2b. A launch that ran, hit the window partway and handed back nothing is still priced as "no
   launch": no row, so the relaunch truncates its log and `reload` cannot recover its session.
   Telling a refusal from a cut-off launch needs the stream — a session id, a model, any turns —
   and pricing a launch that happened as an attempt costing no strike.
   `test_a_throttled_stage_that_did_work_and_said_nothing_is_priced_as_a_refusal` pins the bad
   behaviour on purpose and should be deleted by whoever fixes this.
3. `interrupt` raising on a NULL `current_stage` (critical 3) — a dead reaper hides everything else,
   and it is the failure mode that the `claim` orphan and the failed-start bug both feed.
4. `start`/`reap` race (critical 4) — check whether it also frees `restore` and the strike reset.
5. `reap` discarding `Spawn.reap`'s answer (critical 2).
6. Comment cursor scoping (critical 5) — likely also fixes the two cursor HIGHs.
7. Unstartable items re-commented forever (critical 6).
8. `announce_spawn` orphan — test already written and red, fix already verified.
9. `restart`'s `at_cap?` guard — test already written and red, fix already verified.
10. Failed start losing the answer — test already written and red, both fixes verified.
11–14. The remaining blocking HIGHs: the two `workers.rb` lifecycle bugs, `redrive` killing the
    tick, doctor's public-bind check, `claim`'s orphaned row, `finish` raising, `Repo.slug`.
15. mill's commit identity — decided but not built; see blocker zero above. Last because it is the
    only item here that is not a bug in shipped behaviour, and mill works on a laptop without it.

Merging before at least 1–10 means merging something that is not safe to run unattended:
`Workers.enabled?` defaults to on, so a stray `Ready` on the board reaches every critical path
above. If the branch needs to land sooner, the board-write and repo-preparation work is largely
independent of the poller and supervisor and could be split out first.

## What this says about the process

Several of these were **in the previous day's fixes**, not in the original code.

`resumed` writing `running` before the thread registers was added to fix a resumed run being
invisible to the reaper. It created the two-walker race, and separately made `restore` and the
one-per-run strike reset unreachable on every path the poller drives. The `:rate_limited`
classification was added to stop a subscription limit taking a strike, and became the most-cited bug
in the set.

That is the same lesson the design doc already records from the day before, arriving again one layer
down: **a fix is new code and deserves the same suspicion as the code it replaces.** The earlier
version was "reviews catch the layer they are looking at". This one is narrower and worse — the
fixes themselves were never reviewed, because they were made in response to a review and felt like
conclusions rather than like changes.

The 2026-08-20 session added a third turn of the same screw. The first rewrite of the failed-start
test baked the bug's current location into the test: it would have stayed red under the natural
supervisor-side fix, and a later session would have concluded a correct fix had not worked. A fresh
reviewer caught it by applying each candidate fix and running the test. Reviewing a *test* is worth
as much as reviewing the code, and the check that matters is not "does it fail now" but "would it
pass once this is genuinely fixed".
