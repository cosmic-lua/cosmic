--- The retry of a busy cache is by SQLite's captured codes, and it waits out a real holder: a separate process
--- opens the cache with [`build.shared_sqlite`] while this one holds the whole file, and gets it once this one lets go.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local _ = require("build.shared_sqlite") -- the child loads it

Test.policy{ profiles = { "cosmic" } }

-- TODO: test that the retry follows SQLite's captured codes and not the words of its reasons, as a child once did by
-- replacing [`Sqlite.text_rows_result`] with one that answered a busy or a locked code in other words (and an unrelated
-- error that held the word "busy"), once a test can make SQLite answer so without replacing a field of the library's table.
local function test_a_busy_cache_is_opened_once_its_holder_lets_go(tmp: string)
  local path = tmp .. "/cache.db"
  local seed = assert(Sqlite.open(path, { writable = true }))
  assert(seed:exec("CREATE TABLE kept (x); INSERT INTO kept VALUES (1)"))
  assert(seed:close())
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("BEGIN EXCLUSIVE"))
  local script = [[
local Sqlite = require("cosmic.sqlite")
local shared_sqlite = require("build.shared_sqlite")
local path = ...
if path == nil then return 2 end
local db, trouble = shared_sqlite.open(path, function(_: Sqlite.Handle): boolean, string
  return true, ""
end, 5000000000)
if db == nil then
  print(trouble)
  return 1
end
print("opened")
assert(db:close())
return 0
]]
  local command = this_program.program({ "-e", script, path },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(20) })
  local child = assert(Child.start(command.argv, command.options))
  -- It is waiting on the holder, not failing: it has not finished a quarter of a second in.
  assert(Clock.sleep_ns(Clock.ms(250)))
  assert(not assert(child:try_wait()).finished, "the open did not wait for the holder")
  assert(holder:exec("COMMIT"))
  assert(holder:close())
  local result = assert(child:wait(Clock.seconds(15)))
  assert(result.ok and result.stdout == "opened\n", tostring(result.stdout) .. tostring(result.stderr))
end
