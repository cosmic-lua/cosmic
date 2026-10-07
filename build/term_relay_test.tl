local TermRelay = require("build.term_relay")
local sys = require("cosmic.sys")

--- A caller whose input is not a terminal is refused before anything
--- starts, naming it: the verb relays only a terminal, and a relay with
--- none to restore would leave nothing as it was.
local function test_a_relay_needs_a_terminal_for_input()
  local null = assert(sys.open("/dev/null", sys.O_RDWR))
  local result, why = TermRelay.run({ "/bin/true" }, {}, { input = null, output = null })
  assert(result == nil)
  -- Where the platform cannot give a program a terminal the refusal says so first.
  local uname = assert(sys.uname())
  if uname.sysname == "Linux" then
    assert(why:find("input is no terminal", 1, true), why)
  else
    assert(why:find("Seatbelt", 1, true), why)
  end
  assert(sys.close(null))
end
