# Every row in stage_attempts is exactly one launch, which is what lets the
# invocation number name a log file and a verdict file without ambiguity.
#
# A reviewer that finds something serious strikes the stage it reviewed, and that
# stage has not launched again yet — so the strike is recorded here, on the
# reviewer's own row, rather than as a row for a launch that never happened. A
# phantom row would put an invocation number on a log file nothing ever wrote and
# push the real re-launch one higher.
Sequel.migration do
	change do
		alter_table(:stage_attempts) do
			add_column :struck_stage, String
			add_index %i[run_id struck_stage]
		end
	end
end
