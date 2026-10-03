--- SQLite outcomes against a lock owned by an independent process.
local Child = require("cosmic.child")
local type _ = require("cosmic.fs")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.needs{ lua = true }

local function test_exec_result_reports_busy_then_acquires_after_the_holder_exits(tmp: string)
  local path = tmp .. "/db"
  local script = [[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("BEGIN IMMEDIATE"))
print("held")
Fs.take(Fs.stdin, 1)
assert(db:close())
]]
  local command = this_program.program({ "-e", script:format(path) },
    { stdin = "stream", stdout = "stream", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  assert(Stream.lines(assert(child.stdout_stream)):read() == "held")
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("PRAGMA busy_timeout = 0"))
  local busy = db:exec_result("BEGIN IMMEDIATE")
  assert(busy.code == Sqlite.BUSY and busy.extended_code == Sqlite.BUSY and busy.reason ~= "")
  assert(db:exec("PRAGMA busy_timeout = 1"))
  assert(busy.code == Sqlite.BUSY and busy.reason ~= "", "a later PRAGMA changed the failure")
  assert(assert(child.stdin_stream):close())
  assert(assert(child:wait(Clock.seconds(5))).ok)
  assert(db:exec_result("BEGIN IMMEDIATE").code == Sqlite.OK)
  assert(db:close())
end

local function test_exec_result_rechecks_a_handle_closed_by_a_finalizer()
  -- A separate Lua state keeps collector settings and finalizers apart
  -- from the worker's coverage hook. Vary the step size to reach the
  -- call's allocations across cores without pinning a heap size.
  local script = [[
local Sqlite = require("cosmic.sqlite")
local overlapped = false
for size = 1, 256 do
  collectgarbage("collect")
  collectgarbage("stop")
  local db = assert(Sqlite.memory())
  db:busy_timeout(1000000)
  local during, closed = false, false
  local marker = setmetatable({}, { __gc = function()
    if during then
      assert(db:close())
      closed = true
    end
  end })
  marker = nil
  collectgarbage("incremental")
  collectgarbage("param", "pause", 0)
  collectgarbage("param", "stepmul", 100)
  collectgarbage("param", "stepsize", size)
  collectgarbage("restart")
  during = true
  local ok, result = pcall(db.exec_result, db, "SELECT 1")
  during = false
  if closed and not ok then
    assert(tostring(result):find("database handle is closed", 1, true), tostring(result))
    overlapped = true
  elseif ok then
    assert(result.code == Sqlite.OK and result.extended_code == Sqlite.OK and result.reason == "" and result.cancelled == false)
  else
    error(result)
  end
  db:close()
  if overlapped then break end
end
assert(overlapped, "no finalizer closed the handle during the call")
]]
  local command = this_program.program({ "-e", script }, { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  local result = assert(child:wait(Clock.seconds(5)))
  assert(result.ok, result.stderr)
end

local function test_typed_step_snapshot_survives_a_reentrant_finalizer()
  local script = [[
local Sqlite = require("cosmic.sqlite")
local overlapped = false
for size = 1, 256 do
  collectgarbage("collect")
  collectgarbage("stop")
  local db = assert(Sqlite.memory())
  local statement = assert(db:prepare("SELECT CASE WHEN ?1=1 THEN 1 WHEN ?1=2 THEN abs(-9223372036854775808) ELSE json('bad') END"))
  assert(statement:bind_integer(1, 1))
  assert(statement:step_result() == "row")
  assert(statement:reset())
  assert(statement:bind_integer(1, 0))
  local during, changed = false, false
  local marker = setmetatable({}, { __gc = function()
    if during then
      local _, _ = statement:reset()
      assert(statement:bind_integer(1, 2))
      local inner = statement:step_result()
      assert(type(inner) == "table" and inner.reason == "integer overflow")
      statement:finalize()
      assert(db:exec("SELECT 1"))
      changed = true
    end
  end })
  marker = nil
  collectgarbage("incremental")
  collectgarbage("param", "pause", 0)
  collectgarbage("param", "stepmul", 100)
  collectgarbage("param", "stepsize", size)
  collectgarbage("restart")
  during = true
  local result = statement:step_result()
  during = false
  assert(type(result) == "table" and result.code == 1 and result.extended_code == 1)
  assert(result.reason == "malformed JSON" and result.cancelled == false)
  statement:finalize()
  assert(db:close())
  if changed then overlapped = true; break end
end
assert(overlapped, "no finalizer re-entered during snapshot construction")
]]
  local command = this_program.program({ "-e", script }, { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  local result = assert(child:wait(Clock.seconds(5)))
  assert(result.ok, result.stderr)
end

local function test_typed_steps_allocate_no_result_per_successful_row()
  local script = [[
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.memory())
local statement = assert(db:prepare("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT x FROM n"))
collectgarbage("collect")
collectgarbage("stop")
assert(statement:step_result() == "row")
local before = collectgarbage("count")
for i = 2, 10000 do assert(statement:step_result() == "row") end
local after = collectgarbage("count")
assert(after - before < 1, "typed steps allocated per row: " .. (after-before) .. " KiB")
assert(statement:step_result() == "done")
statement:finalize()
assert(db:close())
]]
  local command = this_program.program({ "-e", script }, { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(command.argv, command.options))
  local result = assert(child:wait(Clock.seconds(5)))
  assert(result.ok, result.stderr)
end
