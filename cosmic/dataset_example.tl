--- Worked examples for `cosmic.dataset`, shown by `cosmic docs` and run by
--- `cosmic test`.

local Dataset = require("cosmic.dataset")
local Sqlite = require("cosmic.sqlite")

local Example = {}

--- A CSV file as a table, then a question about it as SQL. The columns
--- follow the header, a number is a number, and an empty cell is NULL.
function Example.load()
  local rows = assert(Dataset.read("csv", "type,balance\nsavings,10\nchecking,5\nsavings,2.5\nchecking,\n"))
  local db = assert(Sqlite.memory())
  local made = assert(Dataset.load(db, "accounts", rows))
  print(table.concat(made.columns, ", ")) -- type, balance, _json
  assert(table.concat(made.columns, ",") == "type,balance,_json")
  local totals = assert(Sqlite.text_rows(db,
    "SELECT type, sum(balance) FROM accounts GROUP BY type ORDER BY type"))
  assert(totals[1][1] == "checking" and totals[1][2] == "5")
  assert(totals[2][1] == "savings" and totals[2][2] == "12.5")
  assert(db:close())
end

--- JSON rows carry no column order, so a key one row lacks is NULL there
--- and the columns come in byte order. `_json` holds each whole row.
function Example.read()
  local rows = assert(Dataset.read("json", '[{"id": 1, "type": "a"}, {"id": 2}]'))
  local db = assert(Sqlite.memory())
  local made = assert(Dataset.load(db, "accounts", rows))
  assert(table.concat(made.columns, ",") == "id,type,_json")
  local nulls = assert(Sqlite.rows(db, "SELECT id FROM accounts WHERE type IS NULL"))
  assert(#nulls == 1 and nulls[1][1].integer == 2)
  local format = assert(Dataset.format_of("accounts.jsonl"))
  assert(format == "ndjson")
  assert(db:close())
end

return Example
