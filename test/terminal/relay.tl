--- Runs `cosmic sandbox` on a terminal, as a user would, and checks what
--- its pty relay does with it (build/term_relay.tl), for each way the
--- caller's standard streams can be terminals:
---   all three: the program runs on a terminal of its own, what it writes
---   reaches the caller's terminal through the filter (an allowed
---   sequence passes, OSC 52 and a title do not), what the caller types
---   reaches it, the caller's window size reaches it, at the start and
---   when it changes, its status is the sandbox's, and the caller's
---   termios is as it was once it has ended;
---   a terminal in and files out: what the program writes to a file is
---   written as it wrote it, unfiltered and untranslated, stdout and
---   stderr apart;
---   a pipe in and a terminal out: the program has no terminal for input,
---   the output is filtered, and the terminal is never made raw;
---   a SIGTERM to the sandbox: it reaches the program, and the sandbox
---   ends by it once the terminal is restored.
---
--- It needs a pty and the sandbox's own start, which the test workers
--- have neither of, so the CI fixture runs it unsandboxed
--- (ci/fixtures/self_driven_test.tl); `cosmic test/terminal/relay.tl` runs
--- it by hand.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local exe = assert(Proc.executable())

--- One caller's terminal: a pty of its own, and what it has shown.
local record Caller
  master: integer
  slave: integer
  before: string
  shown: string
end

--- Whether two termios states (opaque bytes from tcgetattr) are the same
--- terminal setting. A BSD kernel (macOS) sets PENDIN in the local flags
--- by itself as a terminal leaves raw mode for canonical, so a restored
--- state differs from the one saved by that flag alone: it is left out,
--- from the local flags, the fourth of Darwin's 8-byte words.
local PENDIN <const> = 0x20000000
local function same(a: string, b: string): boolean
  if a == b then return true end
  if (assert(sys.uname())).sysname ~= "Darwin" or #a ~= #b or #a < 32 then return false end
  local function plain(state: string): string
    local flags = string.unpack("<I8", state, 25)
    return state:sub(1, 24) .. string.pack("<I8", flags & ~PENDIN) .. state:sub(33)
  end
  return plain(a) == plain(b)
end

local function hex(bytes: string): string
  return (bytes:gsub(".", function(c: string): string return string.format("%02x", c:byte()) end))
end

--- The terminal's state is as it was at the start.
local function restored(caller: Caller): boolean
  return same((assert(sys.tcgetattr(caller.slave))), caller.before)
end

local function termios_note(caller: Caller, what: string): string
  return what .. ": now " .. hex((assert(sys.tcgetattr(caller.slave)))) .. ", before " .. hex(caller.before)
end

local function new_caller(): Caller
  local pty = assert(sys.openpty())
  assert(sys.setwinsize(pty.master, 37, 111))
  return { master = pty.master, slave = pty.slave, before = assert(sys.tcgetattr(pty.slave)), shown = "" }
end

--- Reads the caller's terminal until what it has shown holds `needle`,
--- or `seconds` pass.
local function wait_for(caller: Caller, needle: string, seconds: integer)
  local deadline = Clock.monotonic_ns() + Clock.seconds(seconds)
  while not caller.shown:find(needle, 1, true) do
    local left = deadline - Clock.monotonic_ns()
    assert(left > 0, "no " .. string.format("%q", needle) .. " in " .. string.format("%q", caller.shown))
    local ready, _ = Poll.readable(caller.master, left)
    if ready then
      local data, why = sys.read(caller.master, 4096)
      assert(data ~= nil and data ~= "", "the terminal closed: " .. tostring(why) ..
          string.format(" %q", caller.shown))
      caller.shown = caller.shown .. data
    end
  end
end

--- Reads what is left to read without waiting for more.
local function drain(caller: Caller)
  while true do
    local ready, _ = Poll.readable(caller.master, Clock.ms(200))
    if not ready then return end
    local data, _ = sys.read(caller.master, 4096)
    if data == nil or data == "" then return end
    caller.shown = caller.shown .. data
  end
end

local function shown_of(caller: Caller): string
  return string.format("%q", caller.shown)
end

--- `cosmic sandbox` running `script` under sh, with the caller's streams
--- as `opts` says (a terminal where it names the slave).
local function start(script: string, opts: Child.Options): Child.Handle
  opts.timeout_ns = Clock.seconds(60)
  -- The root, which the system profile lets a program read: a shell
  -- started in a directory the profile does not grant prints a getcwd
  -- error of its own on macOS, into what these tests compare byte for byte.
  opts.cwd = "/"
  local child, why = Child.start({ exe, "sandbox", "--system", "--env", "PATH", "--promise", "fork",
    "--", "/bin/sh", "-c", script }, opts)
  assert(child, why)
  return child
end

local function finish(caller: Caller)
  assert(sys.close(caller.slave))
  assert(sys.close(caller.master))
end

local function read_file(path: string): string
  local text, _ = Fs.read(path)
  return text or ""
end

local output <const> = "A\\033[1mB\\033[0m\\033]52;c;aGVsbG8=\\007\\033]0;title\\007C\\n"

-- All three are the caller's terminal.
do
  local caller = new_caller()
  local child = start(table.concat({
    "[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo tty-ok",
    "printf '" .. output .. "'",
    "stty size",
    "read line",
    "stty size",
    "echo got:$line",
    "exit 7",
  }, "\n"), { stdin = caller.slave, stdout = caller.slave, stderr = caller.slave })
  wait_for(caller, "37 111", 30)
  -- The caller's terminal is raw while the program runs.
  assert(not restored(caller), "the caller's terminal was not made raw")
  assert(sys.setwinsize(caller.master, 50, 120))
  -- The relay looks at the window between its waits.
  assert(sys.nanosleep(Clock.ms(300)))
  assert(sys.write(caller.master, "hello\r"))
  wait_for(caller, "got:hello", 30)
  local result = assert(child:wait())
  drain(caller)
  assert(result.code == 7 and result.signal == nil, "exit status " .. tostring(result.code) ..
      shown_of(caller))
  assert(caller.shown:find("tty-ok", 1, true), "the program had no terminal: " .. shown_of(caller))
  assert(caller.shown:find("A\27[1mB\27[0mC", 1, true), "an allowed sequence did not pass: " ..
      shown_of(caller))
  assert(not caller.shown:find("\27]", 1, true) and not caller.shown:find("52;c", 1, true) and
      not caller.shown:find("aGVsbG8=", 1, true) and not caller.shown:find("title", 1, true),
    "OSC reached the terminal: " .. shown_of(caller))
  assert(caller.shown:find("50 120", 1, true), "the window size change did not reach the program")
  assert(restored(caller), termios_note(caller, "the caller's termios was not restored"))
  finish(caller)
end

-- A terminal in and files out: the files are the program's own bytes.
do
  local caller = new_caller()
  local dir = assert(Fs.mkdtemp("relay-"))
  local out, err = dir .. "/out", dir .. "/err"
  local out_fd = assert(sys.open(out, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, tonumber("644", 8)))
  local err_fd = assert(sys.open(err, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, tonumber("644", 8)))
  local child = start(table.concat({
    "[ -t 0 ] && echo stdin-tty-ok",
    "[ -t 1 ] || echo stdout-file-ok",
    "printf '" .. output .. "'",
    "printf 'to-stderr\\n' >&2",
    "read line",
    "echo got:$line",
  }, "\n"), { stdin = caller.slave, stdout = out_fd, stderr = err_fd })
  -- The program has written its stderr, so it is about to read.
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  while read_file(err) ~= "to-stderr\n" or restored(caller) do
    assert(Clock.monotonic_ns() < deadline, "the program did not get to its read: stderr " ..
        string.format("%q", read_file(err)) .. ", terminal " .. shown_of(caller))
    assert(sys.nanosleep(Clock.ms(20)))
  end
  assert(sys.write(caller.master, "hi\r"))
  local result = assert(child:wait())
  drain(caller)
  assert(result.code == 0, "exit status " .. tostring(result.code) .. shown_of(caller))
  assert(sys.close(out_fd))
  assert(sys.close(err_fd))
  local wrote = read_file(out)
  local expected = "stdin-tty-ok\nstdout-file-ok\nA\27[1mB\27[0m\27]52;c;aGVsbG8=\7\27]0;title\7C\ngot:hi\n"
  assert(wrote == expected, "stdout was changed: " .. string.format("%q", wrote))
  assert(read_file(err) == "to-stderr\n", "stderr was changed or merged: " .. string.format("%q", read_file(err)))
  assert(not caller.shown:find("52;c", 1, true), "the program's file output reached the terminal")
  assert(restored(caller), termios_note(caller, "the caller's termios was not restored"))
  local _, _ = Fs.remove_tree(dir)
  finish(caller)
end

-- A pipe in and a terminal out: the output is filtered, the terminal is not made raw.
do
  local caller = new_caller()
  local child = start(table.concat({
    "[ -t 1 ] && [ ! -t 0 ] && echo notty-in",
    "read line",
    "echo got:$line",
    "printf '" .. output .. "'",
  }, "\n"), { stdin = "stream", stdout = caller.slave, stderr = caller.slave })
  assert((assert(child.stdin_stream)):write("piped\n"))
  assert(assert(child.stdin_stream):close())
  local result = assert(child:wait())
  drain(caller)
  assert(result.code == 0, "exit status " .. tostring(result.code) .. shown_of(caller))
  assert(caller.shown:find("notty-in", 1, true), shown_of(caller))
  assert(caller.shown:find("got:piped", 1, true), shown_of(caller))
  assert(caller.shown:find("A\27[1mB\27[0mC", 1, true), shown_of(caller))
  assert(not caller.shown:find("\27]", 1, true) and not caller.shown:find("title", 1, true),
    "OSC reached the terminal: " .. shown_of(caller))
  assert(restored(caller), termios_note(caller, "the terminal was touched"))
  finish(caller)
end

-- A terminal on every stream and a policy with `connect`: the relay may not
-- hold the caller's terminal as its standard error, so its decision line
-- comes through the verb's own pipe, as a line of its own, in order with what
-- the program wrote, and unfiltered, while the program's own words are the
-- filter's. `cosmic sandbox connect` is the program, refused by the relay.
do
  local caller = new_caller()
  local opts: Child.Options = { stdin = caller.slave, stdout = caller.slave, stderr = caller.slave,
    timeout_ns = Clock.seconds(60) }
  local child, why = Child.start({ exe, "sandbox", "--cosmic", "--connect", "127.0.0.2:9", "--", exe,
    "sandbox", "connect", "example.invalid", "443" }, opts)
  assert(child, why)
  local result = assert(child:wait())
  drain(caller)
  if result.code == 125 and caller.shown:find("relay", 1, true) then
    -- A host that cannot give the program a network of its own (no user
    -- namespaces) cannot start the relay: nothing here is about that.
    print("relay: SKIP the relay's lines on the terminal: the relay cannot start here:" .. shown_of(caller))
    finish(caller)
  else
    assert(result.code == 1, "exit status " .. tostring(result.code) .. shown_of(caller))
    local line = "relay: #1 socks5 example.invalid:443: refused: not granted: --connect example.invalid:443\r\n"
    assert(caller.shown:find(line, 1, true), "the relay's decision line is not one of the terminal's: " ..
        shown_of(caller))
    assert(not caller.shown:find("\r\r\n", 1, true) and not caller.shown:find("[^\r]\n"),
      "a line of the terminal's has no carriage return: " .. shown_of(caller))
    assert(caller.shown:find("connection not allowed by ruleset", 1, true), shown_of(caller))
    assert(restored(caller), termios_note(caller, "the caller's termios was not restored"))
    finish(caller)
  end
end

-- A terminal as a policy's `relay_log` is refused naming the option.
do
  local caller = new_caller()
  local started, why = Child.start({ exe, "--help" }, { policy = { profiles = { "cosmic" },
    connect = { "127.0.0.2:9" } }, relay_log = caller.slave })
  assert(started == nil, "a terminal as the relay's log was taken")
  print("relay: refused: " .. tostring(why))
  finish(caller)
end

-- A SIGTERM to the sandbox reaches the program, and ends the sandbox by it
-- once the terminal is restored.
do
  local caller = new_caller()
  local child = start("echo ready\nread line", { stdin = caller.slave, stdout = caller.slave, stderr = caller.slave })
  wait_for(caller, "ready", 30)
  assert(not restored(caller))
  assert(child:stop(sys.SIGTERM))
  local result = assert(child:wait())
  assert(result.signal == sys.SIGTERM, "the sandbox did not end by SIGTERM: " ..
      tostring(result.signal) .. "/" .. tostring(result.code) .. shown_of(caller))
  assert(restored(caller), termios_note(caller, "the caller's termios was not restored"))
  finish(caller)
end

print("relay: PASS")
