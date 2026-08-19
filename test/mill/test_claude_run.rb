require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

module Mill
	# The Plan A seam: one launch composed end to end, driven by a fake stage that
	# replays recorded stream-json. Never runs `claude`.
	class TestClaudeRun < Minitest::Test
		# A stand-in stage that echoes back a verdict built from the envelope it was
		# handed, so the nonce round-trip is exercised rather than hardcoded.
		def fake_stage(verdict_overrides = {}, exit_code: 0)
			script = <<~RUBY
				require 'json'
				prompt = ARGV[ARGV.index('-p') + 1]
				stage = prompt[/`stage` is "([^"]+)"/, 1]
				invocation = prompt[/`invocation` is (\\d+)/, 1].to_i
				nonce = prompt[/`nonce` is\\s*\\n?\\s*"([0-9a-f]+)"/, 1]
				verdict = { stage: stage, invocation: invocation, nonce: nonce, status: 'ok' }
					.merge(JSON.parse(#{verdict_overrides.to_json.dump}, symbolize_names: true))
				puts({ type: 'system', subtype: 'init', session_id: 'sess-fake', model: 'claude-opus-5' }.to_json)
				# --json-schema makes the real CLI return the verdict already parsed in
				# structured_output, with the same object as a string in result.
				puts({ type: 'result', subtype: 'success', is_error: false, session_id: 'sess-fake',
					usage: { input_tokens: 5, output_tokens: 356, cache_read_input_tokens: 900,
						cache_creation_input_tokens: 20 },
					result: verdict.to_json, structured_output: verdict }.to_json)
				exit #{exit_code}
			RUBY
			['ruby', '-e', script]
		end

		# Intercepts argv so the fake stage runs in place of `claude`, leaving every
		# other part of the seam — nonce, envelope, spawn, tee, verdict — untouched.
		class Fake < Mill::Claude
			attr_accessor :stand_in, :seen_argv

			def argv(prompt, session_id: nil)
				@seen_argv = super
				# `--` or ruby eats the -p itself as its own loop-mode flag.
				stand_in + ['--', '-p', prompt]
			end
		end

		def setup = @worktree = Dir.mktmpdir('mill-seam')

		def teardown = FileUtils.remove_entry(@worktree)

		def launch(stage, overrides = {}, exit_code: 0, stand_in: nil, **rest)
			claude = Fake.new(stage, home: '/tmp/mill-test')
			claude.stand_in = stand_in || fake_stage(overrides, exit_code: exit_code)
			yield @worktree if block_given?
			attempt = claude.run('Do the thing.', invocation: rest.fetch(:invocation, 1),
				worktree: @worktree, log_path: File.join(@worktree, '.log', 'a.jsonl'))
			[attempt, claude]
		end

		def test_a_launch_produces_a_validated_attempt
			attempt, = launch('triage')

			assert_predicate attempt, :ok?
			assert_equal 'triage', attempt.stage
			assert_equal 'sess-fake', attempt.session_id, 'the session id is what every relaunch resumes'
			assert_equal 'claude-opus-5', attempt.model
			assert_equal 356, attempt.tokens[:tokens_out]
			assert_equal 900, attempt.tokens[:cache_read_tokens]
			assert_empty attempt.errors
		end

		# The nonce reaches the stage only through the prompt, which is what makes a
		# replayed verdict unrepresentable. The schema constrains the shape; it
		# cannot know which launch this is, so the nonce still has to travel.
		def test_the_nonce_travels_in_the_prompt_and_must_come_back
			attempt, claude = launch('triage')
			prompt = claude.seen_argv[claude.seen_argv.index('-p') + 1]

			assert_match(/`nonce` is\s*\n?\s*"#{attempt.nonce}"/, prompt)
			assert_predicate attempt.verdict, :valid?
		end

		def test_two_launches_never_share_a_nonce
			first, = launch('triage')
			second, = launch('triage')

			refute_equal first.nonce, second.nonce
		end

		# A stage that answers with someone else's nonce has not proved it ran.
		def test_a_forged_nonce_fails_the_attempt
			attempt, = launch('triage', { nonce: 'deadbeefdeadbeef' })

			refute_predicate attempt, :ok?
			assert_includes attempt.errors, 'nonce mismatch'
		end

		# Silence is never success: a clean exit with no verdict is still a failure.
		def test_a_stage_that_says_nothing_has_failed
			attempt, = launch('triage', stand_in: ['ruby', '-e', 'exit 0'])

			refute_predicate attempt, :ok?
			assert_match(/no verdict/, attempt.errors.first)
		end

		# An exit code of zero and a well-formed verdict are separate claims, and
		# neither implies the other.
		def test_a_good_verdict_from_a_process_that_died_is_not_ok
			attempt, = launch('triage', {}, exit_code: 3)

			assert_predicate attempt.verdict, :valid?
			refute_predicate attempt, :ok?
			assert_includes attempt.errors, 'stage exited non-zero'
		end

		def test_a_stage_that_cannot_start_is_a_failed_attempt_not_an_exception
			attempt, = launch('triage', stand_in: ['mill-no-such-binary-xyz'])

			refute_predicate attempt, :ok?
			assert_match(/did not start/, attempt.errors.first)
		end

		# The artifact is resolved against the worktree the stage actually ran in.
		def test_the_artifact_is_checked_against_the_worktree
			attempt, = launch('plan', { artifact: 'docs/superpowers/plans/x.md' }) do |worktree|
				FileUtils.mkdir_p(File.join(worktree, 'docs/superpowers/plans'))
				File.write(File.join(worktree, 'docs/superpowers/plans/x.md'), '# a plan')
			end

			assert_predicate attempt, :ok?, attempt.errors.join('; ')

			FileUtils.rm_rf(File.join(@worktree, 'docs'))
			missing, = launch('plan', { artifact: 'docs/superpowers/plans/x.md' })

			refute_predicate missing, :ok?
		end

		def test_a_blocked_stage_is_not_ok_and_carries_its_questions
			attempt, = launch('triage', { status: 'blocked', questions: ['which spec?'] })

			refute_predicate attempt, :ok?
			assert_predicate attempt, :blocked?
			assert_equal ['which spec?'], attempt.verdict.questions
		end

		# The reviewer's severities decide whether the reviewed stage re-runs.
		def test_a_serious_objection_rejects
			attempt, = launch('review:code', { objections: [{ severity: 'HIGH', claim: 'race' }] })

			assert_predicate attempt, :ok?
			assert_predicate attempt, :rejects?
		end

		# The envelope is what the stage is told; the containment flags are what it
		# is held to. Both must be on every launch.
		def test_the_launch_still_carries_every_containment_flag
			_, claude = launch('implement')

			assert_includes claude.seen_argv, '--tools'
			assert_includes claude.seen_argv, '--strict-mcp-config'
			assert_includes claude.seen_argv, '--settings'
			Mill::Claude::BANNED_FLAGS.each { |f| refute_includes claude.seen_argv, f }
		end

		def test_the_log_is_written_where_the_attempt_says_it_is
			attempt, = launch('triage')

			assert_path_exists attempt.log_path
			assert_includes File.read(attempt.log_path), 'sess-fake'
		end
	end
end
