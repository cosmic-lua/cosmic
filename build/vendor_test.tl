--- `build/vendor.tl` over an unpacked archive built here: what the tree
--- holds afterward, and what it refuses.
local Fs = require("cosmic.fs")
local vendor = require("build.vendor")

local function write_all(root: string, files: {string:string})
  assert(Fs.mkdirs(root))
  for path, data in pairs(files) do
    local dir = path:match("^(.*)/[^/]+$")
    if dir ~= nil then
      assert(Fs.mkdirs(root .. "/" .. dir))
    end
    assert(Fs.write(root .. "/" .. path, data))
  end
end

--- A tree holding PIN and a stale file, and an unpacked archive holding
--- `files`; returns what `vendor.tl` exited with.
local function run(dir: string, pin: string, files: {string:string}): integer
  write_all(dir .. "/tree", { ["PIN"] = pin, ["old/gone.c"] = "stale" })
  write_all(dir .. "/unpacked", files)
  return vendor({ [1] = dir .. "/tree", [2] = dir .. "/unpacked" })
end

local function test_a_tree_keeps_what_the_pin_names(dir: string)
  local status = run(dir,
    "version 1\nstrip pkg-1/\nkeep src/*.c\nkeep include/**\ndrop src/main.c\n", {
      ["pkg-1/src/one.c"] = "one",
      ["pkg-1/src/main.c"] = "a program's own main",
      ["pkg-1/src/deep/two.c"] = "not one segment down",
      ["pkg-1/include/a/b.h"] = "header",
      ["pkg-1/doc/manual.html"] = "prose",
      ["other/src/three.c"] = "outside the prefix",
    })
  assert(status == 0)
  local tree = dir .. "/tree"
  assert(Fs.read(tree .. "/src/one.c") == "one")
  assert(Fs.read(tree .. "/include/a/b.h") == "header")
  assert(not Fs.exists(tree .. "/src/main.c"))
  assert(not Fs.exists(tree .. "/src/deep"))
  assert(not Fs.exists(tree .. "/doc"))
  assert(not Fs.exists(tree .. "/old"), "the stale tree was not pruned")
  assert(Fs.read(tree .. "/PIN") ~= nil)
end

local function test_a_keep_that_matches_nothing_changes_nothing(dir: string)
  assert(run(dir, "keep missing.c\n", { ["a.c"] = "a" }) == 1)
  assert(Fs.read(dir .. "/tree/old/gone.c") == "stale")
  assert(not Fs.exists(dir .. "/tree/a.c"))
end
