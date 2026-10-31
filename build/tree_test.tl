--- `build.tree`: what a root is to the running tool.

local Fs = require("cosmic.fs")
local tree = require("build.tree")

local function test_a_root_with_core_build_and_the_importer_is_standing_own(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local standing, trouble = tree.standing(tmp)
  assert(standing ~= nil and standing.own, tostring(trouble))
end

local function test_a_root_without_the_layout_is_not_own(tmp: string)
  local bare, bare_trouble = tree.standing(tmp)
  assert(bare ~= nil and not bare.own, tostring(bare_trouble))
  -- A directory of the importer's name is no importer.
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build/importer.tl"))
  local faked, faked_trouble = tree.standing(tmp)
  assert(faked ~= nil and not faked.own, tostring(faked_trouble))
end
