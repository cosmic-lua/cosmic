local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")

local function test_external_path_with_top_level_parent(tmp: string)
  local candidate = tmp .. "/candidate"
  assert(Fs.mkdirs(candidate))
  assert(State.external_path("/tmp", candidate) == assert(Fs.absolute("/tmp")))
end
