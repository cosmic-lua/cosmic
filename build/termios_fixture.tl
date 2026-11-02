--- What build/term_relay_backpressure_test.tl and test/terminal/relay.tl share: the comparison of two termios states.
--- Test support.

local sys = require("cosmic.sys")

local record termios_fixture
end

--- A BSD kernel (macOS) sets PENDIN in the local flags by itself as a terminal leaves raw mode for canonical, so a
--- restored state differs from the one saved by that flag alone: it is left out, from the local flags, the fourth of
--- Darwin's 8-byte words.
local PENDIN <const> = 0x20000000

local darwin = (assert(sys.uname())).sysname == "Darwin"

--- Whether two termios states (opaque bytes from tcgetattr) are the same terminal setting.
--- @param a one state
--- @param b the other
function termios_fixture.same(a: string, b: string): boolean
  if a == b then return true end
  if not darwin or #a ~= #b or #a < 32 then return false end
  local function plain(state: string): string
    local flags = string.unpack("<I8", state, 25)
    return state:sub(1, 24) .. string.pack("<I8", flags & ~PENDIN) .. state:sub(33)
  end
  return plain(a) == plain(b)
end

return termios_fixture
