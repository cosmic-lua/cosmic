--- The rebuild lock between processes, as two runs in one checkout meet
--- it: another process of this program holds or asks for it, the way a
--- tool from before the flock does (its SQLite half alone) or the way
--- this one does (`rebuild_lock.take`). The flock and SQLite's fcntl
--- lock only exclude one another across processes, so these start this
--- program; the rest is in `rebuild_lock_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")

--- The program itself, which holds the lock against this process.
Test.needs{ tool = true }

--- Asks for the lock of the tree at `root` as a tool from before the
--- flock does, and prints "held" or "busy". A holder keeps it until its
--- standard input ends.
local old_tool = [[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q .. "/o/rebuild.lock", true))
assert(db:exec("PRAGMA busy_timeout = 0"))
if not db:exec("BEGIN IMMEDIATE") then
  print("busy")
  return
end
print("held")
Fs.take(Fs.stdin, 1)
]]

--- The same, as this tool does.
local new_tool = [[
local Fs = require("cosmic.fs")
local taken = require("build.rebuild_lock").take(%q, 0)
print(taken)
if taken == "held" then
  Fs.take(Fs.stdin, 1)
end
]]

--- A process of this program running `script` against the tree at
--- `root`, and the first line it printed.
local function start(script: string, root: string): Child.Handle, string
  local started = this_program.program({ "-e", script:format(root) },
    { stdin = "pipe", stdout = "stream" })
  local child = assert(Child.start(started.argv, started.options))
  local line, trouble = Stream.lines(child.stdout_stream as Stream.Reader):read()
  assert(line ~= nil, trouble)
  return child, line
end

--- Lets the holder `child` go and waits for it to exit.
local function finish(child: Child.Handle)
  assert(child:close_stdin())
  local result = assert(child:wait(30000))
  assert(result.ok, result.stderr)
end

--- Whether another open of the lock file is refused the flock.
local function flock_refused(root: string): boolean
  local fd = assert(sys.open(root .. "/o/rebuild.lock", sys.O_RDWR, 0))
  local ok, _, _ = sys.flock(fd, "exclusive")
  assert(sys.close(fd))
  return not ok
end

local function tree(tmp: string): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  return root
end

--- A tool from before the flock takes only the SQLite half, which a
--- flock does not see: this tool still waits for it, letting the flock
--- go meanwhile, and keeps it out once it holds the lock itself.
local function test_a_tool_holding_only_the_sqlite_lock_is_excluded(tmp: string)
  local root = tree(tmp)
  local old, said = start(old_tool, root)
  assert(said == "held", said)
  local taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  taken, trouble = rebuild_lock.take(root, 50)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  assert(not flock_refused(root), "a run kept out still holds the flock")
  finish(old)
  taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "held", tostring(taken) .. " " .. trouble)
  local late, late_said = start(old_tool, root)
  finish(late)
  rebuild_lock.release()
  assert(late_said == "busy", "a tool from before the flock took the lock " ..
    "this one held")
end

--- Two runs of this tool exclude one another, whichever holds the lock.
local function test_two_holders_exclude_one_another(tmp: string)
  local root = tree(tmp)
  local other, said = start(new_tool, root)
  assert(said == "held", said)
  local taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  finish(other)
  taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "held", tostring(taken) .. " " .. trouble)
  local late, late_said = start(new_tool, root)
  finish(late)
  rebuild_lock.release()
  assert(late_said == "busy", "another run took the lock this one held")
end
