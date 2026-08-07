#!/usr/bin/env cosmic
-- Regressions for the cosmic.child I/O layer (child_io.pump): stdin is fed
-- concurrently with stdout/stderr draining so no direction deadlocks, a child
-- that stops reading stdin cannot SIGPIPE-kill the parent, and run()/wait()
-- capture both output streams plus the exit status.
local check = require("cosmic.check")
local child = require("cosmic.child")
local childio = require("cosmic.child.io")
local fs = require("cosmic.fs")
local signal = require("cosmic.signal")
-- cosmo.unix is required directly only to monkey-patch unix.pipe for fault
-- injection (test_spawn_pipe_failure_cleans_up), which must share the exact
-- module table that child.tl uses.
local unix = require("cosmo.unix")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")

local function test_first_start_keeps_installed_sigpipe_handler()
  -- Must run before any other spawn in this file: SIGPIPE neutralization
  -- decides at the FIRST start(), not at require, and only claims the
  -- default disposition — a handler installed before that spawn stays
  -- installed. The inherited disposition is not asserted: ignored
  -- signals survive exec, so a test child spawned by the build harness
  -- (itself a cosmic.child user) already arrives with SIGPIPE ignored.
  local function handler(_sig: integer) end
  unix.sigaction(unix.SIGPIPE, handler)
  local r = check.must(child.run({lua_bin, "-e", "os.exit(0)"}))
  assert(r.ok, "spawn should succeed")
  assert(unix.sigaction(unix.SIGPIPE) == handler,
    "first start() clobbered the installed SIGPIPE handler")
  -- Hand the rest of the file the disposition the lazy install would have
  -- chosen from the default: ignored, so the EPIPE tests below stay safe.
  unix.sigaction(unix.SIGPIPE, unix.SIG_IGN)
end
test_first_start_keeps_installed_sigpipe_handler()

local function test_large_stdin_no_deadlock()
  -- 256KB of stdin far exceeds the pipe buffer, and the child echoes it back,
  -- so both directions overflow at once. The pump interleaves the write with
  -- draining stdout, so neither side blocks.
  local big = string.rep("z", 262144)
  local r = check.must(child.run({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = big}),
    "run should succeed")
  assert(r.ok, "command should succeed")
  assert(#r.stdout == #big, "expected " .. #big .. " bytes echoed, got " .. #r.stdout)
  assert(r.stdout == big, "echoed stdin should match input")
end
test_large_stdin_no_deadlock()

local function test_stdin_to_early_exiting_child_no_sigpipe()
  -- The child exits immediately without reading stdin, closing its read end.
  -- Feeding a large stdin then hits a broken pipe: SIGPIPE is ignored, so the
  -- write fails with EPIPE and the run completes with the child's exit code.
  local big = string.rep("q", 262144)
  local r = check.must(child.run({lua_bin, "-e", "os.exit(3)"}, {stdin = big}),
    "run should succeed")
  assert(r.code == 3, "expected exit code 3 from early-exiting child, got " .. tostring(r.code))
end
test_stdin_to_early_exiting_child_no_sigpipe()

local function test_run_captures_both_streams()
  local r = check.must(child.run({lua_bin, "-e", [[
    io.write("on stdout")
    io.flush()
    io.stderr:write("on stderr")
    io.stderr:flush()
    os.exit(7)
  ]]}), "run should succeed")
  assert(r.stdout == "on stdout", "expected stdout 'on stdout', got '" .. tostring(r.stdout) .. "'")
  assert(r.stderr == "on stderr", "expected stderr 'on stderr', got '" .. tostring(r.stderr) .. "'")
  assert(r.code == 7, "expected exit code 7, got " .. tostring(r.code))
  assert(r.signal == nil, "a normal exit has no signal")
end
test_run_captures_both_streams()

local function test_run_reports_signal_death()
  -- The child SIGKILLs itself; the Result reports the signal (not a fake exit)
  -- and leaves `code` nil.
  local r = check.must(child.run({lua_bin, "-e", [[
    local unix = require("cosmo.unix")
    unix.kill(unix.getpid(), unix.SIGKILL)
  ]]}), "run should succeed")
  assert(r.code == nil, "signal death has no exit code, got " .. tostring(r.code))
  assert(r.signal == signal.SIGKILL, "expected SIGKILL, got " .. tostring(r.signal))
  assert(r.ok == false, "signal death is not ok")
end
test_run_reports_signal_death()

local function test_large_stdin_with_output_no_deadlock()
  -- Large stdin AND large stdout at once: the child reads all of stdin and
  -- writes twice as much to stdout. The pump must interleave write and reads.
  local big = string.rep("m", 200000)
  local r = check.must(child.run({lua_bin, "-e", [[
    local data = io.read("*a")
    io.write(data)
    io.write(data)
  ]]}, {stdin = big}), "run should succeed")
  assert(r.code == 0, "expected exit 0, got " .. tostring(r.code))
  assert(#r.stdout == 2 * #big, "expected " .. (2 * #big) .. " bytes, got " .. #r.stdout)
  assert(r.stderr == "", "expected empty stderr, got " .. #r.stderr .. " bytes")
end
test_large_stdin_with_output_no_deadlock()

local function test_spawn_pipe_failure_cleans_up()
  -- Monkey-patch unix.pipe to fail, as the fork-failure test does for fork.
  -- spawn() must unwind cleanly and return an error, not leak fds or crash.
  local real_pipe = rawget(unix, "pipe")
  rawset(unix, "pipe", function(): number, number return nil, nil end)
  local handle, err = child.start({lua_bin, "-e", "print('x')"})
  rawset(unix, "pipe", real_pipe)
  assert(handle == nil, "expected nil handle on pipe failure, got: " .. tostring(handle))
  assert(type(err) == "string" and err:find("pipe", 1, true),
    "expected a 'pipe' error, got: " .. tostring(err))
end
test_spawn_pipe_failure_cleans_up()

local function test_spawn_exec_status_read_failure()
  -- A non-EINTR failure reading the exec-status pipe (childio.read_retry
  -- returning nil + an error) used to be indistinguishable from EOF —
  -- misread as "exec succeeded". It must surface as a spawn error instead.
  -- cwd forces the fork path: only it uses the exec-status pipe.
  local real_read_retry = childio.read_retry
  childio.read_retry = function(_fd: integer, _bufsiz: integer): string, string
    return nil, "read: EIO: Input/output error"
  end
  local handle, err = child.start({lua_bin, "-e", "print('x')"}, {cwd = "."})
  childio.read_retry = real_read_retry
  assert(handle == nil, "expected nil handle when the exec-status read fails")
  assert(err ~= nil and err:find("EIO", 1, true),
    "expected the read failure's errno to surface, got: " .. tostring(err))
end
test_spawn_exec_status_read_failure()

local function test_wait_reports_io_error()
  -- state.io_err (set by the pump on a read/write/poll failure) must land
  -- in Result and force ok=false. There is no portable way to force a
  -- genuine mid-pump I/O failure, so this injects the (documented
  -- internal) state directly, the same way test_spawn_pipe_failure_cleans_up
  -- injects a pipe failure above.
  local h = check.must(child.start({lua_bin, "-e", "os.exit(0)"}))
  h._st.io_err = "read: EIO: Input/output error"
  local r = check.must(h:wait())
  assert(r.ok == false, "a Result with an io_error must not be ok")
  assert(r.io_error == "read: EIO: Input/output error",
    "expected io_error to surface, got: " .. tostring(r.io_error))
end
test_wait_reports_io_error()
