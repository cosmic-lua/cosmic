--- Runs `cosmic sandbox` on a terminal, as a user would, and checks what
--- its pty relay does with it (build/term_relay.tl): the program runs on
--- a terminal of its own, what it writes reaches the caller's terminal
--- through the filter (an allowed sequence passes, OSC 52 and a title do
--- not), what the caller types reaches it, the caller's window size
--- reaches it, at the start and when it changes, its status is the
--- relay's, and the caller's termios is as it was once it has ended.
---
--- It needs a pty and the sandbox's own start, which the test workers
--- have neither of, so the CI fixture runs it unsandboxed
--- (ci/fixtures/self_driven_test.tl); `cosmic test/terminal/relay.tl` runs
--- it by hand. On a platform that cannot give a program a controlling
--- terminal (macOS) it checks the refusal instead: a clear failure, 125.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local exe = assert(Proc.executable())
local pty = assert(sys.openpty())
assert(sys.setwinsize(pty.master, 37, 111))
local before = assert(sys.tcgetattr(pty.slave))

--- What the caller's terminal has shown so far.
local shown = ""

--- Reads the caller's terminal until what it has shown holds `needle`,
--- or `seconds` pass.
local function wait_for(needle: string, seconds: integer)
  local deadline = Clock.monotonic_ns() + Clock.seconds(seconds)
  while not shown:find(needle, 1, true) do
    local left = deadline - Clock.monotonic_ns()
    assert(left > 0, "no " .. string.format("%q", needle) .. " in " .. string.format("%q", shown))
    local ready, _ = Poll.readable(pty.master, left)
    if ready then
      local data, why = sys.read(pty.master, 4096)
      assert(data ~= nil and data ~= "", "the terminal closed: " .. tostring(why) .. string.format(" %q", shown))
      shown = shown .. data
    end
  end
end

--- Reads what is left to read without waiting for more.
local function drain()
  while true do
    local ready, _ = Poll.readable(pty.master, Clock.ms(200))
    if not ready then return end
    local data, _ = sys.read(pty.master, 4096)
    if data == nil or data == "" then return end
    shown = shown .. data
  end
end

local function start(program: {string}): Child.Handle
  local argv: {string} = { exe, "sandbox", "--system", "--env", "PATH", "--promise", "fork", "--" }
  for _, word in ipairs(program) do argv[#argv + 1] = word end
  local child, why = Child.start(argv, {
    stdin = pty.slave, stdout = pty.slave, stderr = pty.slave, timeout_ns = Clock.seconds(60),
  })
  assert(child, why)
  return child
end

if (assert(sys.uname())).sysname ~= "Linux" then
  local child = start({ "/bin/sh", "-c", "exit 0" })
  local result = assert(child:wait())
  drain()
  assert(result.code == 125, string.format("%q", shown))
  assert(shown:find("Seatbelt", 1, true), string.format("%q", shown))
  print("relay: PASS (refused: no controlling terminal on this platform)")
  sys.exit(0)
end

local script = table.concat({
  "[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo tty-ok",
  "printf 'A\\033[1mB\\033[0m\\033]52;c;aGVsbG8=\\007\\033]0;title\\007C\\n'",
  "stty size",
  "read line",
  "stty size",
  "echo got:$line",
  "exit 7",
}, "\n")
local child = start({ "/bin/sh", "-c", script })
wait_for("37 111", 30)
-- The caller's terminal is raw while the program runs.
assert(assert(sys.tcgetattr(pty.slave)) ~= before, "the caller's terminal was not made raw")
assert(sys.setwinsize(pty.master, 50, 120))
-- The relay looks at the window between its waits.
assert(sys.nanosleep(Clock.ms(300)))
assert(sys.write(pty.master, "hello\r"))
wait_for("got:hello", 30)
local result = assert(child:wait())
drain()
assert(result.code == 7 and result.signal == nil, "exit status " .. tostring(result.code) ..
    string.format(" %q", shown))
assert(shown:find("tty-ok", 1, true), "the program had no terminal: " .. string.format("%q", shown))
assert(shown:find("A\27[1mB\27[0mC", 1, true), "an allowed sequence did not pass: " ..
    string.format("%q", shown))
assert(not shown:find("\27]", 1, true) and not shown:find("52;c", 1, true) and
    not shown:find("aGVsbG8=", 1, true) and not shown:find("title", 1, true),
  "OSC reached the terminal: " .. string.format("%q", shown))
assert(shown:find("50 120", 1, true), "the window size change did not reach the program")
assert(assert(sys.tcgetattr(pty.slave)) == before, "the caller's termios was not restored")
assert(sys.close(pty.slave))
assert(sys.close(pty.master))
print("relay: PASS")
