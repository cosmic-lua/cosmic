--- The pty relay (build/term_relay.tl) on macOS, where it runs a policy's
--- child held by Seatbelt on a pty of its own: what the child writes last
--- before it exits must reach the caller's terminal, though Darwin drops
--- what the master has not read when the last slave descriptor closes.
--- The CI fixture test/terminal/relay.tl drives the verb itself; this runs
--- the relay in the regular suite.

local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local TermRelay = require("build.term_relay")
local sys = require("cosmic.sys")

--- The system's own paths, which the child's shell is run and loaded from.
Test.policy{ env = { "TMPDIR" }, profiles = { "system" } }

local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("the relay holds a policy's child by Seatbelt on macOS alone")
  end
end

--- Everything the caller's terminal has to read, without waiting for more.
local function shown(master: integer): string
  local text = ""
  while true do
    local ready, _ = Poll.readable(master, Clock.ms(200))
    if not ready then return text end
    local data, _ = sys.read(master, 4096)
    if data == nil or data == "" then return text end
    text = text .. data
  end
end

local function test_the_last_output_of_a_policy_child_reaches_the_terminal_whatever_its_exit()
  macos_only()
  local caller = assert(sys.openpty())
  for run = 1, 5 do
    local marker = "TAIL-MARKER-" .. run
    local result, why = TermRelay.run({ "/bin/sh", "-c", "echo head; printf " .. marker },
      { policy = { profiles = { "system" } }, timeout_ns = Clock.seconds(20) },
      { input = caller.slave, output = caller.slave, error = caller.slave })
    local text = shown(caller.master)
    assert(result ~= nil, tostring(why))
    assert(result.code == 0, "exit " .. tostring(result.code) .. string.format(" %q", text))
    assert(text:find("head", 1, true), string.format("%q", text))
    assert(text:find(marker, 1, true), "the last output was lost: " .. string.format("%q", text))
  end
  assert(sys.close(caller.slave))
  assert(sys.close(caller.master))
end
