require 'json'
require 'set'

module Mill
	# Consumes stream-json a line at a time as Mill::Claude tees it, so a killed
	# attempt keeps whatever it had. Shapes verified against real CLI output,
	# 2026-08-19.
	class Stream
		TOKEN_FIELDS = {
			tokens_in: 'input_tokens',
			tokens_out: 'output_tokens',
			cache_creation_tokens: 'cache_creation_input_tokens',
			cache_read_tokens: 'cache_read_input_tokens'
		}.freeze

		attr_reader :session_id, :model, :last_output_at, :pending_tool_at,
			:rate_limited_at, :result, :raw_verdict, :structured_verdict, :permission_denials

		def initialize(clock: -> { Mill::Clock.awake })
			@clock = clock
			@counted = {}				# message id => usage, deduped
			@pending = {}				# tool_use id => when it started
			@permission_denials = []
			@final_usage = nil
		end

		# The silence clock is stamped before the parse, not after. A line that
		# arrives is output whatever it contains, and a stage emitting a banner or
		# a partial line would otherwise read as silent and be killed as wedged.
		def consume(line)
			@last_output_at = @clock.call
			msg = JSON.parse(line, symbolize_names: true)
			@session_id ||= msg[:session_id]

			case msg[:type]
			when 'system' then on_system(msg)
			when 'assistant' then on_assistant(msg)
			when 'user' then on_user(msg)
			when 'rate_limit_event' then on_rate_limit(msg)
			when 'result' then on_result(msg)
			end

			msg
		rescue JSON::ParserError, EncodingError
			nil		# a partial or mis-encoded line is not a failure
		end

		# What mill validates: the parsed structured output when the CLI produced
		# one, and the final message otherwise.
		def verdict_payload = @structured_verdict || @raw_verdict

		# The four counts the design requires. Cache reads dominated fresh input
		# 7182:3 in the spike, so recording only in/out understates flow by ~99%.
		#
		# Before the result line arrives only three of them are trustworthy.
		# Measured across four real runs, summed per-message output_tokens came to
		# 13, 15, 37, and 16 where the result line reported 356, 361, 786, and 645
		# — the stream carries no running output total, and thinking-token events
		# do not account for the gap. Input and cache counts matched exactly.
		# So a killed attempt reports tokens_out as nil (unmeasured) rather than a
		# number that is wrong by more than an order of magnitude.
		def tokens
			return usage_to_tokens(@final_usage) if @final_usage

			partial = TOKEN_FIELDS.keys.to_h { |field| [field, 0] }
			@counted.each_value { |usage| usage_to_tokens(usage).each { |k, v| partial[k] += v } }
			partial.merge(tokens_out: nil)
		end

		# False while only per-message usage has been seen, so a caller never
		# mistakes an unmeasured attempt for a cheap one.
		def tokens_complete? = !@final_usage.nil?

		def rate_limited? = !@rate_limited_at.nil?

		# True while a command is outstanding. The stall detector suspends its
		# silence window here: a stage running a six-minute test suite emits
		# nothing and would otherwise look identical to a wedged one.
		def tool_pending? = !@pending.empty?

		def finished? = !@result.nil?

		def error? = @result ? !!@result[:is_error] : false

		private

		def on_system(msg)
			@model ||= msg[:model]
			@permission_denials << msg if msg[:subtype] == 'permission_denied'
		end

		# Usage repeats on every content block of a message, not once per message:
		# five blocks sharing one id each report the same output_tokens. Summing
		# blindly overcounts by the block count, so dedupe on message id.
		def on_assistant(msg)
			message = msg[:message] or return
			@counted[message[:id]] = message[:usage] if message[:id] && message[:usage]

			# content is a string on simple messages, not always a list of blocks.
			blocks(message[:content]).each do |block|
				@pending[block[:id]] = @clock.call if block[:type] == 'tool_use' && block[:id]
			end
			refresh_pending
		end

		def on_user(msg)
			blocks(msg.dig(:message, :content)).each do |block|
				@pending.delete(block[:tool_use_id]) if block[:type] == 'tool_result'
			end
			refresh_pending
		end

		# Most rate_limit_events are heartbeats: every one observed in the spike
		# carried status "allowed". Stamping on all of them would make every
		# attempt look throttled and exempt it from its own deadlines — and so
		# would leaving the stamp in place once the limit lifts, which is why an
		# "allowed" event clears it. A stage throttled at minute 2 and wedged at
		# minute 20 must still be reaped.
		def on_rate_limit(msg)
			status = msg.dig(:rate_limit_info, :status)
			return if status.nil?

			@rate_limited_at = status == 'allowed' ? nil : @clock.call
		end

		# With `--json-schema` the CLI returns the verdict already parsed, in
		# `structured_output`. `result` still carries the same object as a string;
		# mill prefers the parsed one and keeps the string for the log.
		def on_result(msg)
			@result = msg
			@final_usage = msg[:usage] if msg[:usage]
			@raw_verdict = msg[:result]
			@structured_verdict = msg[:structured_output]
		end

		def blocks(content) = content.is_a?(Array) ? content.select { |b| b.is_a?(Hash) } : []

		def refresh_pending = @pending_tool_at = @pending.values.min

		def usage_to_tokens(usage)
			TOKEN_FIELDS.transform_values { |field| usage[field.to_sym].to_i }
		end
	end
end
