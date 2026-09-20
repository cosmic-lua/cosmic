--- Checks that release, changed-basis, and sanitized contexts stay distinct.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

return function(argv: {string}): integer
  local database, counter = argv[1], argv[2]
  assert(database ~= nil and counter ~= nil,
    "usage: verify_runtime_verdicts.tl DATABASE COUNTER")
  local db = assert(Sqlite.open(database, false))
  local keys = assert(Sqlite.text_rows(db,
    "SELECT key FROM verdicts ORDER BY key"))
  assert(db:close())
  local text = assert(Fs.read(counter))
  local lines: {string} = {}
  local distinct: {string:boolean} = {}
  for line in text:gmatch("([^\n]+)\n?") do
    lines[#lines + 1] = line
    distinct[line] = true
  end
  local distinct_count = 0
  for _ in pairs(distinct) do distinct_count = distinct_count + 1 end
  assert(#keys == 3 and #lines == 3 and distinct_count == 3,
    "identity fixture: expected three distinct runtime verdicts")
  return 0
end
