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
--- A base inside the root leaves none to be had, which the location
--- says; a base that is no absolute path is refused.
function Example.directory()
  local dir = assert(Fs.mkdtemp("cosmic-project-example-"))
  assert(Fs.mkdirs(dir .. "/notes"))
  local environment = { COSMIC_BUILD_HOME = dir .. "/builds" }
  local location = assert(Project.directory(dir .. "/notes", environment))
  print(location.none == "", Fs.dirname(location.directory) == assert(sys.realpath(dir)) .. "/builds")
  assert(Fs.exists(location.directory) == false)
  assert(assert(Project.directory(dir .. "/notes/.", environment)).directory == location.directory)
  local inside = assert(Project.directory(dir .. "/notes", { COSMIC_BUILD_HOME = dir .. "/notes/o" }))
  print(inside.directory == "", inside.none ~= "")
  assert(inside.directory == "" and inside.none ~= "")
  local refused, why = Project.directory(dir .. "/notes", { COSMIC_BUILD_HOME = "builds" })
  print(refused, why)
  assert(refused == nil and why == "COSMIC_BUILD_HOME=builds is not an absolute path")
  assert(Fs.remove_tree(dir))
end

return Example
