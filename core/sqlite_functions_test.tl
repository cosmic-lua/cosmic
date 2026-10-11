--- The SQL functions the core's SQLite is built with beyond its
--- defaults: each must be callable from a fresh connection, with no
--- loading step.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" } }

--- The one row `sql` yields, each value as SQLite's text.
local function row(sql: string): {string}
  local handle = assert(Sqlite.memory())
  local rows, trouble = Sqlite.text_rows(handle, sql)
  handle:close()
  assert(rows ~= nil, trouble)
  assert(#rows == 1, sql .. ": expected one row, got " .. #rows)
  return rows[1]
end

local function test_math_functions_are_built_in()
  local got = row("SELECT sqrt(16), pow(2, 10), floor(-1.5), ceil(1.2), " ..
      "ln(1), log10(1000), log2(8), round(pi(), 5), mod(7, 3), trunc(-2.7), acosh(1), " ..
      "sqrt(-1) IS NULL, ln(0) IS NULL")
  local want = { "4.0", "1024.0", "-2.0", "2.0", "0.0", "3.0", "3.0", "3.14159", "1.0",
    "-2.0", "0.0", "1", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_percentile_aggregates_are_built_in()
  local values = "(SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 10)"
  local got = row("SELECT median(x), percentile(x, 50), percentile_cont(x, 0.25), " ..
      "percentile_disc(x, 0.5) FROM " .. values)
  local want = { "2.5", "2.5", "1.75", "2.0" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end
