--- The retry keeps SQLite's captured codes authoritative even if the
--- diagnostic wording changes. A separate Lua process supplies real
--- SQLite failures before loading the cache module, whose binding stays
--- held, and changes their diagnostics independently of their codes.
local Child = require("cosmic.child")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

local this_program = require("build.this_program")
local _ = require("build.shared_sqlite") -- the child loads it after installing its observer

Test.needs{ lua = true }

local function classified(tmp: string, scenario: string)
  local path = tmp .. "/cache.db"
  local seed = assert(Sqlite.open(path, { writable = true }))
  assert(seed:exec("CREATE TABLE kept (x); INSERT INTO kept VALUES (1)"))
  assert(seed:close())
  local script = ([[
local Sqlite = require("cosmic.sqlite")
local query = Sqlite.text_rows_result
local scenario, path = %q, %q
local calls = 0
local holder
if scenario == "busy" then
  holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("BEGIN EXCLUSIVE"))
end
Sqlite.text_rows_result = function(db, sql, values)
  calls = calls + 1
  if scenario == "error" then
    local result = query(db, "SELECT * FROM busy_missing_table")
    assert(result.rows == nil and result.code ~= Sqlite.BUSY and result.code ~= Sqlite.LOCKED)
    return result
  end
  if calls == 1 and scenario == "locked" then
    local reader = assert(db:prepare("SELECT * FROM kept"))
    assert(reader:step() == "row")
    local result = query(db, "DROP TABLE kept")
    reader:finalize()
    assert(result.rows == nil and result.code == Sqlite.LOCKED)
    result.reason = "a reader prevents this operation"
    return result
  end
  local result = query(db, sql, values)
  if calls == 1 and scenario == "busy" then
    assert(result.rows == nil and result.code == Sqlite.BUSY)
    assert(holder:exec("COMMIT"))
    result.reason = "another connection prevents this operation"
  end
  return result
end
local shared_sqlite = require("build.shared_sqlite")
Sqlite.text_rows_result = query
local db, trouble = shared_sqlite.open(path, function() return true, "" end, 500000000)
if scenario == "error" then
  assert(db == nil and trouble:find("busy_missing_table", 1, true), trouble)
  assert(calls == 1, "a diagnostic word caused a retry: " .. calls)
else
  assert(db ~= nil, trouble)
  assert(calls == 2, "the captured code did not cause exactly one retry: " .. calls)
  assert(db:close())
end
if holder then assert(holder:close()) end
]]):format(scenario, path)
  local command = this_program.program({ "-e", script },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(5) })
  local result, trouble = Child.run(command.argv, command.options)
  assert(result ~= nil and result.ok, tostring(trouble) .. (result and result.stderr or ""))
end

local function test_a_real_busy_code_retries_without_english_lock_words(tmp: string)
  classified(tmp, "busy")
end

local function test_a_real_locked_code_retries_without_english_lock_words(tmp: string)
  classified(tmp, "locked")
end

local function test_a_busy_word_in_an_unrelated_error_does_not_retry(tmp: string)
  classified(tmp, "error")
end
