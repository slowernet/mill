# "Invocation" and "attempt" named the same thing. An attempt is one launch of one
# stage — one row, one log, one verdict — and the number is its ordinal within that
# stage. The ledger still counts two separate things; they are attempts and strikes.
Sequel.migration do
	change do
		rename_column :stage_attempts, :invocation, :number
	end
end
