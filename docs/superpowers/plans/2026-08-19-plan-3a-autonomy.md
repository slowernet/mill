# Plan 3a — Autonomy

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not dispatch subagents:
> this repo's operator has not opted into them.

**Goal:** Set a board item to `Ready`, walk away, and come back to a pull request — with no human
in the middle, and with the board telling you what happened while you were gone.

**Architecture:** Plan 2 built one run driven by hand. Plan 3a builds the two loops around it.
`Mill::Poller` reconciles the board into work and sweeps comments behind a transactional cursor;
`Mill::Supervisor` prepares repos, claims items up to a cap, owns the worktree lifecycle, spawns a
thread per run, and reaps a process group against a verified identity. `Mill::Board` is the writing
side mill has never had — Status on claim, block, finish and failure, re-driven when GitHub was
unreachable. `Mill::Workers` holds both loops inside the Puma process, and `app.rb` plus
`config.ru` give them a home that Plan 4 fills in with routes.

**Tech Stack:** Ruby, Roda, Puma, Sequel over SQLite, Minitest. YAML from stdlib. No new gems.

**Spec:** `docs/superpowers/specs/2026-08-06-software-factory-design.md`.

**Spec sections this plan implements:** Ingress (the board is the queue, the poller reconciles,
triggers, who may trigger a run, how mill avoids triggering itself); Architecture (process shape,
paths); Setting up, and preparing a repo; Data model (`runs`, `repos`, `events`, board status
re-drive, the three reaping branches); Killing a run and tearing it down (stale locks, the branch
checked out in your clone, branch and worktree collisions, teardown); Web UI (only the boot path
and `GET /`).

**Explicitly out of scope**, listed so nobody builds them by accident: the stall detector, sleep
detection, the settle window and `caffeinate`, and the log reaper — all Plan 3b. The web UI's
routes, views, kill switch and log tail — Plan 4. The `fast` and `iterate` routes, `diagnose`,
`implement:fast`, `push`, the `mill:` comment trigger, review-comment triggers and CI-fix
triggers — Plan 5. Deep review and the evidence deliverable — unplanned.

**Gate.** Before Task 1, run `claude -p 'say ok'` on the Linux box mill will live on, and then
`bundle exec rake test:boundary` there. If `claude` cannot authenticate headlessly against the
subscription, mill has no primary deployment and this plan is being written for the wrong target —
stop and re-plan. If the boundary suite fails on Linux, that is a containment gap, not a
portability annoyance; fix it before any stage runs on that host. Neither result blocks writing
code on the laptop, but both block trusting it.

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
- **An endless method body cannot carry a trailing `if`.** `def teardown = x if y` defines the
  method conditionally rather than guarding the body. Use a normal `def` when the body needs a
  guard. Plan 2's `review:code` caught this against Plan 2's own constraints; it is here so it does
  not have to catch it again.
- **Comments only when something non-obvious is happening.** The design doc holds the reasoning.
- **Test files mirror source paths**: `lib/mill/poller.rb` → `test/mill/test_poller.rb`.
- **Test command:** `bundle exec rake test`. Passing output ends with a line like
  `308 runs, 1242 assertions, 0 failures, 0 errors, 0 skips`. Run it and read its output before any
  task claims completion. Never claim a pass you did not see.
- **No network and no `claude` in `rake test`.** `Mill::Github` is driven through an injected
  runner returning fixture JSON; the runner is driven through an injected launcher returning
  scripted `Mill::Claude::Attempt` values; git tests build real repositories in `Dir.mktmpdir`.
- **Boundary discipline.** Any new `gh` call belongs in `Mill::Github`. Any new `git` call belongs
  in `Mill::Git`. Any new subprocess belongs in `Mill::Spawn`. If you are reaching for a backtick,
  `system`, or `Open3` anywhere else, stop. `Mill::Clock` is the sole exception and already exists.
- **Safety invariants** from `CLAUDE.md` are not negotiable in any task: never write a call to
  `gh pr merge`; never post a comment except through `Mill::Github`; never add a retry path around
  the two-strikes-per-stage counter, and never charge a strike for something the machine did to a
  stage; never signal a bare pid, and never signal at all without checking the recorded boot time
  first; never loosen a ruleset in `~/.mill/settings/`; never add `--dangerously-skip-permissions`;
  never write an absolute path into a permission ruleset; never remove `--tools` or
  `--strict-mcp-config`; never bypass verdict validation.
- **A rescue must never convert a failure into a pass.** Silence is never success. This bites hardest
  in this plan: a poller that swallows a `gh` error looks exactly like a quiet board.
- **mill writes nothing to a repository** except local git config. No labels, no files, no branches
  it did not adopt.
- **Every numeric setting read from the environment is validated, not coerced.** `.to_i` turns
  `MILL_CONCURRENCY=lots` into `0`, which makes `at_cap?` true forever and stops mill claiming
  anything, silently and with a green doctor. `.to_f` turns `MILL_POLL_SECONDS=` into `0.0`, which
  turns the poll tick into a loop hammering the GitHub API as fast as it will answer. Both failures
  look like mill being broken rather than mill being misconfigured. So: parse with `Integer()` or
  `Float()`, reject anything outside the stated range, and fall back to the default with a warning
  on stderr naming the variable and the value.

  | Variable | Type | Range | Default |
  |---|---|---|---|
  | `MILL_CONCURRENCY` | Integer | 1–8 | 2 |
  | `MILL_POLL_SECONDS` | Float | 5–3600 | 30 |
  | `MILL_CLONES` | colon-separated paths | — | `~/code` on Darwin, empty on Linux |
  | `MILL_WORKERS` | `off` or unset | — | on |
  | `MILL_BIND` | Puma bind string | — | `tcp://127.0.0.1:9494` |
  | `MILL_PROJECT` | Integer | — | none; the board is not read without it |
  | `MILL_PROJECT_OWNER` | String | — | none; the board is not read without it |

---

### Task 1: The live process identity, and migration 005

The design's data model puts `pid`, `pid_started_at` and `host_boot_at` on `stage_attempts`. That
cannot work: `Mill::Ledger#charge` inserts the attempt row when the attempt is **over**, in one
insert, deliberately — so while a stage is actually running there is no row to read, and the
supervisor reaping in Task 8 would have nothing to identify. `runs.pgid` already exists for exactly
this reason. This task puts the other three beside it and gives `Mill::Spawn` a way to report them
the moment the process starts.

**Files:**
- Create: `db/migrations/005_a_live_run_carries_its_own_identity.rb`
- Modify: `lib/mill/spawn.rb` — add the `on_spawn:` callback
- Modify: `lib/mill/claude.rb:85` — pass it through `#run`
- Modify: `lib/mill/run.rb` — the launcher records it
- Test: `test/mill/test_spawn.rb`, `test/mill/test_schema.rb`

**Interfaces:**
- Consumes: `Mill::Spawn::Result` (`pid`, `pgid`, `pid_started_at`, `host_boot_at`), which exists.
- Produces: `runs.board_item_id` (String), `runs.pid`, `runs.pid_started_at`, `runs.host_boot_at`
  (Integer). `Mill::Spawn.new(..., on_spawn: ->(pid, pgid, started_at, boot_at) {})` and
  `Mill::Claude#run(..., on_spawn: nil)`. `Mill.setting_int(name, default:, min:, max:) -> Integer`
  and `Mill.setting_float(name, default:, min:, max:) -> Float`. Tasks 5, 7 and 8 read the columns;
  Tasks 6 and 12 read the settings.

- [ ] **Step 1: Write the failing schema test**

Add to `test/mill/test_schema.rb`:

```ruby
	# The identity of a live process belongs to the run, not to the attempt row:
	# the attempt row does not exist until the attempt is over, so a supervisor
	# reaping a running stage would have nothing to check it against.
	def test_a_run_carries_the_identity_of_its_live_process
		columns = db.schema(:runs).map(&:first)

		assert_includes columns, :pid
		assert_includes columns, :pgid
		assert_includes columns, :pid_started_at
		assert_includes columns, :host_boot_at
		assert_includes columns, :board_item_id
	end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_schema.rb -n test_a_run_carries_the_identity_of_its_live_process`
Expected: FAIL — `Expected [...] to include :pid.`

- [ ] **Step 3: Write the migration**

Create `db/migrations/005_a_live_run_carries_its_own_identity.rb`:

```ruby
# A stage_attempts row is written when the attempt ends, in one insert. So while a
# stage is running there is no row to read, and the three columns that identify a
# live process have to sit beside the pgid that is already on the run.
#
# board_item_id is here for the same reason: writing Status needs the project item
# id, and the poller that found the item is not the thing that later reports the
# run finished.
Sequel.migration do
	change do
		alter_table :runs do
			add_column :pid, Integer
			add_column :pid_started_at, Integer
			add_column :host_boot_at, Integer
			add_column :board_item_id, String
		end
	end
end
```

- [ ] **Step 4: Run the schema test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_schema.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing spawn test**

Add to `test/mill/test_spawn.rb`:

```ruby
	# The caller has to be able to record the identity before the process ends,
	# because the whole point of recording it is reaping something still alive.
	def test_reports_its_identity_as_soon_as_the_process_starts
		seen = nil
		spawn = Mill::Spawn.new(log_path: @log, chdir: Dir.tmpdir,
			on_spawn: ->(pid, pgid, started_at, boot_at) { seen = [pid, pgid, started_at, boot_at] })
		spawn.run(['ruby', '-e', 'sleep 0.1'])

		refute_nil seen, 'on_spawn was never called'
		pid, pgid, started_at, boot_at = seen

		assert_operator pid, :>, 1
		assert_equal pid, pgid
		refute_nil started_at
		refute_nil boot_at
	end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_spawn.rb -n test_reports_its_identity_as_soon_as_the_process_starts`
Expected: FAIL — `unknown keyword: :on_spawn`.

- [ ] **Step 7: Add the callback to `Mill::Spawn`**

In `lib/mill/spawn.rb`, change the constructor:

```ruby
		def initialize(log_path:, chdir:, secrets: [], on_spawn: nil, clock: -> { Mill::Clock.awake })
			@log_path = log_path
			@chdir = chdir
			@secrets = expand_secrets(secrets)
			@on_spawn = on_spawn
			@clock = clock
		end
```

In `#pump`, immediately after the identity is established and before the read loop, call it. Find
where `@pid`, `@pgid` and `@pid_started_at` are assigned inside `Open3.popen3` and add:

```ruby
				# Reported before the first line is read: a caller that waits for the
				# result cannot reap a process that is still running.
				@on_spawn&.call(@pid, @pgid, @pid_started_at, @host_boot_at)
```

- [ ] **Step 8: Run the spawn test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_spawn.rb`
Expected: PASS.

- [ ] **Step 9: Thread it through `Mill::Claude` and the launcher**

In `lib/mill/claude.rb`, change the signature at line 85 and the `Spawn.new` below it:

```ruby
		def run(prompt, number:, worktree:, log_path:, session_id: nil, env: {}, secrets: [],
			on_spawn: nil)
			nonce = self.class.nonce
			spawn = Mill::Spawn.new(log_path: log_path, chdir: worktree, secrets: secrets,
				on_spawn: on_spawn)
```

In `lib/mill/run.rb`, `#default_launcher` records it against the run:

```ruby
		def default_launcher(&announce)
			lambda do |stage:, prompt:, number:, session_id:|
				announce&.call(stage, number, !session_id.nil?)
				log = File.join(Mill.home, 'logs', @run_id.to_s,
					"#{Mill::Stages.slug(stage)}-#{number}.jsonl")
				@claude.new(stage).run(prompt, number: number, worktree: @worktree,
					log_path: log, session_id: session_id, env: Mill::Rules.env_for(stage),
					on_spawn: method(:record_identity))
			end
		end

		# What the supervisor reaps against. Cleared when the launch returns, so a
		# run between stages never looks like one holding a live process group.
		def record_identity(pid, pgid, started_at, boot_at)
			@db[:runs].where(id: @run_id).update(pid: pid, pgid: pgid, pid_started_at: started_at,
				host_boot_at: boot_at, heartbeat_at: Mill.now)
		end
```

And in `#default_launcher`, wrap the launch so the identity is cleared afterwards:

```ruby
				attempt = @claude.new(stage).run(prompt, number: number, worktree: @worktree,
					log_path: log, session_id: session_id, env: Mill::Rules.env_for(stage),
					on_spawn: method(:record_identity))
				@db[:runs].where(id: @run_id).update(pid: nil, pgid: nil, heartbeat_at: Mill.now)
				attempt
```

- [ ] **Step 10: Write the failing test for the two settings readers**

Every later task reads a number out of the environment, and coercion is the wrong tool: `.to_i`
turns a typo into a working value that stops the factory. Add to `test/mill/test_schema.rb` — or a
new `test/mill/test_settings.rb` if you prefer, matching the file naming rule:

```ruby
	def test_a_setting_falls_back_rather_than_coercing_a_typo
		ENV['MILL_TEST_N'] = 'lots'

		assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
	ensure
		ENV.delete('MILL_TEST_N')
	end

	def test_a_setting_outside_its_range_falls_back
		ENV['MILL_TEST_N'] = '99'

		assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
	ensure
		ENV.delete('MILL_TEST_N')
	end

	def test_a_valid_setting_is_used
		ENV['MILL_TEST_N'] = '4'

		assert_equal 4, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
	ensure
		ENV.delete('MILL_TEST_N')
	end

	def test_an_unset_setting_is_the_default
		assert_in_delta 30.0, Mill.setting_float('MILL_TEST_F', default: 30, min: 5, max: 3600)
	end
```

- [ ] **Step 11: Write them**

Add to `lib/mill.rb`, inside `module Mill`:

```ruby
	# Settings are parsed, never coerced. `'lots'.to_i` is 0, and a concurrency cap
	# of 0 stops mill claiming anything while every check stays green — a
	# misconfiguration that presents as mill being broken. A rejected value falls
	# back and says so, so the mistake is visible in the log rather than in the
	# absence of work.
	def self.setting_int(name, default:, min:, max:)
		setting(name, default: default, min: min, max: max) { |raw| Integer(raw, 10) }
	end

	def self.setting_float(name, default:, min:, max:)
		setting(name, default: default.to_f, min: min, max: max) { |raw| Float(raw) }
	end

	def self.setting(name, default:, min:, max:)
		raw = ENV[name]
		return default if raw.nil? || raw.strip.empty?

		value = yield(raw.strip)
		return value if value >= min && value <= max

		warn "#{name}=#{raw} is outside #{min}..#{max}; using #{default}"
		default
	rescue ArgumentError, TypeError
		warn "#{name}=#{raw} is not a number; using #{default}"
		default
	end
```

- [ ] **Step 12: Run the whole suite**

Run: `bundle exec rake test`
Expected: PASS, with the run count up by six from 308.

- [ ] **Step 13: Commit**

```bash
git add db/migrations/005_a_live_run_carries_its_own_identity.rb lib/mill/spawn.rb \
  lib/mill/claude.rb lib/mill/run.rb lib/mill.rb test/mill/test_spawn.rb test/mill/test_schema.rb
git commit -m "A live run carries the identity of its own process group"
```

---

### Task 2: `Mill::Secrets` — the per-repo environment and the narrow token

A fresh worktree holds tracked files only, so `.env` and `config/master.key` are absent and an
env-dependent suite fails identically on both attempts. That reads as a stage defect and is not
one. `Mill::Rules.env_for` is the hook the design left for this and today carries one variable.

**Files:**
- Create: `lib/mill/secrets.rb`
- Create: `test/mill/test_secrets.rb`
- Modify: `lib/mill/rules.rb:89` — `env_for` gains the repo
- Modify: `lib/mill.rb` — require it
- Modify: `lib/mill/run.rb` — the launcher passes the values to be scrubbed

**Interfaces:**
- Consumes: `Mill.home`, `Mill.utf8`, `Mill::Spawn`'s existing `secrets:` scrubber.
- Produces: `Mill::Secrets.for_repo(owner, name) -> Hash[String, String]`,
  `Mill::Secrets.token -> String | nil`, `Mill::Secrets.values_for(stage, owner:, name:) -> Array[String]`,
  and `Mill::Rules.env_for(stage, owner: nil, name: nil) -> Hash[String, String]`. Task 4 checks the
  named variables are present; Task 7 passes owner and name from the run's repo.

- [ ] **Step 1: Write the failing test**

Create `test/mill/test_secrets.rb`:

```ruby
require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# No network, no real ~/.mill: MILL_HOME points at a tmpdir for the whole test.
	class TestSecrets < Minitest::Test
		def setup
			@home = Dir.mktmpdir('mill-secrets')
			FileUtils.mkdir_p(File.join(@home, 'secrets'))
			Mill.instance_variable_set(:@home, @home)
		end

		def teardown
			FileUtils.remove_entry(@home, true)
			Mill.instance_variable_set(:@home, nil)
		end

		def write_secret(name, body, mode: 0o600)
			path = File.join(@home, 'secrets', name)
			File.write(path, body)
			FileUtils.chmod(mode, path)
			path
		end

		def test_a_repo_with_no_secrets_file_gets_an_empty_environment
			assert_empty Mill::Secrets.for_repo('slowernet', 'mill-scratch')
		end

		def test_reads_plain_key_value_lines
			write_secret('slowernet-rep.env', "DATABASE_URL=postgres://x\nAPI_KEY=abc123\n")

			env = Mill::Secrets.for_repo('slowernet', 'rep')

			assert_equal 'postgres://x', env['DATABASE_URL']
			assert_equal 'abc123', env['API_KEY']
		end

		# A value with a '=' in it is ordinary in a connection string, and splitting
		# on every '=' would truncate it silently.
		def test_a_value_may_contain_the_separator
			write_secret('slowernet-rep.env', "TOKEN=a=b=c\n")

			assert_equal 'a=b=c', Mill::Secrets.for_repo('slowernet', 'rep')['TOKEN']
		end

		def test_ignores_comments_and_blank_lines
			write_secret('slowernet-rep.env', "# a note\n\nA=1\n   \n")

			assert_equal({ 'A' => '1' }, Mill::Secrets.for_repo('slowernet', 'rep'))
		end

		def test_strips_matching_quotes_only
			write_secret('slowernet-rep.env', %(A="one two"\nB='three'\nC="mismatched'\n))

			env = Mill::Secrets.for_repo('slowernet', 'rep')

			assert_equal 'one two', env['A']
			assert_equal 'three', env['B']
			assert_equal %("mismatched'), env['C']
		end

		# The runbook tells you to chmod this file. A mode drift is otherwise silent,
		# and these values reach a subprocess environment.
		def test_refuses_a_world_readable_secrets_file
			write_secret('slowernet-rep.env', "A=1\n", mode: 0o644)

			error = assert_raises(Mill::Error) { Mill::Secrets.for_repo('slowernet', 'rep') }

			assert_match(/expected 600/, error.message)
		end

		# Only the stages that push carry the token. Handing it to `implement` would
		# put a credential inside the widest ruleset mill has.
		def test_only_the_pushing_stages_carry_the_token
			write_secret('stage-token', "ghp_example\n")

			assert_equal 'ghp_example', Mill::Rules.env_for('pr')['GH_TOKEN']
			assert_nil Mill::Rules.env_for('implement')['GH_TOKEN']
		end

		def test_the_repo_environment_reaches_a_stage
			write_secret('slowernet-rep.env', "API_KEY=abc123\n")

			env = Mill::Rules.env_for('implement', owner: 'slowernet', name: 'rep')

			assert_equal 'abc123', env['API_KEY']
		end

		# What the scrubber is given. A path is not a secret, so SSL_CERT_FILE must
		# not be scrubbed out of every log line that happens to contain it.
		def test_only_real_secrets_are_offered_to_the_scrubber
			write_secret('slowernet-rep.env', "API_KEY=abcdefghijklmnopqrst\n")
			write_secret('stage-token', "ghp_exampleexampleexample\n")

			values = Mill::Secrets.values_for('pr', owner: 'slowernet', name: 'rep')

			assert_includes values, 'abcdefghijklmnopqrst'
			assert_includes values, 'ghp_exampleexampleexample'
			refute(values.any? { |v| v.include?('cert') })
		end

		# The scrubber does a literal gsub on every line of a stream-json log that
		# mill parses back. A short value redacts far more than itself.
		def test_a_short_value_is_never_offered_to_the_scrubber
			write_secret('slowernet-rep.env', "RAILS_ENV=test\nDEBUG=true\nAPI_KEY=abcdefghijklmnopqrst\n")

			values = Mill::Secrets.values_for('implement', owner: 'slowernet', name: 'rep')

			assert_equal ['abcdefghijklmnopqrst'], values
		end

		# It still reaches the stage. Not redacting it is a decision about the log,
		# not about the environment.
		def test_a_short_value_still_reaches_the_stage
			write_secret('slowernet-rep.env', "RAILS_ENV=test\n")

			assert_equal 'test', Mill::Rules.env_for('implement', owner: 'slowernet', name: 'rep')['RAILS_ENV']
		end
	end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_secrets.rb`
Expected: FAIL — `uninitialized constant Mill::Secrets`.

- [ ] **Step 3: Write `Mill::Secrets`**

Create `lib/mill/secrets.rb`:

```ruby
module Mill
	# What a stage runs with beyond its own argv. A fresh worktree holds tracked
	# files only, so a repo whose suite needs an .env would fail identically on
	# both attempts — which looks like the stage failing and is not.
	#
	# Values from here reach a subprocess environment and must never reach the log,
	# so every caller hands them to Spawn's scrubber as well.
	module Secrets
		MODE = 0o600

		# Pushing is the only thing a stage does that needs a credential of its own.
		PUSHING = %w[pr push].freeze

		def self.dir = File.join(Mill.home, 'secrets')

		def self.path_for(owner, name) = File.join(dir, "#{owner}-#{name}.env")

		def self.for_repo(owner, name)
			return {} if owner.nil? || name.nil?

			read_env(path_for(owner, name))
		end

		# The narrow token the pushing stages carry. Setting GH_TOKEN is enough:
		# the credential helper the runbook configures asks gh for a credential, and
		# gh honours GH_TOKEN over its stored login. So one variable re-points both
		# `gh` and `git push` at the scoped token without touching the worktree.
		def self.token
			path = File.join(dir, 'stage-token')
			return nil unless File.exist?(path)

			check_mode!(path)
			value = Mill.utf8(File.read(path)).strip
			value.empty? ? nil : value
		end

		# A value shorter than this is not redacted, because redacting it does more
		# damage than leaking it. The scrubber does a literal gsub on every log
		# line, and the log is stream-json that mill's own parser reads back: an
		# env file carrying RAILS_ENV=test turns every "test" in the transcript
		# into [redacted], and DEBUG=true turns `"success":true` into
		# `"success":[redacted]`, which stops being JSON. The stage then reads as
		# having produced no verdict and is charged a strike for mill's own
		# scrubber. No real credential is this short.
		SHORTEST_REDACTABLE = 16

		# Exactly the strings that must never appear in a log, and no others.
		def self.values_for(stage, owner: nil, name: nil)
			values = for_repo(owner, name).values
			values += [token].compact if PUSHING.include?(stage)
			values.reject { |v| v.to_s.length < SHORTEST_REDACTABLE }
		end

		def self.read_env(path)
			return {} unless File.exist?(path)

			check_mode!(path)
			parse(File.read(path))
		end

		def self.parse(text)
			Mill.utf8(text).lines.filter_map do |line|
				line = line.strip
				next if line.empty? || line.start_with?('#')

				key, value = line.split('=', 2)
				next if value.nil?

				key = key.strip
				key.empty? ? nil : [key, unquote(value.strip)]
			end.to_h
		end

		# Matching quotes only. A value that opens with one quote and closes with
		# another is not quoted, it is a value containing quotes.
		def self.unquote(value)
			return value if value.length < 2

			%w[" '].each do |q|
				return value[1..-2] if value.start_with?(q) && value.end_with?(q)
			end
			value
		end

		def self.check_mode!(path)
			mode = File.stat(path).mode & 0o777
			return if mode == MODE

			raise Mill::Error, "#{path} is mode #{format('%o', mode)}, expected 600"
		end
	end
end
```

- [ ] **Step 4: Widen `Mill::Rules.env_for`**

Replace `lib/mill/rules.rb:89-92` with:

```ruby
		def self.env_for(stage, owner: nil, name: nil)
			env = {}
			bundle = ca_bundle
			env['SSL_CERT_FILE'] = bundle if bundle
			env.merge!(Mill::Secrets.for_repo(owner, name))
			gh_token = Mill::Secrets.token if Mill::Secrets::PUSHING.include?(stage)
			env['GH_TOKEN'] = gh_token if gh_token
			env
		end
```

Add `require_relative 'mill/secrets'` to `lib/mill.rb`, before `require_relative 'mill/rules'`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_secrets.rb`
Expected: PASS, 9 runs.

- [ ] **Step 6: Wire the launcher**

In `lib/mill/run.rb`, `#default_launcher` — the stage now gets the repo's environment, and the
scrubber gets exactly the values that must not be logged:

```ruby
				env = Mill::Rules.env_for(stage, owner: @owner, name: @name)
				attempt = @claude.new(stage).run(prompt, number: number, worktree: @worktree,
					log_path: log, session_id: session_id, env: env,
					secrets: Mill::Secrets.values_for(stage, owner: @owner, name: @name),
					on_spawn: method(:record_identity))
```

- [ ] **Step 7: Run the whole suite**

Run: `bundle exec rake test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/mill/secrets.rb test/mill/test_secrets.rb lib/mill/rules.rb lib/mill.rb lib/mill/run.rb
git commit -m "Inject a repo's secrets, and give only the pushing stages a token"
```

---

### Task 3: `Mill::Git.clone` and resolving a working copy

On a laptop mill uses a clone you already keep. On a server there are none, so it makes its own.
Several matches is the case that must not resolve silently: picking one means committing to a
checkout the operator did not choose.

**Files:**
- Create: `lib/mill/repo.rb`
- Create: `test/mill/test_repo.rb`
- Modify: `lib/mill/git.rb` — add `.clone`
- Modify: `lib/mill.rb` — require it

**Interfaces:**
- Consumes: `Mill::Git.run`, `Mill::Git.run!`, `Mill::Clock::DARWIN`.
- Produces: `Mill::Git.clone(url, path) -> String`, `Mill::Repo::Result` (a Struct with `path`,
  `problem`, `questions` and `ok?`), `Mill::Repo.roots -> Array[String]`,
  `Mill::Repo.resolve(owner, name, git: Mill::Git) -> Result`. Task 4 calls `resolve`; Task 6 reads
  `Result#path`.

- [ ] **Step 1: Write the failing test**

Create `test/mill/test_repo.rb`:

```ruby
require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Real git in a tmpdir, no network: the "remote" is a bare repository on disk.
	class TestRepo < Minitest::Test
		def setup
			@root = Dir.mktmpdir('mill-repo')
			@home = File.join(@root, 'home')
			@clones = File.join(@root, 'code')
			FileUtils.mkdir_p([@home, @clones])
			Mill.instance_variable_set(:@home, @home)
			ENV['MILL_CLONES'] = @clones
			@origin = build_origin
		end

		def teardown
			FileUtils.remove_entry(@root, true)
			Mill.instance_variable_set(:@home, nil)
			ENV.delete('MILL_CLONES')
		end

		# A bare repo standing in for github.com/slowernet/rep.
		def build_origin
			path = File.join(@root, 'origin.git')
			seed = File.join(@root, 'seed')
			Mill::Git.clone_init(seed)
			File.write(File.join(seed, 'README.md'), "# seed\n")
			Mill::Git.run!(seed, 'add', '-A')
			Mill::Git.run!(seed, 'commit', '-m', 'first')
			Mill::Git.run!(seed, 'clone', '--bare', seed, path)
			path
		end

		def place_clone(dir_name, origin_url)
			path = File.join(@clones, dir_name)
			Mill::Git.clone(origin_url, path)
			path
		end

		def test_one_matching_clone_is_used_as_it_stands
			expected = place_clone('rep', @origin)

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal expected, result.path
		end

		# Choosing between two silently means working in a checkout you did not pick.
		def test_two_matching_clones_block_rather_than_choosing
			place_clone('rep', @origin)
			place_clone('rep-again', @origin)

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			refute_predicate result, :ok?
			assert_equal :ambiguous_clone, result.problem
			assert_match(/more than one/, result.questions.first)
			assert_match(/rep-again/, result.questions.first)
		end

		# The server case: nothing on disk, so mill makes its own.
		def test_no_match_clones_into_mills_own_directory
			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal File.join(@home, 'clones', 'slowernet-rep'), result.path
			assert_path_exists File.join(result.path, '.git')
		end

		def test_a_directory_that_is_not_a_repository_is_ignored
			FileUtils.mkdir_p(File.join(@clones, 'rep'))

			result = Mill::Repo.resolve('slowernet', 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal File.join(@home, 'clones', 'slowernet-rep'), result.path
		end

		# The same repository is written four ways depending on how it was cloned.
		def test_every_origin_form_names_the_same_repository
			%w[
				git@github.com:slowernet/rep.git
				https://github.com/slowernet/rep.git
				https://github.com/slowernet/rep
				ssh://git@github.com/slowernet/rep.git
			].each do |url|
				assert_equal 'slowernet/rep', Mill::Repo.slug(url), url
			end
		end

		def test_roots_default_by_platform
			ENV.delete('MILL_CLONES')

			roots = Mill::Repo.roots

			Mill::Clock::DARWIN ? assert_equal([File.expand_path('~/code')], roots) : assert_empty(roots)
		end

		def test_roots_accept_several_directories
			ENV['MILL_CLONES'] = "#{@clones}:#{@root}"

			assert_equal [@clones, @root], Mill::Repo.roots
		end
	end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_repo.rb`
Expected: FAIL — `uninitialized constant Mill::Repo`.

- [ ] **Step 3: Add the two git commands**

`git clone` and `git init` take no `-C` because there is no repository yet, so they cannot go
through `Mill::Git.run`. Add to `lib/mill/git.rb`:

```ruby
		# Cloning has no repository to run inside, so it cannot go through `run`.
		# It stays here anyway: this module is the only place mill runs git.
		def self.clone(url, path)
			FileUtils.mkdir_p(File.dirname(path))
			out, err, status = Open3.capture3('git', 'clone', url.to_s, path.to_s)
			raise Error, "git clone failed: #{Mill.utf8(err).strip[0, 300]}" unless status.success?

			Mill.utf8(out)
			path
		end

		# Only tests need this; it is here so that they, too, run no git of their own.
		def self.clone_init(path)
			FileUtils.mkdir_p(path)
			run!(path, 'init', '--initial-branch=main')
			run!(path, 'config', 'user.email', 'test@example.com')
			run!(path, 'config', 'user.name', 'Test')
			path
		end

		def self.origin(repo_path)
			result = run(repo_path, 'remote', 'get-url', 'origin')
			result.ok? ? result.out.strip : nil
		end
```

- [ ] **Step 4: Write `Mill::Repo` resolution**

Create `lib/mill/repo.rb`:

```ruby
require 'fileutils'

module Mill
	# Finding, or making, the working copy a run happens in.
	#
	# On a laptop mill uses a clone you already keep, because working against the
	# same checkout you use is the point of running it there. A server keeps none,
	# so mill clones into its own directory. Those are the same code path with a
	# different answer to "did anything match".
	module Repo
		Result = Struct.new(:path, :problem, :questions, keyword_init: true) do
			def ok? = problem.nil?
		end

		def self.roots
			raw = ENV['MILL_CLONES'].to_s
			return raw.split(':').reject(&:empty?).map { |p| File.expand_path(p) } unless raw.empty?

			Mill::Clock::DARWIN ? [File.expand_path('~/code')] : []
		end

		def self.clone_dir = File.join(Mill.home, 'clones')

		def self.default_url(owner, name) = "https://github.com/#{owner}/#{name}.git"

		# owner/name, lowercased, whatever form the remote was written in.
		def self.slug(url)
			url.to_s.strip.sub(/\.git\z/, '')[%r{[:/]([^/:]+/[^/:]+)\z}, 1]&.downcase
		end

		def self.resolve(owner, name, git: Mill::Git, url: nil)
			wanted = "#{owner}/#{name}".downcase
			matches = candidates(wanted, git)

			return Result.new(path: matches.first) if matches.length == 1
			return ambiguous(owner, name, matches) if matches.length > 1

			path = File.join(clone_dir, "#{owner}-#{name}")
			return Result.new(path: path) if Dir.exist?(File.join(path, '.git'))

			Result.new(path: git.clone(url || default_url(owner, name), path))
		rescue Mill::Git::Error => e
			Result.new(problem: :clone_failed, questions: ["mill could not clone #{owner}/#{name}: #{e.message}"])
		end

		def self.candidates(wanted, git)
			roots.flat_map { |root| Dir.glob(File.join(root, '*')) }
				.select { |path| Dir.exist?(File.join(path, '.git')) }
				.select { |path| slug(git.origin(path)) == wanted }
				.sort
		end

		def self.ambiguous(owner, name, matches)
			Result.new(problem: :ambiguous_clone, questions: [
				"#{owner}/#{name} matches more than one working copy: #{matches.join(', ')}. " \
				'mill will not choose between them. Move or remove all but one, then reply here.'
			])
		end
	end
end
```

Add `require_relative 'mill/repo'` to `lib/mill.rb`, after `require_relative 'mill/git'`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_repo.rb`
Expected: PASS, 7 runs.

- [ ] **Step 6: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/repo.rb lib/mill/git.rb test/mill/test_repo.rb lib/mill.rb
git commit -m "Find a working copy, or make one"
```

---

### Task 4: `Mill::Repo.prepare` — first touch

Preparation is lazy and per-item: the first time an item from a repo reaches the board, mill
resolves the clone, sets the two git config values that stop a stage's commit triggering a gc while
other runs hold refs, reads `.mill.yml` from the **base branch** — never the worktree HEAD, because
an agent can edit it and that edit must not weaken the next run — and checks the named secrets
exist. Anything missing blocks that one item and says exactly what.

**Files:**
- Modify: `lib/mill/repo.rb` — add `prepare`
- Modify: `test/mill/test_repo.rb`

**Interfaces:**
- Consumes: `Mill::Repo.resolve`, `Mill::Secrets.for_repo`, `Mill::Git.run!`.
- Produces: `Mill::Repo.prepare(db:, owner:, name:, git: Mill::Git) -> Result`, where `Result#path`
  is the clone and the `repos` row is upserted with `local_path`, `base_branch`, `config_json` and
  `prepared_at`. `Mill::Repo.config(db, repo_id) -> Hash` with symbol keys. Task 6 requires a
  prepared repo before claiming; Task 9 blocks the item when preparation fails.

- [ ] **Step 1: Write the failing tests**

Add to `test/mill/test_repo.rb`. Note this class needs a database, so change its superclass to
`Mill::TestCase` and keep the existing `setup` body, calling `super` first:

```ruby
		def test_preparation_sets_the_config_that_stops_a_stage_triggering_gc
			place_clone('rep', @origin)

			result = Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal '0', Mill::Git.run!(result.path, 'config', 'gc.auto').strip
			assert_equal '0', Mill::Git.run!(result.path, 'config', 'maintenance.auto').strip
		end

		def test_preparation_caches_the_repo_row
			place_clone('rep', @origin)

			Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)
			row = db[:repos].where(owner: 'slowernet', name: 'rep').first

			refute_nil row[:prepared_at]
			assert_equal 'main', row[:base_branch]
		end

		# .mill.yml is read from the base branch, never from a worktree: an agent can
		# edit it in its own checkout and that edit must not weaken the next run.
		def test_reads_the_config_from_the_base_branch_only
			clone = place_clone('rep', @origin)
			commit_to_base(clone, '.mill.yml', "test_command: bundle exec rake test\nsecrets:\n  - API_KEY\n")
			Mill::Git.run!(clone, 'switch', '-c', 'feature')
			File.write(File.join(clone, '.mill.yml'), "secrets: []\n")

			write_secret_file('slowernet-rep.env', "API_KEY=x\n")
			Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

			config = Mill::Repo.config(db, db[:repos].where(name: 'rep').get(:id))

			assert_equal 'bundle exec rake test', config[:test_command]
			assert_equal ['API_KEY'], config[:secrets]
		end

		def test_a_repo_with_no_config_file_prepares_anyway
			place_clone('rep', @origin)

			result = Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

			assert_predicate result, :ok?
			assert_equal({}, Mill::Repo.config(db, db[:repos].where(name: 'rep').get(:id)))
		end

		# A missing secret fails the suite on both attempts, which reads as the stage
		# being wrong. Say so before the run starts instead.
		def test_a_named_secret_that_is_absent_blocks_the_item
			clone = place_clone('rep', @origin)
			commit_to_base(clone, '.mill.yml', "secrets:\n  - API_KEY\n  - DATABASE_URL\n")

			result = Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

			refute_predicate result, :ok?
			assert_equal :missing_secrets, result.problem
			assert_match(/API_KEY/, result.questions.first)
			assert_match(/DATABASE_URL/, result.questions.first)
		end

		def test_a_prepared_repo_is_not_prepared_twice
			place_clone('rep', @origin)
			Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)
			first = db[:repos].where(name: 'rep').get(:prepared_at)

			db[:repos].where(name: 'rep').update(local_path: '/gone')
			result = Mill::Repo.prepare(db: db, owner: 'slowernet', name: 'rep', url: @origin)

			assert_equal '/gone', result.path
			assert_equal first, db[:repos].where(name: 'rep').get(:prepared_at)
		end
```

Add these helpers to the test class:

```ruby
		def commit_to_base(clone, path, body)
			File.write(File.join(clone, path), body)
			Mill::Git.run!(clone, 'add', '-A')
			Mill::Git.run!(clone, 'commit', '-m', "add #{path}")
			Mill::Git.run!(clone, 'push', 'origin', 'main')
			Mill::Git.run!(clone, 'fetch', 'origin', 'main')
		end

		def write_secret_file(name, body)
			FileUtils.mkdir_p(File.join(@home, 'secrets'))
			path = File.join(@home, 'secrets', name)
			File.write(path, body)
			FileUtils.chmod(0o600, path)
		end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_repo.rb -n /prepar/`
Expected: FAIL — `undefined method 'prepare'`.

- [ ] **Step 3: Write `prepare`**

Add to `lib/mill/repo.rb`, and `require 'json'` and `require 'yaml'` at the top:

```ruby
		# Lazy and per-item: the first time an item from a repo reaches the board.
		# Everything here is a read or a local git config write — mill writes nothing
		# to the repository itself, which is what lets it use no labels.
		def self.prepare(db:, owner:, name:, git: Mill::Git, url: nil)
			row = db[:repos].where(owner: owner, name: name).first
			return Result.new(path: row[:local_path]) if row && row[:prepared_at]

			resolved = resolve(owner, name, git: git, url: url)
			return resolved unless resolved.ok?

			path = resolved.path
			git.run!(path, 'config', 'gc.auto', '0')
			git.run!(path, 'config', 'maintenance.auto', '0')

			base = base_branch(path, git)
			config = read_config(path, base, git)
			missing = missing_secrets(owner, name, config)
			return missing unless missing.nil?

			upsert(db, owner, name, path, base, config)
			Result.new(path: path)
		rescue Mill::Git::Error => e
			Result.new(problem: :unprepared, questions: ["mill could not prepare #{owner}/#{name}: #{e.message}"])
		end

		def self.config(db, repo_id)
			raw = db[:repos].where(id: repo_id).get(:config_json)
			raw ? JSON.parse(raw, symbolize_names: true) : {}
		end

		def self.base_branch(path, git)
			result = git.run(path, 'symbolic-ref', 'refs/remotes/origin/HEAD')
			ref = result.ok? ? result.out.strip.split('/').last : nil
			ref.nil? || ref.empty? ? 'main' : ref
		end

		# From the base branch, never from a checkout. `git show` reads the committed
		# blob, so nothing has to be checked out and no worktree can influence it.
		def self.read_config(path, base, git)
			git.run(path, 'fetch', 'origin', base)
			%W[origin/#{base} #{base}].each do |ref|
				result = git.run(path, 'show', "#{ref}:.mill.yml")
				next unless result.ok?

				parsed = YAML.safe_load(result.out, symbolize_names: true)
				return parsed.is_a?(Hash) ? parsed : {}
			end
			{}
		rescue Psych::SyntaxError => e
			raise Mill::Git::Error, ".mill.yml on #{base} does not parse: #{e.message}"
		end

		def self.missing_secrets(owner, name, config)
			named = Array(config[:secrets]).map(&:to_s)
			return nil if named.empty?

			present = Mill::Secrets.for_repo(owner, name).keys
			absent = named - present
			return nil if absent.empty?

			Result.new(problem: :missing_secrets, questions: [
				"#{Mill::Secrets.path_for(owner, name)} is missing #{absent.join(', ')}, which " \
				"#{owner}/#{name}'s .mill.yml names. Add them and reply here."
			])
		end

		def self.upsert(db, owner, name, path, base, config)
			db[:repos].insert_conflict(target: %i[owner name]).insert(
				owner: owner, name: name, local_path: path, base_branch: base,
				config_json: config.to_json, prepared_at: Mill.now, created_at: Mill.now
			)
			db[:repos].where(owner: owner, name: name).update(
				local_path: path, base_branch: base, config_json: config.to_json, prepared_at: Mill.now
			)
		end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_repo.rb`
Expected: PASS, 13 runs.

- [ ] **Step 5: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/repo.rb test/mill/test_repo.rb
git commit -m "Prepare a repo on first touch, and block the item when something is missing"
```

---

### Task 5: Board writes — `Mill::Github` and `Mill::Board`

mill has never written a Status. Every write is a network call that can fail, and nothing else
re-drives it: the poller only ever asks which items are `Ready`. So a run that blocks while the
network is down would show `Running` forever — and because a comment's meaning depends on Status,
your answer to its questions would never be recognised as an answer.

**Files:**
- Create: `lib/mill/board.rb`
- Create: `test/mill/test_board.rb`
- Create: `test/fixtures/gh/project_fields.json`
- Create: `test/fixtures/gh/project_view.json`
- Modify: `lib/mill/github.rb` — three reads and one write
- Modify: `lib/mill.rb`

**Interfaces:**
- Consumes: `Mill::Github#board_items`, `runs.board_item_id` from Task 1.
- Produces: `Mill::Github#project_id(project, owner:) -> String`,
  `#project_fields(project, owner:) -> Array[Hash]`,
  `#set_status(project_id:, item_id:, field_id:, option_id:)`;
  `Mill::Board.new(db:, github:, project:, owner:)` with `#want(run_id, status)`,
  `#redrive`, `#items` and `#interference?(item, run_row)`. Tasks 7, 9 and 11 call `want`; Task 12
  calls `redrive` on every tick.

- [ ] **Step 1: Write the fixtures**

Create `test/fixtures/gh/project_fields.json`:

```json
{"fields":[
 {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField",
  "options":[{"id":"opt_ready","name":"Ready"},{"id":"opt_running","name":"Running"},
             {"id":"opt_blocked","name":"Blocked"},{"id":"opt_done","name":"Done"},
             {"id":"opt_failed","name":"Failed"}]},
 {"id":"PVTSSF_evidence","name":"Evidence","type":"ProjectV2SingleSelectField",
  "options":[{"id":"opt_required","name":"Required"}]},
 {"id":"PVTSSF_review","name":"Review","type":"ProjectV2SingleSelectField",
  "options":[{"id":"opt_deep","name":"Deep"}]}]}
```

Create `test/fixtures/gh/project_view.json`:

```json
{"id":"PVT_board","number":3,"title":"mill","owner":{"login":"slowernet"}}
```

- [ ] **Step 2: Write the failing test**

Create `test/mill/test_board.rb`:

```ruby
require 'test_helper'

module Mill
	# Fixture-backed. Nothing here reaches the network.
	class TestBoard < Mill::TestCase
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'gh')

		def fixture(name) = File.read(File.join(FIXTURES, "#{name}.json"))

		# Answers each gh call from a fixture chosen by its subcommand, and records
		# every call so the writes can be asserted.
		def board(failing: false)
			calls = []
			github = Mill::Github.new(runner: lambda { |args|
				calls << args
				raise Mill::Github::Error, 'network is down' if failing && args[1] == 'item-edit'

				case args[1]
				when 'view' then fixture('project_view')
				when 'field-list' then fixture('project_fields')
				when 'item-list' then fixture('board_items')
				else ''
				end
			})
			[Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet'), calls]
		end

		def a_run(status: 'running', item: 'PVTI_1')
			repo_id = create_repo
			create_run(repo_id: repo_id, status: status, board_item_id: item)
		end

		def test_writing_a_status_names_the_option_by_id
			run_id = a_run
			b, calls = board

			assert b.want(run_id, 'running')
			edit = calls.find { |args| args[1] == 'item-edit' }

			assert_includes edit, 'PVTI_1'
			assert_includes edit, 'PVTSSF_status'
			assert_includes edit, 'opt_running'
			assert_includes edit, 'PVT_board'
		end

		def test_a_killed_run_reads_as_failed_on_the_board
			run_id = a_run(status: 'killed')
			b, calls = board
			b.want(run_id, 'killed')

			assert_includes calls.find { |args| args[1] == 'item-edit' }, 'opt_failed'
		end

		# The whole mechanism: an unconfirmed write is what redrive looks for.
		def test_a_failed_write_leaves_the_run_unconfirmed
			run_id = a_run
			b, = board(failing: true)

			refute b.want(run_id, 'blocked')
			row = db[:runs].where(id: run_id).first

			assert_equal 'Blocked', row[:desired_board_status]
			assert_nil row[:board_status_at]
		end

		def test_redrive_retries_only_what_was_never_confirmed
			confirmed = a_run(item: 'PVTI_1')
			unconfirmed = a_run(item: 'PVTI_2')
			b, = board(failing: true)
			b.want(confirmed, 'running')
			b.want(unconfirmed, 'blocked')

			ok, = board
			ok.redrive

			refute_nil db[:runs].where(id: confirmed).get(:board_status_at)
			refute_nil db[:runs].where(id: unconfirmed).get(:board_status_at)
		end

		def test_redrive_leaves_a_run_that_was_never_asked_for_alone
			a_run
			b, calls = board
			b.redrive

			assert_nil calls.find { |args| args[1] == 'item-edit' }
		end

		# A run with no board item is a run started by hand. It must not raise, and
		# it must not silently look confirmed either.
		def test_a_run_with_no_board_item_is_not_confirmed
			run_id = a_run(item: nil)
			b, calls = board

			refute b.want(run_id, 'done')
			assert_nil calls.find { |args| args[1] == 'item-edit' }
			assert_nil db[:runs].where(id: run_id).get(:board_status_at)
		end

		# Board automation writing Status under a live run is what the runbook
		# disables. Catching it later is what catches it being re-enabled.
		def test_a_status_mill_did_not_write_is_interference
			run_id = a_run
			b, = board
			b.want(run_id, 'running')
			row = db[:runs].where(id: run_id).first

			assert b.interference?({ id: 'PVTI_1', status: 'Done' }, row)
			refute b.interference?({ id: 'PVTI_1', status: 'Running' }, row)
		end

		# redrive runs in the poller thread while run threads decide. A label read a
		# moment ago may already be stale, and stamping against a stale one is what
		# would leave a blocked run behind a board saying Running, permanently.
		def test_a_decision_that_changed_underneath_a_write_is_not_marked_confirmed
			run_id = a_run
			b, = board
			db[:runs].where(id: run_id).update(desired_board_status: 'Running', board_status_at: nil)

			# Stand in for the run thread deciding differently mid-write.
			github = Mill::Github.new(runner: lambda { |args|
				db[:runs].where(id: run_id).update(desired_board_status: 'Blocked',
					board_status_at: nil) if args[1] == 'item-edit'
				case args[1]
				when 'view' then fixture('project_view')
				when 'field-list' then fixture('project_fields')
				else ''
				end
			})
			racing = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')

			refute racing.send(:confirm, run_id)
			assert_nil db[:runs].where(id: run_id).get(:board_status_at)
			refute_nil b
		end

		# A board missing an option is a configuration error, not a network blip. It
		# must not be swallowed into an endless retry.
		def test_a_board_missing_a_status_option_raises
			run_id = a_run
			github = Mill::Github.new(runner: lambda { |args|
				case args[1]
				when 'view' then fixture('project_view')
				when 'field-list'
					'{"fields":[{"id":"F","name":"Status","options":[{"id":"1","name":"Ready"}]}]}'
				else ''
				end
			})
			b = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')

			error = assert_raises(Mill::Error) { b.want(run_id, 'running') }

			assert_match(/Blocked/, error.message)
		end

		def test_field_and_option_ids_are_resolved_once
			run_id = a_run
			b, calls = board
			b.want(run_id, 'running')
			b.want(run_id, 'done')

			assert_equal 1, calls.count { |args| args[1] == 'field-list' }
		end
	end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_board.rb`
Expected: FAIL — `uninitialized constant Mill::Board`.

- [ ] **Step 4: Add the gh calls**

In `lib/mill/github.rb`, under the reads:

```ruby
		def project_id(project, owner:)
			json('project', 'view', project.to_s, '--owner', owner, '--format', 'json')[:id]
		end

		def project_fields(project, owner:)
			json('project', 'field-list', project.to_s, '--owner', owner, '--format', 'json')
				.fetch(:fields, [])
		end
```

And under the writes, beneath `#comment`:

```ruby
		# mill is the sole writer of Status. This is the only method that writes one,
		# which is what makes that rule enforceable rather than aspirational.
		def set_status(project_id:, item_id:, field_id:, option_id:)
			run('project', 'item-edit', '--id', item_id, '--project-id', project_id,
				'--field-id', field_id, '--single-select-option-id', option_id)
		end
```

- [ ] **Step 5: Write `Mill::Board`**

Create `lib/mill/board.rb`:

```ruby
module Mill
	# The writing side of the board, and the only thing that decides what Status an
	# item should carry.
	#
	# Every write is a network call that can fail, and nothing else re-drives one:
	# the poller only ever asks which items are Ready. So mill records what it
	# decided the board should say and when it last confirmed it, and a write that
	# never landed is retried until it does. Without that, a run that blocks while
	# the network is down shows Running forever — and because a comment's meaning
	# depends on Status, the answer to its questions is never recognised as one.
	class Board
		STATUS = {
			'running' => 'Running',
			'blocked' => 'Blocked',
			'done' => 'Done',
			'failed' => 'Failed',
			'killed' => 'Failed'
		}.freeze

		def initialize(db: Mill.db, github: nil, project: ENV['MILL_PROJECT'],
			owner: ENV['MILL_PROJECT_OWNER'])
			@db = db
			@github = github || Mill::Github.new
			@project = project
			@owner = owner
		end

		def configured? = !@project.to_s.empty? && !@owner.to_s.empty?

		def items = @github.board_items(@project, owner: @owner)

		# Records the decision first, then tries to make it true. The order matters:
		# a crash between the two leaves a decision redrive can act on, where the
		# reverse leaves a board mill believes it already fixed.
		def want(run_id, status)
			label = STATUS.fetch(status.to_s) { raise Mill::Error, "no board status for #{status}" }
			@db[:runs].where(id: run_id).update(desired_board_status: label, board_status_at: nil)
			confirm(run_id)
		end

		def redrive
			return unless configured?

			@db[:runs].exclude(desired_board_status: nil).where(board_status_at: nil)
				.select_map(:id).each { |id| confirm(id) }
		end

		# True when the board says something mill did not put there, under a run mill
		# owns. That is a built-in workflow re-enabled after setup, and obeying it
		# would flip Status out from under a live subprocess.
		def interference?(item, run_row)
			return false if run_row[:desired_board_status].nil? || run_row[:board_status_at].nil?
			return false unless item[:id] == run_row[:board_item_id]

			item[:status].to_s != run_row[:desired_board_status]
		end

		private

		# The label is re-read here rather than passed in, and the stamp is
		# conditional on it not having changed. redrive runs in the poller thread
		# while run threads call `want`, so a label read a moment ago may already be
		# stale — and stamping board_status_at against a stale label is worse than
		# not writing at all, because that stamp is the only thing that would have
		# caused a retry. The run would then sit blocked behind a board saying
		# Running, and your answer would never be read as an answer.
		def confirm(run_id)
			return false unless configured?

			row = @db[:runs].where(id: run_id).first
			return false if row.nil? || row[:board_item_id].nil? || row[:desired_board_status].nil?

			label = row[:desired_board_status]
			option = ids[:options][label] or
				raise Mill::Error, "the project's Status field has no `#{label}` option"

			@github.set_status(project_id: ids[:project], item_id: row[:board_item_id],
				field_id: ids[:field], option_id: option)
			stamped = @db[:runs].where(id: run_id, desired_board_status: label)
				.update(board_status_at: Mill.now)
			stamped.positive?
		rescue Mill::Github::Error
			# Deliberately swallowed and deliberately not recorded as confirmed: the
			# unset board_status_at is the retry, and redrive is what performs it.
			# Only network failures are swallowed. A board that is wrong rather than
			# unreachable is a configuration error and must not retry forever.
			false
		end

		def ids
			@ids ||= begin
				status = @github.project_fields(@project, owner: @owner)
					.find { |f| f[:name] == 'Status' } or
					raise Mill::Error, 'the project has no Status field'
				options = status.fetch(:options, []).to_h { |o| [o[:name], o[:id]] }
				missing = STATUS.values.uniq - options.keys
				raise Mill::Error, "the project's Status field is missing #{missing.join(', ')}" if
					missing.any?

				{ project: @github.project_id(@project, owner: @owner), field: status[:id],
					options: options }
			end
		end
	end
end
```

Add `require_relative 'mill/board'` to `lib/mill.rb`, after `require_relative 'mill/github'`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_board.rb`
Expected: PASS, 8 runs.

- [ ] **Step 7: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/board.rb lib/mill/github.rb test/mill/test_board.rb \
  test/fixtures/gh/project_fields.json test/fixtures/gh/project_view.json lib/mill.rb
git commit -m "Write Status, and retry the write that never landed"
```

---

### Task 6: `Mill::Supervisor` — claiming an item

Four things stand between an item and a worktree, and each has a different answer. The cap means
try later. A branch another live run holds means skip and say so once, because a blocked run holds
its branch indefinitely and an item queued behind one can wait forever. A branch checked out in
your own clone means block and name it — mill does not switch your clone and does not force the
worktree, because two live checkouts of one branch can silently diverge the ref. A stale lock or a
stale worktree admin entry means clear it and carry on.

**Files:**
- Create: `lib/mill/supervisor.rb`
- Create: `test/mill/test_supervisor.rb`
- Modify: `lib/mill.rb`

**Interfaces:**
- Consumes: `Mill::Repo::Result`, `Mill::Git.checked_out_branches`, `Mill::Git.worktree_add`,
  `Mill::Board#want`.
- Produces: `Mill::Supervisor.new(db:, github:, git:, board:)` with `#cap`, `#at_cap?`,
  `#claim(repo_row:, subject_kind:, subject_number:, route:, branch:, spec_path:, board_item_id:) -> Integer | :held | Blocked`
  and `Mill::Supervisor::Blocked = Struct.new(:problem, :questions)`. Task 9 calls `claim`.

- [ ] **Step 1: Write the failing test**

Create `test/mill/test_supervisor.rb`:

```ruby
require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# Real git in a tmpdir; no network, no claude.
	class TestSupervisor < Mill::TestCase
		def setup
			super
			@root = Dir.mktmpdir('mill-supervisor')
			@home = File.join(@root, 'home')
			FileUtils.mkdir_p(@home)
			Mill.instance_variable_set(:@home, @home)
			@clone = File.join(@root, 'rep')
			Mill::Git.clone_init(@clone)
			File.write(File.join(@clone, 'README.md'), "# rep\n")
			Mill::Git.run!(@clone, 'add', '-A')
			Mill::Git.run!(@clone, 'commit', '-m', 'first')
			Mill::Git.run!(@clone, 'branch', '1-a-feature')
			@repo_id = create_repo(owner: 'slowernet', name: 'rep', local_path: @clone,
				base_branch: 'main', prepared_at: Mill.now)
		end

		def teardown
			FileUtils.remove_entry(@root, true)
			Mill.instance_variable_set(:@home, nil)
			ENV.delete('MILL_CONCURRENCY')
			super
		end

		def repo_row = db[:repos].where(id: @repo_id).first

		def supervisor(comments: [])
			github = Mill::Github.new(runner: ->(args) { comments << args; '' })
			Mill::Supervisor.new(db: db, github: github, board: nil)
		end

		def claim(sup, branch: '1-a-feature', number: 1)
			sup.claim(repo_row: repo_row, subject_kind: 'issue', subject_number: number,
				route: 'plan', branch: branch, spec_path: 'docs/spec.md', board_item_id: 'PVTI_1')
		end

		def test_claiming_inserts_a_running_run_and_a_worktree
			run_id = claim(supervisor)
			row = db[:runs].where(id: run_id).first

			assert_equal 'running', row[:status]
			assert_equal '1-a-feature', row[:branch]
			assert_equal 'PVTI_1', row[:board_item_id]
			assert_path_exists File.join(row[:worktree_path], 'README.md')
		end

		def test_the_cap_counts_running_rows_only
			ENV['MILL_CONCURRENCY'] = '1'
			sup = supervisor
			claim(sup)

			assert_predicate sup, :at_cap?

			db[:runs].update(status: 'blocked')

			refute_predicate sup, :at_cap?
		end

		# A blocked run holds its branch by design, so the item behind it waits.
		def test_a_branch_another_live_run_holds_is_skipped
			sup = supervisor
			claim(sup)

			assert_equal :held, claim(sup, number: 2)
		end

		# Silence here means mill appears to ignore you forever.
		def test_the_skip_is_announced_once
			calls = []
			sup = supervisor(comments: calls)
			claim(sup)
			claim(sup, number: 2)
			claim(sup, number: 2)

			comments = calls.select { |args| args.first(2) == %w[issue comment] }

			assert_equal 1, comments.length
			assert_match(/1-a-feature/, comments.first.join(' '))
		end

		# git worktree add refuses a branch checked out anywhere, including the
		# clone's own HEAD, and the prescribed workflow leaves it that way.
		def test_a_branch_checked_out_in_your_clone_blocks_the_item
			Mill::Git.run!(@clone, 'switch', '1-a-feature')

			result = claim(supervisor)

			assert_kind_of Mill::Supervisor::Blocked, result
			assert_equal :branch_checked_out, result.problem
			assert_match(/#{Regexp.escape(@clone)}/, result.questions.first)
			assert_match(/1-a-feature/, result.questions.first)
		end

		def test_mill_never_forces_a_worktree_onto_a_checked_out_branch
			Mill::Git.run!(@clone, 'switch', '1-a-feature')
			claim(supervisor)

			assert_equal 0, db[:runs].count
		end

		# A SIGKILL during git commit leaves a lock git never cleans, and the next
		# launch fails instantly on it.
		def test_a_stale_lock_is_cleared_before_claiming
			lock = File.join(@clone, '.git', 'index.lock')
			File.write(lock, '')
			FileUtils.touch(lock, mtime: Time.now - 3600)

			claim(supervisor)

			refute_path_exists lock
		end

		# A lock that is minutes old may belong to a command running right now.
		def test_a_fresh_lock_is_left_alone
			lock = File.join(@clone, '.git', 'index.lock')
			File.write(lock, '')

			claim(supervisor)

			assert_path_exists lock
		end

		# A row inserted before a worktree that never appears is a running run with
		# no process, which nothing reaps and which holds a slot forever.
		def test_a_worktree_that_cannot_be_made_leaves_no_run_behind
			failing = Class.new do
				def self.method_missing(name, *args, &blk) = Mill::Git.send(name, *args, &blk)
				def self.respond_to_missing?(*) = true
				def self.worktree_add(*) = raise(Mill::Git::Error, 'no space left on device')
			end
			sup = Mill::Supervisor.new(db: db, github: Mill::Github.new(runner: ->(_) { '' }),
				git: failing, board: nil)

			assert_raises(Mill::Git::Error) do
				sup.claim(repo_row: repo_row, subject_kind: 'issue', subject_number: 1,
					route: 'plan', branch: '1-a-feature', spec_path: 'docs/spec.md',
					board_item_id: 'PVTI_1')
			end
			assert_equal 0, db[:runs].count
		end

		# Not knowing whether a branch is checked out is not the same as it not
		# being checked out, and claiming on that guess is how two live checkouts of
		# one branch happen.
		def test_a_git_failure_is_never_read_as_a_free_branch
			failing = Class.new do
				def self.method_missing(name, *args, &blk) = Mill::Git.send(name, *args, &blk)
				def self.respond_to_missing?(*) = true
				def self.checked_out_branches(*) = raise(Mill::Git::Error, 'not a git repository')
			end
			sup = Mill::Supervisor.new(db: db, github: Mill::Github.new(runner: ->(_) { '' }),
				git: failing, board: nil)

			assert_raises(Mill::Git::Error) do
				sup.claim(repo_row: repo_row, subject_kind: 'issue', subject_number: 1,
					route: 'plan', branch: '1-a-feature', spec_path: 'docs/spec.md',
					board_item_id: 'PVTI_1')
			end
			assert_equal 0, db[:runs].count
		end

		# git worktree add refuses a branch whose admin entry survives even after
		# the directory is gone.
		def test_a_stale_worktree_entry_is_pruned
			dead = File.join(@root, 'dead')
			Mill::Git.run!(@clone, 'worktree', 'add', dead, '1-a-feature')
			FileUtils.remove_entry(dead, true)

			assert_operator claim(supervisor), :>, 0
		end
	end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb`
Expected: FAIL — `uninitialized constant Mill::Supervisor`.

- [ ] **Step 3: Write the claiming half of `Mill::Supervisor`**

Create `lib/mill/supervisor.rb`:

```ruby
require 'fileutils'

module Mill
	# Claims work up to the cap, owns the worktree lifecycle, and reaps process
	# groups. Everything here is about the machine rather than the work: what a
	# stage decides is the runner's business, and what an item means is the
	# poller's.
	class Supervisor
		Blocked = Struct.new(:problem, :questions, keyword_init: true)

		DEFAULT_CAP = 2
		# A lock younger than this may belong to a command running right now — one
		# of mill's own stages, or you in a terminal on the same clone.
		STALE_LOCK_AFTER = 300

		def initialize(db: Mill.db, github: nil, git: Mill::Git, board: nil)
			@db = db
			@github = github || Mill::Github.new
			@git = git
			@board = board
			@announced = {}
		end

		# Not `.to_i`: MILL_CONCURRENCY=lots would become 0, at_cap? would be true
		# forever, and mill would claim nothing while every check stayed green.
		def cap = Mill.setting_int('MILL_CONCURRENCY', default: DEFAULT_CAP, min: 1, max: 8)

		# Counts running rows only. A blocked run is not working, and there is no
		# queued status: a run is inserted as running in the transaction that claims.
		def at_cap? = @db[:runs].where(status: 'running').count >= cap

		def claim(repo_row:, subject_kind:, subject_number:, route:, branch:, spec_path:,
			board_item_id: nil)
			holder = live_holder(repo_row[:id], branch)
			return held(repo_row, subject_number, branch, holder) if holder

			clone = repo_row[:local_path]
			@git.run(clone, 'worktree', 'prune')
			clear_stale_locks(clone, branch)

			elsewhere = checked_out(clone, branch)
			return checked_out_block(clone, branch) if elsewhere

			# The row and the worktree go together. A row inserted before a worktree
			# that then fails to appear is a `running` run with no process and no
			# thread — which nothing reaps, because there is nothing to identify, and
			# which counts against the cap for as long as the database survives. Two
			# of those and mill claims nothing ever again, with every check green.
			run_id = nil
			begin
				@db.transaction do
					run_id = insert_run(repo_row, subject_kind, subject_number, route, branch,
						spec_path, board_item_id)
					attach_worktree(repo_row, run_id, branch)
				end
			rescue StandardError
				discard(repo_row, run_id)
				raise
			end

			@board&.want(run_id, 'running')
			run_id
		end

		private

		# Running or blocked: a blocked run keeps its worktree, and therefore its
		# branch, until it is answered or killed.
		def live_holder(repo_id, branch)
			@db[:runs].where(repo_id: repo_id, branch: branch, status: %w[running blocked]).first
		end

		def held(repo_row, subject_number, branch, holder)
			key = [repo_row[:id], subject_number, branch]
			unless @announced[key]
				@announced[key] = true
				comment(repo_row, subject_number,
					"Waiting: run #{holder[:id]} still has `#{branch}` checked out (it is " \
					"#{holder[:status]}). This item starts as soon as that run finishes or is killed.")
			end
			:held
		end

		# No rescue. `git worktree list` failing means mill does not know whether the
		# branch is checked out, and answering "it is not" is a rescue that turns a
		# failure into a pass — the one thing the constraints forbid. It raises, the
		# poller records it, and nothing is claimed on a guess.
		def checked_out(clone, branch)
			@git.checked_out_branches(clone).include?(branch)
		end

		# The transaction rolls the row back; the worktree is not transactional, so
		# a directory that did appear before the failure has to go by hand or the
		# next claim on this branch trips over it.
		def discard(repo_row, run_id)
			return if run_id.nil?

			path = File.join(Mill.home, 'worktrees', "#{repo_row[:owner]}-#{repo_row[:name]}",
				run_id.to_s)
			@git.worktree_remove(repo_row[:local_path], path) if Dir.exist?(path)
			@git.run(repo_row[:local_path], 'worktree', 'prune')
		rescue Mill::Git::Error
			nil
		end

		def checked_out_block(clone, branch)
			Blocked.new(problem: :branch_checked_out, questions: [
				"`#{branch}` is checked out in #{clone}. mill will not force a second working " \
				'copy of one branch, because two live checkouts can diverge the ref without either ' \
				'side noticing. Switch that clone to your base branch and reply here.'
			])
		end

		# A SIGKILL during git commit leaves an index or ref lock that git never
		# cleans, and the next launch fails instantly on it. The branch's own ref
		# lock is included whatever the branch is named — scoping this to mill/*
		# would miss the plan route entirely, which adopts the branch gh made.
		def clear_stale_locks(clone, branch)
			dir = @git.run(clone, 'rev-parse', '--git-common-dir')
			return unless dir.ok?

			common = File.expand_path(dir.out.strip, clone)
			candidates = Dir[File.join(common, '*.lock')] +
				Dir[File.join(common, 'worktrees', '*', '*.lock')] +
				[File.join(common, 'refs', 'heads', "#{branch}.lock")]

			candidates.uniq.each { |lock| delete_if_stale(lock) }
		end

		def delete_if_stale(lock)
			return unless File.file?(lock)
			return if Mill.now - File.stat(lock).mtime.utc.to_i < STALE_LOCK_AFTER

			File.delete(lock)
		rescue SystemCallError
			nil
		end

		def insert_run(repo_row, subject_kind, subject_number, route, branch, spec_path, item_id)
			@db[:runs].insert(
				repo_id: repo_row[:id], subject_kind: subject_kind, subject_number: subject_number,
				route: route, branch: branch, spec_path: spec_path, status: 'running',
				board_item_id: item_id, created_at: Mill.now
			)
		end

		def attach_worktree(repo_row, run_id, branch)
			path = File.join(Mill.home, 'worktrees', "#{repo_row[:owner]}-#{repo_row[:name]}",
				run_id.to_s)
			@git.worktree_add(repo_row[:local_path], path, branch)
			@db[:runs].where(id: run_id).update(worktree_path: path)
			path
		end

		def comment(repo_row, number, body)
			@github.comment("#{repo_row[:owner]}/#{repo_row[:name]}", number, body)
		rescue Mill::Github::Error
			nil
		end
	end
end
```

Add `require_relative 'mill/supervisor'` to `lib/mill.rb`, after `require_relative 'mill/board'`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb`
Expected: PASS, 9 runs.

- [ ] **Step 5: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/supervisor.rb test/mill/test_supervisor.rb lib/mill.rb
git commit -m "Claim an item, or say why not"
```

---

### Task 7: `Mill::Supervisor` — running, blocking, and tearing down

A route walk takes eighteen minutes. If the supervisor walked it, it would claim one item and stop
reconciling, so each claimed run gets its own thread. When the run halts, its questions have to
reach a person: `Mill::Run` returns them and today only `rake mill:run` prints them, which is no
use to anybody who has walked away.

**Files:**
- Modify: `lib/mill/supervisor.rb`
- Modify: `lib/mill/run.rb` — add `Mill::Run.adopt`
- Modify: `test/mill/test_supervisor.rb`

**Interfaces:**
- Consumes: `Mill::Run.adopt`, `Mill::Runner#state`, `Mill::Board#want`, `Mill::Github#comment`.
- Produces: `Mill::Run.adopt(run_id, answers: [], db:, claude:) -> Mill::Run`;
  `Mill::Supervisor#start(run_id, launcher: nil) -> Thread`, `#running?(run_id)`, `#finish(run_id, state)`,
  `#teardown(run_id)`, `#own_pgids -> Set`. Task 8 reads `own_pgids`; Task 11 calls `start` for a
  resumed run.

- [ ] **Step 1: Write the failing test**

Add to `test/mill/test_supervisor.rb`:

```ruby
		# The route walk is scripted: no claude, no network.
		def finished_state(status, questions: [])
			{ stage: 'plan', status: status, reason: 'scripted', questions: questions }
		end

		def test_a_finished_run_is_torn_down_and_its_branch_freed
			sup = supervisor
			run_id = claim(sup)
			worktree = db[:runs].where(id: run_id).get(:worktree_path)
			db[:runs].where(id: run_id).update(status: 'done', pr_number: 7)

			sup.finish(run_id, finished_state(:done))

			refute_path_exists worktree
			refute_includes Mill::Git.checked_out_branches(@clone), '1-a-feature'
		end

		# A blocked run keeps its worktree: mill needs it to resume, and a timer
		# should not destroy the thing you have to answer a question about.
		def test_a_blocked_run_keeps_its_worktree
			sup = supervisor
			run_id = claim(sup)
			worktree = db[:runs].where(id: run_id).get(:worktree_path)
			db[:runs].where(id: run_id).update(status: 'blocked')

			sup.finish(run_id, finished_state(:blocked, questions: ['Which spec is authoritative?']))

			assert_path_exists worktree
		end

		# The questions are the only channel that reaches a person once you walk away.
		def test_a_blocked_run_posts_its_questions
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'blocked')

			sup.finish(run_id, finished_state(:blocked, questions: ['Which spec is authoritative?']))
			body = calls.select { |args| args.first(2) == %w[issue comment] }.last.join(' ')

			assert_match(/Which spec is authoritative\?/, body)
		end

		def test_a_failed_run_says_so_without_pretending_to_ask
			calls = []
			sup = supervisor(comments: calls)
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(status: 'failed')

			sup.finish(run_id, finished_state(:failed))
			body = calls.select { |args| args.first(2) == %w[issue comment] }.last.join(' ')

			assert_match(/failed/i, body)
			refute_match(/\?/, body.split("\n").last.to_s)
		end

		def test_a_run_thread_is_tracked_while_it_walks
			sup = supervisor
			run_id = claim(sup)
			gate = Queue.new
			thread = sup.start(run_id, walker: ->(_id) { gate.pop; finished_state(:done) })

			assert sup.running?(run_id)

			gate << :go
			thread.join

			refute sup.running?(run_id)
		end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb -n /finish|thread/`
Expected: FAIL — `undefined method 'finish'`.

- [ ] **Step 3: Add `Mill::Run.adopt`**

In `lib/mill/run.rb`, replace `self.resume` with:

```ruby
		# Builds a Run from a row that already exists. Nothing is re-resolved, so
		# adopting a run cannot pick a different branch than the one it has been
		# working on.
		def self.adopt(run_id, answers: [], db: Mill.db, claude: Mill::Claude)
			row = db[:runs].where(id: run_id).first or raise Mill::Error, "no run #{run_id}"
			repo = db[:repos].where(id: row[:repo_id]).first

			run = allocate
			run.send(:initialize_resumed, row, repo, db, claude, Array(answers))
			run
		end

		def self.resume(run_id, answers, db: Mill.db, claude: Mill::Claude, &announce)
			adopt(run_id, answers: answers, db: db, claude: claude).call(&announce)
		end
```

And in `#initialize_resumed`, replace `@resumed = true` with:

```ruby
			# A fresh run has nothing to restore; a blocked one has verdicts the
			# resumed stage needs handed back to it.
			@resumed = row[:status] == 'blocked'
```

- [ ] **Step 4: Add the running half of `Mill::Supervisor`**

Add `require 'set'` at the top of `lib/mill/supervisor.rb`, initialise `@threads = {}` and
`@own_pgids = Set.new` in the constructor, and add:

```ruby
		attr_reader :own_pgids

		# One thread per run: a route walk takes tens of minutes, and a supervisor
		# that walked it would claim one item and then stop reconciling.
		def start(run_id, walker: nil)
			walk = walker || method(:walk)
			@threads[run_id] = Thread.new do
				state = walk.call(run_id)
				finish(run_id, state)
			rescue StandardError => e
				# A dead runner thread must not leave a run marked running forever.
				# It costs an attempt and no strike: the machine failed, not the stage.
				warn "run #{run_id} thread died: #{e.class}: #{e.message}"
				@db[:runs].where(id: run_id).update(status: 'failed', finished_at: Mill.now)
				finish(run_id, { stage: nil, status: :failed, reason: e.message, questions: [] })
			ensure
				@threads.delete(run_id)
			end
		end

		def running?(run_id) = @threads[run_id]&.alive? || false

		def finish(run_id, state)
			row = @db[:runs].where(id: run_id).first or return
			announce(row, state)
			@board&.want(run_id, row[:status])
			teardown(run_id)
		end

		# A blocked run keeps its worktree indefinitely: mill needs it to resume, and
		# a timer should not destroy the thing you have to answer a question about.
		def teardown(run_id)
			row = @db[:runs].where(id: run_id).first or return
			return unless %w[done failed killed].include?(row[:status])

			repo = @db[:repos].where(id: row[:repo_id]).first
			path = row[:worktree_path]
			return if path.nil? || !Dir.exist?(path)

			@git.worktree_remove(repo[:local_path], path)
			@git.run(repo[:local_path], 'worktree', 'prune')
		rescue Mill::Git::Error => e
			warn "run #{run_id} worktree not removed: #{e.message}"
		end

		private

		def walk(run_id)
			Mill::Run.adopt(run_id, db: @db).call
			@db[:runs].where(id: run_id).first
		end

		def announce(row, state)
			repo = @db[:repos].where(id: row[:repo_id]).first
			body = case row[:status]
			when 'blocked' then blocked_body(state)
			when 'done' then "Opened ##{row[:pr_number]}." 
			else "This run #{row[:status]}: #{state[:reason]}. Nothing was merged and no further " \
				'work will start on it. Reply here after fixing the cause and set Status back to Ready.'
			end
			comment(repo, row[:subject_number], body)
		end

		def blocked_body(state)
			questions = Array(state[:questions])
			return "Blocked at `#{state[:stage]}`: #{state[:reason]}." if questions.empty?

			["Blocked at `#{state[:stage]}`: #{state[:reason]}.", '',
			 'Answer in a reply and this run continues from where it stopped.', '',
			 *questions.map { |q| "- #{q}" }].join("\n")
		end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb`
Expected: PASS, 14 runs.

- [ ] **Step 6: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/supervisor.rb lib/mill/run.rb test/mill/test_supervisor.rb
git commit -m "Walk a run in its own thread, say what happened, and tear it down"
```

---

### Task 8: `Mill::Supervisor` — reaping a run whose process is gone

Pids are recycled: after a reboot they restart low, so a stored pgid of `431` may well be alive and
belong to a system daemon. Three branches, evaluated in order, and nothing gets signalled on the
boot time alone. `Mill::Spawn.reap` already implements the signalling with both checks; this task
is the decision above it.

**Files:**
- Modify: `lib/mill/runner.rb:65` — `current_stage` becomes true while a stage runs
- Modify: `lib/mill/supervisor.rb`
- Modify: `test/mill/test_supervisor.rb`, `test/mill/test_runner.rb`

**Interfaces:**
- Consumes: `Mill::Clock.pid_started_at`, `Mill::Spawn.reap`, `runs.pid/pgid/pid_started_at/host_boot_at`
  from Task 1, `Mill::Ledger#charge(outcome: :interrupted)`.
- Produces: `Mill::Supervisor#reap -> Array[Integer]` returning the run ids it interrupted, and
  `#identify(row) -> :gone | :foreign | :ours`. Task 12 calls `reap` at boot and on a timer.

**Read this before writing any of it.** `Mill::Runner` writes `current_stage` in exactly two
places today — `halt` (`runner.rb:220`) and `finish` (234) — so for the whole time a stage is
actually running the column is **nil**. Every part of this task depends on knowing which stage a
live run is in, so the column has to become true first. That is Step 1, and it is not optional:
without it `interrupt` has nothing to charge and the reaper silently does nothing, which is
exactly the shape of failure that looks like the feature working.

- [ ] **Step 1: Make `current_stage` true while a stage is running**

Write this test in `test/mill/test_runner.rb`, following that file's existing scripted-launcher
helpers:

```ruby
	# The column is what a supervisor reaping a live run reads to know what to
	# charge. Written only at halt, it is nil for the entire time a stage runs.
	def test_the_current_stage_is_recorded_while_the_stage_is_running
		seen = nil
		runner = runner_with(launcher: lambda { |stage:, **rest|
			seen = db[:runs].where(id: @run_id).get(:current_stage)
			ok_attempt(stage: stage, **rest)
		})
		runner.call

		assert_equal 'triage', seen
	end
```

Run it: FAIL, `Expected nil to equal "triage"`. Then in `lib/mill/runner.rb#step`, record the
stage before launching it:

```ruby
		def step
			return finish if stage.nil?
			return terminate("#{@stage} ran out of strikes twice") if @exhausted

			tally = @ledger.tally(@stage)
			return halt(:blocked, "#{@stage} has used both its strikes") if tally.out_of_strikes?
			return halt(:blocked, "#{@stage} hit its number cap") if tally.out_of_attempts?

			# Recorded before the launch, not after it. This is what the supervisor
			# reads to know which stage to charge for an interruption, and an
			# interruption is by definition something that happens mid-launch.
			@db[:runs].where(id: @run_id).update(current_stage: @stage)
			settle(launch(@stage, tally.next_attempt), tally.next_attempt)
		end
```

Run it again: PASS. Then `bundle exec rake test` — `Mill::Runner#restore` already reads
`current_stage` when resuming a blocked run, so confirm the resume tests still pass.

- [ ] **Step 2: Write the failing reaper test**

Add to `test/mill/test_supervisor.rb`:

```ruby
		def running_run(pid:, started_at:, boot_at: Mill::Clock.boot_time)
			run_id = claim(supervisor)
			db[:runs].where(id: run_id).update(pid: pid, pgid: pid, pid_started_at: started_at,
				host_boot_at: boot_at, current_stage: 'plan', heartbeat_at: Mill.now)
			run_id
		end

		# No process, so whether the machine rebooted or the process simply died, the
		# attempt is over. Signal nothing.
		def test_a_run_whose_process_is_gone_is_interrupted
			sup = supervisor
			run_id = running_run(pid: 999_999, started_at: Mill.now)

			assert_equal [run_id], sup.reap
			assert_equal 'running', db[:runs].where(id: run_id).get(:status)
			assert_equal 'interrupted', db[:stage_attempts].where(run_id: run_id).first[:status]
		end

		# An interruption is the machine's fault, so it costs an attempt and no strike.
		def test_an_interruption_charges_no_strike
			sup = supervisor
			run_id = running_run(pid: 999_999, started_at: Mill.now)
			sup.reap

			refute db[:stage_attempts].where(run_id: run_id).first[:strike_charged]
		end

		# A pid that exists but started at a different time is a stranger wearing a
		# recycled number. Signalling it would kill something else entirely.
		def test_a_recycled_pid_is_never_signalled
			sup = supervisor
			run_id = running_run(pid: Process.pid, started_at: 1)

			assert_equal :gone, sup.identify(db[:runs].where(id: run_id).first)
			assert_equal [run_id], sup.reap
			assert_predicate Process, :pid
		end

		# mill restarted and the stage kept running. Two agents in one worktree is
		# worse than losing partial work.
		def test_a_live_group_mill_did_not_spawn_is_foreign
			sup = supervisor
			run_id = running_run(pid: Process.pid, started_at: Mill::Clock.pid_started_at(Process.pid))

			assert_equal :foreign, sup.identify(db[:runs].where(id: run_id).first)
		end

		def test_a_live_group_mill_spawned_this_instance_is_left_alone
			sup = supervisor
			run_id = running_run(pid: Process.pid, started_at: Mill::Clock.pid_started_at(Process.pid))
			sup.own_pgids << Process.pid

			assert_equal :ours, sup.identify(db[:runs].where(id: run_id).first)
			assert_empty sup.reap
		end

		# pid and pgid are nil for the whole gap between two stages, which happens
		# five times on the plan route. Reading nil as "mill has this in hand"
		# strands every run mill was restarted between stages, and each one holds a
		# slot against the cap forever.
		def test_a_running_run_with_no_thread_and_no_process_is_gone
			sup = supervisor
			run_id = claim(sup)
			db[:runs].where(id: run_id).update(current_stage: 'plan')

			assert_equal :gone, sup.identify(db[:runs].where(id: run_id).first)
		end

		# Interrupting without re-entering leaves the run running with no thread,
		# which nothing else ever picks up.
		def test_an_interrupted_run_is_started_again
			sup = supervisor
			started = []
			sup.define_singleton_method(:start) { |id, **| started << id }
			run_id = running_run(pid: 999_999, started_at: Mill.now)
			sup.reap

			assert_equal [run_id], started
		end

		# A run blocked by the interruption cap is waiting for a person. Starting it
		# again on the next tick would burn its attempts without anyone answering.
		def test_a_run_blocked_by_the_cap_is_not_started_again
			sup = supervisor
			started = []
			sup.define_singleton_method(:start) { |id, **| started << id }
			run_id = running_run(pid: 999_999, started_at: Mill.now)
			Mill::Ledger::MAX_INTERRUPTIONS.times do
				db[:runs].where(id: run_id).update(status: 'running', pid: 999_999, pgid: 999_999,
					pid_started_at: Mill.now, host_boot_at: Mill::Clock.boot_time)
				sup.reap
			end

			assert_equal 'blocked', db[:runs].where(id: run_id).get(:status)
			assert_equal Mill::Ledger::MAX_INTERRUPTIONS - 1, started.length
		end

		# A running row with no current_stage means something above lost track of
		# what the run was doing. Charging nothing and moving on hides it.
		def test_a_running_run_with_no_stage_is_an_error_rather_than_a_no_op
			sup = supervisor
			run_id = running_run(pid: 999_999, started_at: Mill.now)
			db[:runs].where(id: run_id).update(current_stage: nil)

			assert_raises(Mill::Error) { sup.reap }
		end

		def test_interruptions_are_capped_per_stage
			sup = supervisor
			run_id = running_run(pid: 999_999, started_at: Mill.now)
			Mill::Ledger::MAX_INTERRUPTIONS.times do
				db[:runs].where(id: run_id).update(pid: 999_999, pgid: 999_999,
					pid_started_at: Mill.now, host_boot_at: Mill::Clock.boot_time)
				sup.reap
			end

			assert_equal 'blocked', db[:runs].where(id: run_id).get(:status)
		end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb -n /reap|identify|interrupt/`
Expected: FAIL — `undefined method 'reap'`.

- [ ] **Step 4: Write the reaping half**

Add to `lib/mill/supervisor.rb`:

```ruby
		# Every run marked running, checked against the live process table. Called at
		# boot and on a timer. At boot mill has no live threads, so every group it
		# finds is foreign by definition — which is the correct answer: mill
		# restarted and the stage outlived it.
		#
		# Interrupting is only half the job. A run that is interrupted and not
		# restarted stays `running` with no thread forever, holds its slot against
		# the cap, and is skipped by the poller because its item has an active run.
		# Two of those stop the factory with nothing anywhere reporting a problem.
		def reap
			@db[:runs].where(status: 'running').select_map(:id).filter_map do |run_id|
				row = @db[:runs].where(id: run_id).first
				next if row.nil? || running?(run_id)

				case identify(row)
				when :ours then next
				when :foreign
					Mill::Spawn.reap(row[:pgid], boot_at: row[:host_boot_at],
						started_at: row[:pid_started_at])
				end

				interrupt(row)
				restart(run_id)
				run_id
			end
		end

		# Three branches, in this order. Nothing is signalled on the strength of the
		# boot time alone: kern.boottime moves when NTP corrects the clock, which it
		# does routinely on waking, so the live process is what settles it.
		#
		# `:ours` means mill has a thread walking this run right now — not merely
		# that no process is recorded. pid and pgid are nil for the whole gap
		# between two stages, which on the plan route happens five times per run, so
		# reading nil as "fine, leave it" strands any run mill was restarted during.
		def identify(row)
			return :ours if running?(row[:id])
			return :gone if row[:pid].nil? || row[:pid_started_at].nil?

			started = Mill::Clock.pid_started_at(row[:pid])
			return :gone if started.nil?
			return :gone if (started - row[:pid_started_at]).abs > 2

			@own_pgids.include?(row[:pgid]) ? :ours : :foreign
		end

		private

		# Re-enters the stage the run was in. Costs an attempt and no strike: the
		# machine lost the process, the stage did not fail. A run that interrupt just
		# blocked — because it hit the interruption cap — is not restarted; it is
		# waiting for a person, and the next tick would otherwise start it again.
		def restart(run_id)
			return if at_cap?
			return unless @db[:runs].where(id: run_id).get(:status) == 'running'

			start(run_id)
		end

		def interrupt(row)
			stage = row[:current_stage] or
				raise Mill::Error, "run #{row[:id]} is running with no current_stage"

			ledger = Mill::Ledger.new(@db, row[:id])
			ledger.charge(stage: stage, outcome: :interrupted)
			@db[:runs].where(id: row[:id]).update(pid: nil, pgid: nil, heartbeat_at: nil)
			return unless ledger.out_of_interruptions?(stage)

			@db[:runs].where(id: row[:id]).update(status: 'blocked')
			repo = @db[:repos].where(id: row[:repo_id]).first
			comment(repo, row[:subject_number],
				"Blocked at `#{stage}`: this stage has been interrupted " \
				"#{Mill::Ledger::MAX_INTERRUPTIONS} times without finishing. Nothing was charged " \
				'against it — each interruption was mill losing the process, not the stage ' \
				'failing. Reply here to try again.')
			@board&.want(row[:id], 'blocked')
		end
```

In `#start`, record and release the pgid so `identify` can tell mill's own launches apart. Add to
the thread body, before `walk.call`:

```ruby
				@own_pgids << @db[:runs].where(id: run_id).get(:pgid)
```

That reads too early — the pgid is not known until the stage spawns. Instead, have `Mill::Run`
report it: in `lib/mill/run.rb` `#record_identity`, add an optional observer:

```ruby
		attr_accessor :on_identity

		def record_identity(pid, pgid, started_at, boot_at)
			@db[:runs].where(id: @run_id).update(pid: pid, pgid: pgid, pid_started_at: started_at,
				host_boot_at: boot_at, heartbeat_at: Mill.now)
			@on_identity&.call(pgid)
		end
```

and in `Mill::Supervisor#walk`:

```ruby
		def walk(run_id)
			run = Mill::Run.adopt(run_id, db: @db)
			run.on_identity = ->(pgid) { @own_pgids << pgid }
			run.call
			@db[:runs].where(id: run_id).first
		end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_supervisor.rb`
Expected: PASS, 21 runs.

- [ ] **Step 6: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/supervisor.rb lib/mill/run.rb test/mill/test_supervisor.rb
git commit -m "Reap a run against a verified identity, never against a pid alone"
```

---

### Task 9: `Mill::Poller` — reconciling the board into work

The question the poller asks is idempotent: which items are `Ready` with no active run? It needs no
dedupe key and heals itself when mill crashes mid-transition. The label design that preceded it
consumed events and produced four separate bugs; a single-select cannot express any of them.

**Files:**
- Create: `lib/mill/poller.rb`
- Create: `test/mill/test_poller.rb`
- Create: `test/fixtures/gh/board_ready.json`
- Modify: `lib/mill.rb`

**Interfaces:**
- Consumes: `Mill::Board#items`, `Mill::Repo.prepare`, `Mill::Spec.locate`, `Mill::Supervisor#claim`
  and `#start`.
- Produces: `Mill::Poller.new(db:, github:, board:, supervisor:)` with `#tick`, `#reconcile` and
  `#ready_items`. Task 12 calls `tick`.

- [ ] **Step 1: Write the fixture**

Create `test/fixtures/gh/board_ready.json`:

```json
{"items":[
 {"id":"PVTI_1","content":{"number":1,"type":"Issue","repository":"slowernet/rep"},"status":"Ready"},
 {"id":"PVTI_2","content":{"number":2,"type":"Issue","repository":"slowernet/rep"},"status":"Running"},
 {"id":"PVTI_3","content":{"number":3,"type":"Issue","repository":"slowernet/rep"},"status":"Done"},
 {"id":"PVTI_4","content":{"number":4,"type":"Issue","repository":"slowernet/rep"},"status":"Ready",
  "evidence":"Required","review":"Deep"}]}
```

- [ ] **Step 2: Write the failing test**

Create `test/mill/test_poller.rb`:

```ruby
require 'test_helper'

module Mill
	# Fixture-backed. The supervisor is a stub: claiming is Task 6's business and is
	# tested there against real git.
	class TestPoller < Mill::TestCase
		FIXTURES = File.join(__dir__, '..', 'fixtures', 'gh')

		def fixture(name) = File.read(File.join(FIXTURES, "#{name}.json"))

		# Records what it was asked to claim and answers with an incrementing id.
		class FakeSupervisor
			attr_reader :claimed, :started, :answer

			def initialize(answer: nil)
				@claimed = []
				@started = []
				@answer = answer
				@next = 100
			end

			def at_cap? = false

			def claim(**args)
				@claimed << args
				return @answer if @answer

				@next += 1
			end

			def start(run_id, **) = @started << run_id
		end

		def poller(supervisor: FakeSupervisor.new, board_json: 'board_ready', located: nil)
			github = Mill::Github.new(runner: lambda { |args|
				case args[1]
				when 'item-list' then fixture(board_json)
				else ''
				end
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			Mill::Poller.new(db: db, github: github, board: board, supervisor: supervisor,
				locator: located || ->(*) { Mill::Spec::Located.new(branch: 'x', path: 'docs/s.md') })
		end

		def prepared_repo
			create_repo(owner: 'slowernet', name: 'rep', local_path: '/tmp/rep',
				base_branch: 'main', prepared_at: Mill.now)
		end

		def test_only_ready_items_are_claimed
			prepared_repo
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [1, 4], sup.claimed.map { |c| c[:subject_number] }.sort
		end

		def test_an_item_with_an_active_run_is_left_alone
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'running')
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [4], sup.claimed.map { |c| c[:subject_number] }
		end

		# A blocked run is still guarding its subject: resume is comment-triggered,
		# so a second run would take the branch and the answer would find nothing.
		def test_a_blocked_run_still_guards_its_subject
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal [4], sup.claimed.map { |c| c[:subject_number] }
		end

		def test_nothing_is_claimed_at_the_cap
			prepared_repo
			sup = FakeSupervisor.new
			def sup.at_cap? = true
			poller(supervisor: sup).reconcile

			assert_empty sup.claimed
		end

		def test_the_directives_on_an_item_reach_the_run
			prepared_repo
			sup = FakeSupervisor.new
			p = poller(supervisor: sup)
			p.reconcile
			run_id = sup.claimed.length

			assert_equal 'PVTI_4', sup.claimed.last[:board_item_id]
			refute_nil p
			refute_nil run_id
		end

		def test_a_claimed_run_is_started
			prepared_repo
			sup = FakeSupervisor.new
			poller(supervisor: sup).reconcile

			assert_equal sup.claimed.length, sup.started.length
		end

		# The item waits rather than failing: the run holding the branch will finish
		# or be reaped.
		def test_a_held_item_starts_nothing
			prepared_repo
			sup = FakeSupervisor.new(answer: :held)
			poller(supervisor: sup).reconcile

			assert_empty sup.started
		end

		# An unprepared repo blocks that one item and names what is missing.
		def test_an_unpreparable_repo_blocks_only_its_own_item
			posted = []
			github = Mill::Github.new(runner: lambda { |args|
				posted << args
				args[1] == 'item-list' ? fixture('board_ready') : ''
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			sup = FakeSupervisor.new
			p = Mill::Poller.new(db: db, github: github, board: board, supervisor: sup,
				preparer: ->(**) { Mill::Repo::Result.new(problem: :missing_secrets,
					questions: ['API_KEY is missing']) })
			p.reconcile

			assert_empty sup.claimed
			assert_match(/API_KEY/, posted.select { |a| a.first(2) == %w[issue comment] }.first.join(' '))
		end

		# :no_spec carries no questions, so the generic block comment would post a
		# heading over an empty list and read as a bug in mill.
		def test_an_item_with_no_spec_is_told_what_to_commit
			prepared_repo
			posted = []
			github = Mill::Github.new(runner: lambda { |args|
				posted << args
				args[1] == 'item-list' ? fixture('board_ready') : ''
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			p = Mill::Poller.new(db: db, github: github, board: board, supervisor: FakeSupervisor.new,
				locator: ->(*) { Mill::Spec::Located.new(branch: 'x', problem: :no_spec) })
			p.reconcile
			body = posted.select { |a| a.first(2) == %w[issue comment] }.first.join(' ')

			assert_match(%r{docs/superpowers/specs/}, body)
			refute_match(/^- $/, body)
		end

		def test_an_item_with_no_linked_branch_is_told_to_make_one
			prepared_repo
			posted = []
			github = Mill::Github.new(runner: lambda { |args|
				posted << args
				args[1] == 'item-list' ? fixture('board_ready') : ''
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			p = Mill::Poller.new(db: db, github: github, board: board, supervisor: FakeSupervisor.new,
				locator: ->(*) { Mill::Spec::Located.new(problem: :no_branch) })
			p.reconcile

			assert_match(/gh issue develop/, posted.select { |a| a.first(2) == %w[issue comment] }.first.join(' '))
		end

		# Silence is never success: a board mill could not read is not an empty board.
		def test_an_unreadable_board_raises_rather_than_reading_as_empty
			github = Mill::Github.new(runner: ->(_) { raise Mill::Github::Unauthorized, 'bad token' })
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			p = Mill::Poller.new(db: db, github: github, board: board, supervisor: FakeSupervisor.new)

			assert_raises(Mill::Github::Unauthorized) { p.reconcile }
		end
	end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb`
Expected: FAIL — `uninitialized constant Mill::Poller`.

- [ ] **Step 4: Read `Mill::Spec::Located` before writing against it**

Verified 2026-08-19: `Mill::Spec::Located` carries `branch`, `path`, `problem`, `detail`, and
answers `found?`, `blocked?` and `questions`. Two details matter to this task and are easy to get
wrong.

`questions` is empty for `:no_branch` and `:no_spec`. Those are the two problems `Located#blocked?`
calls ordinary — the design leaves them unblocked because `triage` might still route the issue to
`fast`. That route does not exist in 3a, so mill has nothing to do with such an item either way and
must still say so; but posting the generic block comment would produce an empty bullet list under a
heading. They get their own sentence instead.

- [ ] **Step 5: Write `Mill::Poller`**

Create `lib/mill/poller.rb`:

```ruby
module Mill
	# Reconciles the board into runnable work. It asks one idempotent question —
	# which items are Ready with no active run — which needs no dedupe key and
	# heals itself when mill crashes mid-transition.
	#
	# The label design that preceded this consumed change *events*, and four bugs
	# came from that shape: a relabelled issue deduped permanently, an item that
	# was Ready and Running at once, nothing clearing Running when a run was
	# killed, and no label change reaching a terminal state. A single-select
	# cannot express any of them.
	class Poller
		# `supervisor` is required and is never built here. There must be exactly one
		# supervisor in the process: it is the only thing that knows which process
		# groups mill spawned and which runs have a live thread, and a second
		# instance believes the answer to both is "none". A reaper holding that
		# belief classifies every healthy stage mill just started as a foreign
		# process and SIGKILLs it, roughly thirty seconds into every run.
		def initialize(supervisor:, db: Mill.db, github: nil, board: nil,
			preparer: Mill::Repo.method(:prepare), locator: nil)
			@db = db
			@github = github || Mill::Github.new
			@board = board || Mill::Board.new(db: db, github: @github)
			@supervisor = supervisor
			@preparer = preparer
			@locator = locator
		end

		def tick
			@board.redrive
			reconcile
			sweep
		end

		def reconcile
			return unless @board.configured?

			ready_items.each do |item|
				break if @supervisor.at_cap?

				start(item)
			end
		end

		def ready_items
			@board.items.select { |item| item[:status] == 'Ready' && !active?(item) }
		end

		private

		# Both issues and PRs appear as items, and a PR-entry item is a subject in
		# its own right — a Dependabot PR has no issue, so questions need somewhere
		# to go.
		def subject_kind(item) = item.dig(:content, :type) == 'PullRequest' ? 'pr' : 'issue'

		def active?(item)
			repo = repo_row(item) or return false

			@db[:runs].where(repo_id: repo[:id], subject_kind: subject_kind(item),
				subject_number: item.dig(:content, :number), status: %w[running blocked]).any?
		end

		def repo_row(item)
			owner, name = item.dig(:content, :repository).to_s.split('/', 2)
			return nil if name.nil?

			@db[:repos].where(owner: owner, name: name).first
		end

		def start(item)
			owner, name = item.dig(:content, :repository).to_s.split('/', 2)
			number = item.dig(:content, :number)
			return if name.nil? || number.nil?

			prepared = @preparer.call(db: @db, owner: owner, name: name)
			return block_item(owner, name, number, prepared.problem, prepared.questions) unless
				prepared.ok?

			repo = @db[:repos].where(owner: owner, name: name).first
			located = locate(repo, "#{owner}/#{name}", number)
			return no_spec(owner, name, number, located) unless located.found?

			claim(item, repo, number, located)
		end

		# :no_branch and :no_spec carry no questions, because there is nothing to
		# ask — the answer is a branch or a file, not a decision. Saying "mill cannot
		# start this" and then listing nothing reads as a bug in mill rather than a
		# missing spec, so those two get told plainly.
		def no_spec(owner, name, number, located)
			return block_item(owner, name, number, located.problem, located.questions) if
				located.blocked?

			body = case located.problem
			when :no_branch
				'This item has no linked branch, so there is nothing for mill to adopt. Run ' \
					"`gh issue develop #{number}`, commit a spec on that branch under " \
					'`docs/superpowers/specs/`, and set Status back to `Ready`.'
			else
				"`#{located.branch}` adds no file under `docs/superpowers/specs/`, so mill has no " \
					'spec to plan from. Commit one on that branch and set Status back to `Ready`.'
			end
			comment_on(owner, name, number, body)
		end

		def claim(item, repo, number, located)
			result = @supervisor.claim(repo_row: repo, subject_kind: subject_kind(item),
				subject_number: number, route: 'plan', branch: located.branch,
				spec_path: located.path, board_item_id: item[:id])

			case result
			when :held then nil
			when Mill::Supervisor::Blocked
				block_item(repo[:owner], repo[:name], number, result.problem, result.questions)
			else
				@supervisor.start(result)
			end
		end

		def locate(repo, slug, number)
			return @locator.call(repo, slug, number) if @locator

			Mill::Spec.locate(github: @github, repo: slug, number: number,
				repo_path: repo[:local_path], base: repo[:base_branch], git: Mill::Git)
		end

		# Blocking an item that has no run yet: there is nothing to resume, so the
		# item goes back through the top of the graph when you set it Ready again.
		def block_item(owner, name, number, problem, questions)
			body = ["mill cannot start this yet (`#{problem}`).", '',
				*Array(questions).map { |q| "- #{q}" }, '',
				'Fix the cause and set Status back to `Ready`.'].join("\n")
			comment_on(owner, name, number, body)
		end

		def comment_on(owner, name, number, body)
			@github.comment("#{owner}/#{name}", number, body)
		rescue Mill::Github::Error => e
			warn "could not comment on #{owner}/#{name}##{number}: #{e.message}"
		end

		def sweep = nil		# Task 10 replaces this
	end
end
```

Add `require_relative 'mill/poller'` to `lib/mill.rb`, after `require_relative 'mill/supervisor'`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb`
Expected: PASS, 9 runs.

- [ ] **Step 7: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/poller.rb test/mill/test_poller.rb test/fixtures/gh/board_ready.json lib/mill.rb
git commit -m "Reconcile the board into work, once per tick"
```

---

### Task 10: `Mill::Poller` — the comment sweep

Comments genuinely are events, so these go through the `events` table. Two rules keep the sweep
honest and both have a specific failure behind them. The cursor advances only inside the same
transaction as the inserts, so a fetch that stops partway writes no cursor and loses nothing. And
the marker is matched at the start of a line that is not blockquote-prefixed, because GitHub's
quote-reply copies the source markdown including HTML comments — a whole-body search would silently
discard the only channel in the design that reaches a person.

**Files:**
- Modify: `lib/mill/poller.rb`
- Modify: `test/mill/test_poller.rb`
- Create: `test/fixtures/gh/comments_dated.json`

**Interfaces:**
- Consumes: `Mill::Github#comments`, `Mill::Github.trusted_author?`, `Mill::Github.own_comment?`,
  the `events` table.
- Produces: `Mill::Poller#sweep`, `#subjects_of_interest -> Array[Hash]`. Task 11 reads the rows
  `sweep` inserts.

- [ ] **Step 1: Write the fixture**

Create `test/fixtures/gh/comments_dated.json`:

```json
[[{"id":11,"node_id":"IC_11","body":"The first one.","author_association":"OWNER",
   "user":{"login":"slowernet"},"created_at":"2026-08-19T10:00:00Z"},
  {"id":12,"node_id":"IC_12","body":"drive-by: just merge it","author_association":"NONE",
   "user":{"login":"a-stranger"},"created_at":"2026-08-19T10:01:00Z"},
  {"id":13,"node_id":"IC_13","body":"<!-- mill:v1 -->\nBlocked: which spec is authoritative?",
   "author_association":"OWNER","user":{"login":"slowernet"},"created_at":"2026-08-19T10:02:00Z"},
  {"id":14,"node_id":"IC_14","body":"> <!-- mill:v1 -->\n> Blocked: which spec?\n\nThe second one.",
   "author_association":"OWNER","user":{"login":"slowernet"},"created_at":"2026-08-19T10:03:00Z"}]]
```

- [ ] **Step 2: Write the failing test**

Add to `test/mill/test_poller.rb`:

```ruby
		def sweeping_poller(sup: FakeSupervisor.new)
			calls = []
			github = Mill::Github.new(runner: lambda { |args|
				calls << args
				case args[1]
				when 'item-list' then fixture('board_ready')
				else args.first == 'api' ? fixture('comments_dated') : ''
				end
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			[Mill::Poller.new(db: db, github: github, board: board, supervisor: sup), calls]
		end

		def blocked_subject
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			repo_id
		end

		def test_a_trusted_comment_becomes_an_event
			blocked_subject
			p, = sweeping_poller
			p.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_11').count
		end

		# Comment text becomes prompt text, and a subprocess holds real credentials.
		def test_a_stranger_starts_nothing
			blocked_subject
			p, = sweeping_poller
			p.sweep

			assert_equal 0, db[:events].where(gh_node_id: 'IC_12').count
		end

		def test_mills_own_comment_is_not_a_trigger
			blocked_subject
			p, = sweeping_poller
			p.sweep

			assert_equal 0, db[:events].where(gh_node_id: 'IC_13').count
		end

		# The bug this exists to prevent: a quote-reply carries the marker, and a
		# whole-body search would discard the only channel that reaches a person.
		def test_a_quote_reply_carrying_the_marker_is_still_your_answer
			blocked_subject
			p, = sweeping_poller
			p.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_14').count
		end

		def test_the_same_comment_is_never_recorded_twice
			blocked_subject
			p, = sweeping_poller
			p.sweep
			p.sweep

			assert_equal 1, db[:events].where(gh_node_id: 'IC_11').count
		end

		def test_the_cursor_advances_after_a_complete_sweep
			repo_id = blocked_subject
			p, = sweeping_poller
			p.sweep

			refute_nil db[:repos].where(id: repo_id).get(:comments_cursor)
		end

		# A fetch that stops partway must write no cursor, or the comments it never
		# saw are skipped forever.
		def test_a_failed_fetch_leaves_the_cursor_alone
			repo_id = blocked_subject
			github = Mill::Github.new(runner: lambda { |args|
				raise Mill::Github::Error, 'boom' if args.first == 'api'

				fixture('board_ready')
			})
			board = Mill::Board.new(db: db, github: github, project: 3, owner: 'slowernet')
			p = Mill::Poller.new(db: db, github: github, board: board, supervisor: FakeSupervisor.new)

			assert_raises(Mill::Github::Error) { p.sweep }
			assert_nil db[:repos].where(id: repo_id).get(:comments_cursor)
		end

		# The sweep is bounded: only subjects mill has reason to care about, not
		# every issue in every repo the board touches.
		def test_only_interesting_subjects_are_swept
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			create_run(repo_id: repo_id, subject_number: 9, status: 'done')
			p, calls = sweeping_poller
			p.sweep
			fetched = calls.select { |args| args.first == 'api' }.map { |args| args[1] }

			assert(fetched.any? { |url| url.include?('/issues/1/comments') })
			refute(fetched.any? { |url| url.include?('/issues/9/comments') })
		end
	end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb -n /sweep|comment|cursor/`
Expected: FAIL — `assert_equal 1, 0` on the first event test, since `sweep` returns nil.

- [ ] **Step 4: Write the sweep**

Replace `def sweep = nil` in `lib/mill/poller.rb` with:

```ruby
		# Comments are genuinely events, unlike board state, so these are consumed
		# rather than reconciled — which is why they need a cursor and a dedupe key.
		def sweep
			subjects_of_interest.group_by { |s| s[:repo_id] }.each do |repo_id, subjects|
				repo = @db[:repos].where(id: repo_id).first
				fetched = subjects.flat_map { |s| fetch(repo, s) }
				record(repo, fetched)
			end
		end

		# Bounded deliberately: items on the board and subjects mill has a live run
		# on, not every issue in every repo the board touches. An unbounded sweep on
		# an active repo would leave tens of thousands of rows behind.
		def subjects_of_interest
			@db[:runs].where(status: %w[running blocked])
				.select_map(%i[repo_id subject_kind subject_number])
				.uniq
				.map { |repo_id, kind, number| { repo_id: repo_id, kind: kind, number: number } }
		end

		private

		# `since` is why the cursor exists. Without it every tick re-fetches every
		# comment on every live subject: a run blocked for a week on a 300-comment
		# issue is ten paginated pages every 30 seconds, which is 28,800 API calls a
		# day for one waiting run and ends in a secondary rate limit that wedges the
		# poller. The client-side filter below stays as a belt.
		def fetch(repo, subject)
			slug = "#{repo[:owner]}/#{repo[:name]}"
			@github.comments(slug, subject[:number], since: repo[:comments_cursor]).map do |comment|
				comment.merge(subject_kind: subject[:kind], subject_number: subject[:number])
			end
		end

		# The cursor is advanced inside the same transaction as the inserts. A fetch
		# that raises partway therefore writes no cursor, and the comments it never
		# saw are picked up next tick instead of being skipped forever.
		def record(repo, comments)
			usable = comments.select { |c| trigger?(c, repo) }
			latest = comments.filter_map { |c| c[:created_at] }.max

			@db.transaction do
				usable.each { |comment| insert_event(repo, comment) }
				@db[:repos].where(id: repo[:id]).update(comments_cursor: latest) if latest
			end
		end

		def trigger?(comment, repo)
			return false unless Mill::Github.trusted_author?(comment)
			return false if Mill::Github.own_comment?(comment[:body])

			cursor = repo[:comments_cursor]
			cursor.nil? || comment[:created_at].to_s > cursor
		end

		def insert_event(repo, comment)
			@db[:events].insert_conflict.insert(
				repo_id: repo[:id], kind: 'comment', gh_node_id: comment[:node_id].to_s,
				payload_json: comment.to_json, attempts: 0, state: 'pending', created_at: Mill.now
			)
		end
```

`Mill::Github.own_comment?` already checks `line.start_with?(MARKER)` per line, which is exactly the
rule: a blockquoted marker begins with `>` and does not match. Do not change it.

`Mill::Github#comments` needs the `since` parameter, which it does not have. Widen it, keeping the
`--slurp` behaviour and the comment above it intact:

```ruby
		def comments(repo, number, since: nil)
			path = "repos/#{repo}/issues/#{number}/comments?per_page=100"
			path += "&since=#{since}" if since
			pages = json('api', path, '--paginate', '--slurp')
			Array(pages).flatten(1)
		end
```

`since` is inclusive of the boundary second, so a comment created in the same second as the cursor
comes back again. That is what the client-side filter is for, and what the unique index on
`gh_node_id` is for — both have to stay.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb`
Expected: PASS, 18 runs.

- [ ] **Step 6: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/poller.rb test/mill/test_poller.rb test/fixtures/gh/comments_dated.json
git commit -m "Sweep comments behind a cursor that only advances on a whole sweep"
```

---

### Task 11: Dispatch — a comment on a blocked item resumes its run

Board Status decides what a comment is. While an item is `Blocked`, every comment on it is an
answer and none of them starts a run. Without that rule your answer would try to start a second
run, the uniqueness index would refuse it, the event would retry until it died, and the blocked run
would sit waiting for an answer that had already arrived.

**Files:**
- Modify: `lib/mill/poller.rb`
- Modify: `test/mill/test_poller.rb`

**Interfaces:**
- Consumes: the `events` rows from Task 10, `Mill::Run.adopt`, `Mill::Supervisor#start`.
- Produces: `Mill::Poller#dispatch`, called from `#tick` after `#sweep`. Events reach `processed`
  or `dead`.

- [ ] **Step 1: Write the failing test**

Add to `test/mill/test_poller.rb`:

```ruby
		def pending_event(repo_id, number, body: 'The second one.', node: 'IC_99')
			db[:events].insert(repo_id: repo_id, kind: 'comment', gh_node_id: node,
				payload_json: { body: body, subject_number: number, subject_kind: 'issue',
					author_association: 'OWNER' }.to_json,
				attempts: 0, state: 'pending', created_at: Mill.now)
		end

		def test_a_comment_on_a_blocked_run_resumes_it
			repo_id = prepared_repo
			run_id = create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1)
			sup = FakeSupervisor.new
			p, = sweeping_poller(sup: sup)
			p.dispatch

			assert_equal [run_id], sup.started
		end

		def test_the_answer_reaches_the_run
			repo_id = prepared_repo
			run_id = create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1, body: 'Use the second spec.')
			sup = FakeSupervisor.new
			p, = sweeping_poller(sup: sup)
			p.dispatch

			assert_equal ['Use the second spec.'], sup.answers_for(run_id)
		end

		# Marked processed in the same transaction that acts on it, or an exception
		# afterwards drops your answer with no trace.
		def test_an_acted_event_is_marked_processed
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1)
			p, = sweeping_poller
			p.dispatch

			row = db[:events].where(gh_node_id: 'IC_99').first

			assert_equal 'processed', row[:state]
			refute_nil row[:processed_at]
		end

		# Only two of the five triggers have a route. The rest are recorded and
		# logged rather than acted on or silently dropped.
		def test_a_comment_with_no_route_is_recorded_and_left
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'running')
			pending_event(repo_id, 1)
			sup = FakeSupervisor.new
			p, = sweeping_poller(sup: sup)
			p.dispatch

			assert_empty sup.started
			assert_equal 'no_route', db[:events].where(gh_node_id: 'IC_99').get(:state)
		end

		# A failed start must not swallow the answer: fail_event is the compensation
		# for having marked it processed first.
		def test_a_failed_start_leaves_the_answer_to_be_retried
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1)
			sup = FakeSupervisor.new
			def sup.start(*) = raise(Mill::Error, 'nope')
			p, = sweeping_poller(sup: sup)
			p.dispatch
			row = db[:events].where(gh_node_id: 'IC_99').first

			assert_equal 'pending', row[:state]
			assert_nil row[:processed_at]
		end

		# One walker per run. A retried event must not become a second thread in the
		# same worktree.
		def test_a_run_already_walking_is_never_started_twice
			repo_id = prepared_repo
			run_id = create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1)
			sup = FakeSupervisor.new
			sup.define_singleton_method(:running?) { |id| id == run_id }
			p, = sweeping_poller(sup: sup)
			p.dispatch

			assert_empty sup.started
		end

		def test_an_event_that_keeps_raising_dies_rather_than_retrying_forever
			repo_id = prepared_repo
			create_run(repo_id: repo_id, subject_number: 1, status: 'blocked')
			pending_event(repo_id, 1)
			sup = FakeSupervisor.new
			def sup.start(*) = raise(Mill::Error, 'nope')
			p, = sweeping_poller(sup: sup)
			(Mill::Poller::MAX_EVENT_ATTEMPTS + 1).times { p.dispatch }
			row = db[:events].where(gh_node_id: 'IC_99').first

			assert_equal 'dead', row[:state]
			assert_match(/nope/, row[:last_error])
		end
	end
end
```

Add to `FakeSupervisor`:

```ruby
			def start(run_id, **kwargs)
				@started << run_id
				(@answers ||= {})[run_id] = kwargs[:answers]
			end

			def answers_for(run_id) = (@answers || {})[run_id]

			def running?(_run_id) = false
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb -n /dispatch|resume|event/`
Expected: FAIL — `undefined method 'dispatch'`.

- [ ] **Step 3: Write dispatch**

Add to `lib/mill/poller.rb`, and change `#tick` to call it after `sweep`:

```ruby
		MAX_EVENT_ATTEMPTS = 3

		# Board Status decides what a comment is. While an item is Blocked, every
		# comment on it is an answer and none of them starts a run — otherwise your
		# answer tries to start a second run, the uniqueness index refuses it, the
		# event retries until it dies, and the blocked run waits for an answer that
		# already arrived.
		# The cap binds here too. Ten answers arriving at once would otherwise start
		# ten route walks, because a blocked run is not counted as running until its
		# own thread says so.
		def dispatch
			@db[:events].where(kind: 'comment', state: 'pending').order(:id).each do |event|
				break if @supervisor.at_cap?

				handle(event)
			end
		end

		private

		# Marked processed, committed, and only then is the thread spawned — never
		# inside the same transaction.
		#
		# A thread started inside an open transaction writes to the same SQLite file
		# from another connection while this one still holds the write lock, so
		# either the thread or the commit raises SQLITE_BUSY. If the commit is what
		# raises, the event rolls back to pending while the thread it already
		# spawned keeps running, and the next dispatch starts a second thread on the
		# same run. Two agents in one worktree, reached from inside the check built
		# to prevent it.
		#
		# Marking first would drop the answer if `start` then failed, which is what
		# the design's same-transaction rule exists to stop. `fail_event` is the
		# compensation: it puts the event back to pending, so the answer survives a
		# failed start and is retried. `running?` is what stops a retry becoming a
		# second walker.
		def handle(event)
			payload = JSON.parse(event[:payload_json].to_s, symbolize_names: true)
			run = blocked_run_for(event[:repo_id], payload)

			return no_route(event) if run.nil?
			return if @supervisor.running?(run[:id])

			finish_event(event, 'processed')
			@supervisor.start(run[:id], answers: [payload[:body].to_s])
		rescue StandardError => e
			fail_event(event, e)
		end

		def blocked_run_for(repo_id, payload)
			@db[:runs].where(repo_id: repo_id, subject_kind: payload[:subject_kind].to_s,
				subject_number: payload[:subject_number], status: 'blocked').first
		end

		# Only two of the five triggers have a route: the `mill:` marker, review
		# comments and red checks all need the iterate route, which does not exist.
		# Recorded and logged rather than dropped, so Plan 5 can see what it missed.
		def no_route(event)
			warn "no route for comment event #{event[:gh_node_id]}"
			finish_event(event, 'no_route')
		end

		def finish_event(event, state)
			@db[:events].where(id: event[:id]).update(state: state, processed_at: Mill.now)
		end

		def fail_event(event, error)
			attempts = event[:attempts].to_i + 1
			state = attempts >= MAX_EVENT_ATTEMPTS ? 'dead' : 'pending'
			@db[:events].where(id: event[:id]).update(attempts: attempts, state: state,
				last_error: "#{error.class}: #{error.message}"[0, 300],
				processed_at: state == 'dead' ? Mill.now : nil)
		end
```

Change `#tick`:

```ruby
		def tick
			@board.redrive
			reconcile
			sweep
			dispatch
		end
```

`Mill::Supervisor#start` gains the answers, so update it in `lib/mill/supervisor.rb`:

```ruby
		def start(run_id, walker: nil, answers: [])
			walk = walker || ->(id) { walk(id, answers: answers) }
```

and:

```ruby
		def walk(run_id, answers: [])
			run = Mill::Run.adopt(run_id, answers: answers, db: @db)
			run.on_identity = ->(pgid) { @own_pgids << pgid }
			run.call
			@db[:runs].where(id: run_id).first
		end
```

Add `require 'json'` to the top of `lib/mill/poller.rb`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_poller.rb`
Expected: PASS, 23 runs.

- [ ] **Step 5: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/poller.rb lib/mill/supervisor.rb test/mill/test_poller.rb
git commit -m "A comment on a blocked item is an answer, and resumes its run"
```

---

### Task 12: `Mill::Workers`, and a Roda host for them

Both loops live in the Puma process. Each is wrapped in a supervising loop that logs the exception
and restarts the thread with backoff, and each writes a heartbeat so `GET /` can report an error
when either goes stale. `MILL_WORKERS=off` starts neither, which is what makes editing the web
layer safe: a stray `Ready` on the board must not launch a real run against a real repo while
somebody is changing a template.

**Files:**
- Create: `lib/mill/workers.rb`
- Create: `test/mill/test_workers.rb`
- Create: `app.rb`
- Create: `config.ru`
- Create: `config/puma.rb`
- Modify: `lib/mill.rb`
- Modify: `Gemfile` — add `rackup` and `rack-test` where `rack-test` is not already present

**Interfaces:**
- Consumes: `Mill::Poller#tick`, `Mill::Supervisor#reap`.
- Produces: `Mill::Workers.new(poller:, supervisor:, interval:)` with `#start`, `#stop`,
  `#health -> Hash`, `#backoff(failures)`, and `Mill::Workers.enabled?`. `App.workers` and
  `GET /`. Task 13's doctor reads nothing from here; Plan 4 mounts routes beside it.
- **One supervisor per process.** `Mill::Workers` builds it and hands the same instance to
  `Mill::Poller`. It is the only object that knows which process groups mill spawned and which runs
  have a live thread, so a second instance answers "none" to both — and a reaper that believes no
  run has a thread and no group is mill's kills every healthy stage it finds, about thirty seconds
  into every run. `Mill::Poller` therefore takes `supervisor:` as a required keyword and never
  builds one.

- [ ] **Step 1: Write the failing test**

Create `test/mill/test_workers.rb`:

```ruby
require 'test_helper'
require 'rack/test'
require_relative '../../app'

module Mill
	class TestWorkers < Minitest::Test
		include Rack::Test::Methods

		def app = App.freeze.app

		def teardown
			ENV.delete('MILL_WORKERS')
			@workers&.stop
		end

		# A stray Ready on the board must not launch a real run while somebody is
		# editing a template.
		def test_workers_are_off_when_the_environment_says_so
			ENV['MILL_WORKERS'] = 'off'

			refute Mill::Workers.enabled?
		end

		def test_workers_are_on_by_default
			ENV.delete('MILL_WORKERS')

			assert Mill::Workers.enabled?
		end

		def test_each_loop_ticks_and_heartbeats
			ticks = Queue.new
			@workers = Mill::Workers.new(poller: ->{ ticks << :tick }, supervisor: ->{ }, interval: 0.01)
			@workers.start
			ticks.pop

			sleep 0.05 until @workers.health[:poller][:at]

			refute_nil @workers.health[:poller][:at]
		end

		# A thread that raises must come back, or the factory silently stops.
		def test_a_raising_loop_is_restarted
			calls = Queue.new
			first = true
			@workers = Mill::Workers.new(interval: 0.01, supervisor: ->{ },
				poller: lambda {
					calls << :call
					next unless first

					first = false
					raise 'boom'
				})
			@workers.start
			3.times { calls.pop }

			assert @workers.health[:poller][:alive]
		end

		def test_the_root_route_reports_worker_health
			get '/'

			assert last_response.ok?
			assert_match(/poller/, last_response.body)
		end

		# Requiring app.rb must not start polling a real board.
		def test_loading_the_app_starts_nothing
			refute App.workers.health[:poller][:alive]
		end

		# The cap is in seconds. Applied before the multiplier it was three seconds,
		# so an expired token retried twelve hundred times an hour indefinitely.
		def test_backoff_grows_to_the_stated_ceiling
			workers = Mill::Workers.new(interval: 30, poller: ->{}, supervisor: ->{})

			assert_in_delta 60, workers.send(:backoff, 1)
			assert_in_delta Mill::Workers::MAX_BACKOFF, workers.send(:backoff, 20)
			assert_operator workers.send(:backoff, 20), :>, 60
		end
	end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_workers.rb`
Expected: FAIL — `cannot load such file -- app`.

- [ ] **Step 3: Write `Mill::Workers`**

Create `lib/mill/workers.rb`:

```ruby
module Mill
	# Both loops, inside one process. Each is wrapped in a supervising loop that
	# logs the exception and restarts with backoff — a factory whose poller thread
	# died in the night and left no trace is worse than one that never started.
	#
	# Thread.report_on_exception stays at its default of true.
	class Workers
		DEFAULT_INTERVAL = 30
		MAX_BACKOFF = 300

		def initialize(poller: nil, supervisor: nil, interval: nil, db: Mill.db)
			@db = db
			# One supervisor, shared. It is the only thing holding which process
			# groups mill spawned and which runs have a live thread; a second
			# instance believes there are none of either and reaps healthy stages.
			@shared = Mill::Supervisor.new(db: db)
			@poller = poller
			@supervisor = supervisor
			# Not `.to_f`: an empty or unparseable MILL_POLL_SECONDS would become 0.0
			# and turn the tick into a loop hammering the API as fast as it answers.
			@interval = interval ||
				Mill.setting_float('MILL_POLL_SECONDS', default: DEFAULT_INTERVAL, min: 5, max: 3600)
			@beats = {}
			@threads = {}
			@lock = Mutex.new
			@stopping = false
		end

		def self.enabled? = ENV['MILL_WORKERS'].to_s.downcase != 'off'

		def start
			return self unless self.class.enabled?

			@lock.synchronize do
				@threads[:supervisor] = loop_thread(:supervisor, supervisor_tick)
				@threads[:poller] = loop_thread(:poller, poller_tick)
			end
			self
		end

		def stop
			@stopping = true
			@lock.synchronize do
				@threads.each_value { |t| t&.kill }
				@threads.clear
			end
		end

		# Reads a snapshot of both hashes rather than iterating live ones: this runs
		# in a Puma thread while two worker threads are writing.
		def health
			beats = @lock.synchronize { @beats }
			threads = @lock.synchronize { @threads.dup }
			%i[poller supervisor].to_h do |name|
				[name, (beats[name] || {}).merge(alive: threads[name]&.alive? || false)]
			end
		end

		private

		def poller_tick
			@poller || begin
				poller = Mill::Poller.new(db: @db, supervisor: @shared)
				-> { poller.tick }
			end
		end

		def supervisor_tick
			@supervisor || -> { @shared.reap }
		end

		def loop_thread(name, work)
			Thread.new do
				failures = 0
				until @stopping
					begin
						work.call
						beat(name, nil)
						failures = 0
						sleep @interval
					rescue StandardError => e
						failures += 1
						beat(name, "#{e.class}: #{e.message}")
						warn "#{name} raised: #{e.class}: #{e.message}"
						sleep backoff(failures)
					end
				end
			end
		end

		# The cap is in seconds, and applying it before the multiplier made the real
		# ceiling three seconds rather than five minutes. An expired token would
		# then have retried twelve hundred times an hour, forever.
		def backoff(failures) = [@interval * (2**failures), MAX_BACKOFF].min

		# @beats is written from two worker threads and read from a Puma thread.
		# Replacing the whole hash rather than mutating it in place means a reader
		# never sees it mid-write.
		def beat(name, error)
			@lock.synchronize { @beats = @beats.merge(name => { at: Mill.now, error: error }) }
		end
	end
end
```

Add `require_relative 'mill/workers'` to `lib/mill.rb`, last.

- [ ] **Step 4: Write the host**

Create `app.rb`:

```ruby
# frozen-string-literal: true

require 'bundler'
Bundler.require

require_relative 'lib/mill'

# Plan 4 mounts the run list, the log tail, and the kill switch beside this.
# Plan 3a needs exactly one thing from the web layer: somewhere for the two
# worker threads to live, and a way to tell whether they are still alive.
class App < Roda
	plugin :json

	# Built here, started in config.ru. Starting threads as a side effect of
	# `require` means anything that loads this file — a test, a console, a rake
	# task — silently starts polling a real board.
	def self.workers = @workers ||= Mill::Workers.new

	route do |r|
		r.root do
			{ workers: App.workers.health, runs: Mill.db[:runs].where(status: 'running').count }
		end
	end
end
```

Create `config.ru`:

```ruby
require './app'

App.workers.start

run App.freeze.app
```

Create `config/puma.rb`:

```ruby
# Puma defaults to 0.0.0.0, so mill always binds explicitly. On a laptop the
# loopback interface is the boundary; on a server MILL_BIND names the address the
# reverse proxy talks to, and Plan 4 adds the sign-in that makes that safe.
bind ENV['MILL_BIND'] || 'tcp://127.0.0.1:9494'

# One process: the poller and the supervisor are threads inside it, and a second
# worker process would run a second copy of both.
workers 0
threads 1, 8
```

- [ ] **Step 5: Add the test dependency**

In `Gemfile`, inside the `:development, :test` group, ensure both are present:

```ruby
	gem 'rack-test'
	gem 'rackup'
```

Run `bundle install`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_workers.rb`
Expected: PASS, 5 runs. If `App::WORKERS` starts real threads during the test, set
`ENV['MILL_WORKERS'] = 'off'` at the top of `test/test_helper.rb` alongside `MILL_DB`, and assert
`enabled?` by setting and clearing the variable inside the two tests that check it.

- [ ] **Step 7: Run the whole suite and commit**

```bash
bundle exec rake test
git add lib/mill/workers.rb test/mill/test_workers.rb app.rb config.ru config/puma.rb \
  Gemfile Gemfile.lock lib/mill.rb test/test_helper.rb
git commit -m "Give the two loops a home, and a way to say they are alive"
```

---

### Task 13: Doctor learns the new preconditions

A red doctor blocks everything, and everything this plan added has a way of being quietly wrong: a
secrets file with the wrong mode, a board whose Status options are not the five mill writes, a
clone root that does not exist.

**Files:**
- Modify: `lib/mill/doctor.rb`
- Modify: `test/mill/test_doctor.rb`
- Modify: `docs/reference/setup.md` — extend the section 10 checklist

**Interfaces:**
- Consumes: `Mill::Board`, `Mill::Repo.roots`, `Mill::Secrets`.
- Produces: four more checks in the existing report structure. Read `lib/mill/doctor.rb` and follow
  its existing check shape exactly rather than inventing a second one.

- [ ] **Step 1: Write the failing tests**

Add to `test/mill/test_doctor.rb`, matching the file's existing helper style:

```ruby
	# mill writes five Status values. A board missing one fails the write at the
	# moment it matters rather than at setup.
	def test_the_board_must_carry_every_status_mill_writes
		report = doctor_with_fields([{ id: 'F', name: 'Status',
			options: [{ id: '1', name: 'Ready' }, { id: '2', name: 'Running' }] }])

		assert_includes failures(report).join(' '), 'Blocked'
	end

	def test_a_clone_root_that_does_not_exist_is_named
		ENV['MILL_CLONES'] = '/no/such/place'

		assert_includes failures(doctor).join(' '), '/no/such/place'
	ensure
		ENV.delete('MILL_CLONES')
	end

	def test_a_world_readable_secrets_file_fails
		write_secret('slowernet-rep.env', "A=1\n", mode: 0o644)

		assert_includes failures(doctor).join(' '), 'slowernet-rep.env'
	end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_doctor.rb`
Expected: FAIL on all three.

- [ ] **Step 3: Add the checks**

In `lib/mill/doctor.rb`, following its existing structure, add:

- **Status options.** `Mill::Board::STATUS.values.uniq` must all appear in the project's `Status`
  field options. Name the missing ones.
- **Clone roots.** Every directory in `Mill::Repo.roots` must exist. A root that does not is a
  typo that silently turns into "clone it myself" on every repo.
- **Secrets modes.** Every file in `~/.mill/secrets/` must be mode `0600`. Name each that is not.
- **Bind and admin list.** When `MILL_BIND` is set to anything that is not loopback,
  `MILL_ADMIN_EMAILS` must be non-empty. This is the check behind the rule in the design doc's Web
  UI section; the app enforces it at boot in Plan 4, and doctor says so before then.

- [ ] **Step 4: Run the tests, then the suite**

Run: `bundle exec ruby -Ilib -Itest test/mill/test_doctor.rb`, then `bundle exec rake test`
Expected: PASS.

- [ ] **Step 5: Update the runbook checklist and commit**

Add the four checks to the bulleted list under `## 10. Verify` in `docs/reference/setup.md`.

```bash
git add lib/mill/doctor.rb test/mill/test_doctor.rb docs/reference/setup.md
git commit -m "Doctor checks the board's options, the clone roots, and the secrets modes"
```

---

### Task 14: The rehearsal — walk away, come back to a pull request

Everything above is fixture-backed. This is the demonstrable, and it runs against the real board
and the real scratch repo. **The operator runs it**, because it starts a real subprocess with real
credentials against a real repository.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-software-factory-design.md` — the "Where this stands"
  table only
- Modify: `docs/reference/setup.md` — if anything in the runbook turns out to be wrong

**Interfaces:**
- Consumes: everything.
- Produces: a pull request nobody asked for by hand.

- [ ] **Step 1: Reset the scratch repo**

Delete the branch and PR from the last rehearsal, and confirm `1-track-low-stock-items` is not
checked out anywhere:

```bash
cd ~/code/mill-scratch
git switch main
git worktree list
gh pr list --state all
```

- [ ] **Step 2: Confirm doctor is green**

```bash
cd ~/code/mill
MILL_PROJECT=3 MILL_PROJECT_OWNER=slowernet bundle exec rake mill:doctor
```

Expected: every check passes. A red doctor blocks everything; fix it rather than proceeding.

- [ ] **Step 3: Prepare a fresh subject**

Create an issue on `mill-scratch`, run `gh issue develop` against it, commit a spec on the linked
branch under `docs/superpowers/specs/`, and **switch the clone back to `main`**. That last step is
the one the runbook exists to remind you about: `git worktree add` refuses a branch checked out
anywhere.

- [ ] **Step 4: Start mill and release the work**

```bash
MILL_PROJECT=3 MILL_PROJECT_OWNER=slowernet bundle exec puma -C config/puma.rb
```

In the browser, `http://127.0.0.1:9494/` should report both workers alive. Then set the item's
Status to `Ready` on the board and walk away.

- [ ] **Step 5: Confirm the whole loop**

Within roughly twenty minutes, all of these should be true, and each is a separate claim to check
rather than one impression:

- the board shows `Running` while the run is working, and `Done` when it finishes
- a pull request exists on `mill-scratch` that you did not open
- `~/.mill/worktrees/slowernet-mill-scratch/<run-id>/` is gone
- `git worktree list` in the clone shows only the clone itself
- the branch is free
- `~/.mill/logs/<run-id>/` holds one file per attempt
- `sqlite3 ~/.mill/mill.db 'select status, pid, pgid from runs'` shows `done` with both null

- [ ] **Step 6: Rehearse a block and an answer**

Set a second item `Ready` whose spec is deliberately underspecified — omit a validation rule, the
way the spec standard's check 9 describes. Confirm that mill comments its questions on the issue,
that the board shows `Blocked`, that your reply in a comment resumes the run rather than starting a
second one, and that the worktree survived in between.

- [ ] **Step 7: Update "Where this stands" and commit**

Change the `Mill::Poller`, `Mill::Supervisor`, `Board writes, comments` and
`Secrets injection, scoped GH_TOKEN` rows in the design doc's table to what is now true, and record
the rehearsal the way Plan 2's entry does: what it cost, what blocked, and what each block found.

```bash
git add docs/superpowers/specs/2026-08-06-software-factory-design.md docs/reference/setup.md
git commit -m "Set Ready, walk away, come back to a pull request"
```

---

## Self-review

**Spec coverage.** Ingress: the board as queue (Task 5, 9), the poller reconciling rather than
consuming (9), the comment cursor and marker rule (10), who may trigger a run (10), how mill avoids
triggering itself (10), Status decides what a comment is (11). Two of five triggers dispatch, by
decision; the other three are recorded as `no_route` and belong to Plan 5. Setting up and preparing
a repo: Tasks 3 and 4, with secrets in Task 2. Data model: migration 005 (1), board status re-drive
(5), the three reaping branches (8), `events` with attempts and a dead cap (11). Killing and tearing
down: stale locks and the checked-out branch (6), teardown (7), the process group (8). Architecture:
paths (3), process shape (12). Web UI: the boot path only (12) — the routes are Plan 4.

**Deliberately not covered**, and each is in Plan 3b or later: the stall detector, sleep detection,
the settle window, `caffeinate`, retention, the log reaper, repo health marking, and the per-subject
daily run limit. The daily limit needs the `fast` and `iterate` routes to be worth enforcing — one
`plan` run per subject is what the uniqueness index already allows.

**One design correction is folded in** rather than left to be discovered: `pid`, `pid_started_at`
and `host_boot_at` move from `stage_attempts` to `runs`, because the attempt row is inserted when
the attempt ends and reaping needs to identify a process that is still alive. Task 1 explains it in
the migration comment; the design doc's Data model section should be corrected to match when Task
14 updates "Where this stands".

**Placeholders:** none. Every code step carries the code.

**Type consistency:** `Mill::Repo::Result` and `Mill::Supervisor::Blocked` both expose `problem`
and `questions`, which is what lets Task 9 handle either with one branch. `Mill::Board#want` takes
the run's own status string and maps it, so no caller has to know the board's vocabulary.
`Mill::Supervisor#start(run_id, walker:, answers:)` has one signature, used by Task 9 with no
answers and Task 11 with one.

**Interfaces checked against the code rather than remembered**, on 2026-08-19:
`Mill::Spec::Located` (`branch`, `path`, `problem`, `detail`, `found?`, `blocked?`, `questions`),
`Mill::Spawn::Result` and its four identity readers, `Mill::Ledger#charge` and
`MAX_INTERRUPTIONS`, `Mill::Github`'s injected runner and its `trusted_author?` / `own_comment?` /
`comment` methods, `Mill::Git.checked_out_branches` and `worktree_add` / `worktree_remove`, and
`Mill::Stages::ROUTES`. Two shapes are **not** verified and the tasks that use them say so:
`Mill::Doctor`'s internal check structure (Task 13 says to read it and follow it) and the exact
`gh project field-list` payload, which the fixture asserts and a real board should be diffed
against during Task 14.

**An adversarial review of this plan's code, before any of it was written**, found twelve defects
and all twelve are fixed above. Four would have stopped the factory outright and none of them would
have looked like a failure: two `Mill::Supervisor` instances, so the reaper killed every healthy
stage as foreign about thirty seconds in; `interrupt` reading `current_stage`, which `Mill::Runner`
leaves nil for the entire time a stage runs, so the reaper silently charged nothing; `reap`
interrupting without re-entering, stranding the run as `running` with no thread; and `identify`
answering `:ours` for a run with no recorded process, which is its state in all five gaps between
stages. Each of those consumed a concurrency slot permanently, so two of them stopped mill claiming
anything ever again with every check green.

The rest: a run row inserted before its worktree and leaked when the worktree failed; `redrive`
writing a stale Status and then stamping it as confirmed, which is the one thing that would have
made it retry; the comment cursor written but never sent to GitHub, so every tick re-fetched every
comment on every live subject; the scrubber redacting short env values like `DEBUG=true` and
breaking the JSONL log mill parses back; a backoff cap applied before its multiplier, making five
minutes into three seconds; a thread spawned inside a transaction, which on a commit failure gave
one run two walkers; `Board#confirm` rescuing only `Github::Error` while `ids` raised `Mill::Error`
past it and skipped teardown; and `checked_out` rescuing a git failure into "the branch is free",
which is the rescue-into-a-pass the constraints forbid.

Two tests asserted the buggy behaviour and are inverted:
`test_a_run_with_no_recorded_process_is_left_alone` and the interruption-cap test that set
`current_stage` by hand, which production never did.

**One judgement call worth re-examining when 3a has run for a week.** The concurrency cap defaults
to 2 and the poll tick to 30 seconds. Both are guesses. The cap especially: two concurrent Opus
runs on one laptop is a load estimate, not a measurement, and the server may want more.
