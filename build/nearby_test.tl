--- The files of a tree's modules ([`build.nearby`]): [`Nearby.find`] leaves the binary's to it, and [`Nearby.file`]
--- reads any module's file, as Host.check does in cosmic's own tree ([`Nearby.own`]).
local Fs = require("cosmic.fs")
local Nearby = require("build.nearby")
local sys = require("cosmic.sys")

--- A `cosmic.*` module with a file in the tree is the binary's to `find`, and the tree's to `file`.
local function test_a_stdlib_module_of_a_tree_is_read_only_by_file(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic"))
  assert(Fs.write(tmp .. "/cosmic/cookies.tl", "return {}\n"))
  assert(Fs.mkdirs(tmp .. "/util"))
  assert(Fs.write(tmp .. "/util/init.tl", "return 1\n"))
  assert(Nearby.find({ tmp }, "cosmic.cookies") == nil)
  local found = assert(Nearby.file({ tmp }, "cosmic.cookies"))
  assert(found.file == tmp .. "/cosmic/cookies.tl" and found.text == "return {}\n", found.file)
  assert(assert(Nearby.file({ tmp }, "util")).file == tmp .. "/util/init.tl")
  assert(Nearby.file({ tmp }, "cosmic.none") == nil)
  assert(Nearby.file({ tmp }, "../x") == nil)
end

--- A root is own to a tool built from its canonical path, and to no tool that records none.
local function test_a_root_is_own_to_the_tool_built_from_it(tmp: string)
  local real = assert(sys.realpath(tmp))
  local own = Nearby.own({ tmp, "/" }, real)
  assert(#own == 1 and own[1] == tmp, table.concat(own, " "))
  assert(#Nearby.own({ tmp }, nil) == 0)
  assert(#Nearby.own({ tmp }, "/elsewhere") == 0)
end
