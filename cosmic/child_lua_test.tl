--- The cases of cosmic.child that start a child only to run Lua in it:
--- each child is this program again, past its launcher, running a chunk
--- (`lua`), where a shell would need the system's. They declare `lua`,
--- not `tool`, so an edit to a module the program carries outside their
--- closure does not run them again, and every child runs an artifact of
--- that closure ([`cosmic.test`]'s `lua`). The cases whose child runs a file
--- of its own, or is sandboxed, are in cosmic/child_tool_test.tl; the
--- cases that start nothing -- a refused option, a refused stream, a
--- guard -- are in cosmic/child_test.tl.

local Child = require("cosmic.child")
local Signal = require("cosmic.signal")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local fixture = require("build.child_lua_fixture")

--- What the tests read: /proc, where a test finds a child's processes;
--- and the program itself, started past its launcher so that no host
--- program is read, only to run Lua (`lua`).
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "/proc", letters = "r" } },
}

local function path_exists(path: string): boolean
  local answer, trouble = Fs.exists(path)
  assert(answer ~= nil, trouble)
  return answer
end

--- The pid, in this process's pid namespace, of the process that `pid`
--- names in the pid namespace of `within`, a live child of this process.
--- It is `pid` unless `within` was started in a pid namespace of its own
--- (a `sandbox` that unveils); then the process is found by the last
--- number of its NSpid, and the result is nil if none matches. A process
--- started without one is in the worker's namespace, sandboxed or not.
local function host_pid(within: integer, pid: integer): integer | nil
  local own, _ = sys.readlink("/proc/self/ns/pid")
  local theirs, _ = sys.readlink("/proc/" .. tostring(within) .. "/ns/pid")
  if theirs == nil or theirs == own then return pid end
  local names = assert(Fs.list("/proc"))
  for _, name in ipairs(names) do
    local number = math.tointeger(tonumber(name:match("^%d+$")))
    if number ~= nil and sys.readlink("/proc/" .. name .. "/ns/pid") == theirs then
      local status = Fs.read("/proc/" .. name .. "/status") or ""
      local nspid = status:match("\nNSpid:([^\n]*)") or ""
      if tonumber(nspid:match("(%d+)%s*$")) == pid then return number end
    end
  end
  return nil
end

local function output(dir: string, name: string): integer, string
  local path = dir .. "/" .. name
  return assert(Fs.open_write(path)), path
end

--- Chunk prefixes: cosmic.fs as `Fs`, cosmic.sys as `sys`.
local FS <const> = fixture.FS
local SYS <const> = 'local sys = require("cosmic.sys") '

--- The child each test starts ([`build/child_lua_fixture.tl`]'s `lua`): its
--- argv and options, for [`Child.run`] or [`Child.start`].
local function lua(chunk: string, args?: {string}, opts?: Child.Options): {string}, Child.Options
  local started = fixture.lua(chunk, args, opts)
  return started.argv, started.options
end

local sleep = fixture.sleeping

--- `cat`: stdin to stdout, to its end.
local CAT <const> = FS .. 'while true do local s = assert(Fs.take(0, 65536)) ' ..
  'if s == "" then break end assert(Fs.put(1, s)) end '

local AGAIN <const> = fixture.AGAIN

local function test_start_failure_is_not_exit_127()
  local h, trouble = Child.start({ "/definitely/not/a/cosmic-command" })
  assert(h == nil)
  assert(trouble:find("start:", 1, true))
  local r = assert(Child.run(lua("return 127")))
  assert(r.code == 127 and not r.ok)
end

local function test_argv_environment_directory_and_file_output(tmp: string)
  local fd, path = output(tmp, "answer")
  local r = assert(Child.run(lua('local a, b = ... ' .. SYS .. FS ..
      'assert(Fs.put(1, a .. "|" .. b .. "|" .. (sys.getenv("WORD") or "") .. ' ..
      'assert(sys.getcwd()) .. "\\n"))', { "a b", "" },
    { cwd = tmp, env = { WORD = "value" }, stdout = fd })))
  assert(Fs.close(fd))
  assert(r.ok)
  assert(assert(Fs.read(path)) == "a b||value" .. assert(Fs.absolute(tmp)) .. "\n")
end

local function test_large_redirect_does_not_depend_on_pipe_capacity(tmp: string)
  local fd, path = output(tmp, "large")
  local r = assert(Child.run(lua(FS .. 'assert(Fs.put(1, string.rep("0123456789", 10000)))',
    nil, { stdout = fd })))
  assert(Fs.close(fd))
  assert(r.ok and #assert(Fs.read(path)) == 100000)
end

local function test_redirect_source_descriptor_does_not_leak(tmp: string)
  local fd = assert(Fs.open_write(tmp .. "/out"))
  local r = assert(Child.run(lua(SYS ..
      'return sys.fstat(math.tointeger(tonumber(sys.getenv("SOURCE")))) == nil and 0 or 1',
    nil, { env = { SOURCE = tostring(fd) }, stdout = fd })))
  assert(Fs.close(fd))
  assert(r.ok)
end

local function test_nonzero_and_signal_status()
  local exited = assert(Child.run(lua("return 23")))
  assert(exited.code == 23 and exited.signal == nil and not exited.ok)
  local signaled = assert(Child.run(lua(SYS .. "sys.kill(sys.getpid(), sys.SIGTERM) " ..
      sleep(1000))))
  assert(signaled.code == nil and signaled.signal == sys.SIGTERM)
end

local function test_shell_status_of_a_real_exit_and_a_real_signal()
  local clean = assert(Child.run(lua("return 0")))
  assert(Child.shell_status(clean) == 0)
  local exited = assert(Child.run(lua("return 23")))
  assert(Child.shell_status(exited) == 23)
  local signaled = assert(Child.run(lua(SYS .. "sys.kill(sys.getpid(), sys.SIGTERM) " ..
      sleep(1000))))
  assert(Child.shell_status(signaled) == 128 + sys.SIGTERM)
end

local function test_shell_status_of_a_result_with_neither_code_nor_signal_is_one()
  local bare: Child.Result = { ok = false, timed_out = false, captured = {}, truncated = false }
  assert(Child.shell_status(bare) == 1)
  -- The signal wins, though a Result never carries both.
  bare.signal = sys.SIGKILL
  assert(Child.shell_status(bare) == 128 + sys.SIGKILL)
end

local function test_timeout_kills_the_process_group_and_reaps_child(tmp: string)
  local function check(name: string)
    local fd, path = output(tmp, name)
    local h = assert(Child.start(lua(AGAIN ..
        "local h = again('" .. sleep(30000) .. "', { process_group = false }) " .. FS ..
        "assert(Fs.put(1, tostring(h.pid))) h:wait()",
      nil, { stdout = fd, stderr = fd })))
    local deadline = Clock.monotonic_ns() + Clock.seconds(10)
    while assert(Fs.stat(path)).size == 0 and Clock.monotonic_ns() < deadline do
      Clock.sleep_ns(Clock.ms(10))
    end
    assert(assert(Fs.stat(path)).size > 0, "child did not report readiness")
    -- The descendant's pid as the child saw it, and as this process
    -- does, found while the child still runs.
    local contents = assert(Fs.read(path))
    local pid = assert(host_pid(h.pid, assert(math.tointeger((assert(tonumber(contents)))))))
    local r = assert(h:wait(Clock.ms(40)))
    assert(Fs.close(fd))
    assert(r.timed_out and not r.ok)
    -- A process-group timeout includes descendants. Signal zero would succeed
    -- for a surviving process (or fail with EPERM, not ESRCH).
    local alive = sys.kill(pid, 0)
    assert(not alive)
  end
  check("group")
end

local function test_non_group_timeout_returns_graceful_term_status(tmp: string)
  local ready = tmp .. "/ready"
  local h = assert(Child.start(lua('local g = assert(require("cosmic.signal").guard()) ' ..
      FS .. 'assert(Fs.write((...), "ready")) while g:cancelled() == 0 do ' .. sleep(10) ..
      'end return 19', { ready }, { process_group = false })))
  local deadline = Clock.monotonic_ns() + Clock.seconds(10)
  while not path_exists(ready) and Clock.monotonic_ns() < deadline do
    Clock.sleep_ns(Clock.ms(10))
  end
  assert(path_exists(ready), "child did not report readiness")
  local r = assert(h:wait(0))
  assert(r.code == 19 and r.signal == nil and r.timed_out)
end

-- The `/bin/sh` a refusal case in this module names is never started:
-- its option is refused before a start, and a sandboxed worker has no
-- sh to find, so a refusal that regressed fails the case either way.
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
  local result = assert(Child.run(lua("")))
  assert(result.ok)
end

--- Successful public child operations always fill the error slot.
local function test_success_results_carry_empty_errors()
  local result, run_trouble = Child.run(lua(""))
  assert(result ~= nil and run_trouble == "")

  local first, start_trouble = Child.start(lua(""))
  assert(first ~= nil and start_trouble == "")
  local waited, wait_trouble = first:wait()
  assert(waited ~= nil and wait_trouble == "")

  local second = assert(Child.start(lua(sleep(50))))
  local polled, poll_trouble = second:try_wait()
  assert(polled ~= nil and poll_trouble == "")
  if not polled.finished then
    assert(second:wait())
  end
end

local function test_captures_stdout_and_stderr_apart()
  local r = assert(Child.run(lua(FS .. 'Fs.put(1, "out") Fs.put(2, "err") return 3', nil,
    { stdout = "capture", stderr = "capture" })))
  assert(r.code == 3 and not r.ok)
  assert(r.stdout == "out" and r.stderr == "err")
  assert(r.captured[1] == "out" and r.captured[2] == "err")
  assert(not r.truncated)
end

local function test_stderr_can_share_captured_stdout()
  local r = assert(Child.run(lua(FS .. 'Fs.put(1, "a") Fs.put(2, "b") Fs.put(1, "c")', nil,
    { stdout = "capture", stderr = "stdout" })))
  assert(r.ok and r.stdout == "abc" and r.stderr == nil)
end

local function test_input_and_output_both_larger_than_a_pipe()
  local input = string.rep("0123456789abcdef", 64 * 1024)
  local r = assert(Child.run(lua(CAT, nil, { input = input, stdout = "capture" })))
  assert(r.ok and r.stdout == input)
end

local function test_empty_input_is_end_of_file()
  local r = assert(Child.run(lua(CAT, nil, { input = "", stdout = "capture" })))
  assert(r.ok and r.stdout == "")
end

local function test_a_child_that_stops_reading_ends_the_input_quietly()
  local r = assert(Child.run(lua("", nil, { input = string.rep("x", 1024 * 1024) })))
  assert(r.ok)
end

local function test_capture_keeps_the_newest_bytes_past_the_limit()
  local r = assert(Child.run(lua(FS .. 'for _ = 1, 1000 do Fs.put(1, "0123456789") end Fs.put(1, "END")',
    nil, { stdout = "capture", capture_limit = 100 })))
  assert(r.ok and r.truncated)
  local kept = assert(r.stdout)
  assert(#kept == 100 and kept:sub(-3) == "END")
end

local function test_null_streams()
  local r = assert(Child.run(lua(CAT .. 'Fs.put(1, "gone") Fs.put(2, "gone")', nil,
    { stdin = "null", stdout = "null", stderr = "null" })))
  assert(r.ok and r.stdout == nil)
end

local function test_more_descriptors_by_number(tmp: string)
  local fd, path = output(tmp, "five")
  -- Descriptors 19 and 20: a sealed child's SQLite holds its database open at a low number.
  local r = assert(Child.run(lua(FS .. SYS .. 'Fs.put(3, "report") Fs.put(20, "five") ' ..
      'return sys.fstat(19) == nil and 0 or 1', nil,
    { fds = { [3] = "capture", [20] = fd }, stdout = "capture" })))
  assert(Fs.close(fd))
  assert(r.ok, "code " .. tostring(r.code))
  assert(r.captured[3] == "report" and r.stdout == "")
  assert(assert(Fs.read(path)) == "five")
end

--- The caller's stdin stream, with the output captured for the Result.
local function test_stdin_stream_belongs_to_the_caller()
  local h = assert(Child.start(lua(CAT, nil, { stdin = "stream", stdout = "capture" })))
  local stdin = assert(h.stdin_stream)
  assert(stdin:write("typed"))
  assert(stdin:close())
  assert(stdin:close())
  local r = assert(h:wait(Clock.seconds(5)))
  assert(r.ok and r.stdout == "typed")
end

--- A start with `stdin = "pipe"` raises, and the message names the
--- stream and `input` to use instead.
local function test_a_stdin_pipe_names_the_stream_to_use()
  local ok, trouble = pcall(Child.start, { "/bin/sh" }, { stdin = "pipe" } as Child.Options)
  assert(not ok and tostring(trouble):find('"stream"', 1, true) ~= nil and
      tostring(trouble):find("stdin_stream", 1, true) ~= nil, tostring(trouble))
  assert(not pcall(Child.run, { "/bin/sh" }, { stdin = "pipe" } as Child.Options))
end

local function read_all(reader: Stream.Reader): string
  return (assert(Stream.read_all(reader)))
end

--- A streamed stdout is read while the child still runs: the child
--- answers what it is sent, through the stdin stream, only after its
--- first output has been read.
local function test_streams_are_read_and_written_while_the_child_runs()
  local h = assert(Child.start(lua(FS .. 'Fs.put(1, "first") local x = "" while true do ' ..
      'local c = assert(Fs.take(0, 1)) if c == "" or c == "\\n" then break end x = x .. c end ' ..
      'Fs.put(1, "second-" .. x)', nil, { stdin = "stream", stdout = "stream" })))
  local stdout = assert(h.stdout_stream)
  local stdin = assert(h.stdin_stream)
  assert(h.stderr_stream == nil)
  assert(assert(stdout:read()) == "first")
  assert(stdin:write("go\n"))
  assert(stdin:close())
  assert(read_all(stdout) == "second-go")
  local chunk, trouble = stdout:read()
  assert(chunk == nil and trouble == "")
  local r = assert(h:wait(Clock.seconds(5)))
  assert(r.ok and r.stdout == nil and r.captured[1] == nil)
  assert(not stdin:write("late"))
end

--- Reading stdout services stderr meanwhile, so a child that fills
--- stderr before it writes stdout does not stall the read.
local function test_reading_stdout_does_not_stall_on_a_full_stderr()
  local h = assert(Child.start(lua(FS .. 'assert(Fs.put(2, string.rep("0123456789", 20000))) ' ..
      'Fs.put(1, "done")', nil, { stdout = "stream", stderr = "stream" })))
  assert(read_all(assert(h.stdout_stream)) == "done")
  assert(#read_all(assert(h.stderr_stream)) == 200000)
  assert(assert(h:wait(Clock.seconds(5))).ok)
end

--- Writing stdin services stdout meanwhile, so a child echoing far more
--- than a pipe holds does not stall the write.
local function test_writing_stdin_does_not_stall_on_a_full_stdout()
  local input = string.rep("0123456789abcdef", 256 * 1024)
  local h = assert(Child.start(lua(CAT, nil, { stdin = "stream", stdout = "stream" })))
  local stdin = assert(h.stdin_stream)
  assert(stdin:write(input))
  assert(stdin:close())
  assert(read_all(assert(h.stdout_stream)) == input)
  assert(assert(h:wait(Clock.seconds(5))).ok)
end

--- Unread output is held up to `capture_limit`, and then the child
--- waits for the reader: nothing is dropped.
local function test_a_streamed_output_holds_the_child_at_its_limit()
  local h = assert(Child.start(lua(FS .. 'for _ = 1, 20000 do assert(Fs.put(1, "0123456789")) end',
    nil, { stdout = "stream", capture_limit = 100 })))
  local deadline = Clock.monotonic_ns() + Clock.ms(300)
  while Clock.monotonic_ns() < deadline do
    assert(not assert(h:try_wait()).finished, "the child ran past its reader")
    Clock.sleep_ns(Clock.ms(10))
  end
  assert(read_all(assert(h.stdout_stream)) == string.rep("0123456789", 20000))
  assert(assert(h:wait(Clock.seconds(5))).ok)
end

--- What the child wrote before a wait settled it is still there to
--- read afterward.
local function test_a_streamed_output_is_read_after_the_wait()
  local h = assert(Child.start(lua(FS .. 'Fs.put(1, "hello") Fs.put(2, "there")', nil,
    { stdout = "stream", stderr = "stdout" })))
  assert(assert(h:wait(Clock.seconds(5))).ok)
  assert(read_all(assert(h.stdout_stream)) == "hellothere")
end

--- How long an escaped writer runs: past any read or wait that ends at
--- its parent's exit, and within CI's 10 s per-test deadline, so a read
--- or wait that waited for it fails an assertion rather than the clock.
local ESCAPED_MS <const> = 7500

--- Whether the escaped writer whose pid follows "done " in `said` still
--- runs. It is ended either way.
local function ended_escaped(said: string): boolean
  local pid = assert(math.tointeger(tonumber(said:match("^done (%d+)$"))), said)
  local alive = sys.kill(pid, 0)
  local _, _ = sys.kill(pid, sys.SIGKILL)
  -- Reaped here where this process adopted it.
  local _ = Child.end_strays()
  return alive
end

--- A streamed output ends once the child has exited and nothing more
--- is waiting, though a descendant that left the group holds it open:
--- the read ends while that descendant still runs.
local function test_an_escaped_writer_does_not_hold_up_a_read()
  local started = Clock.monotonic_ns()
  local h = assert(Child.start(lua(AGAIN .. "local escaped = again('" .. sleep(ESCAPED_MS) ..
      "') " .. FS .. 'Fs.put(1, "done " .. escaped.pid) require("cosmic.sys").exit(0)', nil,
    { stdout = "stream" })))
  local said = read_all(assert(h.stdout_stream))
  -- A zombie answers `kill(pid, 0)` too, where this process adopted
  -- the descendant; then only the time tells the read waited for it.
  local took = Clock.monotonic_ns() - started
  local alive = ended_escaped(said)
  assert(assert(h:wait(Clock.seconds(5))).ok)
  assert(alive, "the read ended only once the escaped writer had")
  assert(took < Clock.ms(ESCAPED_MS), "the read waited for the escaped writer")
end

--- Closing a streamed output early closes the pipe: a child still
--- writing to it is not left blocked, but ended by SIGPIPE, or, where
--- it started with SIGPIPE ignored (as a CI runner may start this
--- process), stopped by its write's EPIPE.
local function test_closing_a_streamed_output_ends_a_writer()
  local h = assert(Child.start(lua(FS .. 'while Fs.put(1, "0123456789") do end return 1', nil,
    { stdout = "stream", stderr = "null" })))
  local stdout = assert(h.stdout_stream)
  assert(stdout:read(10))
  assert(stdout:close())
  local chunk, trouble = stdout:read()
  assert(chunk == nil and trouble ~= "")
  local r = assert(h:wait(Clock.seconds(5)))
  assert(not r.timed_out, "the writer was left blocked on the closed pipe")
end

--- A streamed output's `read` refuses a `max_bytes` below 1 by raising,
--- and a read of a positive one still answers.
local function test_a_streamed_output_refuses_a_max_bytes_below_one()
  local h = assert(Child.start(lua(FS .. 'Fs.put(1, "x")', nil, { stdout = "stream", stderr = "null" })))
  local stdout = assert(h.stdout_stream)
  for _, bad in ipairs({ 0, -1 }) do
    local ok, why: boolean, any = pcall(function() local _, _ = stdout:read(bad) end)
    assert(not ok and tostring(why):find("child: read's max_bytes must be positive", 1, true) ~= nil,
      tostring(why))
  end
  assert(read_all(stdout) == "x")
  assert(assert(h:wait(Clock.seconds(5))).ok)
end

--- A write to a child that has closed its stdin fails instead of ending
--- this process, and keeps failing.
local function test_writing_to_a_gone_stdin_stream_fails()
  local h = assert(Child.start(lua(SYS .. "sys.close(0) " .. sleep(5000), nil,
    { stdin = "stream" })))
  local stdin = assert(h.stdin_stream)
  local chunk = string.rep("x", 1 << 20)
  local ok, trouble = true, ""
  for _ = 1, 8 do
    ok, trouble = stdin:write(chunk)
    if not ok then break end
  end
  assert(not ok and trouble ~= "")
  local again, again_trouble = stdin:write("x")
  assert(not again and again_trouble == trouble)
  assert(h:close())
end

--- A wait holds a streamed output to its limit, even while a writer
--- outside the group goes on filling the pipe: the rest waits in the
--- pipe for the reader, which reads on after the wait. The child's own
--- 2 KiB, past the limit and within what a pipe holds, goes into the
--- pipe before the background writer starts, so it is there when the
--- child exits however late that writer runs, and the writer cannot
--- fill the pipe ahead of it and leave the child blocked.
local function test_a_wait_holds_a_streamed_output_to_its_limit()
  local h = assert(Child.start(lua(AGAIN .. FS .. 'assert(Fs.put(1, string.rep("\\0", 2048))) ' ..
      "again('" .. FS .. 'Fs.put(1, string.rep("\\\\0", 4000000))' .. "', " ..
      '{ process_group = false }) require("cosmic.sys").exit(0)', nil,
    { stdout = "stream", capture_limit = 1024, process_group = false })))
  assert(assert(h:wait(Clock.seconds(5))).ok)
  Clock.sleep_ns(Clock.ms(100))
  assert(assert(h:try_wait()).finished)
  local queued = 0
  for _, stream in ipairs(h._streams) do queued = queued + stream.size end
  assert(queued <= 1024, "the wait queued " .. tostring(queued) .. " bytes")
  local chunk = assert(assert(h.stdout_stream):read())
  assert(#chunk > 0)
  assert(h:close())
  -- The reader reads what was queued, then ends with the pipe closed.
  local rest = read_all(assert(h.stdout_stream))
  assert(#rest <= 1024)
end

local function test_a_streamed_read_of_nothing_is_refused()
  local h = assert(Child.start(lua(FS .. 'Fs.put(1, "x")', nil, { stdout = "stream" })))
  local stdout = assert(h.stdout_stream)
  assert(not pcall(stdout.read, stdout, 0))
  assert(read_all(stdout) == "x")
  assert(assert(h:wait(Clock.seconds(5))).ok)
end

--- A write after the wait says the child has gone; one after its own
--- close says it is closed.
local function test_a_stdin_stream_write_after_the_wait_says_why()
  local h = assert(Child.start(lua("", nil, { stdin = "stream" })))
  local stdin = assert(h.stdin_stream)
  assert(assert(h:wait(Clock.seconds(5))).ok)
  local wrote, trouble = stdin:write("late")
  assert(not wrote and trouble == "child: the child has exited", trouble)
  assert(stdin:close())
  local again, again_trouble = stdin:write("later")
  assert(not again and again_trouble:find("closed", 1, true) ~= nil, again_trouble)
end

local function test_try_wait_services_a_chatty_child()
  local h = assert(Child.start(lua(FS .. 'assert(Fs.put(1, string.rep("0123456789", 20000)))',
    nil, { stdout = "capture" })))
  local deadline = Clock.monotonic_ns() + Clock.seconds(10)
  local polled = assert(h:try_wait())
  while not polled.finished and Clock.monotonic_ns() < deadline do
    Clock.sleep_ns(Clock.ms(1))
    polled = assert(h:try_wait())
  end
  assert(polled.finished, "a full pipe stalled the child")
  assert(#polled.result.stdout == 200000)
end

local function test_timeout_keeps_what_was_captured()
  -- The timeout must outlast the child's start and its write, which take
  -- over 200 ms on the sanitized core under a full suite's load.
  local r = assert(Child.run(lua(FS .. 'Fs.put(1, "partial") ' .. sleep(30000), nil,
    { stdout = "capture", timeout_ns = Clock.seconds(5) })))
  assert(r.timed_out and not r.ok and r.stdout == "partial")
end

--- A leader that exits leaves no member of its group behind, and none of
--- them a zombie: a descendant that outlives the leader is ended and
--- reaped before the wait answers.
--- The descendant is looked for by its group, the leader's pid.
local function test_exit_ends_and_reaps_what_the_group_left_behind()
  local function check()
    local h = assert(Child.start(lua(AGAIN .. "local h = again('" .. sleep(30000) ..
        "', { process_group = false }) " .. FS ..
        'Fs.put(1, tostring(h.pid)) require("cosmic.sys").exit(0)', nil, { stdout = "capture" })))
    local r = assert(h:wait(Clock.seconds(5)))
    assert(r.ok and not r.timed_out and assert(math.tointeger(tonumber(r.stdout))) > 0)
    local alive, _, errno = sys.kill(-h.pid, 0)
    assert(not alive and errno == sys.ESRCH, "a member of group " .. tostring(h.pid) ..
        " survived")
  end
  check()
end

--- Completion is the leader's exit: a descendant that left the group
--- while holding the captured pipe cannot hold the wait open. The run's
--- timeout comes before the descendant ends, so a wait it held open
--- times out.
local function test_an_escaped_writer_does_not_hold_up_the_wait()
  local r = assert(Child.run(lua(AGAIN .. "local escaped = again('" .. sleep(ESCAPED_MS) ..
      "') " .. FS .. 'Fs.put(1, "done " .. escaped.pid) require("cosmic.sys").exit(0)', nil,
    { stdout = "capture", timeout_ns = Clock.seconds(5) })))
  local alive = ended_escaped(assert(r.stdout))
  assert(r.ok and not r.timed_out, "the wait was held open: " .. tostring(r.stdout))
  assert(alive, "the wait ended only once the escaped writer had")
end

local function test_wait_any_returns_the_first_to_finish()
  local slow = assert(Child.start(lua(sleep(5000))))
  local fast = assert(Child.start(lua(FS .. 'Fs.put(1, "quick")', nil, { stdout = "capture" })))
  local first, first_trouble = Child.wait_any({ slow, fast }, Clock.seconds(5))
  assert(first == fast, first_trouble)
  local r = assert(fast:wait())
  assert(r.ok and r.stdout == "quick")
  local none, trouble = Child.wait_any({ slow }, 0)
  assert(none == nil and trouble == Poll.TIMEOUT, trouble)
  assert(slow:close())
end

--- What `call` raised, which must name this file: a wrong shape is the
--- caller's mistake, so the error points at the call.
local function raised(call: function()): string
  local ok, message: boolean, any = pcall(call)
  assert(not ok, "did not raise")
  local text = tostring(message)
  assert(text:find("child_lua_test:", 1, true), text)
  return text
end

local function test_a_wait_refuses_a_timeout_out_of_range()
  local h <close> = assert(Child.start(lua(sleep(5000))))
  for _, bad in ipairs({ -1, math.mininteger, Poll.MOST_NS + 1 }) do
    local message = raised(function() local _, _ = h:wait(bad) end)
    assert(message:find("timeout_ns must be nil or an integer from 0 to", 1, true), message)
  end
  -- The handle is untouched by the refusals: a zero timeout ends it.
  local r = assert(h:wait(0))
  assert(r.timed_out)
  -- A settled handle refuses one too, rather than answering its Result.
  local message = raised(function() local _, _ = h:wait(-1) end)
  assert(message:find("timeout_ns must be nil or an integer from 0 to", 1, true), message)
  local quick <close> = assert(Child.start(lua("return 3")))
  r = assert(quick:wait(Clock.seconds(10)))
  assert(r.code == 3 and not r.timed_out)
  local plain <close> = assert(Child.start(lua("return 4")))
  r = assert(plain:wait())
  assert(r.code == 4)
end

local function test_wait_any_refuses_a_timeout_out_of_range()
  local slow <close> = assert(Child.start(lua(sleep(5000))))
  for _, bad in ipairs({ -1, math.mininteger, Poll.MOST_NS + 1 }) do
    local message = raised(function() local _, _ = Child.wait_any({ slow }, bad) end)
    assert(message:find("timeout_ns must be nil or an integer from 0 to", 1, true), message)
  end
  local none, trouble = Child.wait_any({ slow }, 0)
  assert(none == nil and trouble == Poll.TIMEOUT, trouble)
  local quick <close> = assert(Child.start(lua("")))
  local first = assert(Child.wait_any({ slow, quick }))
  assert(first == quick)
end

--- How long `began` was ago, in whole milliseconds, for a message.
local function ms_since(began: integer): string
  return tostring((Clock.monotonic_ns() - began) // Clock.ms(1)) .. " ms"
end

--- Whether `began` was at least `ns` ago, give or take a scheduler's
--- slack, and well under the child's own 30 seconds.
local function about(began: integer, ns: integer): boolean
  local took = Clock.monotonic_ns() - began
  return took >= ns - Clock.ms(10) and took < Clock.seconds(20)
end

--- A start timeout that outlasts the child's own startup, for a test whose
--- child must write before its deadline: 200 ms past twice what a child
--- that does nothing takes to run, which on a slow core (the checked one)
--- can pass a flat 200 ms before the child runs its chunk. What the test
--- measures is the deadline it passes, so it bounds the elapsed time
--- against what this returns.
local function startup_timeout(): integer
  local began = Clock.monotonic_ns()
  assert(Child.run(lua("")))
  return Clock.ms(200) + 2 * (Clock.monotonic_ns() - began)
end

--- A started child's `timeout_ns` is a deadline from its start, which a
--- wait with no timeout of its own ends it at, as an expired `wait`
--- does: the plain wait that blocks on the child, and one that services
--- its captured output or waits longer than the deadline.
local function test_a_start_timeout_ends_the_child_a_wait_waits_on()
  local timeout = startup_timeout()
  local began = Clock.monotonic_ns()
  local plain <close> = assert(Child.start(lua(sleep(30000), nil, { timeout_ns = timeout })))
  local r = assert(plain:wait())
  assert(r.timed_out and not r.ok, "the child was not ended for its start's timeout")
  assert(about(began, timeout), ms_since(began))
  began = Clock.monotonic_ns()
  local captured <close> = assert(Child.start(lua(FS .. 'Fs.put(1, "early") ' .. sleep(30000), nil,
    { stdout = "capture", timeout_ns = timeout })))
  r = assert(captured:wait(Clock.seconds(10)))
  assert(r.timed_out and r.stdout == "early", tostring(r.stdout))
  assert(about(began, timeout), ms_since(began))
  -- A child that exits first is not timed out.
  local quick <close> = assert(Child.start(lua("return 3", nil, { timeout_ns = Clock.seconds(10) })))
  r = assert(quick:wait())
  assert(r.code == 3 and not r.timed_out)
end

--- A `timeout_ns` of 0 is not "no limit": the first wait on the child
--- ends it, [`Child.run`]'s at once.
local function test_a_timeout_of_0_ends_the_child_at_the_first_wait()
  local began = Clock.monotonic_ns()
  local r = assert(Child.run(lua(sleep(30000), nil, { timeout_ns = 0 })))
  assert(r.timed_out and not r.ok, "a run with a timeout of 0 was not ended for it")
  assert(about(began, 0), ms_since(began))
  local h <close> = assert(Child.start(lua(sleep(30000), nil, { timeout_ns = 0 })))
  local look = assert(h:try_wait())
  assert(look.finished and look.result.timed_out, "the first try_wait left the child running")
end

--- [`Child.wait_any`] ends a handle whose start's deadline passes while
--- it waits, and answers it settled; its own shorter timeout ends no
--- child, and a `wait` shorter than the deadline ends its child its own
--- way.
local function test_wait_any_ends_a_child_past_its_start_timeout()
  local slow <close> = assert(Child.start(lua(sleep(30000))))
  local timed <close> = assert(Child.start(lua(sleep(30000), nil, { timeout_ns = Clock.ms(400) })))
  local none, trouble = Child.wait_any({ slow, timed }, Clock.ms(50))
  assert(none == nil and trouble == Poll.TIMEOUT, trouble)
  local running = assert(timed:try_wait())
  assert(not running.finished, "wait_any's own timeout ended a child")
  local began = Clock.monotonic_ns()
  local first = assert(Child.wait_any({ slow, timed }, Clock.seconds(10)))
  assert(first == timed)
  local r = assert(timed:wait())
  assert(r.timed_out)
  assert(about(began, Clock.ms(300)), ms_since(began))
  running = assert(slow:try_wait())
  assert(not running.finished)
  local later <close> = assert(Child.start(lua(sleep(30000), nil, { timeout_ns = Clock.seconds(10) })))
  began = Clock.monotonic_ns()
  r = assert(later:wait(Clock.ms(100)))
  assert(r.timed_out and about(began, Clock.ms(100)), ms_since(began))
end

--- A child that exits by itself after its start's deadline, before
--- anything waits on it, was not ended for it: its Result is its own.
local function test_a_child_that_exited_past_its_start_timeout_is_not_timed_out()
  local h <close> = assert(Child.start(lua(sleep(200) .. "return 4", nil,
    { timeout_ns = Clock.ms(50) })))
  local _, _ = Clock.sleep_ns(Clock.seconds(1))
  local r = assert(h:wait())
  assert(r.code == 4 and not r.timed_out, tostring(r.code))
end

--- `try_wait` past a start's deadline ends the child and answers it
--- finished; before it, the child runs on.
local function test_try_wait_ends_a_child_past_its_start_timeout()
  local h <close> = assert(Child.start(lua(sleep(30000), nil, { timeout_ns = Clock.ms(300) })))
  local look = assert(h:try_wait())
  assert(not look.finished)
  local _, _ = Clock.sleep_ns(Clock.ms(350))
  look = assert(h:try_wait())
  assert(look.finished and look.result.timed_out, "try_wait left the child past its deadline")
end

--- A read of a streamed output waits no longer than the child's start
--- deadline: the child is ended there, and the read ends with its pipe.
local function test_a_stream_read_ends_a_child_past_its_start_timeout()
  local timeout = startup_timeout()
  local h <close> = assert(Child.start(lua(FS .. 'Fs.put(1, "early") ' .. sleep(30000), nil,
    { stdout = "stream", timeout_ns = timeout })))
  local began = Clock.monotonic_ns()
  local out = assert(Stream.read_all(h.stdout_stream as Stream.Reader))
  assert(out == "early", out)
  assert(about(began, timeout - Clock.ms(50)), ms_since(began))
  local r = assert(h:wait())
  assert(r.timed_out)
end

--- A write to a stdin stream the child does not read waits no longer
--- than the child's start deadline: the child is ended there, and the
--- write fails.
local function test_a_stream_write_ends_a_child_past_its_start_timeout()
  local h <close> = assert(Child.start(lua(sleep(30000), nil,
    { stdin = "stream", timeout_ns = Clock.ms(200) })))
  local began = Clock.monotonic_ns()
  local writer = h.stdin_stream as Stream.Writer
  local wrote, trouble = writer:write(string.rep("x", 4 * 1024 * 1024))
  assert(not wrote, "a write to a child that never reads went through")
  assert(about(began, Clock.ms(150)), ms_since(began) .. ": " .. trouble)
  local r = assert(h:wait())
  assert(r.timed_out)
end

--- A run made while the caller holds a guard, and nothing is sent,
--- runs as it would alone, and the caller's guard catches nothing.
local function test_a_run_inside_a_guard_runs()
  local guard = assert(Signal.guard())
  local r = assert(Child.run(lua("return 5")))
  assert(r.code == 5, tostring(r.code))
  assert(guard:cancelled() == 0)
  assert(guard:release() == 0)
end

--- A timeout is nanoseconds: the child is ended about when it says, not
--- a millionth of the time before nor a million times after.
local function test_a_timeout_ends_a_child_after_the_nanoseconds_it_says()
  local began = Clock.monotonic_ns()
  local r = assert(Child.run(lua(sleep(30000), nil, { timeout_ns = Clock.ms(200) })))
  local took = Clock.monotonic_ns() - began
  assert(r.timed_out, "the child was not ended for its timeout")
  assert(took >= Clock.ms(190) and took < Clock.seconds(20), tostring(took // Clock.ms(1)) .. " ms")
  local h <close> = assert(Child.start(lua(sleep(30000))))
  began = Clock.monotonic_ns()
  local waited = assert(h:wait(Clock.ms(200)))
  took = Clock.monotonic_ns() - began
  assert(waited.timed_out)
  assert(took >= Clock.ms(190) and took < Clock.seconds(20), tostring(took // Clock.ms(1)) .. " ms")
  local slow <close> = assert(Child.start(lua(sleep(30000))))
  began = Clock.monotonic_ns()
  local none, trouble = Child.wait_any({ slow }, Clock.ms(100))
  took = Clock.monotonic_ns() - began
  assert(none == nil and trouble == Poll.TIMEOUT, trouble)
  assert(took >= Clock.ms(90) and took < Clock.seconds(20), tostring(took // Clock.ms(1)) .. " ms")
  -- A nanosecond is a wait that ends, as zero is a look.
  none, trouble = Child.wait_any({ slow }, 1)
  assert(none == nil and trouble == Poll.TIMEOUT, trouble)
end
