--- The rebuild lock between processes, as two runs in one checkout meet
--- it: another process of this program holds or asks for it, the way a
--- tool from before the flock does (its SQLite half alone) or the way
--- this one does ([`rebuild_lock.take`]), and a child a holder hands it
--- to goes on under it. A process's own fcntl locks never conflict with
--- one another, and closing any descriptor of the file drops them, so
--- these ask from another process, this program running a chunk; those
--- where `cosmic test`, or a write of the projection, takes it are
--- build/rebuild_lock_tool_test.tl's, and the rest
--- `rebuild_lock_test.tl`'s.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")

--- The program itself, which holds the lock against this process,
--- started only to run a chunk (`lua`).
Test.needs{ lua = true }

--- Asks for the lock of the tree at the first `%q` as a tool from
--- before the flock does, and prints "held" or "busy". A holder keeps
--- it for the `%d` milliseconds, or until its standard input ends when
--- that is negative.
local old_tool = [[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local db = assert(Sqlite.open(%q .. "/o/rebuild.lock", true))
assert(db:exec("PRAGMA busy_timeout = 0"))
if not db:exec("BEGIN IMMEDIATE") then
  print("busy")
  return
end
print("held")
local hold_ms = %d
if hold_ms < 0 then Fs.take(Fs.stdin, 1) else Time.sleep_ns(hold_ms * 1000000) end
]]

--- The same, as this tool does.
local new_tool = [[
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local taken = require("build.rebuild_lock").take(%q, 0)
print(taken)
if taken ~= "held" then return end
local hold_ms = %d
if hold_ms < 0 then Fs.take(Fs.stdin, 1) else Time.sleep_ns(hold_ms * 1000000) end
]]

--- Asks once for the flock of the lock file of the tree at `%q`, as a
--- run taking the lock asks first, and prints "taken" or "refused".
local probe = [[
local sys = require("cosmic.sys")
local fd = assert(sys.open(%q .. "/o/rebuild.lock", sys.O_RDWR, 0))
print(sys.flock(fd, "exclusive") and "taken" or "refused")
]]

--- A process of this program running `script` against the tree at
--- `root`, holding what it takes for `hold_ms` (until its standard input
--- ends, by default), and the first line it printed.
local function start(script: string, root: string, hold_ms?: integer): Child.Handle, string
  local started = this_program.program({ "-e", script:format(root, hold_ms or -1) },
    { stdin = "pipe", stdout = "stream" })
  local child = assert(Child.start(started.argv, started.options))
  local line, trouble = Stream.lines(child.stdout_stream as Stream.Reader):read()
  assert(line ~= nil, trouble)
  return child, line
end

--- Lets `child` go and waits for it to exit.
local function finish(child: Child.Handle)
  assert(child:close_stdin())
  local result = assert(child:wait(30000))
  assert(result.ok, result.stderr)
end

--- What `probe` printed.
local function probed(root: string): string
  local child, said = start(probe, root)
  finish(child)
  return said
end

local function tree(tmp: string): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  return root
end

--- A tool from before the flock takes only the SQLite half, an fcntl
--- lock: this tool still waits for it, letting its own flock go when it
--- gives up, and keeps that tool out once it holds the lock itself.
local function test_a_tool_holding_only_the_sqlite_lock_is_excluded(tmp: string)
  local root = tree(tmp)
  local old, said = start(old_tool, root)
  assert(said == "held", said)
  local taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  taken, trouble = rebuild_lock.take(root, 50)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  finish(old)
  local other, other_said = start(new_tool, root)
  finish(other)
  assert(other_said == "held", "a run kept out still holds the lock: " .. other_said)
  taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "held", tostring(taken) .. " " .. trouble)
  local late, late_said = start(old_tool, root)
  finish(late)
  local flock = probed(root)
  rebuild_lock.release()
  assert(late_said == "busy", "a tool from before the flock took the lock " ..
    "this one held")
  assert(flock == "refused", "the holder does not hold the flock")
  assert(probed(root) == "taken", "the flock outlived the release")
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

--- A run waiting for the lock takes it once its holder lets go, of
--- either kind, before the wait is out.
local function test_a_waiting_run_takes_the_lock_once_let_go(tmp: string)
  local root = tree(tmp)
  for _, script in ipairs({ old_tool, new_tool }) do
    local holder, said = start(script, root, 1000)
    assert(said == "held", said)
    local started_ns = Time.monotonic_ns()
    local taken, trouble = rebuild_lock.take(root, 30000)
    local waited_ms = (Time.monotonic_ns() - started_ns) // 1000000
    rebuild_lock.release()
    finish(holder)
    assert(taken == "held", tostring(taken) .. " " .. trouble)
    assert(waited_ms >= 100, "took a held lock after " .. tostring(waited_ms) .. " ms")
  end
end

--- Waits up to 20 s for `holds` to answer true, checking every 20 ms,
--- and answers true once it has.
local function await(what: string, holds: function(): boolean): boolean
  local deadline = Time.monotonic_ns() + 20 * 1000000000
  while not holds() do
    assert(Time.monotonic_ns() < deadline, "gave up waiting for " .. what)
    assert(sys.nanosleep(20 * 1000000))
  end
  return true
end

--- Asks for the lock of the tree at the first `%q` by [`rebuild_lock.hold`]
--- as the role `%q`, and prints what it answered.
local holding = [[
local held, trouble = require("build.rebuild_lock").hold(%q, %q, "probe")
print(tostring(held) .. " " .. trouble)
]]

--- A process asking for the lock by `hold` as `role`, with the lock of
--- `root` handed to it, its stdout and stderr to `output`.
local function start_handed(root: string, role: string, output: string): Child.Handle
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_REBUILD_LOCK_HANDED = root .. "/./o/rebuild.lock"
  local started = this_program.program({ "-e", holding:format(root, role) },
    { env = env, stdout = fd, stderr = fd, process_group = true })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  return h
end

--- A write of the projection by a child of the lock's holder, handed
--- the lock (as a boot's bridge is by the boot), goes on at once under
--- its parent's hold, which it could never take itself; a `cosmic test`
--- run handed it waits all the same, so a variable a user set, or one
--- left over, never lets two runs of the tests in at once.
local function test_a_handed_lock_lets_a_write_on_but_not_a_test_run(tmp: string)
  local root = tree(tmp)
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local write = start_handed(root, "write", tmp .. "/write.out")
  local written, write_trouble = write:wait(20000)
  local test_run = start_handed(root, "test", tmp .. "/test.out")
  local ok, failure = pcall(await, "the test run to wait", function(): boolean
    local text = Fs.read(tmp .. "/test.out") or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local running, _ = test_run:try_wait()
  rebuild_lock.release()
  local ran = assert(test_run:wait(20000))
  local write_text = tostring((Fs.read(tmp .. "/write.out")))
  local test_text = tostring((Fs.read(tmp .. "/test.out")))
  assert(written ~= nil and written.ok, tostring(write_trouble) .. "\n" .. write_text)
  assert(write_text == "false \n", write_text)
  assert(ok, tostring(failure) .. "\n" .. test_text)
  assert(running ~= nil and not running.finished, "a handed test run went on:\n" .. test_text)
  assert(ran.ok and test_text:find("\ntrue \n$"), test_text)
end
