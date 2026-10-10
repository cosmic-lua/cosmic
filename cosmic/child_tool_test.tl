--- The cases of cosmic.child whose child runs a file: this program again,
--- past its launcher, where a shell would need the system's. They declare
--- `tool`: a file run builds the tree the file sits in, which loads far
--- more of the program than a `lua` declaration holds. The cases whose
--- child is sandboxed are in cosmic/child_sandbox_tool_test.tl, which needs
--- a sandbox the host gives, and what a platform with none does is here.
--- The cases whose child only runs a chunk are in cosmic/child_lua_test.tl;
--- the cases that start nothing are in cosmic/child_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local confine = require("build.confine")
local child_tool_fixture = require("build.child_tool_fixture")
local this_program = require("build.this_program")

--- What the tests read: /proc, where a test finds a child's processes;
--- the program itself (`tool`), which every child is, started past its
--- launcher so that no host program is read; and `nests`, for a child
--- sandboxed in a root of its own.
Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
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

--- This program again, past its launcher ([`this_program.program`]),
--- running the Lua chunk `chunk` with `args` as its `...`: the child
--- each test starts, where a shell would need the system's. The argv
--- and options, for [`Child.run`] or [`Child.start`].
local function lua(chunk: string, args?: {string}, opts?: Child.Options): {string}, Child.Options
  local words: {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  local started = this_program.program(words, opts)
  return started.argv, started.options
end

local sleeping, AGAIN = child_tool_fixture.sleeping, child_tool_fixture.AGAIN

--- A child that catches nothing is ended by a timeout's SIGTERM, not
--- left for the SIGKILL after the grace period. The same of a child in a
--- sandbox of its own is in cosmic/child_sandbox_tool_test.tl.
local function test_a_timeout_ends_a_child_that_catches_nothing()
  local r = assert(Child.run(lua(sleeping(100000), nil,
    { timeout_ns = Clock.ms(200), process_group = false })))
  assert(r.timed_out and r.signal == sys.SIGTERM, "ended by " .. tostring(r.signal))
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
  local started = this_program.program({ fixture, stdin })
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
  words[#words + 1] = AGAIN .. "local h = again('" .. ]] .. string.format("%q", sleeping(30000)) .. [[ ..
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
  local started = this_program.program({ fixture, descendant_path, ready },
    { stdout = fd, stderr = fd, process_group = false })
  local driver = assert(Child.start(started.argv, started.options))
  -- The driver is a nested cosmic that compiles its fixture before it
  -- spawns anything; on the checked core, on a loaded runner, that has
  -- taken more than 3 s. The wait ends as soon as it is ready.
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  while (not path_exists(ready) or Fs.read(ready) ~= "ready") and
      Clock.monotonic_ns() < deadline do
    Clock.sleep_ns(Clock.ms(10))
  end
  assert(path_exists(ready) and Fs.read(ready) == "ready",
    "driver did not report readiness; log=" .. (Fs.read(diagnostic) or "<none>"))
  local descendant = assert(host_pid(driver.pid, assert(math.tointeger((assert(tonumber(
    assert(Fs.read(descendant_path)):match("%d+"))))))))
  assert(driver:stop(sys.SIGTERM))
  -- Generous, as the start was: a driver that ignored the signal is
  -- told apart by the signal its Result names, not by the time.
  local stopped = assert(driver:wait(Clock.seconds(8)))
  assert(Fs.close(fd))
  assert(stopped.signal == sys.SIGTERM,
    "driver cancellation result code=" .. tostring(stopped.code) ..
      " signal=" .. tostring(stopped.signal) .. " log=" ..
      (Fs.read(diagnostic) or "<none>"))
  local gone_by = Clock.monotonic_ns() + Clock.seconds(1)
  while sys.kill(descendant, 0) and Clock.monotonic_ns() < gone_by do
    Clock.sleep_ns(Clock.ms(10))
  end
  assert(not sys.kill(descendant, 0))
end

--- A caller writing to a `stdin = "stream"` child that has gone gets
--- EPIPE, not SIGPIPE: the write fails and this process lives on. Run
--- in a relaunched process, since one that already ignores SIGPIPE (a
--- test runner that fed some child `input`) has no case to show.
local function test_writing_to_a_gone_stdin_stream_fails_instead_of_ending(tmp: string)
  if Proc.relaunch() == nil then
    Test.skip("a native start has nothing to relaunch")
    return
  end
  local script = tmp .. "/writes.tl"
  assert(Fs.write(script, [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
return function(): integer
  -- The child closes its end of the pipe and lingers; writing a chunk
  -- past what the pipe holds meets the closed end whenever it closes.
  local relaunch = assert(Proc.relaunch())
  local argv = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "require('cosmic.sys').close(0) require('cosmic.clock').sleep_ns(5000000000)"
  local h = assert(Child.start(argv, { stdin = "stream", env = relaunch.env, fds = relaunch.fds }))
  local stdin = assert(h.stdin_stream)
  local chunk = string.rep("x", 1 << 20)
  local ok, trouble = true, ""
  for _ = 1, 8 do
    ok, trouble = stdin:write(chunk)
    if not ok then break end
  end
  print(tostring(ok) .. " " .. trouble)
  local _, _ = h:stop()
  return 0
end
]]))
  local started = this_program.program({ script }, { cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.signal == nil and r.ok, "ended by signal " .. tostring(r.signal) .. ": " ..
      tostring(r.stderr))
  assert(assert(r.stdout):find("^false "), r.stdout)
end

--- A handle that has settled has no process left to signal, and the
--- refusal, which is no system call's, names the module.
local function test_stopping_a_reaped_child_names_the_module()
  local relaunch = assert(Proc.relaunch())
  local argv = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "local _ = 1"
  local h = assert(Child.start(argv, { env = relaunch.env, fds = relaunch.fds }))
  assert(h:wait())
  local stopped, why = h:stop()
  assert(stopped == false and why == "child: process already reaped", tostring(why))
end

--- Where the platform has no sandbox for a child (anything but Linux), a
--- start with a `sandbox` fails and says why, as a kernel that cannot
--- sandbox refuses. A platform that has one runs the child, in
--- cosmic/child_sandbox_tool_test.tl.
local function test_a_sandboxed_child_is_refused_where_the_platform_has_no_sandbox(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local reads = confine.itself()
  reads[#reads + 1] = tmp
  local r, trouble = Child.run(lua("local _ = 1", nil,
    { cwd = tmp, sandbox = { unveil = { reads = reads }, offline = true } }))
  assert(r == nil, "a child started in a sandbox where the platform has none")
  -- Only as a kernel that cannot sandbox refuses.
  local refused = false
  for _, errno in ipairs({ sys.ENOSYS, sys.EPERM, sys.EACCES, sys.EINVAL, sys.ENOSPC }) do
    if trouble == "child: start: " .. sys.errno_message(errno) then refused = true end
  end
  assert(refused, trouble)
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
local Signal = require("cosmic.signal")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Clock = require("cosmic.clock")
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
    local guard <close> = assert(Signal.guard())
    local timed = this("require('cosmic.clock').sleep_ns(30000000000)")
    local untimed = this("require('cosmic.clock').sleep_ns(30000000000)")
    local done = this("return 3")
    -- Until `done` has exited, its status unclaimed: on its exit watch,
    -- or, for a child with none (a Linux without pidfd_open, or Darwin's
    -- kqueue refusing a child that has already exited, ESRCH), until
    -- /proc shows it a zombie, where there is a /proc.
    -- TODO: on Darwin the watch may be readable a moment before waitpid
    -- can reap the child (core/syscalls.c's `exit_watch` TODO); once
    -- that is settled, this wait is exact there too.
    if done._exit_fd >= 0 then
      assert(Poll.readable(done._exit_fd, Clock.seconds(8)))
    else
      local stat_path = "/proc/" .. tostring(done.pid) .. "/stat"
      local by = Clock.monotonic_ns() + Clock.seconds(8)
      while true do
        local stat = Fs.read(stat_path)
        if stat == nil or stat:match("^%d+ %b() Z") ~= nil then break end
        assert(Clock.monotonic_ns() < by, "the child did not exit")
        Clock.sleep_ns(Clock.ms(10))
      end
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
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  local cancelled = "true child: cancelled by signal " .. tostring(sys.SIGTERM)
  local expected = table.concat({ cancelled, cancelled, "true", "true", "true",
    "3 false", tostring(sys.SIGTERM) }, "|")
  local got = Fs.read(report)
  assert(got == expected, tostring(got) .. " " .. tostring(r.stderr))
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end

--- A run inside a guard holds a guard of its own: its child runs, and
--- a signal ends it as it would anywhere, which the caller's guard
--- then sees rather than the process dying of it; a run begun after
--- that signal runs to its end. The nested cosmic releases its guard,
--- and outlives the signal its child sent it.
local function test_a_run_inside_a_guard_is_cancelled_and_leaves_the_signal_to_it(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/run_inside.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
local relaunch = assert(Proc.relaunch())
local function this(chunk: string): {string}
  local words = { table.unpack(relaunch.argv) }
  words[#words + 1] = "-e"
  words[#words + 1] = chunk
  return words
end
return function(argv: {string}): integer
  local answers: {string} = {}
  local guard = assert(Signal.guard())
  local options: Child.Options = { env = relaunch.env, fds = relaunch.fds, timeout_ns = Clock.seconds(30) }
  local r, why = Child.run(this("local sys = require('cosmic.sys') " ..
    "assert(sys.kill(" .. tostring(sys.getpid()) .. ", sys.SIGTERM)) " ..
    "require('cosmic.clock').sleep_ns(30000000000)"), options)
  answers[#answers + 1] = tostring(r == nil) .. " " .. why
  answers[#answers + 1] = tostring(guard:cancelled())
  local after = assert(Child.run(this("return 4"), options))
  answers[#answers + 1] = tostring(after.code)
  answers[#answers + 1] = tostring((guard:release()))
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(60) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ "true child: cancelled by signal " .. term, term, "4", term }, "|"),
    tostring(got))
end
