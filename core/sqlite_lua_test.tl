--- SQLite outcomes against a lock owned by an independent process.
local Child = require("cosmic.child")
local type _ = require("cosmic.fs")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

--- The next line of `lines`: raises where they ended or failed.
local function line_of(lines: Stream.Lines): string
  local line, why = lines:read()
  if line == nil then error(tostring(why), 2) end
  if line == false then error("the lines ended", 2) end
  return line
end

Test.policy{ profiles = { "cosmic" } }

local function test_exec_result_reports_busy_then_acquires_after_the_holder_exits(tmp: string)
  local path = tmp .. "/db"
  local script = [[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("BEGIN IMMEDIATE"))
print("held")
local _, _ = Fs.take(Fs.stdin, 1)
assert(db:close())
]]
  local command = Test.cosmic({ "-e", script:format(path) },
    { timeout_ns = Child.FOREVER, stdin = "stream", stdout = "stream", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  assert(line_of(Stream.lines(assert(child.stdout_stream))) == "held")
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("PRAGMA busy_timeout = 0"))
  local busy = db.connection:exec_result("BEGIN IMMEDIATE")
  assert(busy.code == Sqlite.BUSY and busy.extended_code == Sqlite.BUSY and busy.reason ~= "")
  assert(db:exec("PRAGMA busy_timeout = 1"))
  assert(busy.code == Sqlite.BUSY and busy.reason ~= "", "a later PRAGMA changed the failure")
  assert(assert(child.stdin_stream):close())
  assert(assert(child:wait(Clock.seconds(5))).ok)
  assert(db.connection:exec_result("BEGIN IMMEDIATE").code == Sqlite.OK)
  assert(db:close())
end

-- TODO: delete the guards of the SQLite binding that a finalizer re-entering a call exercises (the handle closed, or a
-- statement reset or finalized, by a `__gc` while a step or an exec runs): two cases here attached such a finalizer with
-- `setmetatable`, which a checked program does not have, so no caller can reach them. They wait on D1d's deletion of the
-- guards no checked caller reaches (the ceilings plan).
local function test_typed_steps_allocate_no_result_per_successful_row()
  local script = [[
local Sqlite = require("cosmic.sqlite")

local db = assert(Sqlite.memory())
local statement = assert(db.connection:prepare("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT x FROM n"))
collectgarbage("collect")
collectgarbage("stop")
assert(statement:step_result() == "row")
local before = collectgarbage("count")
for _ = 2, 10000 do assert(statement:step_result() == "row") end
local after = collectgarbage("count")
assert(after - before < 1, "typed steps allocated per row: " .. tostring(after - before) .. " KiB")
assert(statement:step_result() == "done")
statement:finalize()
assert(db:close())
]]
  local command = Test.cosmic({ "-e", script }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  local result = assert(child:wait(Clock.seconds(5)))
  assert(result.ok, result.stderr)
end
