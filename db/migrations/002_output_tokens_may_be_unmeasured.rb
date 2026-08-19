# The stream carries no running output-token total, so an attempt killed before
# its result line has no honest figure to record. NULL means unmeasured; 0 would
# make every reaped attempt look free. See the stage contract in the design doc.
Sequel.migration do
	up do
		alter_table(:stage_attempts) do
			set_column_allow_null :tokens_out
			set_column_default :tokens_out, nil
		end
	end

	down do
		from(:stage_attempts).where(tokens_out: nil).update(tokens_out: 0)
		alter_table(:stage_attempts) do
			set_column_not_null :tokens_out
			set_column_default :tokens_out, 0
		end
	end
end
