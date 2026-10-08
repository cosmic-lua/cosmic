--- The physical directory of a project's generated files. Bootstrap and
--- the running tool use the same resolver so a build, its database and
--- its lock always name the same directory.

local Fs = require("cosmic.fs")
local put = Fs.put

local record paths
end

--- The generated directory of `root`, without creating or checking it.
function paths.directory(root: string, _environment?: {string:string}): string | nil, string
  if root == "" then return nil, "project root is empty" end
  return root .. "/o", ""
end

local directory_of = paths.directory

--- The generated directory, raising a diagnostic when it cannot be named.
function paths.required(root: string, environment?: {string:string}): string
  local directory, trouble = directory_of(root, environment)
  if directory == nil then error(trouble, 0) end
  return directory
end

--- Prints the directory for the bootstrap scripts, which run this file
--- standalone before the project's modules have been built.
function paths.main(argv: {integer:string}): integer
  if argv[1] == nil or argv[2] ~= nil then
    local _, _ = put(Fs.stderr, "usage: build/paths.tl <project-root>\n")
    return 2
  end
  local directory, trouble = directory_of(argv[1])
  if directory == nil then
    local _, _ = put(Fs.stderr, trouble .. "\n")
    return 1
  end
  local printed, print_trouble = put(Fs.stdout, directory .. "\n")
  if not printed then
    local _, _ = put(Fs.stderr, print_trouble .. "\n")
    return 1
  end
  return 0
end

return paths
