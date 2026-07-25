--- `cosmic --make <verb> [paths…]` — cosmic's build system.
---
--- Not a wrapper around `--embed`, and no longer a Makefile generator:
--- the flag used to scan a directory and emit a Makefile that was
--- useless without a host make, produced build files rather than
--- builds, and modelled a project as a flat list of `.tl` files. That
--- generator is gone. Two grammars for one flag would have been worse
--- than one rewrite of the guides.
---
--- What is here today is the project model (project.tl), the validator
--- (validate.tl), root discovery (root.tl), and one verb: `check`.
--- The remaining verbs are named below rather than hidden, so a run
--- that asks for one gets told where it stands instead of "unknown
--- option".

local fs = require("cosmic.fs")
local root = require("cosmic.make.root")
local project = require("cosmic.make.project")
local validate = require("cosmic.make.validate")
local check = require("cosmic.make.check")
local types = require("cosmic.make.types")

local type Issue = types.Issue
local type Project = types.Project

--- Verbs that run today.
local IMPLEMENTED < const >: {string} = {"check"}

--- Verbs the design defines and later slices land, in the order they
--- appear in the design's own tables. Naming them costs one line each
--- and turns a typo-shaped failure into a schedule answer.
local PLANNED < const >: {string} = {
  "build", "test", "fmt", "run", "regen", "fetch", "clean",
  "ci", "coverage", "enforce", "reproducible", "offline",
}

--- Usage, printed for a bare `--make` and after an unknown verb.
--- @return string The usage text, without a trailing newline
local function usage(): string
  return "usage: cosmic --make <verb> [paths…]\n" ..
  "make: verbs: " .. table.concat(IMPLEMENTED, ", ") .. "\n" ..
  "make: planned: " .. table.concat(PLANNED, ", ")
end

--- Is this verb one the design defines but this slice does not ship?
--- @param verb string The verb requested
--- @return boolean True when the verb is planned
local function is_planned(verb: string): boolean
  for _, v in ipairs(PLANNED) do
    if v == verb then
      return true
    end
  end
  return false
end

--- Discover the root, announce it, and scan the project.
---
--- The banner is unconditional and goes to stdout: "which tree did that
--- just build" is the question every wrong-directory bug starts with,
--- and it costs one line to answer up front.
--- @param verb string The verb being run, for the discovery message
--- @return Project|nil The scanned project, or nil on failure
--- @return string The error message when discovery or the scan failed
local function open_project(verb: string): Project | nil, string
  local dir, derr = root.discover(verb)
  if not dir then
    return nil, derr or "make: cannot determine the project root"
  end
  local abs = dir as string -- cast: scalar narrowing after the guard
  io.write("make: root=" .. abs .. "\n")
  -- chdir so every path a verb prints, and every path it hands the
  -- checker, is relative to the root the banner just named.
  local ok, cerr = fs.chdir(abs)
  if not ok then
    return nil, "make: cannot enter " .. abs .. ": " .. (cerr or "unknown error")
  end
  local proj, serr = project.scan(abs)
  if not proj then
    return nil, serr or "make: cannot scan the project"
  end
  return proj
end

--- Run one `--make` invocation.
--- @param argv {string} The verb followed by selection paths
--- @return integer Exit code
local function run(argv: {string}): integer
  local verb = argv[1]
  if not verb or verb == "" then
    io.stderr:write(usage() .. "\n")
    return 1
  end

  local paths: {string} = {}
  for i = 2, #argv do
    paths[#paths + 1] = argv[i]
  end

  if verb ~= "check" then
    if is_planned(verb) then
      io.stderr:write("make: '" .. verb ..
        "' is planned but not implemented yet\nmake: verbs: " ..
        table.concat(IMPLEMENTED, ", ") .. "\n")
    else
      io.stderr:write("make: unknown verb '" .. verb .. "'\n" ..
        usage() .. "\n")
    end
    return 1
  end

  local proj, err = open_project(verb)
  if not proj then
    io.stderr:write((err or "make: failed") .. "\n")
    io.write("check: FAIL (no project)\n")
    return 1
  end
  return check.run(proj as Project, paths) -- cast: record union after the guard
end

local record MakeModule
  IMPLEMENTED: {string}
  PLANNED: {string}
  usage: function(): string
  run: function(argv: {string}): integer
  scan: function(root: string): Project | nil, string
  validate: function(proj: Project): {Issue}
end

local M: MakeModule = {
  IMPLEMENTED = IMPLEMENTED,
  PLANNED = PLANNED,
  usage = usage,
  run = run,
  scan = project.scan,
  validate = validate.validate,
}

return M
