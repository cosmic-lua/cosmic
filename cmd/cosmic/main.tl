--- The binary's main.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Fs = require("cosmic.fs")
local fix = require("build.fix")
local project = require("build.project")
local test = require("build.test")

local help = [[
cosmic -- a runtime for self-contained command-line software

  cosmic <file.tl>   build the tree the file sits in, then run it
  cosmic test        build the tree in the working directory, then
                     run every test it defines
  cosmic fix         rewrite every Teal source in the working
                     directory structurally, then write it back out
                     as canonical text, in place
  cosmic fix --check the same, writing nothing: name the files a fix
                     would change, and fail if there are any
  cosmic help        this

`fix` takes paths to narrow it. It rebuilds each file from its parsed
tree: keywords, operators, brackets, spacing and the indentation of
lines that open something come from the tree; line breaks, continued
lines and type syntax are kept as written. Nothing is written until
the result parses again to the same meaning, comments included.

Every verb ends in a verdict line and an exit code.
]]

local function say(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, line .. "\n")
end

--- The directory a path sits in, absolute.
local function directory_of(path: string): string | nil, string
  local resolved, trouble = Fs.absolute(path)
  if resolved == nil then
    return nil, trouble
  end
  local parent = resolved:match("^(.*)/[^/]+$")
  if parent == nil or parent == "" then
    return "/"
  end
  return parent
end

--- The module a file is: its name, less `.tl`, within the directory it
--- sits in.
local function module_of(file: string): string | nil, string
  local name = file:match("([^/]+)%.tl$")
  if name == nil then
    return nil, file .. " is not a Teal source"
  end
  return name
end

local function run(file: string, argv: {integer:string}): integer
  local name, why = module_of(file)
  if name == nil then
    complain("cosmic: " .. why)
    return 1
  end
  local root, trouble = directory_of(file)
  if root == nil then
    complain("cosmic: " .. trouble)
    return 1
  end

  local result, _, build_trouble, code = project.build(root)
  if result == nil then
    complain("cosmic: " .. build_trouble)
    return code
  end

  -- A test file elsewhere in the tree that `importer.compile` refused
  -- is dropped from the database; the file asked for still runs, so
  -- this is a warning, not a failure.
  for _, line in ipairs(result.refused) do
    complain("cosmic: warning: " .. line)
  end

  local produced: any = require(name)
  if produced is function(...: any): any then
    local status: any = produced(argv)
    if status is integer then
      return status
    end
  end
  return 0
end

--- @param argv the command line, with the program's own name at slot 0
local function main(argv: {integer:string}): integer
  local verb = argv[1]
  if verb == nil or verb == "help" or verb == "-h" or verb == "--help" then
    say(help)
    return 0
  end
  if verb == "test" then
    return test.run()
  end
  if verb == "fix" then
    return fix.run(argv)
  end
  if verb:sub(1, 1) == "-" then
    complain("cosmic: no such option: " .. verb)
    complain("cosmic: `cosmic help` is the whole discovery surface")
    return 2
  end
  return run(verb, argv)
end

return main
