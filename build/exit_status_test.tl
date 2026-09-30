--- The exit status a main function's return value asks for
--- ([`build.exit_status.status`]), read as the core reads it
--- (core/check.h, `cosmic_tostatus`). Programs that return one are built
--- and run in build/exit_status_store_test.tl.

local exit_status = require("build.exit_status")

--- Text is read as Lua reads a numeral, as `lua_tointegerx` does for
--- the core: space around it, hex and an exponent are allowed.
local function test_status_reads_text_as_the_core_does()
  for value, status in pairs({ [" 3 "] = 3, ["0x3"] = 3, ["3.0"] = 3, ["3e0"] = 3,
      ["255"] = 255 } as {string:integer}) do
    assert(exit_status.status(value) == status, value)
  end
  for _, value in ipairs({ "", "3x", "1.5", "-1", "256", "1e400", "three" }) do
    assert(exit_status.status(value) == nil, value)
  end
end
