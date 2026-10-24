--- Where the JSON data files beside the driver's modules are. The driver
--- is run by its script's path (arg[0], ci/driver.tl), so the files are
--- found beside it from any directory; a run with no such script (a
--- test's worker) reads them below the working directory, the project's
--- root.
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")

local record DataPath
end

--- The path of `cosmic_ci/<name>` beside `script` when it is there,
--- else below the working directory.
function DataPath.beside(script: string | nil, name: string): string
  if script ~= nil then
    local beside = Fs.dirname(script) .. "/cosmic_ci/" .. name
    if Predicate.exists(beside) then return beside end
  end
  return "cosmic_ci/" .. name
end

--- [`DataPath.beside`] the running script.
function DataPath.of(name: string): string
  return DataPath.beside(arg[0], name)
end

return DataPath
