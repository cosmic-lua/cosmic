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
function DataPath.beside(script: string?, name: string): string
  if script ~= nil then
    local beside = Fs.dirname(script) .. "/cosmic_ci/" .. name
    if Predicate.exists(beside) then return beside end
  end
  return "cosmic_ci/" .. name
end

--- [`DataPath.beside`] the running script.
function DataPath.of(name: string): string
  -- A test's worker has no `arg` table to index.
  local indexed, script = pcall(function(): string? return arg[0] end)
  if indexed and script is string then return DataPath.beside(script, name) end
  return DataPath.beside(nil, name)
end

return DataPath
