--- The pty relay (build/term_relay.tl) while the caller's terminal takes no
--- output: a caller pty whose master nobody reads fills, and the relay
--- must go on serving signals and the program's exit, put the termios and
--- the terminal's blocking mode back, and end. The relay runs in this
--- process, on a pty pair of the test's making; the program signals this
--- process itself, as a user's kill would.

local Signal = require("cosmic.signal")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local TermRelay = require("build.term_relay")
local sys = require("cosmic.sys")

--- The system's own paths, which the program's shell is run from.
Test.policy{ env = { "TMPDIR" }, profiles = { "system" } }

--- A relay that waits on the terminal for longer than this has stopped
--- serving it (a run that is not stuck takes about a second, the stall of 1 s included).
local BOUND_MS <const> = 4000

--- Two termios states are the same terminal setting. A BSD kernel
--- (macOS) sets PENDIN in the local flags by itself as a terminal leaves
--- raw mode, so it is left out there, from the fourth 8-byte word.
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

local record Caller
  master: integer
  slave: integer
  before: string
end

local function caller_pty(): Caller
  -- TODO: run these on Linux workers too, once a test policy can grant a
  -- pty (/dev/ptmx and the slave /dev/pts/N, which an absolute-path grant
  -- cannot name) or build/host_names.tl has a name for one: a sandboxed
  -- worker has no pty, so these skip there and the CI fixture
  -- test/terminal/relay.tl covers the relay on a pty.
  local opened, why = sys.openpty()
  if opened == nil then Test.skip("no pty: " .. why) end
  local pty = assert(opened)
  return { master = pty.master, slave = pty.slave, before = assert(sys.tcgetattr(pty.slave)) }
end

local function finish(caller: Caller)
  assert(sys.close(caller.slave))
  assert(sys.close(caller.master))
end

local function blocking(fd: integer): boolean
  return (assert(sys.fd_status(fd))) & sys.O_NONBLOCK == 0
end

--- A SIGTERM sent to the relay while the terminal takes no output reaches
--- the program, which ends the run, and the terminal is put back: raw mode
--- is gone and the blocking mode is as it was.
local function test_a_signal_is_served_while_the_terminal_takes_no_output()
  local caller = caller_pty()
  local outer <close> = assert(Signal.guard())
  local script = string.format("(sleep 0.3; kill -TERM %d) & exec yes", sys.getpid())
  local started = Clock.monotonic_ns()
  local result, why = TermRelay.run({ "/bin/sh", "-c", script }, { timeout_ns = Clock.ms(BOUND_MS) },
    { input = caller.slave, output = caller.slave, error = caller.slave })
  local took = (Clock.monotonic_ns() - started) // Clock.ms(1)
  assert(result ~= nil, tostring(why))
  assert(not result.timed_out, "the relay never served the signal")
  assert(result.signal == sys.SIGTERM, "the program was ended by " .. tostring(result.signal))
  assert(took < BOUND_MS, took .. " ms")
  assert(outer:release() == sys.SIGTERM, "the relay's guard caught the signal")
  assert(same(caller.before, (assert(sys.tcgetattr(caller.slave)))), "the termios was not restored")
  assert(blocking(caller.slave), "the terminal was left non-blocking")
  finish(caller)
end

--- A program that ends by itself with the terminal still not draining
--- does not hold the run: what is queued is given up after a stall.
local function test_a_program_that_ends_does_not_wait_for_a_terminal_that_takes_nothing()
  local caller = caller_pty()
  local script = "head -c 400000 /dev/zero | tr '\\0' x; printf '\\033[?1049h'"
  local started = Clock.monotonic_ns()
  local result, why = TermRelay.run({ "/bin/sh", "-c", script }, { timeout_ns = Clock.ms(BOUND_MS) },
    { input = caller.slave, output = caller.slave, error = caller.slave })
  local took = (Clock.monotonic_ns() - started) // Clock.ms(1)
  assert(result ~= nil, tostring(why))
  assert(result.code == 0, tostring(result.code))
  -- The program wrote 400000 bytes of x and nobody read the caller's end:
  -- a pty holds far less, so what was queued past it was dropped.
  local held = 0
  while true do
    local ready, _ = Poll.readable(caller.master, 0)
    if not ready then break end
    local data, _ = sys.read(caller.master, 65536)
    if data == nil or data == "" then break end
    held = held + #data
  end
  assert(held < 400000, "the stalled output was delivered whole: " .. held)
  assert(took < BOUND_MS, took .. " ms")
  assert(same(caller.before, (assert(sys.tcgetattr(caller.slave)))), "the termios was not restored")
  assert(blocking(caller.slave), "the terminal was left non-blocking")
  finish(caller)
end

--- A terminal that was non-blocking when the run began is left so.
local function test_a_non_blocking_terminal_is_left_non_blocking()
  local caller = caller_pty()
  assert(sys.set_nonblocking(caller.slave, true))
  local result, why = TermRelay.run({ "/bin/sh", "-c", "echo hi" }, { timeout_ns = Clock.ms(BOUND_MS) },
    { input = caller.slave, output = caller.slave, error = caller.slave })
  assert(result ~= nil and result.code == 0, tostring(why))
  assert(not blocking(caller.slave), "the run changed a mode it did not set")
  assert(sys.read(caller.master, 4096) ~= nil)
  finish(caller)
end
