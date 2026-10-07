local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

local type Searcher = function(string): any, any
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers may return the raw loader argument
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: core/process.h declares this loader argument
    end
  end
  error("cosmic.child has no process table")
end

local function assert_terminal_refusal(child: Child.Handle | nil, trouble: string, slot: string)
  assert(child == nil)
  assert(trouble:find("terminal " .. slot, 1, true), trouble)
end

local pty = assert(sys.openpty())
assert(pty.master ~= pty.slave)
assert(sys.isatty(pty.master) and sys.isatty(pty.slave))
assert((assert(sys.fd_flags(pty.master))) & sys.FD_CLOEXEC ~= 0)
assert((assert(sys.fd_flags(pty.slave))) & sys.FD_CLOEXEC ~= 0)
local saved = assert(sys.tcgetattr(pty.slave))
local restored, restore_trouble, restore_errno = sys.tcsetattr(-1, saved)
assert(restored == false and restore_trouble ~= "" and restore_errno > 0)
assert(sys.tcraw(pty.slave))
assert((assert(sys.tcgetattr(pty.slave))) ~= saved)
assert(sys.tcsetattr(pty.slave, saved))
local returned = assert(sys.tcgetattr(pty.slave))
if returned ~= saved then
  -- A BSD kernel (macOS) sets PENDIN as a terminal leaves raw mode for
  -- canonical, so a restore differs from the state saved by that flag
  -- alone; a second round trip from the restored state must match it.
  assert(sys.tcraw(pty.slave))
  assert(sys.tcsetattr(pty.slave, returned))
  assert((assert(sys.tcgetattr(pty.slave))) == returned)
end
assert(sys.setwinsize(pty.master, 37, 111))
local size = assert(sys.winsize(pty.slave))
assert(size.rows == 37 and size.columns == 111)
assert(sys.tcraw(pty.slave))
local bytes = "a\0\3\n\27[31m"
assert((assert(sys.write(pty.master, bytes))) == #bytes)
assert(Poll.readable(pty.slave, Clock.seconds(5)))
assert((assert(sys.read(pty.slave, 100))) == bytes)
assert((assert(sys.write(pty.slave, bytes))) == #bytes)
assert(Poll.readable(pty.master, Clock.seconds(5)))
assert((assert(sys.read(pty.master, 100))) == bytes)
assert((assert(sys.write(pty.master, "discard-me"))) == 10)
assert(sys.tcflush(pty.slave))
local readable, why = Poll.readable(pty.slave, Clock.ms(20))
assert(not readable and why == Poll.TIMEOUT)
assert(sys.setwinsize(pty.master, 43, 132))
size = assert(sys.winsize(pty.slave))
assert(size.rows == 43 and size.columns == 132)
assert(sys.tcsetattr(pty.slave, saved))
assert(sys.close(pty.slave))
assert(sys.close(pty.master))

if arg[1] == "session" then
  pty = assert(sys.openpty())
  assert(sys.controlling_terminal(pty.slave))
  assert((assert(sys.getpgid(0))) == sys.getpid())
  local tty = assert(sys.open("/dev/tty", sys.O_RDWR))
  assert(sys.isatty(tty))
  assert(sys.close(tty))
  assert(sys.close(pty.slave))
  -- Closing the master sends SIGHUP to our session; exit owns its close.
  print("pty: PASS")
  sys.exit(0)
elseif arg[1] == "inherited" then
  -- Started by the test of start_on_pty, with a terminal of its own on one
  -- of its standard streams, which the pty's streams do not replace.
  local program = { "/bin/sh", "-c", "exit 0" }
  local case = arg[2]
  local streams: {integer} = { 1 }
  local opts: Child.Options = { policy = { profiles = { "system" } } }
  local slot = "stdio[0]"
  if case == "stderr" then
    streams, slot = { 0, 1 }, "stdio[2]"
  elseif case == "alias" then
    -- stderr is stdout's, which is the terminal this process holds.
    streams, slot, opts.stderr = { 0 }, "stdio[1]", "stdout"
  end
  local child, refusal = Child.start_on_pty(program, opts, { streams = streams })
  assert(child == nil, "a terminal this process holds reached a policy child")
  assert_terminal_refusal(nil, refusal, slot)
  print("inherited: PASS")
  sys.exit(0)
else
  local session = assert(Child.run({ assert(Proc.executable()), arg[0], "session" },
    { process_group = false, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) }))
  assert(session.ok, session.stderr)
  assert((assert(session.stdout)):find("pty: PASS", 1, true))
  do
    pty = assert(sys.openpty())
    assert(sys.tcraw(pty.slave))
    local process = process_table()
    local pid = assert(process.spawn("/bin/sh", { "/bin/sh", "-c",
      "test -t 0 && test -t 1 && test -t 2 && printf controlling-terminal >/dev/tty" }, nil, nil,
      pty.slave, pty.slave, pty.slave, true, nil, nil, nil, (assert(sys.ttyname(pty.slave)))))
    assert(sys.close(pty.slave))
    assert(Poll.readable(pty.master, Clock.seconds(5)))
    assert((assert(sys.read(pty.master, 100))) == "controlling-terminal")
    assert((assert(process.waitpid(pid, false))).code == 0)
    assert(sys.close(pty.master))

    pty = assert(sys.openpty())
    for number = 0, 2 do
      local options: Child.Options = { policy = { profiles = { "system" } },
        stdin = "null", stdout = "null", stderr = "null" }
      if number == 0 then
        options.stdin = pty.slave
      elseif number == 1 then
        options.stdout = pty.slave
      else
        options.stderr = pty.slave
      end
      local child, trouble = Child.start({ "/bin/sh", "-c", "exit 0" }, options)
      assert_terminal_refusal(child, trouble, "stdio[" .. number .. "]")
    end
    local child, trouble = Child.start({ "/bin/sh", "-c", "exit 0" }, {
      policy = { profiles = { "system" } },
      stdin = "null", stdout = "null", stderr = "null", fds = { [3] = pty.slave } })
    assert_terminal_refusal(child, trouble, "fds[3]")
    assert(sys.close(pty.slave))
    assert(sys.close(pty.master))

    -- The one start that gives a policy's child a terminal opens the pty
    -- itself, so a terminal the caller holds reaches the child by no
    -- entry point: not as stdio or on another descriptor through
    -- Child.start (refused above), and not through this either.
    local real = assert(sys.openpty())
    local program = { "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2 && printf held-terminal" }
    local held_policy: Child.Options = { policy = { profiles = { "system" } } }
    local function refused_on_pty(opts: Child.Options, streams: {integer}, slot: string)
      opts.policy = held_policy.policy
      local started, refusal = Child.start_on_pty(program, opts, { streams = streams })
      assert(started == nil)
      assert_terminal_refusal(nil, refusal, slot)
    end
    refused_on_pty({ stdin = real.slave }, { 1 }, "stdio[0]")
    refused_on_pty({ stdout = real.slave }, { 0 }, "stdio[1]")
    refused_on_pty({ stderr = real.slave }, { 0 }, "stdio[2]")
    refused_on_pty({ stdout = "null", stderr = "null", fds = { [3] = real.slave } },
      { 0 }, "fds[3]")
    local also, also_why = pcall(Child.start_on_pty, program, { stdin = real.slave }, { streams = { 0 } })
    assert(not also and tostring(also_why):find("takes no stdin, input, stdout or stderr of its own", 1, true),
      tostring(also_why))

    -- A stream not on the pty that is this process's own terminal, which no
    -- option names: the refusal looks at the descriptor the child would get.
    local function inherited(case: string, opts: Child.Options)
      opts.timeout_ns = Clock.seconds(20)
      local ran = assert(Child.run({ assert(Proc.executable()), arg[0], "inherited", case }, opts))
      local said = "code " .. tostring(ran.code) .. " signal " .. tostring(ran.signal) ..
        " stderr " .. tostring(ran.stderr) .. " stdout " .. tostring(ran.stdout)
      if not ran.ok or (ran.stdout ~= nil and not ran.stdout:find("inherited: PASS", 1, true)) then
        error(said, 0)
      end
    end
    inherited("stdin", { stdin = real.slave, stdout = "capture", stderr = "capture" })
    inherited("stderr", { stdin = "null", stdout = "capture", stderr = real.slave })
    inherited("alias", { stdin = "null", stdout = real.slave, stderr = "capture" })
    assert(sys.close(real.slave))
    assert(sys.close(real.master))

    local started = assert(Child.start_on_pty(program, held_policy, { streams = { 0, 1, 2 }, rows = 30, columns = 90 }))
    assert(Poll.readable(started.master, Clock.seconds(5)))
    assert((assert(sys.read(started.master, 100))) == "held-terminal")
    assert((assert(started.child:wait())).code == 0)
    assert(sys.close(started.master))

    -- Only the streams named are the pty: stdout on it, stdin none (so no
    -- controlling terminal), stderr a pipe of its own.
    local mixed = assert(Child.start_on_pty({ "/bin/sh", "-c",
      "test -t 1 && ! test -t 0 && ! test -t 2 && printf out && printf err >&2" },
      { policy = { profiles = { "system" } }, stdin = "null", stderr = "capture" }, { streams = { 1 } }))
    assert(Poll.readable(mixed.master, Clock.seconds(5)))
    assert((assert(sys.read(mixed.master, 100))) == "out")
    local done = assert(mixed.child:wait())
    assert(done.code == 0 and done.stderr == "err", tostring(done.stderr))
    assert(sys.close(mixed.master))
  end
end
print("pty: PASS")
