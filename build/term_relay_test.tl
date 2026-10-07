local TermRelay = require("build.term_relay")
local sys = require("cosmic.sys")

--- A caller none of whose standard streams is a terminal is refused before
--- anything starts, naming it: there is no terminal to relay or to restore.
local function test_a_relay_needs_a_terminal()
  local null = assert(sys.open("/dev/null", sys.O_RDWR))
  local result, why = TermRelay.run({ "/bin/true" }, {}, { input = null, output = null, error = null })
  assert(result == nil)
  assert(why:find("is a terminal", 1, true), why)
  assert(sys.close(null))
end
