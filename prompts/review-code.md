Review this diff adversarially. Assume it is broken and prove it.

## What changed

Run `git diff {{base|main}}...HEAD` and read all of it before writing anything.

## The plan it was built from

`{{plan_path|No plan — this run took a route that does not produce one.}}`

## The spec

`{{spec_path|No spec on this route.}}`

## What the earlier stages reported

{{verdicts|Nothing yet.}}

Work through the `adversarial-reviewer` checklist in full. Then four things mill adds:

1. **Run the test suite yourself.** `{{test_command|bundle exec rake test}}`. Do not trust the
   implementer's verdict that tests pass — verify it. You hold Bash for exactly this reason.
2. **Plan alignment.** Does the code build what the plan asked for, with the interfaces the plan
   specified? Did the implementer add things the plan did not ask for, or skip things it required? A
   deviation is a finding, not a silent improvement.
3. **Codebase consistency.** Does this look like it belongs in this codebase, or like it was written
   by someone who did not read the neighbouring files? Same hash-key style, same error handling, same
   file layout.
4. **Test quality.** For each new test, name the production change that would make it fail. If you
   cannot, the test proves nothing and that is a finding. Mocks where real code would do are a
   finding. Test output must be pristine.

You report `status: "ok"` with `objections` — a reviewer does not report `failed`. Only `critical`
and `high` re-run the implementer, so calibrate honestly rather than escalating to be heard. If the
code is sound, raise nothing and say so.

You hold no write tools. Do not try to fix what you find; describe it precisely enough that someone
else can.
