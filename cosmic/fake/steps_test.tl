--- [`cosmic.fake.steps`], the steps a fake main is made of: what
--- each says, and the status it ends with, run in a fake of
--- build/fake_steps_fake.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Fake = require("cosmic.fake")
-- Required, so the fake's main is of this test's closure.
local _fake = require("build.fake_steps_fake")

--- Runs the fake on `args` with only `env`, its output captured.
local function run(program: string, args: {string}, env?: {string:string}): Child.Result
  return (assert(Child.run({ program, table.unpack(args) }, { env = env or {}, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

local function built(tmp: string): string
  return (assert(Fake.build(tmp .. "/fake", "build.fake_steps_fake")))
end

--- A case it has no name for fails, saying which.
local function test_a_case_of_no_name_fails(tmp: string)
  local ran = run(built(tmp), { "no-such-case" })
  assert(ran.code == 1 and assert(ran.stderr):find("no case no-such-case", 1, true) ~= nil, ran.stderr)
end

--- `signal` to itself ends it by that signal; to another pid it goes on;
--- 0 and -1, which name no one process, it refuses.
local function test_signal_ends_itself_and_refuses_no_one(tmp: string)
  local program = built(tmp)
  local own = run(program, { "signal", "TERM" })
  assert(own.signal == sys.SIGTERM, tostring(own.code))
  for _, pid in ipairs({ "0", "-1" }) do
    local refused = run(program, { "signal", "TERM", pid })
    assert(refused.code == 1 and assert(refused.stderr):find("refusing pid " .. pid, 1, true) ~= nil, refused.stderr)
  end
  local sleeper = assert(Child.start({ program, "sleep-forever" }, { timeout_ns = Child.FOREVER }))
  local sent = run(program, { "signal", "KILL", tostring(sleeper.pid) })
  assert(sent.code == 0, sent.stderr)
  local ended = assert(sleeper:wait())
  assert(ended.signal == sys.SIGKILL, tostring(ended.code))
end

--- `run` ends with what it ran ended with, 128 past a signal, and 127
--- where the program cannot start.
local function test_run_ends_as_a_shell_says(tmp: string)
  local program = built(tmp)
  assert(run(program, { "run", program, "write-fd", "1", "inner" }).stdout == "inner\n")
  local signalled = run(program, { "run", program, "signal", "TERM" })
  assert(signalled.code == 128 + sys.SIGTERM, tostring(signalled.code))
  local missing = run(program, { "run", tmp .. "/missing" })
  assert(missing.code == 127, tostring(missing.code))
end

--- `env-of` tells an empty variable from an unset one.
local function test_env_of_tells_empty_from_unset(tmp: string)
  local program = built(tmp)
  assert(run(program, { "env-of", "NAME" }, { NAME = "" }).stdout == "NAME=\n")
  assert(run(program, { "env-of", "NAME" }).stdout == "NAME unset\n")
end

--- `write-fd` writes to the descriptor it names, and refuses one that is
--- none.
local function test_write_fd_writes_where_it_is_told(tmp: string)
  local program = built(tmp)
  assert(run(program, { "write-fd", "2", "to stderr" }).stderr == "to stderr\n")
  local none = run(program, { "write-fd", "x", "lost" })
  assert(none.code == 1 and assert(none.stderr):find("no descriptor", 1, true) ~= nil, none.stderr)
end

--- `status-field` fails on a field /proc/self/status lacks.
local function test_status_field_fails_on_a_missing_field(tmp: string)
  if not assert(Fs.status("/proc/self/status")).exists then Test.skip("this host has no /proc") end
  local program = built(tmp)
  assert(assert(run(program, { "status-field", "SigIgn" }).stdout):match("^SigIgn:%s*%x+\n$"))
  local missing = run(program, { "status-field", "NoSuchField" })
  assert(missing.code == 1 and missing.stdout == "", missing.stdout)
end

--- `connect` says why a unix socket file it cannot connect to is refused.
local function test_connect_says_why(tmp: string)
  local said = run(built(tmp), { "connect", tmp .. "/none.sock" })
  assert(said.code == 0 and said.stdout ~= "connected\n" and said.stdout ~= "", said.stdout)
end

--- `find-writable` lists the regular files that open to write, and not a
--- link to one or a pipe.
local function test_find_writable_lists_only_files(tmp: string)
  local dir = tmp .. "/tree"
  assert(Fs.mkdirs(dir .. "/sub"))
  assert(Fs.write(dir .. "/sub/f", "x"))
  assert(Fs.symlink(dir .. "/sub/f", dir .. "/link"))
  assert(sys.mkfifo(dir .. "/fifo"))
  local said = run(built(tmp), { "find-writable", dir })
  assert(said.code == 0 and said.stdout == dir .. "/sub/f\n", said.stdout)
end

--- What a failure `attempt` takes up is not said.
local function test_attempt_says_nothing_of_what_it_takes_up(tmp: string)
  local said = run(built(tmp), { "attempt", tmp .. "/missing" })
  assert(said.code == 0 and said.stdout == "taken up\n" and said.stderr == "", said.stderr)
end

--- A count, a program or a mode that is no such thing is refused, saying
--- which, before anything is started or changed.
local function test_a_step_refuses_what_is_no_number_or_program(tmp: string)
  local program = built(tmp)
  local count = run(program, { "start-count", "-1", program })
  assert(count.code == 1 and assert(count.stderr):find("start-count: no count -1", 1, true) ~= nil, count.stderr)
  local none = run(program, { "run-isolated" })
  assert(none.code == 1 and assert(none.stderr):find("run-isolated: no program", 1, true) ~= nil, none.stderr)
  local mode = run(program, { "chmod", tmp .. "/fake", "-1" })
  assert(mode.code == 1 and assert(mode.stderr):find("chmod: no mode -1", 1, true) ~= nil, mode.stderr)
end
