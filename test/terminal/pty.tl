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
else
  local session = assert(Child.run({ assert(Proc.executable()), arg[0], "session" },
    { process_group = false, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) }))
  assert(session.ok, session.stderr)
  assert((assert(session.stdout)):find("pty: PASS", 1, true))
  if (assert(sys.uname())).sysname == "Linux" then
    pty = assert(sys.openpty())
    assert(sys.tcraw(pty.slave))
    local process = process_table()
    local pid = assert(process.spawn("/bin/sh", { "/bin/sh", "-c",
      "test -t 0 && test -t 1 && test -t 2 && printf controlling-terminal >/dev/tty" }, nil, nil,
      pty.slave, pty.slave, pty.slave, true, nil, nil, nil, true))
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

    -- The relay's own start accepts the terminal under a policy, as the
    -- program's stdio and its controlling terminal, and still refuses one
    -- on another descriptor.
    pty = assert(sys.openpty())
    local other = assert(sys.openpty())
    assert(sys.tcraw(pty.slave))
    local program = { "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2 && printf held-terminal" }
    child, trouble = Child.start_on_terminal(program,
      { policy = { profiles = { "system" } }, fds = { [3] = other.slave } }, pty.slave)
    assert_terminal_refusal(child, trouble, "fds[3]")
    local own_stdin = pcall(Child.start_on_terminal, program, { stdin = "null" }, pty.slave)
    assert(not own_stdin)
    local held = assert(Child.start_on_terminal(program, { policy = { profiles = { "system" } } }, pty.slave))
    assert(sys.close(pty.slave))
    assert(Poll.readable(pty.master, Clock.seconds(5)))
    assert((assert(sys.read(pty.master, 100))) == "held-terminal")
    assert((assert(held:wait())).code == 0)
    assert(sys.close(pty.master))
    assert(sys.close(other.slave))
    assert(sys.close(other.master))
  end
end
print("pty: PASS")
