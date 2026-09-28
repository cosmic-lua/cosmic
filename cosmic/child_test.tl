local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local Test = require("cosmic.test")
local observations = require("build.filesystem_observations")

--- The processes Child starts, which inherit the environment unless given
--- one, and what a sandboxed one is given of the host, and /proc, where
--- a test finds a child's processes; and the program itself, which its
--- tests start, past its launcher, for every child: nothing of the host's
--- own programs is read.
Test.needs{ host = { "/proc" }, env = { "*" }, processes = true, tool = true }

local function path_exists(path: string): boolean
  local answer, trouble = Fs.exists(path)
  assert(answer ~= nil, trouble)
  return answer
end

--- The pid, in this process's pid namespace, of the process that `pid`
--- names in the pid namespace of `within`, a live child of this
--- process: the same number, unless `within` was started in a pid
--- namespace of its own (a `sandbox` that unveils), where it is found
--- by the namespace's own pid, the last of its NSpid; nil where none is
--- found. A process this test starts with none is in this worker's own,
--- sandboxed or not: only `Child` ends the group it leads.
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

--- This program again, past its launcher (`observations.program`),
--- running the Lua chunk `chunk` with `args` as its `...`: the child
--- each test starts, where a shell would need the system's. The argv
--- and options, for `Child.run` or `Child.start`.
local function lua(chunk: string, args?: {string}, opts?: Child.Options): {string}, Child.Options
  local words: {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  local started = observations.program(words, opts)
  return started.argv, started.options
end

--- Chunk prefixes: cosmic.fs as `Fs`, cosmic.sys as `sys`.
local FS <const> = 'local Fs = require("cosmic.fs") '
local SYS <const> = 'local sys = require("cosmic.sys") '

--- A chunk's statement that sleeps `ms` milliseconds.
local function sleep(ms: integer): string
  return 'require("cosmic.time").sleep_ns(' .. tostring(ms) .. ' * 1000000) '
end

--- `cat`: stdin to stdout, to its end.
local CAT <const> = FS .. 'while true do local s = assert(Fs.take(0, 65536)) ' ..
  'if s == "" then break end assert(Fs.put(1, s)) end '

--- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
--- starts this program once more, as `lua` does, running `chunk`.
--- A chunk that leaves one running ends by `sys.exit`, past the
--- collector, whose end of the handle would end it, as a shell's `&`
--- leaves it.
local AGAIN <const> = [[
local Child = require("cosmic.child")
local observations = require("build.filesystem_observations")
local function again(chunk, opts)
  local started = observations.program({ "-e", chunk }, opts)
  return assert(Child.start(started.argv, started.options))
end
]]

local function test_start_failure_is_not_exit_127()
  local h, trouble = Child.start({ "/definitely/not/a/cosmic-command" })
  assert(h == nil)
  assert(trouble:find("start:", 1, true))
  local r = assert(Child.run(lua("return 127")))
  assert(r.code == 127 and not r.ok)
end

--- A bare name is not looked for on PATH, and the failure says so and
--- names what finds it; a path that is not there gets no such hint.
local function test_a_bare_name_not_found_points_at_proc_find(tmp: string)
  local _, trouble = Child.run({ "cosmic-no-such-program" }, { cwd = tmp })
  assert(trouble:find("with no PATH search; " ..
    "Proc.find(\"cosmic-no-such-program\") answers", 1, true) ~= nil, trouble)
  local _, pathed = Child.run({ tmp .. "/cosmic-no-such-program" })
  assert(pathed:find("Proc.find(", 1, true) == nil, pathed)
  -- A missing directory, or a script whose interpreter is missing, fails
  -- with the same ENOENT; the name is not what is missing there.
  local _, no_dir = Child.run({ "ls" }, { cwd = tmp .. "/not-here" })
  assert(no_dir:find("Proc.find(", 1, true) == nil, no_dir)
  assert(Fs.write(tmp .. "/script", "#!/cosmic/no/such/interpreter\n"))
  assert(sys.chmod(tmp .. "/script", 0x1c0))
  local _, script = Child.run({ "script" }, { cwd = tmp })
  assert(script ~= "" and script:find("Proc.find(", 1, true) == nil, script)
  local _, empty = Child.run({ "" }, { cwd = tmp })
  assert(empty:find("Proc.find(", 1, true) == nil, empty)
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

local function test_timeout_kills_the_process_group_and_reaps_child(tmp: string)
  local function check(name: string)
    local fd, path = output(tmp, name)
    local h = assert(Child.start(lua(AGAIN ..
      "local h = again('" .. sleep(30000) .. "', { process_group = false }) " .. FS ..
      "assert(Fs.put(1, tostring(h.pid))) h:wait()",
      nil, { stdout = fd, stderr = fd })))
    local deadline = Time.monotonic_ns() + 10 * 1000 * 1000 * 1000
    while assert(Fs.stat(path)).size == 0 and Time.monotonic_ns() < deadline do
      Time.sleep_ns(10 * 1000 * 1000)
    end
    assert(assert(Fs.stat(path)).size > 0, "child did not report readiness")
    -- The descendant's pid as the child saw it, and as this process
    -- does, found while the child still runs.
    local contents = assert(Fs.read(path))
    local pid = assert(host_pid(h.pid, assert(math.tointeger((assert(tonumber(contents)))))))
    local r = assert(h:wait(40))
    assert(Fs.close(fd))
    assert(r.timed_out and not r.ok)
    -- A process-group timeout includes descendants. Signal zero would succeed
    -- for a surviving process (or fail with EPERM, not ESRCH).
    local alive = sys.kill(pid, 0)
    assert(not alive)
  end
  check("group")
end

--- A child that catches nothing is ended by a timeout's SIGTERM, not
--- left for the SIGKILL after the grace period -- and so is one started
--- in a sandbox of its own, where it is its pid namespace's pid 2, not
--- the pid 1 that would pass over a signal it does not catch from
--- outside the namespace. Where the kernel will not sandbox a child, the
--- sandboxed case is the kernel's to refuse.
local function test_a_timeout_ends_a_child_that_catches_nothing(tmp: string)
  local r = assert(Child.run(lua(sleep(100000), nil,
    { timeout_ms = 200, process_group = false })))
  assert(r.timed_out and r.signal == sys.SIGTERM, "ended by " .. tostring(r.signal))
  local reads = observations.itself()
  reads[#reads + 1] = "/proc"
  reads[#reads + 1] = "/dev/null"
  -- A directory it may start in: the worker's own, the tree's root, is
  -- none of what it unveils.
  reads[#reads + 1] = tmp
  local sandboxed, trouble = Child.run(lua(sleep(100000), nil,
    { cwd = tmp, timeout_ms = 200, sandbox = { unveil = { reads = reads }, offline = true } }))
  if sandboxed == nil then
    assert(sys.getenv("COSMIC_SANDBOX") ~= "must", "COSMIC_SANDBOX=must, but: " .. trouble)
    return
  end
  assert(sandboxed.timed_out and sandboxed.signal == sys.SIGTERM,
    "sandboxed, ended by " .. tostring(sandboxed.signal))
end

local function test_non_group_timeout_returns_graceful_term_status(tmp: string)
  local ready = tmp .. "/ready"
  local h = assert(Child.start(lua('local g = assert(require("cosmic.child").guard()) ' ..
    FS .. 'assert(Fs.write((...), "ready")) while g:cancelled() == 0 do ' .. sleep(10) ..
    'end return 19', { ready }, { process_group = false })))
  local deadline = Time.monotonic_ns() + 10 * 1000 * 1000 * 1000
  while not path_exists(ready) and Time.monotonic_ns() < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(path_exists(ready), "child did not report readiness")
  local r = assert(h:wait(0))
  assert(r.code == 19 and r.signal == nil and r.timed_out)
end

local function test_spawn_validates_fds_and_preserves_cloexec_stdio(tmp: string)
  local fixture = tmp .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local relaunch = assert(Proc.relaunch())
local function this(chunk: string, word?: string): {string}
  local argv = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = chunk
  argv[#argv + 1] = word
  return argv
end
return function(argv: {string}): integer
  Fs.close(11)
  local invalid = Child.start(this(""), { stdout = 11, env = relaunch.env, fds = relaunch.fds })
  if invalid then invalid:close(); return 20 end
  -- A file of its own, not /dev/null: a child whose fd 0 exec closed
  -- starts with /dev/null there, and would read nothing.
  assert(Fs.close(0))
  local fd = assert(Fs.open_read(argv[1]))
  assert(fd == 0)
  local result = assert(Child.run(this("local Fs = require('cosmic.fs') " ..
    "return Fs.take(0, 64) == ... and 0 or 1", "stdin's own"),
    { stdin = fd, process_group = false, env = relaunch.env, fds = relaunch.fds }))
  return result.ok and 0 or 21
end
]]))
  local stdin = tmp .. "/stdin"
  assert(Fs.write(stdin, "stdin's own"))
  local started = observations.program({ fixture, stdin })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "descriptor fixture exited " .. tostring(result.code))
end

local function test_run_forwards_parent_cancellation_after_group_cleanup(tmp: string)
  local ready = tmp .. "/ready"
  local descendant_path = tmp .. "/descendant"
  local fixture = tmp .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local AGAIN <const> = ]] .. string.format("%q", AGAIN) .. [[

return function(argv: {string}): integer
  local relaunch = assert(Proc.relaunch())
  local words = { table.unpack(relaunch.argv) }
  words[#words + 1] = "-e"
  words[#words + 1] = AGAIN .. "local h = again('" .. ]] .. string.format("%q", sleep(30000)) .. [[ ..
    "', { process_group = false }) local Fs = require('cosmic.fs') local pid, ready = ... " ..
    "assert(Fs.write(pid, tostring(h.pid))) assert(Fs.write(ready, 'ready')) h:wait()"
  words[#words + 1] = argv[1]
  words[#words + 1] = argv[2]
  local result, trouble = Child.run(words, { env = relaunch.env, fds = relaunch.fds })
  if not result then error(trouble) end
  local finished = assert(result)
  return finished.code or 1
end
]]))
  local fd, diagnostic = output(tmp, "driver.log")
  local started = observations.program({ fixture, descendant_path, ready },
    { stdout = fd, stderr = fd, process_group = false })
  local driver = assert(Child.start(started.argv, started.options))
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
  local descendant = assert(host_pid(driver.pid, assert(math.tointeger((assert(tonumber(
    assert(Fs.read(descendant_path)):match("%d+"))))))))
  assert(driver:stop(sys.SIGTERM))
  local stopped = assert(driver:wait(2000))
  assert(Fs.close(fd))
  assert(stopped.signal == sys.SIGTERM,
    "driver cancellation result code=" .. tostring(stopped.code) ..
    " signal=" .. tostring(stopped.signal) .. " log=" ..
    (Fs.read(diagnostic) or "<none>"))
  local gone_by = Time.monotonic_ns() + 1000 * 1000 * 1000
  while sys.kill(descendant, 0) and Time.monotonic_ns() < gone_by do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(not sys.kill(descendant, 0))
end

--- A refused option is blamed on the line that passed it, not on a line
--- of cosmic.child: the checks under `validate` raise at their caller's
--- caller's caller.
local function test_a_refused_option_names_the_caller_s_line()
  for _, opts in ipairs({
    { stdout = "bad" } as Child.Options,
    { cwd = "/tmp\0bad" } as Child.Options,
    { timeout_ms = -1 } as Child.Options,
  }) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = Child.run({ "/bin/sh" }, opts)
    end)
    assert(not ok and tostring(why):find("child_test:", 1, true) ~= nil, tostring(why))
  end
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
  local r = assert(Child.run(lua(FS .. SYS .. 'Fs.put(3, "report") Fs.put(5, "five") ' ..
    'return sys.fstat(4) == nil and 0 or 1', nil,
    { fds = { [3] = "capture", [5] = fd }, stdout = "capture" })))
  assert(Fs.close(fd))
  assert(r.ok, "code " .. tostring(r.code))
  assert(r.captured[3] == "report" and r.stdout == "")
  assert(assert(Fs.read(path)) == "five")
end

local function test_stdin_pipe_belongs_to_the_caller()
  local h = assert(Child.start(lua(CAT, nil, { stdin = "pipe", stdout = "capture" })))
  assert(h.stdin ~= nil)
  assert(Fs.put(h.stdin as integer, "typed"))
  assert(h:close_stdin())
  assert(not h:close_stdin())
  local r = assert(h:wait(5000))
  assert(r.ok and r.stdout == "typed")
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
  assert(h.stdin == nil and h.stderr_stream == nil)
  assert(assert(stdout:read()) == "first")
  assert(stdin:write("go\n"))
  assert(stdin:close())
  assert(read_all(stdout) == "second-go")
  local chunk, trouble = stdout:read()
  assert(chunk == nil and trouble == "")
  local r = assert(h:wait(5000))
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
  assert(assert(h:wait(5000)).ok)
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
  assert(assert(h:wait(5000)).ok)
end

--- Unread output is held up to `capture_limit`, and then the child
--- waits for the reader: nothing is dropped.
local function test_a_streamed_output_holds_the_child_at_its_limit()
  local h = assert(Child.start(lua(FS .. 'for _ = 1, 20000 do assert(Fs.put(1, "0123456789")) end',
    nil, { stdout = "stream", capture_limit = 100 })))
  local deadline = Time.monotonic_ns() + 300 * 1000 * 1000
  while Time.monotonic_ns() < deadline do
    assert(not assert(h:try_wait()).finished, "the child ran past its reader")
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(read_all(assert(h.stdout_stream)) == string.rep("0123456789", 20000))
  assert(assert(h:wait(5000)).ok)
end

--- What the child wrote before a wait settled it is still there to
--- read afterward.
local function test_a_streamed_output_is_read_after_the_wait()
  local h = assert(Child.start(lua(FS .. 'Fs.put(1, "hello") Fs.put(2, "there")', nil,
    { stdout = "stream", stderr = "stdout" })))
  assert(assert(h:wait(5000)).ok)
  assert(read_all(assert(h.stdout_stream)) == "hellothere")
end

--- A streamed output ends once the child has exited and nothing more
--- is waiting, though a descendant that left the group holds it open.
local function test_an_escaped_writer_does_not_hold_up_a_read()
  local started = Time.monotonic_ns()
  local h = assert(Child.start(lua(AGAIN .. "again('" .. sleep(3000) .. "') " .. FS ..
    'Fs.put(1, "done") require("cosmic.sys").exit(0)', nil, { stdout = "stream" })))
  assert(read_all(assert(h.stdout_stream)):sub(1, 4) == "done")
  assert(Time.monotonic_ns() - started < 2 * 1000 * 1000 * 1000)
  assert(assert(h:wait(5000)).ok)
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
  local r = assert(h:wait(5000))
  assert(not r.timed_out, "the writer was left blocked on the closed pipe")
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
  assert(assert(h:wait(5000)).ok)
  Time.sleep_ns(100 * 1000 * 1000)
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
  assert(assert(h:wait(5000)).ok)
end

--- A write after the wait says the child has gone; one after its own
--- close says it is closed.
local function test_a_stdin_stream_write_after_the_wait_says_why()
  local h = assert(Child.start(lua("", nil, { stdin = "stream" })))
  local stdin = assert(h.stdin_stream)
  assert(assert(h:wait(5000)).ok)
  local wrote, trouble = stdin:write("late")
  assert(not wrote and trouble == "the child has exited", trouble)
  assert(stdin:close())
  local again, again_trouble = stdin:write("later")
  assert(not again and again_trouble:find("closed", 1, true) ~= nil, again_trouble)
end

local function test_run_refuses_a_stream()
  for _, opts in ipairs({
    { stdin = "stream" }, { stdout = "stream" }, { stderr = "stream" },
  } as {Child.Options}) do
    local ok, message = pcall(Child.run, { "/bin/sh", "-c", "exit 0" }, opts)
    assert(not ok and tostring(message):find("Child.start", 1, true), tostring(message))
  end
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "stream", input = "x" } as Child.Options))
end

--- A caller writing to a `stdin = "pipe"` child that has gone gets
--- EPIPE, not SIGPIPE: the write fails and this process lives on. Run
--- in a relaunched process, since one that already ignores SIGPIPE (a
--- test runner that fed some child `input`) has no case to show.
local function test_writing_to_a_gone_stdin_pipe_fails_instead_of_ending(tmp: string)
  if Proc.relaunch() == nil then return end -- a native start has nothing to relaunch
  local script = tmp .. "/writes.tl"
  assert(Fs.write(script, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
return function(): integer
  -- The child closes its end of the pipe and lingers; writing a chunk
  -- past what the pipe holds meets the closed end whenever it closes.
  local relaunch = assert(Proc.relaunch())
  local argv = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "require('cosmic.sys').close(0) require('cosmic.time').sleep_ns(5000000000)"
  local h = assert(Child.start(argv, { stdin = "pipe", env = relaunch.env, fds = relaunch.fds }))
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
  local started = observations.program({ script }, { cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.signal == nil and r.ok, "ended by signal " .. tostring(r.signal) .. ": " ..
    tostring(r.stderr))
  assert(assert(r.stdout):find("^false "), r.stdout)
end

local function test_try_wait_services_a_chatty_child()
  local h = assert(Child.start(lua(FS .. 'assert(Fs.put(1, string.rep("0123456789", 20000)))',
    nil, { stdout = "capture" })))
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
  local r = assert(Child.run(lua(FS .. 'Fs.put(1, "partial") ' .. sleep(30000), nil,
    { stdout = "capture", timeout_ms = 200 })))
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
    local r = assert(h:wait(5000))
    assert(r.ok and not r.timed_out and assert(math.tointeger(tonumber(r.stdout))) > 0)
    local alive, _, errno = sys.kill(-h.pid, 0)
    assert(not alive and errno == sys.ESRCH, "a member of group " .. tostring(h.pid) ..
      " survived")
  end
  check()
end

--- `end_strays` ends a stray whatever it calls itself: one named as a
--- sandbox's init is (/proc/<pid>/comm), since only the process table's
--- own record says which children are inits. The stray is orphaned to
--- this process, which adopts it, in the worker's pid namespace.
--- Only where /proc lists a process's children does `end_strays` find
--- any (Linux, as the guard test's zombie check finds /proc there).
local function test_end_strays_ends_a_stray_named_as_an_init()
  if not path_exists("/proc/thread-self/children") then return end
  do
    -- A group started first makes this process the subreaper it adopts
    -- the stray as.
    assert(Child.run(lua("")))
    local r = assert(Child.run(lua(AGAIN .. "local h = again([=[" .. SYS ..
      'local fd = assert(sys.open("/proc/self/comm", sys.O_WRONLY)) ' ..
      'assert(sys.write(fd, "cosmic-init")) while true do ' .. sleep(1000) .. "end]=], " ..
      '{ process_group = false, stdout = "null", stderr = "null" }) ' .. FS ..
      'Fs.put(1, tostring(h.pid)) require("cosmic.sys").exit(0)', nil,
      { stdout = "capture", process_group = false })))
    local pid = assert(math.tointeger(tonumber(r.stdout)))
    local name = Fs.read("/proc/" .. tostring(pid) .. "/comm")
    local by = Time.monotonic_ns() + 5 * 1000 * 1000 * 1000
    while name ~= "cosmic-init\n" and Time.monotonic_ns() < by do
      Time.sleep_ns(10 * 1000 * 1000)
      name = Fs.read("/proc/" .. tostring(pid) .. "/comm")
    end
    assert(name == "cosmic-init\n", tostring(name))
    assert(Child.end_strays() >= 1)
    local alive, _, errno = sys.kill(pid, 0)
    assert(not alive and errno == sys.ESRCH, "the stray named cosmic-init survived")
  end
end

--- Completion is the leader's exit: a descendant that left the group
--- while holding the captured pipe cannot hold the wait open.
local function test_an_escaped_writer_does_not_hold_up_the_wait()
  local started = Time.monotonic_ns()
  local r = assert(Child.run(lua(AGAIN .. "again('" .. sleep(3000) .. "') " .. FS ..
    'Fs.put(1, "done") require("cosmic.sys").exit(0)', nil,
    { stdout = "capture", timeout_ms = 10000 })))
  assert(r.ok and assert(r.stdout):sub(1, 4) == "done")
  assert(Time.monotonic_ns() - started < 2 * 1000 * 1000 * 1000)
end

local function test_wait_any_returns_the_first_to_finish()
  local slow = assert(Child.start(lua(sleep(5000))))
  local fast = assert(Child.start(lua(FS .. 'Fs.put(1, "quick")', nil, { stdout = "capture" })))
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

--- A child started with a `sandbox` has only what it unveils, a path
--- at the name `at` gives it, and is held there with every process it
--- starts; a relative unveiled path is refused. Where the kernel will not
--- sandbox a child (not Linux, or no unprivileged user namespaces), the
--- start fails and says why, but under COSMIC_SANDBOX=must.
local function test_a_sandboxed_child_has_only_what_it_unveils(tmp: string)
  local given, hidden = tmp .. "/given", tmp .. "/hidden"
  assert(Fs.mkdirs(given))
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(given .. "/f", "in"))
  local reads = observations.itself()
  reads[#reads + 1] = given
  reads[#reads + 1] = "/proc"
  reads[#reads + 1] = "/dev/null"
  local r, trouble = Child.run(lua(AGAIN .. FS .. SYS .. 'local hidden, given = ... ' ..
    'Fs.put(1, assert(Fs.read("f")) .. "\\n" .. assert(sys.getcwd()) .. "\\n" .. ' ..
    '(Fs.exists(hidden) == true and "hidden-seen" or "hidden-absent") .. "\\n") ' ..
    'local own = assert(again("return require(\'cosmic.fs\').exists(" .. ' ..
    'string.format("%q", given) .. ") == true and 0 or 1"):wait()) ' ..
    'Fs.put(1, (own.code == 0 and "own-name" or "no-own-name") .. "\\n")', { hidden, given },
    { cwd = "/given", stdout = "capture", stderr = "stdout",
      sandbox = { unveil = { reads = reads, at = { [given] = "/given" } }, offline = true } }))
  if r == nil then
    assert(sys.getenv("COSMIC_SANDBOX") ~= "must", "COSMIC_SANDBOX=must, but: " .. trouble)
    -- Only as a kernel that cannot sandbox refuses.
    local refused = false
    for _, errno in ipairs({ sys.ENOSYS, sys.EPERM, sys.EACCES, sys.EINVAL, sys.ENOSPC }) do
      if trouble == "start: " .. sys.errno_message(errno) then refused = true end
    end
    assert(refused, trouble)
    return
  end
  assert(r.ok and r.stdout == "in\n/given\nhidden-absent\nno-own-name\n", tostring(r.stdout))
  assert(not pcall(Child.start, { "/bin/sh" },
    { sandbox = { unveil = { reads = { "relative" } } } } as Child.Options))
end

local function test_start_refuses_a_timeout_it_would_not_honour()
  local ok, message = pcall(Child.start, { "/bin/sh", "-c", "exit 0" },
    { timeout_ms = 10 } as Child.Options)
  assert(not ok)
  assert(tostring(message):find("h:wait", 1, true), tostring(message))
  local r = assert(Child.run(lua("", nil, { timeout_ms = 10000 })))
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
local function test_guard_keeps_a_signal_and_delivers_it_on_close(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/guarded.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local relaunch = assert(Proc.relaunch())
local function this(chunk: string): Child.Handle
  local words = { table.unpack(relaunch.argv) }
  words[#words + 1] = "-e"
  words[#words + 1] = chunk
  return (assert(Child.start(words, { env = relaunch.env, fds = relaunch.fds })))
end
return function(argv: {string}): integer
  do
    local guard <close> = assert(Child.guard())
    local timed = this("require('cosmic.time').sleep_ns(30000000000)")
    local untimed = this("require('cosmic.time').sleep_ns(30000000000)")
    local done = this("return 3")
    -- Until `done` has exited: Linux shows it as a zombie in /proc;
    -- elsewhere, half a second is ample for `return 3`.
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
  local started = observations.program({ fixture, report },
    { stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
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
local function test_guard_release_keeps_the_signal_from_close(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/released.tl"
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
  local started = observations.program({ fixture, report },
    { stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, term, term, "true" }, "|"), tostring(got))
end

--- A guard keeps taking signals after its first: a SIGTERM after a
--- Ctrl-C the child handled is what a supervisor must pass on next,
--- and release answers the last one delivered rather than losing it. The nested
--- cosmic outlives both.
local function test_guard_release_answers_the_last_signal(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/latest.tl"
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
  local started = observations.program({ fixture, report },
    { stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local int, term = tostring(sys.SIGINT), tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ int, term, term }, "|"), tostring(got))
end

--- `take` answers each signal once, a repeat of the same one included,
--- while `cancelled` keeps answering the last: a supervisor passes a
--- second SIGTERM on after its child handled the first.
local function test_guard_take_answers_a_repeated_signal_again(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/take.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:take())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:cancelled())
  answers[#answers + 1] = tostring(guard:take())
  answers[#answers + 1] = tostring(guard:take())
  answers[#answers + 1] = tostring(guard:cancelled())
  answers[#answers + 1] = tostring((guard:release()))
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = observations.program({ fixture, report },
    { stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, term, term, "0", term, term }, "|"), tostring(got))
end
