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
