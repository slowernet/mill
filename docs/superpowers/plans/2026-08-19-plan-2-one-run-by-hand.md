# Plan 2 — One run by hand

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not dispatch subagents:
> this repo's operator has not opted into them.

**Goal:** Drive one real issue through `triage → plan → review:plan → implement → review:code → pr`
by hand and open a real pull request, with no board, no poller, no supervisor, and no UI.

**Architecture:** Plan 1 built the seam — `Mill::Claude#run` turns a prompt into a validated
`Attempt`. Plan 2 builds the three things that sit above it and the text that goes into it:
`Mill::Ledger` decides what each ending costs, `Mill::Runner` walks the route applying the ledger,
and `Mill::Prompts` plus mill's own plugin supply what each stage is told. `Mill::Git` is a new
seam for git, matching the existing rule that `Mill::Github` is the only place mill runs `gh` and
`Mill::Spawn` the only place it starts a stage. The runner is driven by an injected launcher, so
every test scripts verdicts and never runs `claude`.

**Tech Stack:** Ruby, Sequel over SQLite, Minitest. No new gems.

**Spec:** `docs/superpowers/specs/2026-08-06-software-factory-design.md`, with the stage-by-stage
detail in `docs/superpowers/specs/2026-08-18-sdlc-beats.md`.

**Spec sections this plan implements:** The stage graph; Finding the spec; Stage prompts; The stage
contract; The attempt ledger; Back-pressure; How a run blocks, asks, and resumes; Skills mill
borrows, and skills mill owns. Every beat in the beats doc for stages 1, 2, 3, 5, 7, 8, plus
`mill-headless`.

**Explicitly out of scope**, and listed so nobody builds them by accident: the board and the poller,
the supervisor and worktree lifecycle, the sleep/wake machinery and the stall detector, the web UI,
the `fast` and `iterate` routes, `diagnose`, `implement:fast`, `push`, deep review, and the evidence
deliverable. Plan 2 runs one route, once, started by hand.

## Global Constraints

Copied from the spec and from `CLAUDE.md`. Every task's requirements implicitly include these.

- **Indentation is tabs**, 4-space width, never spaces. Every file in `lib/` and `test/` already
  uses tabs; match them.
- **Hash keys are symbols**, and parsed JSON is symbolized at the boundary:
  `JSON.parse(str, symbolize_names: true)`. Sequel rows, `gh` payloads, and verdicts all read the
  same way.
- **Timestamps are UTC epoch integers**: `Mill.now`, which is `Time.now.utc.to_i`.
- **Single quotes** unless interpolating. `{ key: value }` hash syntax. Implicit returns. `{ }` for
  single-line blocks, `do...end` for multi-line. Safe navigation `obj&.method`. `||` for defaults.
- **Comments only when something non-obvious is happening.** The design doc holds the reasoning;
  a comment earns its place by explaining what the code cannot say itself.
- **Test files mirror source paths**: `lib/mill/runner.rb` → `test/mill/test_runner.rb`.
- **Test command:** `bundle exec rake test`. Passing output ends with a line like
  `165 runs, 705 assertions, 0 failures, 0 errors, 0 skips`. It must be run and its output read
  before any task claims completion.
- **No network and no `claude` in `rake test`.** Every test in this plan drives the runner through
  an injected launcher returning scripted `Mill::Claude::Attempt` values, or drives `Mill::Github`
  through an injected runner returning fixture JSON.
- **Boundary discipline.** Any new `gh` call belongs in `Mill::Github`. Any new stage subprocess
  belongs in `Mill::Spawn`. Any new `git` call belongs in `Mill::Git` (created in Task 2). If you
  are reaching for a backtick or `system` anywhere else, stop.
- **Safety invariants** from `CLAUDE.md` are not negotiable in any task: never write a call to
  `gh pr merge`; never post a comment except through `Mill::Github`; never add a retry path around
  the two-strikes-per-stage counter, and never charge a strike for something the machine did to a
  stage; never loosen a ruleset in `~/.mill/settings/`; never add `--dangerously-skip-permissions`;
  never remove `--tools` or `--strict-mcp-config`; never bypass verdict validation.
- **A rescue must never convert a stage failure into a pass.** Silence is never success.

---

### Task 1: The scratch repo runbook

Plan 2's demonstrable is a real pull request on a real repository, and mill has nowhere to open one.
This task writes the runbook section; **the operator runs it**, because it creates a repository and
pushes branches under their account.

**Files:**
- Modify: `docs/reference/setup.md` — add a new section after "10. Verify"

**Interfaces:**
- Consumes: nothing.
- Produces: a repository `slowernet/mill-scratch` with a base branch `main`, a Ruby test suite, a
  CI workflow whose job is named `test`, a `.mill.yml`, an issue, a branch linked to that issue via
  `gh issue develop`, and a spec committed on that branch under `docs/superpowers/specs/`. Task 9
  runs against exactly this.

- [x] **Step 1: Write the runbook section**

Append to `docs/reference/setup.md`, and add `- [11. A scratch repo for rehearsals](#11-a-scratch-repo-for-rehearsals)` to the Contents list:

````markdown
## 11. A scratch repo for rehearsals

mill pushes real branches and opens real pull requests, so building it needs a target nobody cares
about. The same scenario gets run many times, so it has to be disposable — reset it after every
rehearsal rather than accumulating state you then have to reason about.

```
gh repo create slowernet/mill-scratch --private --clone
cd mill-scratch
```

It needs enough structure to plan against — a test suite that really runs, and files with actual
shape rather than placeholders:

```
mkdir -p lib test .github/workflows docs/superpowers/specs

cat > Gemfile <<'RUBY'
source 'https://rubygems.org'
gem 'minitest'
gem 'rake'
RUBY

cat > Rakefile <<'RUBY'
require 'rake/testtask'
Rake::TestTask.new(:test) do |t|
	t.libs << 'lib' << 'test'
	t.test_files = FileList['test/**/test_*.rb']
end
task default: :test
RUBY

cat > lib/inventory.rb <<'RUBY'
# A deliberately small domain with room for a feature to be added to it.
class Inventory
	Item = Struct.new(:sku, :name, :count, keyword_init: true)

	def initialize = @items = {}

	def add(sku:, name:, count: 0)
		@items[sku] = Item.new(sku: sku, name: name, count: count)
	end

	def count(sku) = @items[sku]&.count || 0

	def restock(sku, by:)
		item = @items[sku] or raise KeyError, "no such sku: #{sku}"
		item.count += by
	end
end
RUBY

cat > test/test_inventory.rb <<'RUBY'
require 'minitest/autorun'
require 'inventory'

class TestInventory < Minitest::Test
	def setup = @inventory = Inventory.new

	def test_an_added_item_can_be_counted
		@inventory.add(sku: 'A1', name: 'Widget', count: 3)
		assert_equal 3, @inventory.count('A1')
	end

	def test_an_unknown_sku_counts_zero
		assert_equal 0, @inventory.count('nope')
	end

	def test_restocking_raises_for_an_unknown_sku
		assert_raises(KeyError) { @inventory.restock('nope', by: 1) }
	end
end
RUBY

cat > .github/workflows/ci.yml <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
      - run: bundle exec rake test
YAML

cat > .mill.yml <<'YAML'
base_branch: main
test_command: bundle exec rake test
ci_workflow: ci.yml
trusted_authors:
  - dependabot[bot]
evidence_public: false
secrets: []
YAML

git add -A && git commit -m "Scaffold the scratch repo" && git push -u origin main
```

The CI job is named `test`, which is the name branch protection must require. Set that up with
section 7's command, using `contexts: ["test"]`.

**The rehearsal fixture.** mill's `plan` route starts from an issue with a spec on a linked branch,
so create one:

```
gh issue create --repo slowernet/mill-scratch \
  --title 'Track low-stock items' --body-file - <<'MD'
Inventory has no way to answer "what needs reordering?". See the spec on the linked branch.
MD

gh issue develop <number> --repo slowernet/mill-scratch --checkout
```

Write the spec on that branch, to the standard in `docs/reference/spec-standard.md`, commit it, and
push. Then **switch your clone off the branch** — `git worktree add` refuses a branch that is
checked out anywhere, including your clone's own HEAD, and mill blocks rather than forcing it:

```
git add docs/superpowers/specs/ && git commit -m "Spec: track low-stock items" && git push
git switch main
```

**Resetting between rehearsals.** Delete the branch and the pull request, and re-run
`gh issue develop`:

```
gh pr close <pr> --repo slowernet/mill-scratch --delete-branch
git push origin --delete <branch> 2>/dev/null || true
```
````

- [x] **Step 2: Check the Contents list and cross-reference**

Run: `grep -n '^- \[1[01]\.' docs/reference/setup.md`
Expected: both `[10. Verify]` and `[11. A scratch repo for rehearsals]` present, in order.

- [x] **Step 3: Commit**

```bash
git add docs/reference/setup.md
git commit -m "Runbook: the scratch repo Plan 2 rehearses against"
```

- [x] **Step 4: Stop and hand over**

Tell the operator this section is ready and that Task 9 cannot run until they have worked through
it. Continue with Tasks 2–8, none of which need the repo to exist.

---

### Task 2: `Mill::Git` — the git seam

Every git command mill runs, in one place, for the same reason `Mill::Github` exists: it is what
makes "mill never forces a checkout" and "mill clears only age-checked stale locks" enforceable
rather than aspirational. Plan 2 needs three of its methods; Plan 3 grows the rest.

**Files:**
- Create: `lib/mill/git.rb`
- Modify: `lib/mill.rb` — add `require_relative 'mill/git'` after the `mill/github` line
- Test: `test/mill/test_git.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Mill::Git.run(repo_path, *args)` → `Mill::Git::Result` with members `out` (String), `err`
    (String), `ok` (boolean)
  - `Mill::Git.run!(repo_path, *args)` → String, raising `Mill::Git::Error` when the command fails
  - `Mill::Git.added_files(repo_path, base, branch, prefix)` → `Array<String>` of repo-relative
    paths the branch adds under `prefix`
  - `Mill::Git.checked_out_branches(repo_path)` → `Array<String>` of branches checked out in the
    clone or any of its worktrees
  - `Mill::Git.current_branch(repo_path)` → String or nil

- [x] **Step 1: Write the failing test**

Create `test/mill/test_git.rb`:

```ruby
require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Drives real git against a scratch repository built in a tmpdir. No network.
	class TestGit < Minitest::Test
		def setup
			@repo = Dir.mktmpdir('mill-git')
			git('init', '--initial-branch=main')
			git('config', 'user.email', 'test@example.com')
			git('config', 'user.name', 'Test')
			write('README.md', "# scratch\n")
			git('add', '-A')
			git('commit', '-m', 'first')
		end

		def teardown = FileUtils.remove_entry(@repo, true)

		def git(*args) = Mill::Git.run!(@repo, *args)

		def write(path, body)
			full = File.join(@repo, path)
			FileUtils.mkdir_p(File.dirname(full))
			File.write(full, body)
		end

		# A branch name or commit message can carry anything, and Open3 tags its
		# output with whatever the locale says.
		def test_non_ascii_output_survives_the_locale
			subject = "spec: caf\u00E9 \u{1F6A2}"
			git('switch', '-c', 'feature')
			write('notes.md', "x\n")
			git('add', '-A')
			git('commit', '-m', subject)

			log = Mill::Git.run!(@repo, 'log', '-1', '--pretty=%s')

			assert_equal Encoding::UTF_8, log.encoding
			assert_includes log, subject
		end

		def test_a_failing_command_is_reported_not_raised
			result = Mill::Git.run(@repo, 'rev-parse', 'no-such-ref')

			refute result.ok
			refute_empty result.err
		end

		def test_run_bang_raises_with_the_stderr
			error = assert_raises(Mill::Git::Error) { Mill::Git.run!(@repo, 'rev-parse', 'no-such-ref') }

			assert_match(/no-such-ref/, error.message)
		end

		# The spec is the file the branch adds under docs/superpowers/specs/. mill
		# never reads a pasted path, so nothing can be mistyped or go stale.
		def test_added_files_finds_what_a_branch_introduced
			git('switch', '-c', '42-add-widget')
			write('docs/superpowers/specs/2026-08-19-widget.md', "# widget\n")
			write('lib/unrelated.rb', "# not a spec\n")
			git('add', '-A')
			git('commit', '-m', 'spec')

			added = Mill::Git.added_files(@repo, 'main', '42-add-widget', 'docs/superpowers/specs/')

			assert_equal ['docs/superpowers/specs/2026-08-19-widget.md'], added
		end

		# A file the branch only *modified* is not the spec it introduced.
		def test_added_files_ignores_a_modified_file
			write('docs/superpowers/specs/old.md', "# old\n")
			git('add', '-A')
			git('commit', '-m', 'pre-existing spec')
			git('switch', '-c', 'branch-2')
			write('docs/superpowers/specs/old.md', "# old, edited\n")
			git('add', '-A')
			git('commit', '-m', 'edit')

			assert_empty Mill::Git.added_files(@repo, 'main', 'branch-2', 'docs/superpowers/specs/')
		end

		def test_added_files_is_empty_when_the_branch_adds_none
			git('switch', '-c', 'no-spec')
			write('lib/thing.rb', "# code\n")
			git('add', '-A')
			git('commit', '-m', 'code only')

			assert_empty Mill::Git.added_files(@repo, 'main', 'no-spec', 'docs/superpowers/specs/')
		end

		# git worktree add refuses a branch checked out anywhere, including the
		# clone's own HEAD — and the prescribed workflow leaves it that way.
		def test_the_clones_own_head_counts_as_checked_out
			git('switch', '-c', 'held')

			assert_includes Mill::Git.checked_out_branches(@repo), 'held'
			assert_equal 'held', Mill::Git.current_branch(@repo)
		end

		def test_a_worktree_branch_counts_as_checked_out
			Dir.mktmpdir do |elsewhere|
				tree = File.join(elsewhere, 'wt')
				git('worktree', 'add', '-b', 'in-a-worktree', tree)

				assert_includes Mill::Git.checked_out_branches(@repo), 'in-a-worktree'
			ensure
				Mill::Git.run(@repo, 'worktree', 'remove', '--force', tree)
			end
		end
	end
end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_git.rb`
Expected: FAIL with `uninitialized constant Mill::Git`

- [x] **Step 3: Write the implementation**

Create `lib/mill/git.rb`:

```ruby
require 'open3'

module Mill
	# Every git command mill runs. Stages run git themselves inside their worktree;
	# this is mill's own access, and keeping it in one place is what makes the rules
	# about forcing a checkout and clearing stale locks enforceable.
	module Git
		class Error < Mill::Error; end

		Result = Struct.new(:out, :err, :ok, keyword_init: true)

		def self.run(repo_path, *args)
			out, err, status = Open3.capture3('git', '-C', repo_path.to_s, *args.map(&:to_s))
			Result.new(out: utf8(out), err: utf8(err), ok: status.success?)
		rescue SystemCallError => e
			Result.new(out: '', err: e.message, ok: false)
		end

		# Same reason as Mill::Github#utf8: Open3 tags its output with
		# Encoding.default_external, and a branch name, path, or commit message can
		# carry anything. mill pins the default at load too; this is the seam.
		def self.utf8(text)
			text = text.dup.force_encoding(Encoding::UTF_8)
			text.valid_encoding? ? text : text.scrub('')
		end

		def self.run!(repo_path, *args)
			result = run(repo_path, *args)
			raise Error, "git #{args.first(2).join(' ')} failed: #{result.err.strip[0, 300]}" unless result.ok

			result.out
		end

		# The spec is the file the branch *adds* under the prefix, found by diffing
		# rather than by reading a path out of prose. `base...branch` is the
		# three-dot form: what the branch added since it diverged, not everything
		# that differs between the two tips.
		def self.added_files(repo_path, base, branch, prefix)
			out = run!(repo_path, 'diff', '--name-only', '--diff-filter=A',
				"#{base}...#{branch}", '--', prefix)
			out.split("\n").map(&:strip).reject(&:empty?)
		end

		# Includes the clone's own HEAD, not only linked worktrees: `git worktree
		# add` refuses a branch checked out anywhere, and the prescribed design
		# workflow leaves the branch current in the clone.
		def self.checked_out_branches(repo_path)
			out = run!(repo_path, 'worktree', 'list', '--porcelain')
			out.scan(%r{^branch refs/heads/(.+)$}).flatten
		end

		def self.current_branch(repo_path)
			result = run(repo_path, 'rev-parse', '--abbrev-ref', 'HEAD')
			return nil unless result.ok

			name = result.out.strip
			name == 'HEAD' ? nil : name
		end
	end
end
```

Add to `lib/mill.rb`, immediately after `require_relative 'mill/github'`:

```ruby
require_relative 'mill/git'
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_git.rb`
Expected: PASS, 8 runs, 0 failures

- [x] **Step 5: Run the full suite**

Run: `bundle exec rake test`
Expected: 0 failures, 0 errors

- [x] **Step 6: Commit**

```bash
git add lib/mill/git.rb lib/mill.rb test/mill/test_git.rb
git commit -m "Add Mill::Git, the git seam"
```

---

### Task 3: `Mill::Spec` — adopt the branch and find the spec

No path is pasted anywhere. The issue refers to a branch natively; mill reads `linkedBranches`,
adopts that branch, and the spec is the file that branch added under `docs/superpowers/specs/`.
Exactly one file is the spec: none routes to `fast` or blocks, more than one blocks and asks which.

**Files:**
- Create: `lib/mill/spec.rb`
- Modify: `lib/mill.rb` — add `require_relative 'mill/spec'` after the `mill/git` line
- Test: `test/mill/test_spec.rb`

**Interfaces:**
- Consumes: `Mill::Git.added_files`, `Mill::Git.checked_out_branches` (Task 2);
  `Mill::Github#linked_branches` (already exists).
- Produces: `Mill::Spec.locate(github:, git: Mill::Git, repo:, number:, repo_path:, base:)` →
  `Mill::Spec::Located`, a Struct with members `branch`, `path`, `problem`, `detail`, and methods
  `found?`, `blocked?`. `problem` is one of `nil`, `:no_branch`, `:many_branches`, `:no_spec`,
  `:many_specs`, `:branch_checked_out`.

- [x] **Step 1: Write the failing test**

Create `test/mill/test_spec.rb`:

```ruby
require 'test_helper'

module Mill
	# Fixture-backed: a fake github and a fake git, no network and no repository.
	class TestSpec < Minitest::Test
		FakeGit = Struct.new(:added, :checked_out, keyword_init: true) do
			def added_files(*) = added
			def checked_out_branches(*) = checked_out
		end

		def github_with(branches)
			Class.new do
				define_method(:linked_branches) { |*| branches }
			end.new
		end

		def locate(branches: ['42-add-widget'], added: ['docs/superpowers/specs/a.md'], checked_out: [])
			Mill::Spec.locate(
				github: github_with(branches),
				git: FakeGit.new(added: added, checked_out: checked_out),
				repo: 'slowernet/mill-scratch', number: 42, repo_path: '/tmp/clone', base: 'main'
			)
		end

		def test_one_linked_branch_adding_one_spec_is_adopted
			located = locate

			assert_predicate located, :found?
			assert_equal '42-add-widget', located.branch
			assert_equal 'docs/superpowers/specs/a.md', located.path
			assert_nil located.problem
		end

		# An issue with no linked branch is not an error: triage may still route it
		# to fast if it is unambiguously hotfix-shaped.
		def test_no_linked_branch_is_reported_rather_than_blocked
			located = locate(branches: [])

			refute_predicate located, :found?
			refute_predicate located, :blocked?
			assert_equal :no_branch, located.problem
		end

		def test_a_branch_that_adds_no_spec_is_reported_rather_than_blocked
			located = locate(added: [])

			refute_predicate located, :blocked?
			assert_equal :no_spec, located.problem
			assert_equal '42-add-widget', located.branch
		end

		# Two specs on one branch is genuinely ambiguous, and mill declining to
		# guess is the feature.
		def test_more_than_one_spec_blocks_and_names_them
			located = locate(added: ['docs/superpowers/specs/a.md', 'docs/superpowers/specs/b.md'])

			assert_predicate located, :blocked?
			assert_equal :many_specs, located.problem
			assert_match(/a\.md/, located.detail)
			assert_match(/b\.md/, located.detail)
		end

		def test_more_than_one_linked_branch_blocks
			located = locate(branches: %w[42-add-widget 42-other])

			assert_predicate located, :blocked?
			assert_equal :many_branches, located.problem
		end

		# git worktree add refuses a branch checked out anywhere, and the design
		# session leaves it current in the clone. mill blocks rather than forcing
		# it: two live checkouts of one branch can silently diverge the ref.
		def test_a_branch_checked_out_in_the_clone_blocks
			located = locate(checked_out: ['main', '42-add-widget'])

			assert_predicate located, :blocked?
			assert_equal :branch_checked_out, located.problem
			assert_match(/42-add-widget/, located.detail)
		end

		def test_every_problem_carries_a_question_for_the_operator
			%i[many_branches many_specs branch_checked_out].each do |problem|
				located = case problem
					when :many_branches then locate(branches: %w[a b])
					when :many_specs then locate(added: %w[docs/superpowers/specs/a.md docs/superpowers/specs/b.md])
					else locate(checked_out: ['42-add-widget'])
				end

				refute_empty located.questions, "#{problem} must give the operator something to answer"
			end
		end
	end
end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_spec.rb`
Expected: FAIL with `uninitialized constant Mill::Spec`

- [x] **Step 3: Write the implementation**

Create `lib/mill/spec.rb`:

```ruby
module Mill
	# Finds the spec without anyone typing a path. The issue refers to a branch
	# natively; mill adopts that branch and the spec is the file it introduced.
	module Spec
		PREFIX = 'docs/superpowers/specs/'.freeze

		# `problem` distinguishes two kinds of not-found. :no_branch and :no_spec
		# are ordinary — triage may still route the issue to `fast`. The rest are
		# genuinely ambiguous, and mill blocks rather than guessing.
		BLOCKING = %i[many_branches many_specs branch_checked_out].freeze

		Located = Struct.new(:branch, :path, :problem, :detail, keyword_init: true) do
			def found? = problem.nil? && !path.nil?

			def blocked? = BLOCKING.include?(problem)

			def questions
				case problem
				when :many_branches
					["This issue has more than one linked branch (#{detail}). Which one should mill work on?"]
				when :many_specs
					["The branch #{branch} adds more than one file under #{PREFIX} (#{detail}). " \
						'Which one is the spec?']
				when :branch_checked_out
					["The branch #{branch} is checked out in #{detail}. mill will not force a second " \
						'checkout of one branch, because two live checkouts can silently diverge the ref. ' \
						'Switch that clone to another branch and reply here.']
				else
					[]
				end
			end
		end

		def self.locate(github:, repo:, number:, repo_path:, base:, git: Mill::Git)
			branches = Array(github.linked_branches(repo, number))
			return Located.new(problem: :no_branch) if branches.empty?
			return Located.new(problem: :many_branches, detail: branches.join(', ')) if branches.length > 1

			branch = branches.first
			held = git.checked_out_branches(repo_path)
			return Located.new(branch: branch, problem: :branch_checked_out, detail: repo_path) if
				held.include?(branch)

			specs = git.added_files(repo_path, base, branch, PREFIX)
			return Located.new(branch: branch, problem: :no_spec) if specs.empty?
			return Located.new(branch: branch, problem: :many_specs, detail: specs.join(', ')) if
				specs.length > 1

			Located.new(branch: branch, path: specs.first)
		end
	end
end
```

Add to `lib/mill.rb`, immediately after `require_relative 'mill/git'`:

```ruby
require_relative 'mill/spec'
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_spec.rb`
Expected: PASS, 7 runs, 0 failures

- [x] **Step 5: Run the full suite and commit**

Run: `bundle exec rake test`
Expected: 0 failures, 0 errors

```bash
git add lib/mill/spec.rb lib/mill.rb test/mill/test_spec.rb
git commit -m "Find the spec by what the linked branch introduced"
```

---

### Task 4: `Mill::Ledger` — what each ending costs

The control plane. Every recovery path in mill ends here, and the 2026-08-13 review found the same
hole from six directions because the rules lived in fragments that disagreed. This task is the
single implementation of the cost table in the spec's "The attempt ledger" section, and it gets the
most direct test in the suite: one case per row.

**Files:**
- Create: `db/migrations/003_a_rejection_strikes_the_stage_it_reviewed.rb`
- Create: `lib/mill/ledger.rb`
- Modify: `lib/mill.rb` — add `require_relative 'mill/ledger'` after the `mill/spec` line
- Test: `test/mill/test_ledger.rb`

**The row-per-launch invariant.** Every row in `stage_attempts` is exactly one launch of one stage.
That is what lets the attempt number name a log file and a verdict file without ambiguity. A
rejection therefore does *not* insert a row for the stage it strikes — there has been no launch, so
there is no log and no verdict, and a row here would make `plan-2.jsonl` a filename nothing ever
wrote. The strike is recorded on the reviewer's own row, in a `struck_stage` column naming who pays.
The attempt the reviewed stage owes is its re-launch, which happens next and inserts its own row.

**Interfaces:**
- Consumes: `Mill::Claude::Attempt` (Plan 1), the `stage_attempts` and `runs` tables.
- Produces:
  - `Mill::Ledger.classify(attempt)` → one of `:ok`, `:blocked`, `:failed`, `:no_verdict`,
    `:crashed`
  - `Mill::Ledger::COST` → Hash mapping an outcome symbol to `{ attempt: Integer, strike: Integer }`
  - `Mill::Ledger.new(db, run_id)` with instance methods `attempts(stage)`, `strikes(stage)`,
    `next_attempt(stage)`, `charge(stage:, outcome:, attempt: nil, **columns)` →
    `{ attempt:, strike: }`, `out_of_strikes?(stage)`, `out_of_attempts?(stage)`,
    `interruptions(stage)`, `out_of_interruptions?(stage)`, `reset_available?(stage)`, `reset!(stage)`
  - A rejection is recorded as `charge(stage: reviewer, outcome: :reviewed_clean, struck_stage:
    reviewed)` — one row, one launch, the strike attributed to someone else
  - Constants `MAX_STRIKES = 2`, `MAX_ATTEMPTS = 8`, `MAX_INTERRUPTIONS = 3`

- [x] **Step 1: Write the migration**

Create `db/migrations/003_a_rejection_strikes_the_stage_it_reviewed.rb`:

```ruby
# Every row in stage_attempts is exactly one launch, which is what lets the
# attempt number name a log file and a verdict file. A reviewer that finds
# something serious strikes the stage it reviewed, and that stage has not
# launched again yet -- so the strike is recorded here, on the reviewer's own
# row, rather than as a row for a launch that never happened.
Sequel.migration do
	change do
		alter_table(:stage_attempts) do
			add_column :struck_stage, String
			add_index %i[run_id struck_stage]
		end
	end
end
```

Run: `bundle exec rake test` — the existing schema test must still pass.

- [x] **Step 2: Write the failing test**

Create `test/mill/test_ledger.rb`:

```ruby
require 'test_helper'

module Mill
	# One case per row of the spec's cost table. This is the control plane every
	# other subsystem routes its failures into, so it gets the most direct test in
	# the suite.
	class TestLedger < Mill::TestCase
		def setup
			super
			@run = create_run(repo_id: create_repo, route: 'plan')
			@ledger = Mill::Ledger.new(db, @run)
		end

		def attempt(status: 'ok', valid: true, success: true, objections: [], stage: 'plan')
			verdict = Struct.new(:valid?, :status, :rejects?, :blocked?, :errors)
				.new(valid, status, objections.any?, status == 'blocked', valid ? [] : ['bad'])
			result = Struct.new(:success?, :error).new(success, nil)
			Struct.new(:stage, :verdict, :result, :ok?, :blocked?, :rejects?)
				.new(stage, verdict, result, success && valid && status == 'ok',
					valid && status == 'blocked', objections.any?)
		end

		# --- classification -------------------------------------------------

		def test_a_clean_stage_is_ok
			assert_equal :ok, Mill::Ledger.classify(attempt)
		end

		def test_a_blocked_stage_is_blocked
			assert_equal :blocked, Mill::Ledger.classify(attempt(status: 'blocked'))
		end

		def test_a_stage_reporting_failed_is_failed
			assert_equal :failed, Mill::Ledger.classify(attempt(status: 'failed'))
		end

		def test_an_invalid_verdict_is_no_verdict
			assert_equal :no_verdict, Mill::Ledger.classify(attempt(valid: false))
		end

		# A process that died outranks whatever it managed to emit.
		def test_a_dead_process_is_crashed_whatever_it_said
			assert_equal :crashed, Mill::Ledger.classify(attempt(success: false))
		end

		# --- the cost table, one case per row -------------------------------

		def test_bad_work_costs_a_strike
			%i[failed crashed no_verdict artifact_bad].each do |outcome|
				cost = Mill::Ledger::COST.fetch(outcome)

				assert_equal 1, cost[:attempt], "#{outcome} must count as a launch"
				assert_equal 1, cost[:strike], "#{outcome} is the stage's own work being wrong"
			end
		end

		# A rejection strikes the reviewed stage now; the attempt it owes is its
		# re-launch, which has not happened yet. Counting one here would name a log
		# file nothing ever wrote and make the next real launch attempt 3.
		def test_a_rejection_strikes_without_counting_a_launch
			cost = Mill::Ledger::COST.fetch(:rejected)

			assert_equal 0, cost[:attempt]
			assert_equal 1, cost[:strike]
		end

		# A strike means the work was wrong. Everything the machine did is free.
		def test_everything_the_machine_did_is_free
			%i[blocked reviewed_clean stall_recovery resume_failed interrupted].each do |outcome|
				cost = Mill::Ledger::COST.fetch(outcome)

				assert_equal 1, cost[:attempt], "#{outcome} still names a log and a verdict"
				assert_equal 0, cost[:strike], "#{outcome} was not the stage failing"
			end
		end

		def test_waiting_behind_a_rate_limit_is_not_a_launch_at_all
			assert_equal 0, Mill::Ledger::COST.fetch(:rate_limited)[:attempt]
			assert_equal 0, Mill::Ledger::COST.fetch(:rate_limited)[:strike]
		end

		# --- accounting -----------------------------------------------------

		def test_the_attempt_number_rises_on_every_launch
			assert_equal 1, @ledger.next_attempt('plan')
			@ledger.charge(stage: 'plan', outcome: :blocked)

			assert_equal 2, @ledger.next_attempt('plan')
			@ledger.charge(stage: 'plan', outcome: :failed)

			assert_equal 3, @ledger.next_attempt('plan')
		end

		def test_strikes_rise_only_on_bad_work
			3.times { @ledger.charge(stage: 'plan', outcome: :blocked) }

			assert_equal 0, @ledger.strikes('plan')
			assert_equal 3, @ledger.attempts('plan')
		end

		def test_two_strikes_stops_the_stage
			@ledger.charge(stage: 'plan', outcome: :failed)

			refute_predicate_stage :out_of_strikes?, 'plan'
			@ledger.charge(stage: 'plan', outcome: :failed)

			assert @ledger.out_of_strikes?('plan')
		end

		# The case the old one-number rules could not express: a reviewer that
		# crashes, then reviews cleanly, then reviews again after a fix.
		def test_a_reviewer_that_crashes_then_reviews_twice
			@ledger.charge(stage: 'review:code', outcome: :crashed)
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean)
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean)

			assert_equal 3, @ledger.attempts('review:code'), 'three distinct launches'
			assert_equal 1, @ledger.strikes('review:code'), 'only the crash was the reviewer failing'
			refute @ledger.out_of_strikes?('review:code')
			assert_equal 3, db[:stage_attempts].where(run_id: @run, stage: 'review:code').count
		end

		# A reviewer that finds something serious strikes the stage it reviewed,
		# not itself — and the row belongs to the reviewer, because the reviewer is
		# the one that launched.
		def test_a_rejection_strikes_the_reviewed_stage
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement')

			assert_equal 1, @ledger.strikes('implement')
			assert_equal 0, @ledger.strikes('review:code')
		end

		# Every row is one launch. A rejection must not invent an attempt for a
		# stage that has not run again yet.
		def test_a_rejection_does_not_invent_an_attempt
			@ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement')

			assert_equal 0, @ledger.attempts('implement'), 'no launch happened, so no row'
			assert_equal 1, @ledger.next_attempt('implement'), 'the re-launch is attempt 1'
			assert_equal 1, db[:stage_attempts].where(run_id: @run).count
		end

		# Two serious objections against one stage means it has used both strikes,
		# and the run blocks -- before the second re-launch, not after it.
		def test_two_rejections_use_both_strikes
			2.times { @ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement') }

			assert @ledger.out_of_strikes?('implement')
		end

		# A reset has to forgive strikes charged from someone else's row too.
		def test_a_reset_forgives_strikes_charged_by_a_reviewer
			2.times { @ledger.charge(stage: 'review:code', outcome: :reviewed_clean, struck_stage: 'implement') }
			@ledger.reset!('implement')

			assert_equal 0, @ledger.strikes('implement')
			refute @ledger.out_of_strikes?('implement')
		end

		def test_free_paths_are_still_bounded
			8.times { @ledger.charge(stage: 'plan', outcome: :blocked) }

			assert @ledger.out_of_attempts?('plan'), 'nothing may loop forever, even for free'
		end

		def test_interruptions_are_capped_separately
			3.times { @ledger.charge(stage: 'plan', outcome: :interrupted) }

			assert_equal 0, @ledger.strikes('plan')
			assert @ledger.out_of_interruptions?('plan')
		end

		# --- the one sanctioned third strike --------------------------------

		def test_answering_resets_a_stage_once_per_run
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }

			assert @ledger.out_of_strikes?('plan')
			assert @ledger.reset_available?('plan')

			@ledger.reset!('plan')

			refute @ledger.out_of_strikes?('plan')
			assert_equal 0, @ledger.strikes('plan')
			assert_equal 2, @ledger.attempts('plan'), 'a reset forgives strikes, not history'
		end

		def test_a_stage_may_only_be_reset_once
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }
			@ledger.reset!('plan')
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }

			assert @ledger.out_of_strikes?('plan')
			refute @ledger.reset_available?('plan'), 'the second time out is terminal'
		end

		# The reset is per stage, so a run is never trapped by one it spent earlier.
		def test_a_reset_spent_on_one_stage_leaves_another_entitled
			2.times { @ledger.charge(stage: 'plan', outcome: :failed) }
			@ledger.reset!('plan')
			2.times { @ledger.charge(stage: 'implement', outcome: :failed) }

			assert @ledger.reset_available?('implement')
		end

		private

		def refute_predicate_stage(predicate, stage) = refute @ledger.send(predicate, stage)
	end
end
```

- [x] **Step 6: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_ledger.rb`
Expected: FAIL with `uninitialized constant Mill::Ledger`

- [x] **Step 4: Write the implementation**

Create `lib/mill/ledger.rb`:

```ruby
require 'json'

module Mill
	# The single definition of what an attempt is and who pays for one.
	#
	# mill counts two separate things. The attempt number counts how many times
	# mill has launched a stage during a run; it goes up on every launch without
	# exception, and it names the log file and the verdict. The strike count is the
	# two-strikes rule, and it goes up only when the stage's own work was bad.
	#
	# Keeping them apart is what makes the ordinary case expressible: a reviewer
	# that crashes, gets relaunched, finds a real problem, and reviews again is on
	# attempt 3 with one strike, which is exactly the truth.
	class Ledger
		MAX_STRIKES = 2
		MAX_ATTEMPTS = 8
		MAX_INTERRUPTIONS = 3

		# A strike means the work was wrong. Everything the machine did to a stage
		# is free — a laptop that slept, a socket that died, a lock file left by a
		# SIGKILL, and mill restarting are mill's problems, not the stage's.
		COST = {
			failed: { attempt: 1, strike: 1 },
			crashed: { attempt: 1, strike: 1 },
			no_verdict: { attempt: 1, strike: 1 },
			artifact_bad: { attempt: 1, strike: 1 },
			# The strike lands now; the attempt it owes is the re-launch itself,
			# which inserts its own row. See the row-per-launch invariant above.
			rejected: { attempt: 0, strike: 1 },
			ok: { attempt: 1, strike: 0 },
			blocked: { attempt: 1, strike: 0 },
			reviewed_clean: { attempt: 1, strike: 0 },
			stall_recovery: { attempt: 1, strike: 0 },
			resume_failed: { attempt: 1, strike: 0 },
			interrupted: { attempt: 1, strike: 0 },
			rate_limited: { attempt: 0, strike: 0 }
		}.freeze

		# A process that died outranks whatever it managed to emit: mill has no
		# trustworthy account of what happened either way.
		def self.classify(attempt)
			return :crashed unless attempt.result.success?
			return :no_verdict unless attempt.verdict.valid?

			case attempt.verdict.status
			when 'ok' then :ok
			when 'blocked' then :blocked
			else :failed
			end
		end

		def initialize(db, run_id)
			@db = db
			@run_id = run_id
		end

		def attempts(stage) = @db[:stage_attempts].where(run_id: @run_id, stage: stage)

		def attempts(stage) = attempts(stage).count

		# A stage is struck either by its own bad work, or by a reviewer that found
		# something serious in it. The second is recorded on the reviewer's row,
		# because that is the row belonging to a launch that actually happened.
		def strikes(stage)
			attempts(stage).where(strike_charged: true).count +
				@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).count
		end

		def interruptions(stage) = attempts(stage).where(status: 'interrupted').count

		def next_attempt(stage) = attempts(stage) + 1

		# Records one launch and returns what it cost. `stage` is who pays, which
		# for a rejection is the stage that was reviewed rather than the reviewer.
		def charge(stage:, outcome:, attempt: nil, **columns)
			cost = COST.fetch(outcome) { raise Mill::Error, "unknown outcome: #{outcome}" }
			return cost if cost[:attempt].zero?

			@db[:stage_attempts].insert(
				run_id: @run_id, stage: stage, attempt: attempt || next_attempt(stage),
				nonce: columns.delete(:nonce) || '', status: outcome.to_s,
				strike_charged: cost[:strike].positive?, started_at: Mill.now, **columns
			)
			cost
		end

		def out_of_strikes?(stage) = strikes(stage) >= MAX_STRIKES

		def out_of_attempts?(stage) = attempts(stage) >= MAX_ATTEMPTS

		def out_of_interruptions?(stage) = interruptions(stage) >= MAX_INTERRUPTIONS

		# The one sanctioned third strike. When a stage runs out, mill blocks and
		# asks; answering resets that stage's count. Each stage may be reset once
		# per run, so a run is never trapped by a reset it spent on some earlier
		# stage — which is why this is a list of stage names and not one column.
		def reset_available?(stage) = !resets.include?(stage)

		def reset!(stage)
			raise Mill::Error, "#{stage} has already used its reset" unless reset_available?(stage)

			@db[:runs].where(id: @run_id).update(strike_resets_json: (resets + [stage]).to_json)
			@db[:stage_attempts].where(run_id: @run_id, stage: stage, strike_charged: true)
				.update(strike_charged: false)
			@db[:stage_attempts].where(run_id: @run_id, struck_stage: stage).update(struck_stage: nil)
		end

		def resets
			row = @db[:runs].where(id: @run_id).get(:strike_resets_json)
			row ? JSON.parse(row) : []
		end

	end
end
```

Add to `lib/mill.rb`, immediately after `require_relative 'mill/spec'`:

```ruby
require_relative 'mill/ledger'
```

- [x] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_ledger.rb`
Expected: PASS, 21 runs, 0 failures

If `test_a_reviewer_that_crashes_then_reviews_twice` fails on the unique index over
`(run_id, stage, attempt)`, the bug is that `charge` computed the attempt number twice for one
launch — pass it explicitly from the runner rather than recomputing.

- [x] **Step 6: Run the full suite and commit**

Run: `bundle exec rake test`

```bash
git add db/migrations/003_a_rejection_strikes_the_stage_it_reviewed.rb lib/mill/ledger.rb \
	lib/mill.rb test/mill/test_ledger.rb
git commit -m "Add the attempt ledger: attempts count launches, strikes count bad work"
```

---

### Task 5: `Mill::Prompts` — what each stage is told

mill owns a thin prompt per stage that names its skill explicitly, tells it the harness is mill's
own, and passes it its predecessors' verdicts. `Mill::Claude#envelope` already appends the verdict
contract, so these templates carry only the job.

The SessionStart note is not decoration. Measured 2026-08-19: a real `triage` launch received the
operator's inherited Superpowers `SessionStart` reminder telling it that invoking a skill before
responding is non-negotiable, found it held no `Skill` tool, concluded it was being prompt-injected,
and opened its final message saying so. Every prompt names the reminder and says what this stage
actually loads.

**Files:**
- Create: `prompts/triage.md`, `prompts/plan.md`, `prompts/review-plan.md`, `prompts/implement.md`,
  `prompts/review-code.md`, `prompts/pr.md`, `prompts/_preamble.md`
- Create: `lib/mill/prompts.rb`
- Modify: `lib/mill.rb` — add `require_relative 'mill/prompts'` after the `mill/ledger` line
- Test: `test/mill/test_prompts.rb`

**Interfaces:**
- Consumes: `Mill::Stages` (skill name per stage), `Mill::Skills` (to name the skill).
- Produces: `Mill::Prompts.for(stage, context)` → String. `context` is a Hash with symbol keys, any
  of: `:issue`, `:spec_path`, `:plan_path`, `:branch`, `:base`, `:route`, `:verdicts` (Array of
  Hashes), `:objections` (Array of Hashes), `:answers` (Array of Strings), `:test_command`. Missing
  keys render as an explicit "not applicable on this route" line, never as an empty placeholder.

- [x] **Step 1: Write the failing test**

Create `test/mill/test_prompts.rb`:

```ruby
require 'test_helper'

module Mill
	class TestPrompts < Minitest::Test
		def prompt(stage, **context) = Mill::Prompts.for(stage, context)

		def test_every_stage_on_the_plan_route_has_a_prompt
			Mill::Stages::ROUTES['plan'].each do |stage|
				refute_empty prompt(stage, issue: 'Do the thing.'), "#{stage} has no prompt"
			end
		end

		# Claude Code never has to guess which skill to load — the quickstart warns
		# about exactly that guessing.
		def test_a_stage_prompt_names_its_own_skill
			assert_includes prompt('plan', issue: 'x'), 'superpowers:writing-plans'
			assert_includes prompt('review:plan', issue: 'x'), 'adversarial-reviewer'
			assert_includes prompt('implement', issue: 'x'), 'mill:implement'
		end

		# A real triage launch read the inherited SessionStart hook as a
		# prompt-injection attempt and said so in its final message.
		def test_every_prompt_disarms_the_inherited_session_start_hook
			Mill::Stages.names.each do |stage|
				body = prompt(stage, issue: 'x')

				assert_match(/SessionStart/, body, "#{stage} does not account for the inherited hook")
			end
		end

		def test_a_stage_with_no_skill_says_so_rather_than_leaving_it_open
			body = prompt('triage', issue: 'x')

			assert_match(/no skill/i, body)
			refute_includes body, 'superpowers:'
		end

		def test_the_issue_body_reaches_the_stage
			assert_includes prompt('triage', issue: 'Track low-stock items'), 'Track low-stock items'
		end

		def test_predecessor_verdicts_are_passed_down
			body = prompt('implement', issue: 'x', plan_path: 'docs/superpowers/plans/p.md',
				verdicts: [{ stage: 'plan', status: 'ok', summary: 'wrote the plan' }])

			assert_includes body, 'docs/superpowers/plans/p.md'
			assert_includes body, 'wrote the plan'
		end

		# A reviewer's notes are what the coding agent reads on a re-run.
		def test_objections_are_injected_verbatim_on_a_rerun
			body = prompt('implement', issue: 'x', plan_path: 'p.md',
				objections: [{ severity: 'high', claim: 'race on restock',
					notes: 'lib/inventory.rb:14 — two callers can interleave' }])

			assert_includes body, 'race on restock'
			assert_includes body, 'lib/inventory.rb:14'
		end

		# Answering a blocked run injects the answer into the same session.
		def test_answers_are_injected_when_a_block_resumes
			body = prompt('plan', issue: 'x', spec_path: 's.md', answers: ['Use 30 seconds.'])

			assert_includes body, 'Use 30 seconds.'
		end

		# A missing key must never render as a blank. A stage told "the plan is: "
		# will invent one.
		def test_an_absent_context_key_is_stated_not_blanked
			body = prompt('review:code', issue: 'x')

			refute_match(/plan:\s*$/, body)
			assert_match(/no plan|not applicable/i, body)
		end

		def test_the_three_extra_review_lenses_are_present
			%w[review:plan review:code].each do |stage|
				body = prompt(stage, issue: 'x')

				assert_match(/buildabilit|execute each task/i, body) if stage == 'review:plan'
				assert_match(/simplicity|simplest/i, body)
				assert_match(/convention|consistenc/i, body)
			end
		end

		# review:code must not trust the implement verdict.
		def test_review_code_is_told_to_run_the_tests_itself
			assert_match(/run the .*test/i, prompt('review:code', issue: 'x', test_command: 'bundle exec rake test'))
		end

		def test_an_unknown_stage_raises_rather_than_rendering_nothing
			assert_raises(Mill::Error) { prompt('nonesuch', issue: 'x') }
		end
	end
end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_prompts.rb`
Expected: FAIL with `uninitialized constant Mill::Prompts`

- [x] **Step 3: Write the loader**

Create `lib/mill/prompts.rb`:

```ruby
module Mill
	# The thin prompt mill wraps around each stage's skill. The skill text does the
	# job; this says which job, on which artifacts, under which harness.
	#
	# Mill::Claude#envelope appends the verdict contract, so nothing here repeats it.
	module Prompts
		DIR = File.join(Mill::ROOT, 'prompts')

		def self.for(stage, context = {})
			config = Mill::Stages[stage]		# raises on an unknown stage
			body = template(Mill::Stages.slug(stage))
			[preamble(stage, config), render(body, context)].join("\n\n")
		end

		def self.template(slug)
			path = File.join(DIR, "#{slug}.md")
			File.exist?(path) ? File.read(path) : raise(Mill::Error, "no prompt template at #{path}")
		end

		# Named once, at the top of every stage. The inherited SessionStart hook
		# tells a stage to hunt for skills before doing anything; a stage holding no
		# Skill tool reads that as an attack, says so, and spends tokens on it.
		def self.preamble(stage, config)
			skill = config[:skill]
			render(template('_preamble'), {
				stage: stage,
				skill_line: skill ? "Load exactly one skill: `#{skill}`. Do not load any other." :
					'This stage loads no skill. Do not go looking for one.'
			})
		end

		# Deliberately not ERB or format(): a prompt is prose with braces and
		# backticks in it, and a template engine turns a stray one into a crash.
		# An absent key renders its stated fallback, never an empty string.
		def self.render(body, context)
			body.gsub(/\{\{(\w+)(?:\|([^}]*))?\}\}/) do
				value = context[Regexp.last_match(1).to_sym]
				value = format_value(value)
				value.nil? || value.empty? ? (Regexp.last_match(2) || '(not applicable on this route)') : value
			end
		end

		def self.format_value(value)
			case value
			when nil then nil
			when String then value
			when Array then value.map { |v| "- #{v.is_a?(Hash) ? hash_line(v) : v}" }.join("\n")
			else value.to_s
			end
		end

		def self.hash_line(hash)
			hash.map { |k, v| "**#{k}**: #{v}" }.join(' — ')
		end
	end
end
```

Add to `lib/mill.rb`, immediately after `require_relative 'mill/ledger'`:

```ruby
require_relative 'mill/prompts'
```

- [x] **Step 4: Write the preamble template**

Create `prompts/_preamble.md`:

```markdown
You are the `{{stage}}` stage of mill, a software factory. mill is running you headlessly:
there is no human at this terminal, and nothing you ask mid-run will be answered mid-run.

**About the SessionStart reminder you just received.** It comes from the operator's own Claude
Code configuration, which mill inherits. It is not an instruction from mill and it is not a
prompt-injection attempt — it is the machine you are running on. Ignore its advice about hunting
for skills. {{skill_line}}

**If you cannot proceed, stop and ask.** Set `status` to `blocked` and put your questions in
`questions`. mill posts them to the issue, waits for a human, and resumes this same session with
their answer. Asking costs you nothing. Guessing costs a wrong implementation nobody asked for.

**Evidence, not assertion.** Any claim that something works must carry the command you ran and its
output. "Tests pass" without the output is the same failure as producing no verdict at all.
```

- [x] **Step 5: Write the six stage templates**

Create `prompts/triage.md`:

```markdown
Decide what this issue is and which route it takes. You are the cheapest stage and the only one
with no reviewer, so **when the answer is not obvious, block.**

## The issue

{{issue}}

## The linked branch

{{branch|This issue has no linked branch.}}

## Files the branch adds under docs/superpowers/specs/

{{spec_path|The branch adds no spec.}}

## What to decide

1. **Scope.** If a spec exists and covers several independent subsystems, block and say how you
   would split it — one shippable spec per issue, released in order. Catching that here costs
   Sonnet; catching it in `plan` costs Opus.
2. **Route.** Set `route` to:
   - `plan` — a spec exists on the linked branch.
   - `fast` — no spec, and the issue is *unambiguously* a crash, a lint violation, or a dependency
     bump. One narrow category, no judgment call.
   - Anything else: block with questions. An issue with no spec that is not obviously
     hotfix-shaped is one where the answer is usually "go have a design session."

Read the repository if you need context. Change nothing — you hold no write tools.
```

Create `prompts/plan.md`:

```markdown
Turn the spec into a plan another agent can execute without asking anyone a question.

**This is where every question should surface.** Each time the implementer blocks it costs hours
of wall time and wastes every Opus call before it. Ask everything the pipeline will ever need
to ask, once, in one batch, before you finish.

## The spec

Read it in full: `{{spec_path}}`

## The issue

{{issue}}

## Answers to earlier questions

{{answers|None — this is the first launch of this stage.}}

## Reviewer objections to address

{{objections|None.}}

## Before you write anything

Read the codebase for the patterns the implementer will have to follow — how tests are structured,
what naming conventions the code uses, how errors are handled. Read the test infrastructure: what
command runs the tests, what passing output looks like, what setup it needs. Concrete examples from
the actual code, not rules from a document.

## The plan

Follow `superpowers:writing-plans` for structure, with three changes mill requires:

1. **Replace the `REQUIRED SUB-SKILL` header line** with: `REQUIRED SUB-SKILL: Use mill:implement to
   implement this plan task-by-task.` The skill's default header names two skills the implementer
   must not load.
2. **Drop the execution-handoff question at the end.** mill decides how the plan is executed.
3. **The Global Constraints section is the most important one you write.** Put the exact values from
   the spec in it verbatim, the codebase conventions with concrete examples, the test command, and
   the expected passing output.

Then run the buildability test on every task you wrote: could you write the exact failing test right
now, and the exact implementation, from what the spec and the codebase give you? If not, is the gap
in the spec or in your reading of the codebase? Codebase gaps are yours to investigate. **Spec gaps
become questions — collect them all and block once with the full list.**

Finally, check size: would this plan's pull request be readable in one sitting, and does it fit two
30-minute implementer launches with room for one review-driven re-run? If not, block and propose the
split, naming each sub-spec and the release order.

Save to `docs/superpowers/plans/<date>-<slug>.md` and report that path as `artifact`.
```

Create `prompts/review-plan.md`:

```markdown
Review this plan adversarially. Assume it is broken and prove it.

## The plan

`{{plan_path}}`

## The spec it claims to implement

`{{spec_path}}`

## What the earlier stages reported

{{verdicts|Nothing yet.}}

Work through the `adversarial-reviewer` checklist in full. Then three lenses mill adds, which the
generic checklist does not cover:

1. **Buildability — can an agent execute each task without asking a human?** Are interfaces given
   with exact signatures? Does every step carry actual code rather than a description of code? A
   task that says "add appropriate error handling" is a finding, because the implementer *will*
   block on it, and that block costs hours.
2. **Simplicity — is this the simplest decomposition that works?** Does the plan introduce files,
   abstractions, or patterns this codebase does not need? Does anything duplicate what already
   exists? A plan that is correct but unnecessarily complex produces code that is correct but
   unnecessarily complex, and nobody notices until it is everywhere.
3. **Codebase alignment — does the plan follow the conventions it claims to?** Do the examples in
   Global Constraints actually match the code? Are the paths consistent with how this project is
   laid out?

You are a reviewer, so you report `status: "ok"` with `objections` — you do not report `failed`.
Only `critical` and `high` re-run the plan stage; be honest about severity rather than escalating
to be heard. If you found nothing, say so and raise nothing. Silence is approval, and manufacturing
a finding to look thorough wastes a full Opus stage.
```

Create `prompts/implement.md`:

```markdown
Build the plan. One task at a time, test first, commit per task.

## The plan

`{{plan_path}}` — this is your brief and your ledger. Its checkboxes are how mill and you both know
what is done.

## The spec

`{{spec_path}}`

## What the earlier stages reported

{{verdicts|Nothing yet.}}

## Reviewer objections you are re-running to address

{{objections|None — this is a first pass, not a re-run.}}

## Answers to earlier questions

{{answers|None.}}

Load `mill:implement` and follow it. The short version, so you know what you are agreeing to:

- Read the plan once, note the Global Constraints, and check the checkboxes — anything already
  ticked is done, so confirm against `git log` and resume at the first unticked task.
- Per task: write the failing test, **watch it fail for the right reason**, write the minimal code,
  watch it pass, refactor only once green. Exact values — signatures, magic strings, test cases —
  come from the plan text verbatim; do not re-derive them.
- Match the surrounding code. If five methods use symbol keys, the sixth does too.
- Run the full suite once before committing, not after every edit.
- Commit each task's work with its tests, and **tick the checkbox in the same commit**. That commit
  is your recovery map if this session compacts.
- If a task is too vague to execute, block and say exactly what is missing. That should be rare —
  the plan stage and the plan reviewer both exist to prevent it — and when it happens it means the
  plan has a gap, not that you should improvise.

Report `ok` only when every checkbox is ticked and the full suite is green, with the command and its
output in your summary.
```

Create `prompts/review-code.md`:

```markdown
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
   implementer's verdict that tests pass — verify it. You hold Bash for this reason.
2. **Plan alignment.** Does the code build what the plan asked for, with the interfaces the plan
   specified? Did the implementer add things the plan did not ask for, or skip things it required?
   A deviation is a finding, not a silent improvement.
3. **Codebase consistency.** Does this look like it belongs in this codebase, or like it was written
   by someone who did not read the neighbouring files? Same hash-key style, same error handling,
   same file layout.
4. **Test quality.** For each new test, name the production change that would make it fail. If you
   cannot, the test proves nothing and that is a finding. Mocks where real code would do are a
   finding. Test output must be pristine.

You report `status: "ok"` with `objections` — a reviewer does not report `failed`. Only `critical`
and `high` re-run the implementer, so calibrate honestly rather than escalating to be heard. If the
code is sound, raise nothing and say so.

You hold no write tools. Do not try to fix what you find; describe it precisely enough that someone
else can.
```

Create `prompts/pr.md`:

```markdown
Open the pull request.

## The branch

`{{branch}}` against `{{base|main}}`.

## Everything the run produced

{{verdicts|Nothing recorded.}}

## Reviewer objections raised along the way

{{objections|None.}}

Load `mill:pr` and follow it:

1. **Run the full test suite first.** `{{test_command|bundle exec rake test}}`. If anything fails,
   report the failures and block. Nothing else happens until it is green — and "green" means you
   read the exit code and the output, not that you expect it to be.
2. Compose the body: what the spec asked for, what the plan decided, what changed, the objections
   raised and how they were addressed, and the per-stage token usage mill gives you above.
3. Push the branch and open the pull request against the base branch with `gh pr create`.

**Do not merge, and do not comment.** mill never merges, and mill posts the reviewer notes itself
through its own GitHub seam. `gh pr merge`, `gh pr comment`, `gh issue comment`, and `gh api` are
all denied to you; if you find yourself reaching for one, that is the design telling you the job
belongs to mill rather than to you.

Do not report the pull request number in your verdict. mill recovers it with `gh pr list --head`,
which is idempotent — so if you crash between creating the PR and mill recording it, mill reconciles
instead of opening a second one.
```

- [x] **Step 6: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_prompts.rb`
Expected: PASS, 12 runs, 0 failures

- [x] **Step 7: Run the full suite and commit**

```bash
git add prompts/ lib/mill/prompts.rb lib/mill.rb test/mill/test_prompts.rb
git commit -m "Add the stage prompts, and disarm the inherited SessionStart hook"
```

---

### Task 6: mill's own plugin — `mill:implement`, `mill:pr`, `mill-headless`

Two stages need mill's own skill because the Superpowers versions are built to be driven by a human
and collide with mill's graph. `executing-plans` opens by telling the agent to load a different
skill, then creates a worktree mill already made, then ends by opening the pull request before
`review:code` has run. `finishing-a-development-branch` presents a menu whose first option is
merging locally, which is the one thing mill never does.

These live in the mill repo — version-controlled, reviewed alongside the code, outside every
worktree so no stage can edit the instructions it runs under.

**Files:**
- Create: `plugin/.claude-plugin/plugin.json`
- Create: `plugin/skills/implement/SKILL.md`
- Create: `plugin/skills/pr/SKILL.md`
- Create: `plugin/skills/mill-headless/SKILL.md`
- Create: `.claude-plugin/marketplace.json`
- Modify: `docs/reference/setup.md` — add the enabling step to section 6
- Test: `test/mill/test_own_skills.rb`

**Interfaces:**
- Consumes: `Mill::Skills.resolve` (Plan 1), which resolves `mill:implement` only through an
  *enabled* plugin.
- Produces: `mill:implement` and `mill:pr` resolvable, so `Mill::Doctor` goes green on them.

- [x] **Step 1: Write the failing test**

Create `test/mill/test_own_skills.rb`:

```ruby
require 'test_helper'

module Mill
	# The two skills mill owns ship in this repo. These assert the files exist and
	# say the things the design requires, without needing the plugin enabled.
	class TestOwnSkills < Minitest::Test
		PLUGIN = File.join(Mill::ROOT, 'plugin')

		def skill(name) = File.read(File.join(PLUGIN, 'skills', name, 'SKILL.md'))

		def test_the_plugin_declares_itself_as_mill
			manifest = JSON.parse(File.read(File.join(PLUGIN, '.claude-plugin', 'plugin.json')),
				symbolize_names: true)

			assert_equal 'mill', manifest[:name], 'the prefix in mill:implement is the plugin name'
		end

		def test_every_skill_the_graph_names_from_mill_exists
			Mill::Stages::ALL.each_value do |config|
				next unless config[:skill]&.start_with?('mill:')

				name = config[:skill].split(':', 2).last
				assert_path_exists File.join(PLUGIN, 'skills', name, 'SKILL.md')
			end
		end

		# Each is self-contained in one SKILL.md rather than the multi-file shape
		# Superpowers uses, so a stage never has to Read a supporting file.
		def test_each_skill_is_self_contained
			%w[implement pr mill-headless].each do |name|
				dir = File.join(PLUGIN, 'skills', name)

				assert_equal ['SKILL.md'], Dir.children(dir).sort
			end
		end

		def test_each_skill_has_the_required_front_matter
			%w[implement pr mill-headless].each do |name|
				body = skill(name)

				assert_match(/\A---\nname: /, body, "#{name} needs name front matter")
				assert_match(/^description: /, body, "#{name} needs a description")
			end
		end

		# mill never merges. Nothing in the codebase calls gh pr merge, and the
		# skill that opens pull requests must not describe it as an option.
		def test_the_pr_skill_never_offers_to_merge
			body = skill('pr')

			refute_match(/gh pr merge/, body.sub(/never merge[^.]*\./i, ''))
			assert_match(/never merge/i, body)
		end

		# The Superpowers version opens by redirecting to a different skill and ends
		# by opening the PR. Both would break mill's graph.
		def test_the_implement_skill_does_not_redirect_or_finish_the_branch
			body = skill('implement')

			refute_match(/subagent-driven-development/, body)
			refute_match(/finishing-a-development-branch/, body)
			assert_match(/checkbox/i, body, 'the plan file is the ledger')
		end

		def test_the_implement_skill_states_the_iron_law
			assert_match(/no production code without a failing test/i, skill('implement'))
		end

		# Every borrowed skill's interactive gate maps onto block-and-ask.
		def test_mill_headless_covers_every_gate_the_borrowed_skills_have
			body = skill('mill-headless')

			%w[writing-plans test-driven-development systematic-debugging].each do |named|
				assert_match(/#{named}/, body, "mill-headless must say what #{named} does when it would ask")
			end
		end
	end
end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_own_skills.rb`
Expected: FAIL with `No such file or directory ... plugin/.claude-plugin/plugin.json`

- [x] **Step 3: Write the plugin manifest and the marketplace**

Create `plugin/.claude-plugin/plugin.json`:

```json
{
	"name": "mill",
	"description": "The two skills mill owns: building a plan task-by-task, and opening the pull request.",
	"version": "0.1.0"
}
```

Create `.claude-plugin/marketplace.json` at the repo root:

```json
{
	"name": "mill-local",
	"owner": { "name": "slowernet" },
	"plugins": [
		{ "source": "./plugin", "name": "mill" }
	]
}
```

- [x] **Step 4: Write `plugin/skills/mill-headless/SKILL.md`**

```markdown
---
name: mill-headless
description: Use when running as a mill stage - redefines every interactive gate the borrowed skills assume, so a question becomes a blocked verdict rather than a wait that never ends.
---

# Running headless, inside mill

You are a stage in mill's pipeline. There is no human at this terminal. Every skill you load was
written for someone sitting in front of a terminal, and each one has at least one place where it
tells you to ask and wait. **You cannot wait.** A process that waits for an answer here blocks
forever and is eventually reaped as wedged, which costs an attempt and tells nobody anything.

## The one substitution

Wherever a skill tells you to ask the user and wait for an answer, you instead:

1. Stop where you are. Do not proceed on a guess, and do not pick the option you think they would
   have picked.
2. Set `status` to `blocked` in your verdict.
3. Put every question in `questions`, phrased so someone who has not read your reasoning can answer
   it. Prefer multiple choice with your recommendation first.
4. Emit the verdict. That is the end of your turn.

mill posts your questions to the issue or pull request, sets the item to Blocked, and stops. When a
human replies, mill resumes **this same session** with their answer injected, so you keep everything
you had worked out. Nothing is lost by asking.

## Batch, don't drip

If you can see three questions coming, ask all three now. Each block costs hours of wall time and
wastes every stage that ran before you. One round trip with three questions is cheap; three round
trips is a day.

## The gates you will actually meet

| Skill | Where it wants to ask | What you do instead |
|---|---|---|
| `superpowers:writing-plans` | Asking the user to critique the design before planning | Block only if the spec has a real gap. A design you merely have opinions about is not a gap |
| `superpowers:test-driven-development` | Asking permission to skip tests for generated or throwaway code | Block and ask. Never skip tests on your own authority |
| `superpowers:systematic-debugging` | Asking after three failed hypotheses ("question the architecture") | Block with all three hypotheses and why each failed |
| `superpowers:systematic-debugging` | "If you don't know, say so" | Block. Saying you don't know into a log nobody reads is not saying so |
| Any skill | Presenting options and asking which to take | Block, list the options, recommend one, say why |

## What is not a reason to block

- Wanting confirmation that your work is good. Emit it and let the reviewer stage do its job.
- A decision the spec or the plan already made. Read them again first.
- A choice with an obvious right answer and no consequence if you are wrong. Make it and note it in
  your summary.

Blocking is free and always correct when you genuinely cannot proceed. It is not free when used as
a way to avoid committing to a judgment you were asked to make.
```

- [x] **Step 5: Write `plugin/skills/implement/SKILL.md`**

```markdown
---
name: implement
description: Use when building a plan mill has handed you - one task at a time, test first, a commit per task, ticking the plan's checkboxes as the ledger.
---

# Building a plan, headlessly

You have one plan and one process. You will work through it task by task until every checkbox is
ticked or you hit something you genuinely cannot resolve.

**The iron law: no production code without a failing test first.** A test you did not watch fail
proves nothing — it may be passing because the feature exists, or because the test is wrong.

## Before the first task

1. **Read the plan once, end to end.** Note the Global Constraints: they carry the codebase
   conventions, the test command, and the exact values from the spec. You will not re-read the whole
   plan for each task, so take what you need now.
2. **Read the checkboxes.** Any task already ticked `[x]` is done. Confirm against `git log` that
   its commit exists, then skip it and resume at the first unticked task. This is how you recover
   from a compacted context or a resumed session — the plan file is the ledger.
3. **Scan for conflicts once.** Tasks that contradict each other or the Global Constraints. If you
   find any, block with all of them described at once rather than discovering them one at a time.

## The per-task loop

**Read the task.** Files, interfaces, steps. Exact values — signatures, magic strings, test cases —
come from the plan text verbatim. Do not re-derive what the plan already decided; the planner made
those choices for reasons you cannot see from here.

**If the task is too vague to execute** — a step with no code, an interface with no signature, a
missing test command — block and say precisely what is missing. This should be rare. The plan stage
ran a buildability test and a reviewer checked it; if you are here, the plan has a gap. Do not paper
over it.

Then, for each step:

1. **RED.** Write one minimal test showing what should happen. A clear name, real behaviour, one
   thing. Real code, not mocks, unless a mock is genuinely unavoidable.
2. **Verify RED.** Run it. Confirm it fails, and read the failure — it must fail because the feature
   is missing, not because you mistyped. If it passes, you are testing something that already
   works; fix the test.
3. **GREEN.** Write the simplest code that passes. No extra features, no refactoring, no
   improvements beyond what the test demands.
4. **Verify GREEN.** Run it. Confirm it passes, that the other tests still pass, and that the output
   is pristine — no stray warnings, no incidental errors.
5. **REFACTOR.** Only once green. Remove duplication, improve names, extract helpers. Keep the tests
   green. Do not add behaviour.

**Match the codebase.** The Global Constraints carry concrete examples. If five methods use symbol
keys, the sixth does too. Do not introduce a pattern this codebase does not already use, however
much you prefer it.

**Run the focused test while iterating; run the full suite once before committing.**

## Finishing a task

**Self-review before you report.** Four questions, honestly:

- *Completeness* — did I implement everything the task asked for? Any requirement skipped? Any edge
  case the task named and I did not cover?
- *Quality* — is this my best work? Are the names clear? Would I be happy to find this code?
- *Discipline* — did I build only what was asked? Did I follow the existing patterns rather than
  imposing mine?
- *Testing* — do the tests verify real behaviour? Did I actually watch each one fail first? Is the
  output clean?

**Evidence, not assertion.** The task is done when you can show the covering tests, the command you
ran, and its output. "Tests pass" without the output is the same failure as producing no verdict.

**Commit the task's work** — implementation and tests together, one commit per task — **and tick the
checkbox in the plan file in that same commit.** The ticked plan plus `git log` is the only thing
that survives a compacted context, and it lands in the pull request showing exactly what was done.

## When you are in over your head

Stop. Report what you attempted, what you are stuck on, and what you have already tried. Block with
questions rather than producing work you do not believe in. Escalating is always correct. Bad work
is always worse than no work, because someone has to find it first.

## When every task is ticked

Run the full test suite one final time. Verify every checkbox is ticked. Then emit your verdict:
`ok` with the list of commits and the test output, or `blocked` with questions if any task could not
be finished.

## What this skill deliberately does not do

Creating a worktree (mill made it), dispatching subagents (you hold no such tool, and instructions
are not capability), running your own review-and-fix loop (mill's `review:code` stage does that, and
a second retry ledger mill cannot see would corrupt the first), opening a pull request (mill's `pr`
stage, after review), and choosing models (mill's stage table).
```

- [x] **Step 6: Write `plugin/skills/pr/SKILL.md`**

```markdown
---
name: pr
description: Use when mill's pr stage opens the pull request - verify tests with fresh evidence, compose the body from what the run produced, push, and open it. Never merges.
---

# Opening the pull request

The work is done and reviewed. Your job is to prove it still passes, describe it honestly, and open
the pull request. **You never merge**, and you never comment.

## 1. Verify, with fresh evidence

Run the full test suite. Read the exit code and the full output.

This is a gate, not a formality. You may not write "tests pass" because they passed for an earlier
stage, because the code looks right, or because you are confident. Identify the command that proves
the claim, run it, read all of the output, confirm it says what you think it says — and only then
make the claim.

**If anything fails, block.** Report the failing tests and their output in `questions`. Do not fix
them: the fixing stages have already run and been reviewed, and a fix you make here goes out
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
because they now have to work out what you left out.

## 3. Push and open

Push the branch to origin, then `gh pr create` against the base branch mill named. Nothing else.

## What is denied to you, and why

`gh pr merge` — mill never merges. Reading the pull request is the human gate, and a factory that
merges its own output is a dark factory.

`gh issue comment`, `gh pr comment`, `gh api` — only mill comments, and it always stamps a marker so
its own poller does not read mill's writing as a new instruction. If mill's comments were
unstamped, or if you posted one, the pipeline would trigger itself in a loop.

If you find yourself reaching for any of these, that is the design telling you the job is mill's
rather than yours.

## Do not report the pull request number

mill recovers it with `gh pr list --head <branch>`, which is idempotent. If you crash between
creating the pull request and mill recording it, mill reconciles instead of opening a second one.
Reporting it would make that reconciliation a guess.
```

- [x] **Step 7: Add the enabling step to the runbook**

Append to section 6 of `docs/reference/setup.md`:

````markdown
### mill's own plugin

Two stages load skills mill owns, and they live in this repo so a stage cannot edit the instructions
it runs under. They resolve only through an *enabled* plugin — installed-but-disabled provides
nothing, and doctor reports exactly that:

```
claude plugin marketplace add ~/code/mill
claude plugin install mill@mill-local
```

Verify with `bundle exec rake mill:doctor`: the two `skill mill:` lines go green. If they do not,
the plugin is installed but not enabled — `claude plugin enable mill` — or the marketplace path is
wrong.
````

- [x] **Step 8: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_own_skills.rb`
Expected: PASS, 8 runs, 0 failures

- [x] **Step 9: Run the full suite and commit**

```bash
git add plugin/ .claude-plugin/ docs/reference/setup.md test/mill/test_own_skills.rb
git commit -m "Add mill:implement, mill:pr and mill-headless as mill's own plugin"
```

---

### Task 7: `Mill::Runner` — walk the route

The runner walks `ROUTES[route]` one stage at a time, applying the ledger to every ending and
deciding what happens next. It never spawns anything itself: it calls an injected launcher, which in
production is `Mill::Claude#run` and in tests is a lambda returning scripted attempts. That is what
lets the whole control plane be tested with no network and no `claude`.

**Files:**
- Create: `lib/mill/runner.rb`
- Modify: `lib/mill.rb` — add `require_relative 'mill/runner'` after the `mill/prompts` line
- Test: `test/mill/test_runner.rb`

**Interfaces:**
- Consumes: `Mill::Stages.next_stage`, `Mill::Stages.reviewed_stage`, `Mill::Ledger`,
  `Mill::Prompts.for`, `Mill::Claude::Attempt`.
- Produces:
  - `Mill::Runner.new(db:, run_id:, launcher:, context: {})`
  - `#step` → one of `:advanced`, `:rerun`, `:blocked`, `:failed`, `:done`
  - `#call` → the terminal symbol, looping until one is reached
  - `#state` → Hash with `:stage`, `:status`, `:questions`, `:reason`
  - The launcher is called as `launcher.call(stage:, prompt:, attempt:, session_id:)` and must
    return an object shaped like `Mill::Claude::Attempt`.

- [x] **Step 1: Write the failing test**

Create `test/mill/test_runner.rb`:

```ruby
require 'test_helper'

module Mill
	# Walks the graph against scripted verdicts. Never runs claude, never touches
	# the network. Every branch of the ledger is reachable from here.
	class TestRunner < Mill::TestCase
		# The smallest thing shaped like a Mill::Claude::Attempt.
		def scripted(status: 'ok', valid: true, success: true, objections: [], questions: [],
			artifact: nil, session: 'sess-1')
			verdict = Object.new
			verdict.define_singleton_method(:valid?) { valid }
			verdict.define_singleton_method(:status) { status }
			verdict.define_singleton_method(:blocked?) { status == 'blocked' }
			verdict.define_singleton_method(:rejects?) { objections.any? }
			verdict.define_singleton_method(:serious_objections) { objections }
			verdict.define_singleton_method(:questions) { questions }
			verdict.define_singleton_method(:errors) { valid ? [] : ['no verdict'] }
			verdict.define_singleton_method(:data) { { artifact: artifact } }

			result = Object.new
			result.define_singleton_method(:success?) { success }
			result.define_singleton_method(:error) { nil }
			result.define_singleton_method(:log_path) { '/dev/null' }
			result.define_singleton_method(:stream) { self }
			result.define_singleton_method(:session_id) { session }
			result.define_singleton_method(:tokens) { { tokens_in: 1, tokens_out: 2 } }
			result.define_singleton_method(:model) { 'claude-opus-5' }

			Mill::Claude::Attempt.new(stage: nil, attempt: nil, nonce: 'n',
				result: result, verdict: verdict)
		end

		# Scripts one reply per stage visit, in order.
		def runner_for(script, route: 'plan')
			@calls = []
			run_id = create_run(repo_id: create_repo, route: route)
			queue = script.dup
			launcher = lambda do |stage:, prompt:, attempt:, session_id:|
				@calls << { stage: stage, attempt: attempt, session_id: session_id, prompt: prompt }
				reply = queue.shift or raise "script exhausted at #{stage}"
				reply.is_a?(Proc) ? reply.call(stage) : reply
			end
			Mill::Runner.new(db: db, run_id: run_id, launcher: launcher,
				context: { issue: 'Track low-stock items' })
		end

		def ok_for(stage)
			artifact = Mill::Stages[stage][:artifact] ? 'docs/superpowers/plans/p.md' : nil
			scripted(artifact: artifact)
		end

		# --- the happy path -------------------------------------------------

		def test_a_clean_run_walks_the_whole_plan_route
			runner = runner_for(Array.new(6) { ->(stage) { ok_for(stage) } })

			assert_equal :done, runner.call
			assert_equal Mill::Stages::ROUTES['plan'], @calls.map { |c| c[:stage] }
		end

		def test_every_stage_is_launched_as_attempt_one_on_a_clean_run
			runner_for(Array.new(6) { ->(stage) { ok_for(stage) } }).call

			assert_equal [1] * 6, @calls.map { |c| c[:attempt] }
		end

		def test_the_first_launch_of_a_stage_is_a_fresh_session
			runner_for(Array.new(6) { ->(stage) { ok_for(stage) } }).call

			assert(@calls.all? { |c| c[:session_id].nil? }, 'a first launch must not resume')
		end

		def test_each_attempt_is_recorded
			runner = runner_for(Array.new(6) { ->(stage) { ok_for(stage) } })
			runner.call

			assert_equal 6, db[:stage_attempts].where(run_id: runner.run_id).count
		end

		# --- blocking -------------------------------------------------------

		def test_a_blocked_stage_stops_the_line_and_keeps_its_questions
			runner = runner_for([scripted(status: 'blocked', questions: ['Which spec?'])])

			assert_equal :blocked, runner.call
			assert_equal ['Which spec?'], runner.state[:questions]
			assert_equal 'triage', runner.state[:stage]
		end

		def test_blocking_costs_no_strike
			runner = runner_for([scripted(status: 'blocked', questions: ['?'])])
			runner.call

			assert_equal 0, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# --- failure and resume ---------------------------------------------

		# A relaunch resumes the session, so the agent remembers its own work.
		def test_a_failed_stage_is_relaunched_against_its_own_session
			runner = runner_for([scripted(status: 'failed'), ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }])
			runner.call

			assert_equal %w[triage triage], @calls.first(2).map { |c| c[:stage] }
			assert_equal [1, 2], @calls.first(2).map { |c| c[:attempt] }
			assert_equal 'sess-1', @calls[1][:session_id], 'a relaunch resumes'
		end

		# When the verdict itself was untrustworthy mill has no reliable account of
		# what the first launch did, so it starts fresh instead of resuming.
		def test_an_invalid_verdict_starts_a_fresh_session
			runner = runner_for([scripted(valid: false)] + Array.new(6) { ->(stage) { ok_for(stage) } })
			runner.call

			assert_nil @calls[1][:session_id], 'mill cannot trust a session it has no account of'
		end

		def test_two_failures_of_one_stage_block_the_run
			runner = runner_for([scripted(status: 'failed'), scripted(status: 'failed')])

			assert_equal :blocked, runner.call
			assert_match(/strike/i, runner.state[:reason])
			assert_equal 2, Mill::Ledger.new(db, runner.run_id).strikes('triage')
		end

		# --- rejection ------------------------------------------------------

		# A reviewer that finds something serious strikes the stage it reviewed,
		# and mill re-runs that stage rather than the reviewer.
		def test_a_serious_objection_re_runs_the_reviewed_stage
			objection = { severity: 'high', claim: 'race', notes: 'lib/x.rb:1' }
			runner = runner_for([
				->(stage) { ok_for(stage) },										# triage
				->(stage) { ok_for(stage) },										# plan
				scripted(objections: [objection]),									# review:plan rejects
				->(stage) { ok_for(stage) },										# plan again
				->(stage) { ok_for(stage) },										# review:plan clean
				->(stage) { ok_for(stage) },										# implement
				->(stage) { ok_for(stage) },										# review:code
				->(stage) { ok_for(stage) }											# pr
			])

			assert_equal :done, runner.call
			assert_equal %w[triage plan review:plan plan review:plan implement review:code pr],
				@calls.map { |c| c[:stage] }
		end

		def test_a_rejection_strikes_the_reviewed_stage_not_the_reviewer
			objection = { severity: 'critical', claim: 'x', notes: 'y' }
			runner = runner_for([
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				scripted(objections: [objection]),
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }
			])
			runner.call
			ledger = Mill::Ledger.new(db, runner.run_id)

			assert_equal 1, ledger.strikes('plan')
			assert_equal 0, ledger.strikes('review:plan')
			assert_equal 2, ledger.attempts('review:plan'), 'the reviewer reviewed twice'
		end

		# The reviewer's notes reach the stage that has to act on them.
		def test_the_objections_are_injected_into_the_rerun
			objection = { severity: 'high', claim: 'race on restock', notes: 'lib/x.rb:14' }
			runner = runner_for([
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				scripted(objections: [objection]),
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				->(stage) { ok_for(stage) }
			])
			runner.call

			assert_includes @calls[3][:prompt], 'race on restock'
		end

		def test_two_rejections_of_one_stage_block_the_run
			objection = { severity: 'high', claim: 'x', notes: 'y' }
			runner = runner_for([
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				scripted(objections: [objection]),
				->(stage) { ok_for(stage) },
				scripted(objections: [objection])
			])

			assert_equal :blocked, runner.call
			assert_equal 'plan', runner.state[:stage]
		end

		# A reviewer returns ok with objections; low and medium do not re-run
		# anything, they land in the PR body.
		def test_minor_objections_do_not_re_run_anything
			runner = runner_for([
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) },
				scripted(objections: []),
				->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) }, ->(stage) { ok_for(stage) }
			])

			assert_equal :done, runner.call
			assert_equal 6, @calls.length
		end

		# --- the artifact travels forward -----------------------------------

		def test_the_plans_artifact_reaches_the_stages_that_need_it
			runner = runner_for(Array.new(6) { ->(stage) { ok_for(stage) } })
			runner.call
			implement = @calls.find { |c| c[:stage] == 'implement' }

			assert_includes implement[:prompt], 'docs/superpowers/plans/p.md'
		end

		# --- caps -----------------------------------------------------------

		# Free is not unlimited. A stage that keeps producing nothing mill can use
		# costs no strike per the ledger, but it must not loop forever either.
		def test_the_attempt_cap_stops_the_runner_not_just_the_ledger
			runner = runner_for(Array.new(20) { scripted(valid: false) })

			assert_equal :blocked, runner.call
			assert_match(/attempt cap/i, runner.state[:reason])
			assert_operator @calls.length, :<=, Mill::Ledger::MAX_ATTEMPTS
		end

		# Two strikes stop a stage well before the attempt cap does, so the cap
		# is only reachable on the paths that cost nothing.
		def test_strikes_stop_a_stage_before_the_attempt_cap_can
			runner = runner_for(Array.new(20) { scripted(status: 'failed') })
			runner.call

			assert_equal 2, @calls.length, 'two strikes, then block'
			assert_match(/strike/i, runner.state[:reason])
		end
	end
end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_runner.rb`
Expected: FAIL with `uninitialized constant Mill::Runner`

- [x] **Step 3: Write the implementation**

Create `lib/mill/runner.rb`:

```ruby
module Mill
	# Walks the stage graph for one run, applying the ledger to every ending.
	#
	# It never spawns anything. The launcher is injected — Mill::Claude#run in
	# production, a lambda returning scripted attempts in tests — which is what
	# lets the whole control plane be tested with no network and no claude.
	class Runner
		attr_reader :run_id, :state

		def initialize(db:, run_id:, launcher:, context: {})
			@db = db
			@run_id = run_id
			@launcher = launcher
			@context = context
			@ledger = Mill::Ledger.new(db, run_id)
			@sessions = {}
			@artifacts = {}
			@verdicts = []
			@objections = {}
			@state = {}
			@stage = route_stages.first
		end

		def run_row = @db[:runs].where(id: @run_id).first

		def route = run_row[:route] or raise Mill::Error, "run #{@run_id} has no route"

		def route_stages = Mill::Stages::ROUTES.fetch(route)

		TERMINAL = %i[blocked failed done].freeze

		def call
			outcome = step until TERMINAL.include?(outcome)
			outcome
		end

		def step
			return finish(:done) if @stage.nil?
			return halt(:blocked, "#{@stage} has used both its strikes") if @ledger.out_of_strikes?(@stage)
			return halt(:blocked, "#{@stage} hit its attempt cap") if @ledger.out_of_attempts?(@stage)

			attempt = @ledger.next_attempt(@stage)
			attempt = launch(@stage, attempt)
			outcome = settle(attempt, attempt)		# inserts the row
			record(attempt, attempt)					# fills in what the launch produced
			outcome
		end

		private

		def launch(stage, attempt)
			@launcher.call(
				stage: stage, attempt: attempt,
				prompt: Mill::Prompts.for(stage, prompt_context(stage)),
				session_id: @sessions[stage]
			)
		end

		# A relaunch resumes the stage's own session so the agent remembers its
		# work. The one exception is a verdict that failed validation: mill has no
		# trustworthy account of what happened, so it starts fresh.
		def settle(attempt, attempt)
			outcome = Mill::Ledger.classify(attempt)
			@sessions[@stage] = outcome == :no_verdict ? nil : attempt.session_id

			case outcome
			when :blocked
				@ledger.charge(stage: @stage, outcome: :blocked, attempt: attempt)
				halt(:blocked, "#{@stage} asked a question", questions: attempt.verdict.questions)
			when :ok
				remember(attempt)
				reviewer?(@stage) && attempt.verdict.rejects? ? reject(attempt, attempt) : advance(attempt)
			else
				@ledger.charge(stage: @stage, outcome: outcome, attempt: attempt)
				:rerun
			end
		end

		def advance(attempt)
			@ledger.charge(stage: @stage, outcome: reviewer?(@stage) ? :reviewed_clean : :ok,
				attempt: attempt)
			@stage = Mill::Stages.next_stage(route, @stage)
			@stage.nil? ? finish(:done) : :advanced
		end

		# A reviewer that finds something serious is the reviewer succeeding: it
		# costs the reviewer nothing and strikes the stage it reviewed. One row,
		# for the launch that actually happened — the strike rides on it, attributed
		# to whoever pays. The reviewed stage's attempt is its re-launch below.
		def reject(attempt, attempt)
			reviewed = Mill::Stages.reviewed_stage(route, @stage)
			@objections[reviewed] = attempt.verdict.serious_objections
			@ledger.charge(stage: @stage, outcome: :reviewed_clean, attempt: attempt,
				struck_stage: reviewed)

			return halt(:blocked, "#{reviewed} has used both its strikes") if @ledger.out_of_strikes?(reviewed)

			@stage = reviewed
			:rerun
		end

		def remember(attempt)
			path = attempt.verdict.data[:artifact]
			@artifacts[@stage] = path if path
			@verdicts << { stage: @stage, status: attempt.verdict.status,
				summary: attempt.verdict.data[:summary] }
		end

		def prompt_context(stage)
			@context.merge(
				spec_path: @context[:spec_path],
				plan_path: @artifacts['plan'],
				verdicts: @verdicts,
				objections: @objections[stage],
				route: route
			).compact
		end

		def record(attempt, attempt)
			@db[:stage_attempts].where(run_id: @run_id, stage: @stage, attempt: attempt)
				.update(session_id: attempt.session_id, model: attempt.model, log_path: attempt.log_path,
					verdict_json: attempt.verdict.data.to_json, finished_at: Mill.now)
		end

		def reviewer?(stage) = stage.start_with?('review:')

		def halt(status, reason, questions: [])
			@state = { stage: @stage, status: status, reason: reason, questions: questions }
			@db[:runs].where(id: @run_id).update(status: status.to_s, current_stage: @stage)
			status
		end

		def finish(status)
			@state = { stage: nil, status: status, reason: 'the route is complete', questions: [] }
			@db[:runs].where(id: @run_id).update(status: 'done', finished_at: Mill.now)
			status
		end
	end
end
```

Add to `lib/mill.rb`, immediately after `require_relative 'mill/prompts'`:

```ruby
require_relative 'mill/runner'
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_runner.rb`
Expected: PASS, 17 runs, 0 failures

**Amended after a smell review:** the first draft had `charge` insert the row and `record` update it
immediately afterwards. Two statements where one would do, and reversing them silently matched zero
rows — every attempt lost its session id, and *resume* broke rather than anything failing loudly.
`charge` now takes the attempt and inserts once; `record` is gone.

- [x] **Step 5: Run the full suite and commit**

```bash
git add lib/mill/runner.rb lib/mill.rb test/mill/test_runner.rb
git commit -m "Add the runner: walk the route, apply the ledger, resume on relaunch"
```

---

### Task 8: `rake mill:run` — drive one issue by hand

The entry point. No board, no poller: you give it a repo and an issue number, it locates the spec,
creates the worktree, and walks the route with the real launcher.

**Files:**
- Create: `lib/mill/run.rb` — the entry point
- Modify: `Rakefile` — a thin `mill:run` task over it
- Modify: `lib/mill/git.rb` — add `worktree_add` and `worktree_remove`
- Test: `test/mill/test_run.rb`, and worktree coverage in `test/mill/test_git.rb`

**Amended after a smell review:** the first draft put all sixty-odd lines in the Rakefile, where
none of it was testable and where Plan 3's locking and concurrency would have landed on top of it.
`Mill::Run` takes `github:`, `git:` and `claude:` the way everything else in this codebase takes its
seams, so the whole entry point runs in a test against a tmpdir clone and a fake.

**Interfaces:**
- Consumes: everything above.
- Produces: `Mill::Git.worktree_add(repo_path, tree_path, branch)` and
  `Mill::Git.worktree_remove(repo_path, tree_path)`; the rake task
  `mill:run[repo,number,clone_path]`.

- [x] **Step 1: Write the failing test**

Append to `test/mill/test_git.rb`, inside the class:

```ruby
		def test_a_worktree_is_created_on_an_existing_branch
			git('branch', 'work-here')
			Dir.mktmpdir do |elsewhere|
				tree = File.join(elsewhere, 'wt')
				Mill::Git.worktree_add(@repo, tree, 'work-here')

				assert_path_exists File.join(tree, 'README.md')
				assert_includes Mill::Git.checked_out_branches(@repo), 'work-here'

				Mill::Git.worktree_remove(@repo, tree)
				refute_includes Mill::Git.checked_out_branches(@repo), 'work-here'
			end
		end

		# git worktree add refuses a branch checked out anywhere. mill must surface
		# that as its own error rather than a raw git message.
		def test_adding_a_worktree_for_a_held_branch_fails_loudly
			git('switch', '-c', 'held')
			Dir.mktmpdir do |elsewhere|
				assert_raises(Mill::Git::Error) do
					Mill::Git.worktree_add(@repo, File.join(elsewhere, 'wt'), 'held')
				end
			end
		end
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_git.rb`
Expected: FAIL with `undefined method 'worktree_add'`

- [x] **Step 3: Write the implementation**

Add to `lib/mill/git.rb`, inside `module Git`:

```ruby
		# mill adopts a branch; it never creates one for the plan route, because the
		# branch came from `gh issue develop` and carries the spec.
		def self.worktree_add(repo_path, tree_path, branch)
			FileUtils.mkdir_p(File.dirname(tree_path))
			run!(repo_path, 'worktree', 'add', tree_path, branch)
			tree_path
		end

		def self.worktree_remove(repo_path, tree_path)
			run!(repo_path, 'worktree', 'remove', '--force', tree_path)
		end
```

Add `require 'fileutils'` to the top of `lib/mill/git.rb`.

- [x] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_git.rb`
Expected: PASS, 10 runs, 0 failures

- [x] **Step 5: Add the rake task**

Add to `Rakefile`, inside `namespace :mill do`:

```ruby
	desc 'Drive one issue through the plan route by hand: mill:run[owner/repo,42,~/code/repo]'
	task :run, %i[repo number clone] do |_t, args|
		require_relative 'lib/mill'
		abort 'usage: rake "mill:run[owner/repo,42,~/code/repo]"' unless args[:repo] && args[:number]

		owner, name = args[:repo].split('/', 2)
		clone = File.expand_path(args[:clone] || File.join('~/code', name))
		github = Mill::Github.new
		# .mill.yml is read from the base branch in Plan 3; by hand, take it from
		# the remote's default so a repo whose base is not `main` still works.
		base = Mill::Git.run(clone, 'symbolic-ref', 'refs/remotes/origin/HEAD')
			.out.strip.split('/').last
		base = 'main' if base.nil? || base.empty?

		located = Mill::Spec.locate(github: github, repo: args[:repo], number: args[:number].to_i,
			repo_path: clone, base: base)
		if located.blocked? || !located.found?
			puts "cannot start: #{located.problem}"
			located.questions.each { |q| puts "  - #{q}" }
			exit 1
		end

		db = Mill.db
		Mill::DB.migrate!(db)
		db[:repos].insert_conflict(target: %i[owner name]).insert(
			owner: owner, name: name, local_path: clone, base_branch: base, created_at: Mill.now
		)
		repo_id = db[:repos].where(owner: owner, name: name).get(:id)

		run_id = db[:runs].insert(repo_id: repo_id, subject_kind: 'issue',
			subject_number: args[:number].to_i, route: 'plan', branch: located.branch,
			spec_path: located.path, status: 'running', created_at: Mill.now)

		worktree = File.join(Mill.home, 'worktrees', "#{owner}-#{name}", run_id.to_s)
		Mill::Git.worktree_add(clone, worktree, located.branch)
		db[:runs].where(id: run_id).update(worktree_path: worktree)
		puts "run #{run_id} on #{located.branch}, worktree #{worktree}"

		issue = github.issue(args[:repo], args[:number].to_i)
		launcher = lambda do |stage:, prompt:, attempt:, session_id:|
			log = File.join(Mill.home, 'logs', run_id.to_s, "#{Mill::Stages.slug(stage)}-#{attempt}.jsonl")
			puts "-> #{stage} (attempt #{attempt})#{session_id ? ' resuming' : ''}"
			Mill::Claude.new(stage).run(prompt, attempt: attempt, worktree: worktree,
				log_path: log, session_id: session_id)
		end

		runner = Mill::Runner.new(db: db, run_id: run_id, launcher: launcher, context: {
			issue: issue[:body], spec_path: located.path, branch: located.branch, base: base
		})
		outcome = runner.call

		puts "\n#{outcome}: #{runner.state[:reason]}"
		runner.state[:questions].each { |q| puts "  ? #{q}" }
		db[:stage_attempts].where(run_id: run_id).each do |a|
			puts format('  %-14s inv %d  %-12s %s', a[:stage], a[:attempt], a[:status],
				a[:strike_charged] ? 'STRIKE' : '')
		end
		exit 1 unless outcome == :done
	end
```

- [x] **Step 6: Verify the task loads and refuses bad input**

Run: `bundle exec rake 'mill:run[]' 2>&1 | head -2`
Expected: `usage: rake "mill:run[owner/repo,42,~/code/repo]"`

- [x] **Step 7: Run the full suite and commit**

```bash
git add Rakefile lib/mill/git.rb test/mill/test_git.rb
git commit -m "Add rake mill:run, the by-hand entry point"
```

---

### Task 9: The rehearsal — a real pull request

Nothing above proves the pipeline works; it proves each piece works alone. This task is the
demonstrable, and it needs the operator to have completed Task 1.

**Files:** none. This task changes no code unless the rehearsal finds something, in which case fix
it, add the regression test, and note it here.

- [ ] **Step 1: Confirm the prerequisites**

Run: `bundle exec rake mill:doctor`
Expected: every line green. If `skill mill:implement` is red, the plugin is not enabled — see the
runbook step added in Task 6.

Run: `gh issue view <n> --repo slowernet/mill-scratch --json title,url`
Expected: the rehearsal issue exists, with a linked branch carrying one spec.

Run: `cd ~/code/mill-scratch && git branch --show-current`
Expected: `main`, not the issue branch. `git worktree add` refuses a branch checked out anywhere.

- [ ] **Step 2: Run it**

```bash
bundle exec rake 'mill:run[slowernet/mill-scratch,<n>,~/code/mill-scratch]'
```

Expected: each stage announced as it starts, then a summary table, then `done`, then a pull request
on `slowernet/mill-scratch`.

- [ ] **Step 3: Read the pull request**

This is the point of the whole system, so actually do it. Check: does the diff do what the spec
asked? Are the tests real? Does the body say what happened, including any objections raised?

- [ ] **Step 4: Read the logs for what the summary hides**

```bash
ls ~/.mill/logs/<run-id>/
```

For each stage, check the verdict validated first time. A stage that took two attempts for a
reason that is not in the ledger's cost table is a bug in the runner, not in the stage.

- [ ] **Step 5: Record what the rehearsal taught**

Add a short section to the design doc under Plan 2 naming what actually happened: which stages
blocked, which prompts needed changing, what the run cost in tokens. Plan 3 is written from this.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-08-06-software-factory-design.md
git commit -m "Record what the first end-to-end rehearsal taught"
```

---

## Self-review

**Spec coverage.** The stage graph → Task 7. Finding the spec → Tasks 2 and 3. The stage contract →
Plan 1, consumed here. The attempt ledger → Task 4, one test per row of the cost table. Back-pressure
(two strikes, what counts as rejection) → Tasks 4 and 7. How a run blocks and resumes → Task 7's
blocking tests plus `mill-headless` in Task 6. Stage prompts → Task 5. Skills mill borrows and owns →
Task 6. `rake mill:run` → Task 8. The demonstrable → Task 9.

**Known gaps, deliberately left.** The sanctioned strike reset is implemented and tested in the
ledger (Task 4) but the runner has no path that calls it, because that path is triggered by a comment
and comments arrive in Plan 3. `Mill::Spec.locate` returns `:no_branch` and `:no_spec` without acting
on them, because acting means routing to `fast`, which is Plan 5. Neither is a placeholder: both are
complete at their own layer and unused at the layer above, which is stated here so a reviewer does not
read the gap as an omission.

**Amended 2026-08-19, before execution.** The first draft had `reject` insert a `stage_attempts`
row for the stage it struck. That broke the row-per-launch invariant: the reviewed stage would show
an attempt with no log file and no verdict, and its real re-launch would be numbered one higher,
so log filenames skipped. The strike now rides on the reviewer's own row via `struck_stage`, and
`COST[:rejected]` counts no attempt. Task 7's attempt-cap test was also rewritten — it drove
the ledger directly rather than the runner, so it asserted nothing about the thing it named.

**Interfaces checked across tasks.** `Mill::Git.added_files` (Task 2) is called by `Mill::Spec.locate`
(Task 3) with the same arity. `Mill::Ledger#charge` (Task 4) is called by `Mill::Runner` (Task 7) with
`stage:`, `outcome:`, `attempt:`. `Mill::Prompts.for` (Task 5) is called by `Mill::Runner` with a
stage and a context Hash. `Mill::Claude::Attempt`'s members — `verdict`, `result`, `session_id`,
`model`, `tokens`, `log_path` — are all read by the runner and all exist from Plan 1.
