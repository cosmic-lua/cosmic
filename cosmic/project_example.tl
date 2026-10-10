--- Worked examples for [`cosmic.project`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Project = require("cosmic.project")
local sys = require("cosmic.sys")

local Example = {}

--- Where a project's build lands, under a base of builds named for the
--- run: each project has a directory of its own there, which only a
--- build makes, and a path to the root through a link names the same.
function Example.directory()
  local dir = assert(Fs.mkdtemp("cosmic-project-example-"))
  assert(Fs.mkdirs(dir .. "/notes"))
  local environment = { COSMIC_BUILD_HOME = dir .. "/builds" }
  local directory = assert(Project.directory(dir .. "/notes", environment))
  print(Fs.dirname(directory) == assert(sys.realpath(dir)) .. "/builds")
  assert(Fs.exists(directory) == false)
  assert(Project.directory(dir .. "/notes/.", environment) == directory)
  local refused, why = Project.directory(dir .. "/notes", { COSMIC_BUILD_HOME = "builds" })
  print(refused, why)
  assert(refused == nil and why == "COSMIC_BUILD_HOME=builds is not an absolute path")
  assert(Fs.remove_tree(dir))
end

return Example
