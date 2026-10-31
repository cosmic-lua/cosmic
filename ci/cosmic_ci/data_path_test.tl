local DataPath = require("cosmic_ci.data_path")
local Fs = require("cosmic.fs")

--- The data is found beside the script that runs, from any working
--- directory, and below the working directory where no script has it.
local function test_data_is_found_beside_the_script(tmp: string)
  local script = tmp .. "/ci/driver.tl"
  assert(Fs.mkdirs(tmp .. "/ci/cosmic_ci"))
  assert(Fs.write(tmp .. "/ci/cosmic_ci/x.json", "{}"))
  assert(DataPath.beside(script, "x.json") == tmp .. "/ci/cosmic_ci/x.json")
  assert(DataPath.beside(script, "y.json") == "cosmic_ci/y.json")
  assert(DataPath.beside(nil, "x.json") == "cosmic_ci/x.json")
end
