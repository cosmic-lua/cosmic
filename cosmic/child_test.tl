local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local function path_exists(path: string): boolean
  local answer, trouble = Fs.exists(path)
  assert(answer ~= nil, trouble)
  return answer
end

local function temporary(): string
  return (assert(Fs.mkdtemp("cosmic-child-")))
end

local function output(dir: string, name: string): integer, string
  local path = dir .. "/" .. name
  return assert(Fs.open_write(path)), path
end

local function nested_cosmic_environment(): {string:string}
  local environment = Env.all()
  -- These hooks belong to the portable test's outer Cosmic startups. A
  -- nested fixture has no matching FIFO handshake and must not inherit them.
  environment.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  environment.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return environment
end

local function test_start_failure_is_not_exit_127()
  local h, trouble = Child.start({ "/definitely/not/a/cosmic-command" })
  assert(h == nil)
  assert(trouble:find("start:", 1, true))
  local r = assert(Child.run({ "/bin/sh", "-c", "exit 127" }))
  assert(r.code == 127 and not r.ok)
end

local function test_argv_environment_directory_and_file_output()
  local dir = temporary()
  local fd, path = output(dir, "answer")
  local r = assert(Child.run({ "/bin/sh", "-c",
    "printf '%s|%s|%s' \"$1\" \"$2\" \"$WORD\"; pwd", "sh", "a b", "" },
    { cwd = dir, env = { WORD = "value" }, stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok)
  assert(assert(Fs.read(path)) == "a b||value" .. assert(Fs.absolute(dir)) .. "\n")
end

local function test_large_redirect_does_not_depend_on_pipe_capacity()
  local dir = temporary()
  local fd, path = output(dir, "large")
  local r = assert(Child.run({ "/bin/sh", "-c",
    "i=0; while [ $i -lt 10000 ]; do printf 0123456789; i=$((i+1)); done" },
    { stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok and #assert(Fs.read(path)) == 100000)
end

local function test_redirect_source_descriptor_does_not_leak()
  local dir = temporary()
  local fd = assert(Fs.open_write(dir .. "/out"))
  local r = assert(Child.run({ "/bin/sh", "-c",
    "test ! -e /dev/fd/$SOURCE" },
    { env = { SOURCE = tostring(fd) }, stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok)
end

local function test_nonzero_and_signal_status()
  local exited = assert(Child.run({ "/bin/sh", "-c", "exit 23" }))
  assert(exited.code == 23 and exited.signal == nil and not exited.ok)
  local signaled = assert(Child.run({ "/bin/sh", "-c", "kill -TERM $$" }))
  assert(signaled.code == nil and signaled.signal == sys.SIGTERM)
end

local function test_timeout_kills_the_process_group_and_reaps_child()
  local dir = temporary()
  local fd, path = output(dir, "descendant")
  local h = assert(Child.start({ "/bin/sh", "-c",
    "sleep 30 & printf %s $!; wait" },
    { stdout = fd, stderr = fd }))
  local deadline = Time.monotonic_ns() + 1000 * 1000 * 1000
  while assert(Fs.stat(path)).size == 0 and Time.monotonic_ns() < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(assert(Fs.stat(path)).size > 0, "child did not report readiness")
  local r = assert(h:wait(40))
  assert(Fs.close(fd))
  assert(r.timed_out and not r.ok)
  -- A process-group timeout includes descendants. Signal zero would succeed
  -- for a surviving process (or fail with EPERM, not ESRCH).
  local contents = assert(Fs.read(path))
  local pid = math.tointeger((assert(tonumber(contents))))
  assert(pid)
  local alive = sys.kill(pid, 0)
  assert(not alive)
end

local function test_non_group_timeout_returns_graceful_term_status()
  local dir = temporary()
  local ready = dir .. "/ready"
  local h = assert(Child.start({ "/bin/sh", "-c",
    "trap 'exit 19' TERM; printf ready >\"$1\"; while :; do :; done",
    "sh", ready }, { process_group = false }))
  local deadline = Time.monotonic_ns() + 1000 * 1000 * 1000
  while not path_exists(ready) and Time.monotonic_ns() < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(path_exists(ready), "child did not report readiness")
  local r = assert(h:wait(0))
  assert(r.code == 19 and r.signal == nil and r.timed_out)
end

local function test_spawn_validates_fds_and_preserves_cloexec_stdio()
  local dir = temporary()
  local fixture = dir .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
return function(): integer
  Fs.close(11)
  local invalid = Child.start({ "/bin/true" }, { stdout = 11 })
  if invalid then invalid:close(); return 20 end
  assert(Fs.close(0))
  local fd = assert(Fs.open_read("/dev/null"))
  assert(fd == 0)
  local result = assert(Child.run({ "/bin/sh", "-c", "test -e /dev/fd/0" },
    { stdin = fd, process_group = false }))
  return result.ok and 0 or 21
end
]]))
  local executable = assert(Proc.executable())
  local result = assert(Child.run({ executable, fixture },
    { env = nested_cosmic_environment() }))
  assert(result.ok, "descriptor fixture exited " .. tostring(result.code))
end

local function test_run_forwards_parent_cancellation_after_group_cleanup()
  local dir = temporary()
  local ready = dir .. "/ready"
  local descendant_path = dir .. "/descendant"
  local fixture = dir .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
return function(argv: {string}): integer
  local result, trouble = Child.run({ "/bin/sh", "-c",
    "sleep 30 & printf %s $! >\"$1\"; printf ready >\"$2\"; wait",
    "sh", argv[1], argv[2] })
  if not result then error(trouble) end
  local finished = assert(result)
  return finished.code or 1
end
]]))
  local fd, diagnostic = output(dir, "driver.log")
  local executable = assert(Proc.executable())
  local driver = assert(Child.start({ executable, fixture,
    descendant_path, ready },
    { env = nested_cosmic_environment(), stdout = fd, stderr = fd,
      process_group = false }))
  -- The driver is a nested cosmic that compiles its fixture before it
  -- spawns anything; on the checked core, on a loaded runner, that has
  -- taken more than 3 s. The wait ends as soon as it is ready.
  local deadline = Time.monotonic_ns() + 30 * 1000 * 1000 * 1000
  while (not path_exists(ready) or Fs.read(ready) ~= "ready") and
      Time.monotonic_ns() < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(path_exists(ready) and Fs.read(ready) == "ready",
    "driver did not report readiness; log=" .. (Fs.read(diagnostic) or "<none>"))
  assert(driver:stop(sys.SIGTERM))
  local stopped = assert(driver:wait(2000))
  assert(Fs.close(fd))
  assert(stopped.signal == sys.SIGTERM,
    "driver cancellation result code=" .. tostring(stopped.code) ..
    " signal=" .. tostring(stopped.signal) .. " log=" ..
    (Fs.read(diagnostic) or "<none>"))
  local descendant = assert(math.tointeger((assert(tonumber(
    assert(Fs.read(descendant_path)):match("%d+"))))))
  local gone_by = Time.monotonic_ns() + 1000 * 1000 * 1000
  while sys.kill(descendant, 0) and Time.monotonic_ns() < gone_by do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(not sys.kill(descendant, 0))
end

local function test_invalid_inputs_do_not_poison_signal_guard()
  assert(not pcall(Child.run, { "/bin/sh" }, { stdout = "bad" } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh\0bad" }))
  assert(not pcall(Child.run, { "/bin/sh" }, { cwd = "/tmp\0bad" } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { env = { ["BAD=NAME"] = "value" } } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { env = { NAME = "value\0tail" } } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { stdout = 2147483648 } as Child.Options))
  assert(not pcall(sys.kill, 2147483648, 0))
  assert(not pcall(sys.waitpid, 2147483648, true))
  local result = assert(Child.run({ "/bin/sh", "-c", "exit 0" }))
  assert(result.ok)
end

--- Successful public child operations always fill the error slot.
local function test_success_results_carry_empty_errors()
  local result, run_trouble = Child.run({ "/bin/sh", "-c", "exit 0" })
  assert(result ~= nil and run_trouble == "")

  local first, start_trouble = Child.start({ "/bin/sh", "-c", "exit 0" })
  assert(first ~= nil and start_trouble == "")
  local waited, wait_trouble = first:wait()
  assert(waited ~= nil and wait_trouble == "")

  local second = assert(Child.start({ "/bin/sh", "-c", "sleep 0.05" }))
  local polled, poll_trouble = second:try_wait()
  assert(polled ~= nil and poll_trouble == "")
  if not polled.finished then
    assert(second:wait())
  end
end

local function test_captures_stdout_and_stderr_apart()
  local r = assert(Child.run({ "/bin/sh", "-c", "printf out; printf err >&2; exit 3" },
    { stdout = "capture", stderr = "capture" }))
  assert(r.code == 3 and not r.ok)
  assert(r.stdout == "out" and r.stderr == "err")
  assert(r.captured[1] == "out" and r.captured[2] == "err")
  assert(not r.truncated)
end

local function test_stderr_can_share_captured_stdout()
  local r = assert(Child.run({ "/bin/sh", "-c", "printf a; printf b >&2; printf c" },
    { stdout = "capture", stderr = "stdout" }))
  assert(r.ok and r.stdout == "abc" and r.stderr == nil)
end

local function test_input_and_output_both_larger_than_a_pipe()
  local input = string.rep("0123456789abcdef", 64 * 1024)
  local r = assert(Child.run({ "/bin/cat" }, { input = input, stdout = "capture" }))
  assert(r.ok and r.stdout == input)
end

local function test_empty_input_is_end_of_file()
  local r = assert(Child.run({ "/bin/cat" }, { input = "", stdout = "capture" }))
  assert(r.ok and r.stdout == "")
end

local function test_a_child_that_stops_reading_ends_the_input_quietly()
  local r = assert(Child.run({ "/bin/sh", "-c", "exit 0" },
    { input = string.rep("x", 1024 * 1024) }))
  assert(r.ok)
end

local function test_capture_keeps_the_newest_bytes_past_the_limit()
  local r = assert(Child.run({ "/bin/sh", "-c",
    "i=0; while [ $i -lt 1000 ]; do printf 0123456789; i=$((i+1)); done; printf END" },
    { stdout = "capture", capture_limit = 100 }))
  assert(r.ok and r.truncated)
  local kept = assert(r.stdout)
  assert(#kept == 100 and kept:sub(-3) == "END")
end

local function test_null_streams()
  local r = assert(Child.run({ "/bin/sh", "-c", "cat; printf gone; printf gone >&2" },
    { stdin = "null", stdout = "null", stderr = "null" }))
  assert(r.ok and r.stdout == nil)
end

local function test_more_descriptors_by_number()
  local dir = temporary()
  local fd, path = output(dir, "five")
  local r = assert(Child.run({ "/bin/sh", "-c",
    "printf report >&3; printf five >&5; test ! -e /dev/fd/4" },
    { fds = { [3] = "capture", [5] = fd }, stdout = "capture" }))
  assert(Fs.close(fd))
  assert(r.ok, "code " .. tostring(r.code))
  assert(r.captured[3] == "report" and r.stdout == "")
  assert(assert(Fs.read(path)) == "five")
end

local function test_stdin_pipe_belongs_to_the_caller()
  local h = assert(Child.start({ "/bin/cat" }, { stdin = "pipe", stdout = "capture" }))
  assert(h.stdin ~= nil)
  assert(Fs.put(h.stdin as integer, "typed"))
  assert(h:close_stdin())
  assert(not h:close_stdin())
  local r = assert(h:wait(5000))
  assert(r.ok and r.stdout == "typed")
end

local function test_try_wait_services_a_chatty_child()
  local h = assert(Child.start({ "/bin/sh", "-c",
    "i=0; while [ $i -lt 20000 ]; do printf 0123456789; i=$((i+1)); done" },
    { stdout = "capture" }))
  local deadline = Time.monotonic_ns() + 10 * 1000 * 1000 * 1000
  local polled = assert(h:try_wait())
  while not polled.finished and Time.monotonic_ns() < deadline do
    Time.sleep_ns(1000 * 1000)
    polled = assert(h:try_wait())
  end
  assert(polled.finished, "a full pipe stalled the child")
  assert(#polled.result.stdout == 200000)
end

local function test_timeout_keeps_what_was_captured()
  local r = assert(Child.run({ "/bin/sh", "-c", "printf partial; sleep 30" },
    { stdout = "capture", timeout_ms = 200 }))
  assert(r.timed_out and not r.ok and r.stdout == "partial")
end

--- A leader that exits leaves no member of its group behind, and none of
--- them a zombie: a descendant that outlives the leader is ended and
--- reaped before the wait answers.
local function test_exit_ends_and_reaps_what_the_group_left_behind()
  local r = assert(Child.run({ "/bin/sh", "-c", "sleep 30 & printf %s $!" },
    { stdout = "capture", timeout_ms = 5000 }))
  assert(r.ok and not r.timed_out)
  local pid = assert(math.tointeger(tonumber(r.stdout)))
  local alive, _, errno = sys.kill(pid, 0)
  assert(not alive and errno == sys.ESRCH, "descendant " .. tostring(pid) .. " survived")
end

--- Completion is the leader's exit: a descendant that left the group
--- while holding the captured pipe cannot hold the wait open.
local function test_an_escaped_writer_does_not_hold_up_the_wait()
  local started = Time.monotonic_ns()
  local r = assert(Child.run({ "/bin/sh", "-c",
    "if command -v setsid >/dev/null; then setsid sleep 3 & fi; printf done" },
    { stdout = "capture", timeout_ms = 10000 }))
  assert(r.ok and assert(r.stdout):sub(1, 4) == "done")
  assert(Time.monotonic_ns() - started < 2 * 1000 * 1000 * 1000)
end

local function test_wait_any_returns_the_first_to_finish()
  local slow = assert(Child.start({ "/bin/sh", "-c", "sleep 5" }))
  local fast = assert(Child.start({ "/bin/sh", "-c", "printf quick" },
    { stdout = "capture" }))
  local first = assert(Child.wait_any({ slow, fast }, 5000))
  assert(first == fast)
  local r = assert(fast:wait())
  assert(r.ok and r.stdout == "quick")
  local none, trouble = Child.wait_any({ slow }, 0)
  assert(none == nil and trouble == "")
  assert(slow:close())
end

local function test_options_are_validated()
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "capture" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { stdout = "stdout" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "null", input = "x" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { fds = { [2] = 1 } } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { fds = { [256] = 1 } } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { capture_limit = 0 } as Child.Options))
end
