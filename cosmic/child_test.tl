local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local observations = require("build.filesystem_observations")

-- What these tests start is a shell, the system's own, or this very
-- program, which its launcher runs on the core it runs on.
local program: {string} = { (assert(Proc.executable())) }
local launched, _ = Proc.relaunch()
if launched ~= nil then program[#program + 1] = launched.argv[1] end
observations.confine({ reads = program })

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

--- A bare name is not looked for on PATH, and the failure says so and
--- names what finds it; a path that is not there gets no such hint.
local function test_a_bare_name_not_found_points_at_proc_find()
  local dir = temporary()
  local _, trouble = Child.run({ "cosmic-no-such-program" }, { cwd = dir })
  assert(trouble:find("with no PATH search; " ..
    "Proc.find(\"cosmic-no-such-program\") answers", 1, true) ~= nil, trouble)
  local _, pathed = Child.run({ dir .. "/cosmic-no-such-program" })
  assert(pathed:find("Proc.find(", 1, true) == nil, pathed)
  -- A missing directory, or a script whose interpreter is missing, fails
  -- with the same ENOENT; the name is not what is missing there.
  local _, no_dir = Child.run({ "ls" }, { cwd = dir .. "/not-here" })
  assert(no_dir:find("Proc.find(", 1, true) == nil, no_dir)
  assert(Fs.write(dir .. "/script", "#!/cosmic/no/such/interpreter\n"))
  assert(sys.chmod(dir .. "/script", 0x1c0))
  local _, script = Child.run({ "script" }, { cwd = dir })
  assert(script ~= "" and script:find("Proc.find(", 1, true) == nil, script)
  local _, empty = Child.run({ "" }, { cwd = dir })
  assert(empty:find("Proc.find(", 1, true) == nil, empty)
  assert(Fs.remove_tree(dir))
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

--- A caller writing to a `stdin = "pipe"` child that has gone gets
--- EPIPE, not SIGPIPE: the write fails and this process lives on. Run
--- in a relaunched process, since one that already ignores SIGPIPE (a
--- test runner that fed some child `input`) has no case to show.
local function test_writing_to_a_gone_stdin_pipe_fails_instead_of_ending(tmp: string)
  local relaunch = Proc.relaunch()
  if relaunch == nil then return end -- a native start has nothing to relaunch
  local script = tmp .. "/writes.tl"
  assert(Fs.write(script, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
return function(): integer
  -- The child closes its end of the pipe and lingers; writing a chunk
  -- past what the pipe holds meets the closed end whenever it closes.
  local h = assert(Child.start({ "/bin/sh", "-c", "exec 0<&-; sleep 5" },
    { stdin = "pipe" }))
  local chunk = string.rep("x", 1 << 20)
  local ok, trouble = true, ""
  for _ = 1, 8 do
    ok, trouble = Fs.put(h.stdin as integer, chunk)
    if not ok then break end
  end
  print(tostring(ok) .. " " .. trouble)
  local _, _ = h:stop()
  return 0
end
]]))
  local argv: {string} = {}
  for i, value in ipairs(relaunch.argv) do argv[i] = value end
  argv[#argv + 1] = script
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local fds: {integer:integer | string} = {}
  for number, fd in pairs(relaunch.fds) do fds[number] = fd end
  local r = assert(Child.run(argv, { env = env, fds = fds, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(r.signal == nil and r.ok, "ended by signal " .. tostring(r.signal) .. ": " ..
    tostring(r.stderr))
  assert(assert(r.stdout):find("^false "), r.stdout)
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
  local first, first_trouble = Child.wait_any({ slow, fast }, 5000)
  assert(first == fast, first_trouble)
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

local function test_start_refuses_a_timeout_it_would_not_honour()
  local ok, message = pcall(Child.start, { "/bin/sh", "-c", "exit 0" },
    { timeout_ms = 10 } as Child.Options)
  assert(not ok)
  assert(tostring(message):find("h:wait", 1, true), tostring(message))
  local r = assert(Child.run({ "/bin/sh", "-c", "exit 0" }, { timeout_ms = 10000 }))
  assert(r.ok)
end

local function test_guard_is_one_at_a_time_and_closes_once()
  local guard = assert(Child.guard())
  local second, trouble = Child.guard()
  assert(second == nil and trouble ~= "")
  local r, run_trouble = Child.run({ "/bin/sh", "-c", "exit 0" })
  assert(r == nil and run_trouble:find("signal guard: ", 1, true), run_trouble)
  assert(guard:cancelled() == 0)
  assert(guard:close())
  assert(guard:close())
  assert(guard:cancelled() == 0)
  local again = assert(Child.guard())
  assert(again:close())
end

--- A caught signal ends a wait, timed or not, and the child with it:
--- `wait(0)` is how a caller ends a child whose time is up, and a
--- signal caught first must not leave that child running. The signal
--- stays with the guard however many waits see it, and ends the
--- process when the guard closes. The guard lives in a nested cosmic:
--- closing it delivers SIGTERM to whatever process holds it.
local function test_guard_keeps_a_signal_and_delivers_it_on_close()
  local dir = temporary()
  local report = dir .. "/report"
  local fixture = dir .. "/guarded.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  do
    local guard <close> = assert(Child.guard())
    local timed = assert(Child.start({ "/bin/sh", "-c", "sleep 30" }))
    local untimed = assert(Child.start({ "/bin/sh", "-c", "sleep 30" }))
    local done = assert(Child.start({ "/bin/sh", "-c", "exit 3" }))
    -- Until `done` has exited: Linux shows it as a zombie in /proc;
    -- elsewhere, half a second is ample for `exit 3`.
    local stat_path = "/proc/" .. tostring(done.pid) .. "/stat"
    local on_proc = Fs.read(stat_path) ~= nil
    local by = Time.monotonic_ns() + (on_proc and 5000 or 500) * 1000 * 1000
    local zombie = false
    while not zombie and Time.monotonic_ns() < by do
      Time.sleep_ns(20 * 1000 * 1000)
      local stat = Fs.read(stat_path)
      zombie = stat ~= nil and stat:match("^%d+ %b() Z") ~= nil
    end
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    local answers: {string} = {}
    for _, wait in ipairs({ function(): Child.Result | nil, string return timed:wait(0) end,
        function(): Child.Result | nil, string return untimed:wait() end }) do
      local r, trouble = wait()
      answers[#answers + 1] = tostring(r == nil) .. " " .. trouble
    end
    answers[#answers + 1] = tostring(not sys.kill(timed.pid, 0))
    answers[#answers + 1] = tostring(not sys.kill(untimed.pid, 0))
    local later, _ = timed:wait()
    answers[#answers + 1] = tostring(later ~= nil)
    local finished = assert(done:wait())
    answers[#answers + 1] = tostring(finished.code) .. " " .. tostring(finished.timed_out)
    answers[#answers + 1] = tostring(guard:cancelled())
    assert(Fs.write(argv[1], table.concat(answers, "|")))
  end
  return 0
end
]]))
  local r = assert(Child.run({ assert(Proc.executable()), fixture, report },
    { env = nested_cosmic_environment(), stderr = "capture", timeout_ms = 30000 }))
  local cancelled = "true cancelled by signal " .. tostring(sys.SIGTERM)
  local expected = table.concat({ cancelled, cancelled, "true", "true", "true",
    "3 false", tostring(sys.SIGTERM) }, "|")
  local got = Fs.read(report)
  assert(got == expected, tostring(got) .. " " .. tostring(r.stderr))
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end

local function test_guard_release_with_nothing_caught_answers_zero()
  local guard = assert(Child.guard())
  local caught, trouble = guard:release()
  assert(caught == 0 and trouble == "", tostring(caught) .. " " .. trouble)
  assert(guard:release() == 0)
  assert(guard:close())
  local again = assert(Child.guard())
  assert(again:close())
end

--- A released guard hands its signal back rather than delivering it,
--- and a later close -- here the `<close>` scope's -- delivers nothing
--- either. The nested cosmic outlives the SIGTERM it sent itself.
local function test_guard_release_keeps_the_signal_from_close()
  local dir = temporary()
  local report = dir .. "/report"
  local fixture = dir .. "/released.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  do
    local guard <close> = assert(Child.guard())
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    answers[#answers + 1] = tostring(guard:cancelled())
    answers[#answers + 1] = tostring((guard:release()))
    answers[#answers + 1] = tostring((guard:release()))
    answers[#answers + 1] = tostring((guard:close()))
  end
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local r = assert(Child.run({ assert(Proc.executable()), fixture, report },
    { env = nested_cosmic_environment(), stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, term, term, "true" }, "|"), tostring(got))
end

--- A guard keeps taking signals after its first: a SIGTERM after a
--- Ctrl-C the child handled is what a supervisor must pass on next,
--- and release answers the latest rather than losing it. The nested
--- cosmic outlives both.
local function test_guard_release_answers_the_latest_signal()
  local dir = temporary()
  local report = dir .. "/report"
  local fixture = dir .. "/latest.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  answers[#answers + 1] = tostring(guard:cancelled())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:cancelled())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring((guard:release()))
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local r = assert(Child.run({ assert(Proc.executable()), fixture, report },
    { env = nested_cosmic_environment(), stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local int, term = tostring(sys.SIGINT), tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ int, term, term }, "|"), tostring(got))
end

--- A signal this process ignores -- `cosmic test &` from a script, whose
--- shell ignores SIGINT for it -- is not the guard's to catch.
local function test_guard_leaves_an_ignored_signal_ignored()
  local dir = temporary()
  local report = dir .. "/report"
  local fixture = dir .. "/ignoring.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local caught = guard:cancelled()
  assert(guard:close())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  assert(Fs.write(argv[1], tostring(caught)))
  return 0
end
]]))
  local r = assert(Child.run({ "/bin/sh", "-c", "trap '' INT; exec \"$0\" \"$@\"",
    assert(Proc.executable()), fixture, report },
    { env = nested_cosmic_environment(), stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local got = Fs.read(report)
  assert(got == "0", tostring(got))
end
