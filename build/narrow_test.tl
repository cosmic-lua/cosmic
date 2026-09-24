local Fs = require("cosmic.fs")
local narrow = require("build.narrow")

local function test_paths_are_relative_to_the_root(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/hi"))
  local root = assert(Fs.absolute(tmp))
  local paths = narrow.paths(root, { root .. "/cmd/hi/", root, "./not/there/", "/elsewhere" })
  assert(paths[1] == "cmd/hi", paths[1])
  assert(paths[2] == ".", paths[2])
  assert(paths[3] == "not/there", paths[3])
  assert(paths[4] == "/elsewhere", paths[4])
end

local function test_holds_a_file_under_a_path()
  assert(narrow.holds({}, "anything.tl"))
  assert(narrow.holds({ "." }, "cmd/hi/main.tl"))
  assert(narrow.holds({ "cmd" }, "cmd/hi/main.tl"))
  assert(narrow.holds({ "lib", "cmd/hi" }, "cmd/hi/main.tl"))
  assert(not narrow.holds({ "cmd/h" }, "cmd/hi/main.tl"))
  assert(not narrow.holds({ "lib" }, "cmd/hi/main.tl"))
end
