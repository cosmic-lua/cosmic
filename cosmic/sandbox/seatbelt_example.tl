local Seatbelt = require("cosmic.sandbox.seatbelt")

local Example = {}

--- A read grant becomes a parameterized literal rule. Compilation can
--- be inspected on any host; it does not apply a sandbox. An enforcement
--- caller resolves the real host path and kind before compiling.
function Example.compile()
  local profile = assert(Seatbelt.compile({ grants = { { path = "input", letters = "r" } } },
    { paths = { input = { path = "/srv/input", directory = false } } }))
  print(profile.parameters.PATH_1) -- /srv/input
  assert(profile.text:find('(allow file-read* (literal (param "PATH_1")))', 1, true))
  assert(not profile.text:find("/srv/input", 1, true))
end

return Example
