--- An attached database another process holds locked is waited for
--- (core/store.c's store_wait), rather than read as unreadable.
local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
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

--- A process that holds `path` locked against readers until its stdin
--- closes, then `hold_ns` more.
local function holder(path: string, hold_ns: integer): Child.Handle
  local command = Test.cosmic({ "-e", ([[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("BEGIN EXCLUSIVE; INSERT INTO t VALUES ('held')"))
print("held")
local _, _ = Fs.take(Fs.stdin, 1)
assert(Clock.sleep(%d))
assert(db:exec("COMMIT"))
assert(db:close())
]]):format(path, hold_ns) }, { timeout_ns = Child.FOREVER, stdin = "stream", stdout = "stream", stderr = "capture" })
  local child = assert(Child.start(command.argv, command.options))
  assert(line_of(Stream.lines(assert(child.stdout_stream))) == "held")
  return child
end

local function test_a_locked_attached_database_is_waited_for(tmp: string)
  local path = tmp .. "/locked.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:close())
  assert(Store.attach(path, { unchecked_bytecode = true }))
  local attached = Array.at(Store.databases(), 1)
  local child = holder(path, Clock.ms(200))
  local begun = Clock.monotonic_ns()
  assert(assert(child.stdin_stream):close())
  local row = assert(attached:one("SELECT count(*) FROM t"))
  assert(row:integer(1) == 1, "read the holder's commit")
  assert(Clock.monotonic_ns() - begun >= Clock.ms(100), "waited for the lock")
  assert(assert(child:wait(Clock.seconds(5))).ok)
end
