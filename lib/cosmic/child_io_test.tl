#!/usr/bin/env cosmic
-- Regressions for the cosmic.child I/O layer (child_io.pump): stdin is fed
-- concurrently with stdout/stderr draining so no direction deadlocks, a child
-- that stops reading stdin cannot SIGPIPE-kill the parent, and communicate()
-- captures both output streams plus the exit status.
local child = require("cosmic.child")
local fs = require("cosmic.fs")
-- cosmo.unix is required directly only to monkey-patch unix.pipe for fault
-- injection (test_spawn_pipe_failure_cleans_up), which must share the exact
-- module table that child.tl uses, and to send a signal from a child payload.
local unix = require("cosmo.unix")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")

local function test_large_stdin_no_deadlock()
  -- 256KB of stdin far exceeds the pipe buffer, and the child echoes it back,
  -- so both directions overflow at once. Before the pump fix, spawn() wrote
  -- stdin synchronously and blocked once the buffer filled while nobody was
  -- draining stdout -- deadlock.
  local big = string.rep("z", 262144)
  local handle = child.spawn({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = big})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out = (handle as child.Handle):read()
  assert(ok, "command should succeed")
  assert(#out == #big, "expected " .. #big .. " bytes echoed, got " .. #out)
  assert(out == big, "echoed stdin should match input")
end
test_large_stdin_no_deadlock()

local function test_stdin_to_early_exiting_child_no_sigpipe()
  -- The child exits immediately without reading stdin, closing its read end.
  -- Feeding a large stdin then hits a broken pipe: before SIGPIPE was ignored
  -- this SIGPIPE-killed the parent (this test process). It must instead
  -- complete cleanly and report the child's exit code.
  local big = string.rep("q", 262144)
  local handle = child.spawn({lua_bin, "-e", "os.exit(3)"}, {stdin = big})
  assert(handle ~= nil, "handle should not be nil")
  local _, _, code = (handle as child.Handle):communicate()
  assert(code == 3, "expected exit code 3 from early-exiting child, got " .. tostring(code))
end
test_stdin_to_early_exiting_child_no_sigpipe()

local function test_communicate_captures_both_streams()
  local handle = child.spawn({lua_bin, "-e", [[
    io.write("on stdout")
    io.flush()
    io.stderr:write("on stderr")
    io.stderr:flush()
    os.exit(7)
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local out, err_out, code, err = (handle as child.Handle):communicate()
  assert(out == "on stdout", "expected stdout 'on stdout', got '" .. tostring(out) .. "'")
  assert(err_out == "on stderr", "expected stderr 'on stderr', got '" .. tostring(err_out) .. "'")
  assert(code == 7, "expected exit code 7, got " .. tostring(code))
  assert(err == nil, "expected no error on a normal exit, got " .. tostring(err))
end
test_communicate_captures_both_streams()

local function test_communicate_reports_signal_death()
  -- SIGKILL the child; communicate() surfaces the signal as its error and a
  -- -1 exit code rather than pretending the process exited normally.
  local handle = child.spawn({lua_bin, "-e", [[
    local unix = require("cosmo.unix")
    unix.kill(unix.getpid(), unix.SIGKILL)
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local _, _, code, err = (handle as child.Handle):communicate()
  assert(code == -1, "expected -1 exit code for signal death, got " .. tostring(code))
  assert(err ~= nil and err:find("signal"), "expected a signal error, got " .. tostring(err))
end
test_communicate_reports_signal_death()

local function test_large_stdin_with_output_no_deadlock()
  -- Large stdin AND large stdout at the same time: the child reads all of
  -- stdin and writes twice as much to stdout. The pump must interleave the
  -- write and both reads.
  local big = string.rep("m", 200000)
  local handle = child.spawn({lua_bin, "-e", [[
    local data = io.read("*a")
    io.write(data)
    io.write(data)
  ]]}, {stdin = big})
  assert(handle ~= nil, "handle should not be nil")
  local out, err_out, code = (handle as child.Handle):communicate()
  assert(code == 0, "expected exit 0, got " .. tostring(code))
  assert(#out == 2 * #big, "expected " .. (2 * #big) .. " bytes, got " .. #out)
  assert(err_out == "", "expected empty stderr, got " .. #err_out .. " bytes")
end
test_large_stdin_with_output_no_deadlock()

local function test_spawn_pipe_failure_cleans_up()
  -- Monkey-patch unix.pipe to fail, as the fork-failure test does for fork.
  -- spawn() must unwind cleanly and return an error, not leak fds or crash.
  local real_pipe = rawget(unix, "pipe")
  rawset(unix, "pipe", function(): number, number return nil, nil end)
  local handle, err = child.spawn({lua_bin, "-e", "print('x')"})
  rawset(unix, "pipe", real_pipe)
  assert(handle == nil, "expected nil handle on pipe failure, got: " .. tostring(handle))
  assert(type(err) == "string" and err:find("pipe", 1, true),
    "expected a 'pipe' error, got: " .. tostring(err))
end
test_spawn_pipe_failure_cleans_up()
