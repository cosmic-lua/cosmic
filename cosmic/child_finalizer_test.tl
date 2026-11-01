--- A [`Child.Handle`] dropped unclosed is ended and reaped by its finalizer
--- when collected, and a held stdout reader keeps it until it is dropped
--- too. Apart from cosmic/child_test.tl because these read /proc, which
--- the module's `requires` names: the rest of that file runs everywhere.

local Test = require("cosmic.test")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Clock = require("cosmic.clock")
local Stream = require("cosmic.stream")

--- `/bin/sleep` is a host program, which the profile "system" gives; /proc says whether a pid is
--- still running or an unreaped zombie.
Test.policy{
  profiles = { "system", "proc" },
  requires = { "proc" },
}

--- The state letter of `pid` in /proc, or nil where the process is gone
--- (reaped). "Z" is a zombie: ended but not reaped.
local function process_state(pid: integer): string?
  local stat = Fs.read("/proc/" .. tostring(pid) .. "/stat")
  if stat == nil then return nil end
  return stat:match("^%d+ %b() (%a)")
end

--- Whether `pid` is gone, reaped and not a zombie, within a short
--- deadline: SIGKILL reaches the process at once, but the kernel finishes
--- its exit asynchronously.
local function gone_soon(pid: integer): boolean
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  while process_state(pid) ~= nil do
    if Clock.monotonic_ns() > deadline then return false end
    Clock.sleep_ns(Clock.ms(5))
  end
  return true
end

--- Starts a `sleep` and drops the handle unclosed, so no local holds it.
--- Returns the pid, and the reader of its stdout where `keep_stream`.
local function drop_a_sleeper(keep_stream: boolean): integer, Stream.Reader?
  local h = assert(Child.start({ "/bin/sleep", "30" }, { stdout = "stream" }))
  local pid = h.pid
  if keep_stream then return pid, h.stdout_stream end
  return pid, nil
end

--- A handle collected without a close ends and reaps its child. Without
--- the finalizer the child would run on its 30 seconds and then linger as
--- a zombie.
local function test_a_dropped_unclosed_handle_ends_and_reaps_its_child()
  local pid = drop_a_sleeper(false)
  collectgarbage("collect")
  collectgarbage("collect")
  assert(gone_soon(pid), "the child outlived its collected handle: " .. tostring(process_state(pid)))
end

--- A reader of the child's stdout keeps the handle reachable: the child
--- runs until the reader is dropped too, and is then ended and reaped.
local function test_a_held_stdout_stream_keeps_the_child_until_it_is_dropped()
  local pid, reader = drop_a_sleeper(true)
  collectgarbage("collect")
  collectgarbage("collect")
  local state = process_state(pid)
  assert(state ~= nil and state ~= "Z", "the reader's handle was collected while it was held: " .. tostring(state))
  assert(reader ~= nil)
  reader = nil
  collectgarbage("collect")
  collectgarbage("collect")
  assert(gone_soon(pid), "the child outlived its dropped reader: " .. tostring(process_state(pid)))
end
