require 'test_helper'
require 'tmpdir'
require 'fileutils'

module Mill
	# No network and no real ~/.mill: MILL_HOME points at a tmpdir throughout.
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

		# A '=' in a value is ordinary in a connection string, and splitting on
		# every one of them would truncate it silently.
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

		# The runbook tells you to chmod this file. A mode drift is otherwise
		# silent, and these values reach a subprocess environment.
		def test_refuses_a_world_readable_secrets_file
			write_secret('slowernet-rep.env', "A=1\n", mode: 0o644)

			error = assert_raises(Mill::Error) { Mill::Secrets.for_repo('slowernet', 'rep') }

			assert_match(/expected 600/, error.message)
		end

		# Only the stages that push carry the token. Handing it to `implement`
		# would put a credential inside the widest ruleset mill has.
		def test_only_the_pushing_stages_carry_the_token
			write_secret('stage-token', "ghp_exampleexampleexample\n")

			assert_equal 'ghp_exampleexampleexample', Mill::Rules.env_for('pr')['GH_TOKEN']
			assert_nil Mill::Rules.env_for('implement')['GH_TOKEN']
		end

		def test_the_repo_environment_reaches_a_stage
			write_secret('slowernet-rep.env', "API_KEY=abc123\n")

			env = Mill::Rules.env_for('implement', owner: 'slowernet', name: 'rep')

			assert_equal 'abc123', env['API_KEY']
		end

		# A path is not a secret, so SSL_CERT_FILE must not be scrubbed out of
		# every log line that happens to mention it.
		def test_only_real_secrets_are_offered_to_the_scrubber
			write_secret('slowernet-rep.env', "API_KEY=abcdefghijklmnopqrst\n")
			write_secret('stage-token', "ghp_exampleexampleexample\n")

			values = Mill::Secrets.values_for('pr', owner: 'slowernet', name: 'rep')

			assert_includes values, 'abcdefghijklmnopqrst'
			assert_includes values, 'ghp_exampleexampleexample'
			refute(values.any? { |v| v.include?('cert') })
		end

		# The scrubber does a literal gsub on every line of a stream-json log that
		# mill parses back. A short value redacts far more than itself: DEBUG=true
		# turns "success":true into "success":[redacted], which stops being JSON,
		# and the stage is then charged a strike for mill's own scrubber.
		def test_a_short_value_is_never_offered_to_the_scrubber
			write_secret('slowernet-rep.env',
				"RAILS_ENV=test\nDEBUG=true\nAPI_KEY=abcdefghijklmnopqrst\n")

			values = Mill::Secrets.values_for('implement', owner: 'slowernet', name: 'rep')

			assert_equal ['abcdefghijklmnopqrst'], values
		end

		# It still reaches the stage. Not redacting it is a decision about the log,
		# not about the environment.
		def test_a_short_value_still_reaches_the_stage
			write_secret('slowernet-rep.env', "RAILS_ENV=test\n")

			assert_equal 'test',
				Mill::Rules.env_for('implement', owner: 'slowernet', name: 'rep')['RAILS_ENV']
		end

		def test_a_world_readable_token_is_refused
			write_secret('stage-token', "ghp_exampleexampleexample\n", mode: 0o644)

			assert_raises(Mill::Error) { Mill::Secrets.token }
		end

		def test_an_empty_token_file_is_no_token
			write_secret('stage-token', "\n")

			assert_nil Mill::Secrets.token
		end
	end
end
