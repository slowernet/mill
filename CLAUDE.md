# Agent instructions

## CRITICAL: Questions vs. actions

**STOP and ASK before making changes based on questions.**
We need to distinguish between the user thinking out loud vs. making an actual request.
The user may ask questions to understand the system, not to request changes. Do NOT implement solutions when the user is just exploring or asking "why" or "how".

**Question indicators** (EXPLAIN only, do NOT change code):
- "Why did you...?"
- "How does X work?"
- "Can you explain...?"
- "What happens when...?"
- "Does the logic allow for...?"

**Request indicators** (OK to make changes):
- "Please change..."
- "Update X to..."
- "Fix..."
- "Add..."
- After explicit confirmation: "Yes, do it" / "Go ahead" / "Make that change"

**When in doubt:**
1. EXPLAIN the current behavior and reasoning
2. ASK: "Would you like me to change this?"
3. WAIT for confirmation
4. THEN make changes

---

## Basic project facts

- This is a Ruby application built on the Roda web framework, with Sequel over SQLite, served by Puma, tested with Minitest
- mill is an orchestrator: it drives Claude Code through a fixed agentic SDLC for work that arrives as GitHub activity, and opens a pull request. It never merges.
- **Full automation only**: every stage must run unattended. Avoid any design that needs an interactive prompt, a terminal attached, or a human standing in the middle of the pipeline. When an agent cannot proceed, the answer is always to emit questions and block, never to wait.
- **Silence is never success**: a stage that produces no verdict has failed. Never infer a pass from the absence of an error.
- **Testing against GitHub**: use a scratch repo you own for end-to-end exercises. mill acts on LIVE repositories with your own credentials — tests MUST NOT write to a real repo, push a branch, comment on a real issue, or open a real PR. Unit and integration tests use recorded fixtures and never reach the network.
- **Design doc**: `docs/superpowers/specs/2026-08-06-software-factory-design.md` is the source of truth for architecture, the stage graph, the failure taxonomy, and what is deliberately out of scope. Read it before changing the pipeline, and update it when a decision changes.
- **Reference docs**: refer to and maintain `docs/reference/` for domain-specific rules and system documentation. Check relevant reference docs before modifying the systems they describe.

## Priority when instructions conflict

1. Working code over perfect code
2. Conciseness over comprehensiveness
3. Standards compliance over personal preference

## Disagreement and pushback

When you have a reasoned counterargument, state it clearly before accepting my decision. Don't just fold. If I push back on your suggestion and you believe your approach has merit, make the case — then accept my decision if I still disagree. Sycophantic agreement is not helpful.

---

## Safety invariants

Rules about the code you write here. Breaking one is a bug regardless of what a task appears to ask for. mill's *runtime* requirements — the containment layers, who may trigger a run, the spend ceilings — live in the design doc's Ingress, Containment, and Back-pressure sections; do not restate them here.

- Never write a call to `gh pr merge`. mill does not merge.
- Never post a comment except through `Mill::Github`. It stamps the marker; a second comment path lets mill trigger itself again.
- Never add a retry path around the two-attempts-per-stage counter. The design sanctions exactly one reset: when you answer a run that blocked because a stage ran out of attempts. Resuming a session after a stall or a reviewer objection is not a retry — it continues the same attempt or starts attempt 2 within the existing counter.
- Never signal a bare pid. Stages run in their own process group; signal the group and confirm no descendant survives.
- Never loosen a permission ruleset in `~/.mill/settings/` or add `--dangerously-skip-permissions` to the argv builder to make a stage work. A stage that needs a new capability needs a reviewed rule, not a bypass.
- Never bypass or short-circuit verdict validation in `Mill::Claude` — envelope match, artifact path resolution, cost present.
- Never add a rule to the `PreToolUse` hook and treat a containment gap as closed. The hook guards against model error; it is not the boundary.

---

## Development workflow

### Git operations

**Iron Law: No git state changes without explicit user approval.** Asking "should I commit?" is not approval. The user must explicitly say "commit", "push", etc.

**Forbidden without explicit approval:**
- `git commit` (ESPECIALLY `--amend` - rewrites history, can destroy work)
- `git push`, `git checkout`/`git switch`, `git reset`/`git restore`
- `git clean`, `git stash`, `git rebase`, `git merge`
- `git worktree add`/`remove` outside a test fixture

**Allowed without asking:**
- `git status`, `git diff`, `git log` (read-only)
- `git rm`, `git mv` (preferred over `rm`, `mv` for file operations)

### Running code

- **Development server runs at**: `http://localhost:9494`
- Always use `bundle exec` prefix for rake tasks and ruby commands
- To run inline Ruby scripts: `bundle exec ruby -e "load 'app.rb'; ..."`
- **The poller and supervisor threads start with the app.** When working on the web layer, run with `MILL_WORKERS=off` so a stray `Ready` status on the board does not launch a real run against a real repo while you are editing.
- **Never invoke `claude` by hand from application code paths under test.** `Mill::Claude` is the only component that spawns a subprocess, and tests drive it through a fake backed by recorded `stream-json` fixtures in `test/fixtures/`.
- **Never invoke `gh` by hand from application code paths.** `Mill::Github` is the only component that shells out to `gh`; tests use recorded JSON fixtures.
- **`bundle exec rake test`** is everything fixture-backed and is what CI runs. **`bundle exec rake test:boundary`** runs the permission suite against the real `claude` CLI and cannot run in CI — run it locally before merging any change to containment, the argv builder, or the rulesets in `~/.mill/settings/`.

### Context management

- **Use Task tool proactively for complex tasks**: searching many files, discovering a pattern, exploring the codebase, consolidating documents, analyzing a large refactor, or any task that needs several rounds of file operations
- Use direct file reads (Read/Grep/Glob) only when you know the specific file path or pattern
- This avoids "prompt too long" errors and improves performance on complex tasks

### Documentation

- When I say "store this" after you produce an extended reference document, store it in `docs/`
- Whenever you update a documentation file, make sure to update its table of contents
- **Designs** go in `docs/superpowers/specs/`, **plans** go in `docs/superpowers/plans/`, **output samples** go in `docs/superpowers/samples/`. These are the Superpowers defaults and mill writes to the same paths in every repo it works in — do not fork the convention. GitHub issues serve as task trackers with summaries, not full plans.

### GitHub issue workflow

**GitHub Issues is the canonical location for idea and bug tracking**, and for mill it is also the work queue. Use the `gh` CLI directly.

The queue is a **GitHub Project Status field**, not a label — mill uses no labels at all. Projects v2 is GraphQL-only, so board reads go through `gh project item-list` or `gh api graphql`, not `gh issue list`.

**Viewing work:**
- `gh project item-list <number> --owner slowernet --format json` - the board
- `gh issue view 42 --comments` - full detail including the Q&A thread
- `gh issue develop 42` - create and link a branch to an issue; this is how a spec reaches mill

**Creating and updating issues:**
- `gh issue create --title 'Title' --label 'bug,p1' --body-file -` — use `--body-file -` with a heredoc for multi-line bodies rather than escaping into `--body`
- `gh issue edit 42 --body-file -` — same pattern for updates

Board statuses and directive fields are in `docs/reference/mill.md`.

**Best practices:**
- Fetch board state at the start of planning sessions
- Keep issues focused on single concerns - split if too many line items
- An issue mill will act on is a spec. mill blocks an underspecified issue, and that costs you a round trip, so write the constraints down the first time.

---

## Code standards

### Coding approach

- **Use multiple choice questions** to flesh out specs, resolve ambiguity, and clarify requirements - this is faster and clearer than open-ended questions
- For larger tasks, **ask questions until you are 95% sure what to do**, then make a plan, and summarize it for me.
- Before finalizing any plan, **critique it: what code could it reuse, what does it duplicate, and could it be simpler?**
- Avoid rewriting/restructuring working code unnecessarily
- Make only the changes needed to accomplish the stated goal
- Ask for clarification when unsure about existing patterns

### All code

- Favor simplicity, fewer dependencies, concise code (eg. ternary operators)
- Naming: CamelCase classes, snake_case methods/attributes, module namespacing (`Mill::Claude`, `Mill::Github`)
- Indentation: tabs (4-space width), never spaces
- Comments: only when something non-obvious is happening
- Error handling: basic rescue blocks around subprocess and network calls, puts for debugging, graceful degradation. A rescue must never convert a stage failure into a pass.
- Avoid emojis in code or markdown files (unicode ✓ and ✗ are acceptable)
- Use sentence case (eg. "Code standards") for headers in Markdown

### Ruby

- For hashes, prefer `{ key: value }` syntax over `{ :key => value }`
- No Rails gems or helpers
- Single quotes unless interpolating, symbols for hash keys/internal identifiers
- Modifier `if`/`unless` for one-liners when readable: `return if error`
- `{ }` for single-line blocks, `do...end` for multi-line
- Parentheses for method definitions with params, optional for calls when clear
- Implicit returns (no explicit `return` at end of methods)
- Safe navigation operator: `obj&.method` over explicit nil checks
- `||` for defaults: `value || default`
- `attr_reader`/`attr_accessor` over manual getters/setters
- Prefer `map`/`select`/`reject` over `each` with accumulation
- **Timestamps**: always use UTC timestamps stored as integers: `Time.now.utc.to_i`
- **Parsed JSON**: symbolize keys at the boundary (`JSON.parse(str, symbolize_names: true)`) so verdicts, `gh` payloads, and Sequel rows all read the same way

### JavaScript

- No heavy libraries/frameworks like React
- No semicolons except when required (line starts with `[`, `(`, `` ` ``, `+`, `-`, `/`); use leading semicolon for IIFEs: `;(() => {})()`
- All external JS must be loaded with defer
- All inline JS must be wrapped in a DOMContentLoaded event listener
- **Shared helpers live in `public/js/utils.js`**: `qs()`, `qsa()`, `ready()`, `on()`, `onall()`, `getjson()`, `postjson()`. Add to that file rather than repeating verbose native APIs.
- Arrow functions preferred: `() => {}` over `function()`
- Use `const`/`let`, never `var`
- Template literals for interpolation: `` `Hello ${name}` ``, single quotes otherwise
- Prefer destructuring, spread operators, optional chaining (`?.`), nullish coalescing (`??`)
- Ternaries and guard clauses over nested if/else
- `async`/`await` over `.then()` chains
- Minimal comments (same as Ruby: only for non-obvious code)
- The log tail is the only live-updating view. Keep it dumb - poll a JSON endpoint, append lines. No client-side state machine.

### Code consistency checks

Before completing any code changes, proactively check for:

- **Hash access patterns**: Use symbols for hash keys (`:key` not `'key'`), especially when reading verdicts, `gh` payloads, or Sequel rows
- **Method parameter consistency**: If similar methods in a class accept symbols, new/modified methods should too
- **Naming conventions**: Follow established patterns in the same file (if 5 methods use symbols, the 6th should too)
- **Return value patterns**: Check how similar methods handle nil/empty cases and match that approach
- **Reference access**: Use helper methods (like `run.repo`, `attempt.run`) rather than direct foreign-key lookups when they exist
- **Error handling**: Match the rescue/error handling patterns used in the same class or module
- **Boundary discipline**: Any new `gh` call belongs in `Mill::Github`, any new subprocess spawn belongs in `Mill::Claude`. If you are reaching for `` ` `` or `system` anywhere else, stop.

When you notice an inconsistency, mention it and ask if I want it fixed, even if it's outside the immediate task scope.

### Query optimization checks

When moving filtering from Ruby into a query (SQL, or a `gh` API search):

- **Ruby defaults mask missing data**: accessors like `row[:field] || 'default'` make a NULL column or an absent JSON key behave as if it has a value. A query filtering on that column skips those rows entirely. Verify the field is populated on every row before depending on it server-side.
- **Trace all write paths**: before depending on a field in a query, grep for every insert and update touching that table to confirm the field is always set. Backfill in a migration if it is not.
- **`gh` search is not a database**: GitHub's search index lags and is rate-limited. Filter on labels and timestamps you fetched directly, not on search results, when correctness matters.

---

## Communication style

- Be polite, friendly and direct
- Give encouragement, but limit cheerleading phrases like "that's absolutely right" or "great question"
- Tell me when ideas are flawed, incomplete, or poorly thought through
- Focus on practical problems and realistic solutions

---

## Reference

### Identifier types

**GitHub numbers and GitHub ids are different things, and neither is globally unique in the way you expect.**

- **Issue and PR numbers** are integers, unique only within a repository. `#42` is meaningless without a repo. Always carry `repo_id` alongside.
- **Node ids** (`gh_node_id`) are opaque strings — never parse, order, or arithmetic them. They are the dedupe key for comment events precisely because they are stable and unique across the whole of GitHub.
- **Project item ids, field ids, and option ids** are three distinct opaque strings, all required to set a Status. mill resolves them at bootstrap and caches them; never hardcode one, and never assume you can derive an item id from the issue it wraps.
- **Session ids** from Claude Code are opaque strings, and the session file behind one may vanish. Any code path that resumes a session must have a fallback that re-runs the stage from scratch.
- **mill run ids** are local integers and mean nothing outside this database. Never put one in a GitHub comment as though the user could look it up.

### Domain vocabulary

Key models, the Status and directive vocabulary, and operational reference: `docs/reference/mill.md`.
