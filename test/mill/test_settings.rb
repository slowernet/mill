require 'test_helper'

module Mill
	# Settings are parsed, never coerced. `'lots'.to_i` is 0, and a concurrency cap
	# of 0 stops mill claiming anything while every check stays green.
	class TestSettings < Minitest::Test
		def teardown
			ENV.delete('MILL_TEST_N')
			ENV.delete('MILL_TEST_F')
		end

		def test_a_typo_falls_back_rather_than_becoming_zero
			ENV['MILL_TEST_N'] = 'lots'

			assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
		end

		def test_an_empty_value_falls_back
			ENV['MILL_TEST_N'] = '  '

			assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
		end

		def test_a_value_outside_its_range_falls_back
			ENV['MILL_TEST_N'] = '99'

			assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
		end

		def test_zero_is_out_of_range_for_a_cap
			ENV['MILL_TEST_N'] = '0'

			assert_equal 2, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
		end

		def test_a_valid_value_is_used
			ENV['MILL_TEST_N'] = '4'

			assert_equal 4, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 8)
		end

		# Integer('010') is 10 in base 10, not 8. Left to Integer's default base a
		# leading zero would be read as octal.
		def test_a_leading_zero_is_not_octal
			ENV['MILL_TEST_N'] = '010'

			assert_equal 10, Mill.setting_int('MILL_TEST_N', default: 2, min: 1, max: 30)
		end

		def test_an_unset_value_is_the_default
			assert_in_delta 30.0, Mill.setting_float('MILL_TEST_F', default: 30, min: 5, max: 3600)
		end

		def test_a_float_is_parsed_and_ranged
			ENV['MILL_TEST_F'] = '7.5'

			assert_in_delta 7.5, Mill.setting_float('MILL_TEST_F', default: 30, min: 5, max: 3600)
		end

		def test_a_float_typo_falls_back
			ENV['MILL_TEST_F'] = 'soon'

			assert_in_delta 30.0, Mill.setting_float('MILL_TEST_F', default: 30, min: 5, max: 3600)
		end
	end
end
