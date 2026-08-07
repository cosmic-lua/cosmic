#!/usr/bin/env cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local types = require("cosmic.fs.types")
local type WalkStat = types.WalkStat

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Layout:
--   root/a.lua  root/b.lua  root/c.txt  root/.hidden.lua
--   root/src/x.lua  root/src/y.txt
--   root/src/deep/z.lua
local root = fs.join(TEST_TMPDIR, "glob_root")
assert(fs.make_dirs(fs.join(root, "src", "deep")))
for _, p in ipairs({"a.lua", "b.lua", "c.txt", ".hidden.lua", "src/x.lua", "src/y.txt", "src/deep/z.lua"}) do
  assert(fs.write(fs.join(root, p), "-- " .. p))
end

local function names(paths: {string}): {string}
  local out: {string} = {}
  for i, p in ipairs(paths) do
    out[i] = fs.relpath(p, root)
  end
  return out
end

-- glob tests

local function test_glob_single_level_not_recursive()
  local paths = check.must(fs.glob(root, "*.lua"))
  local rel = names(paths)
  assert(#rel == 3, "expected 3 top-level .lua files, got " .. #rel)
  assert(rel[1] == ".hidden.lua" and rel[2] == "a.lua" and rel[3] == "b.lua",
    "expected sorted dotfile-inclusive matches, got " .. table.concat(rel, ","))
end
test_glob_single_level_not_recursive()

local function test_glob_path_components()
  local paths = check.must(fs.glob(root, "src/*.lua"))
  local rel = names(paths)
  assert(#rel == 1 and rel[1] == "src/x.lua", "expected src/x.lua, got " .. table.concat(rel, ","))
end
test_glob_path_components()

local function test_glob_component_wildcard_dir()
  local paths = check.must(fs.glob(root, "*/deep/*.lua"))
  local rel = names(paths)
  assert(#rel == 1 and rel[1] == "src/deep/z.lua", "expected src/deep/z.lua")
end
test_glob_component_wildcard_dir()

local function test_glob_matches_directories_too()
  local paths = check.must(fs.glob(root, "s?c"))
  local rel = names(paths)
  assert(#rel == 1 and rel[1] == "src", "expected the src directory itself")
end
test_glob_matches_directories_too()

local function test_glob_literal_component()
  local paths = check.must(fs.glob(root, "a.lua"))
  assert(#paths == 1, "expected exact-name match")
end
test_glob_literal_component()

local function test_glob_no_match_and_missing_dirs()
  assert(#(check.must(fs.glob(root, "*.nope"))) == 0, "expected no matches")
  assert(#(check.must(fs.glob(root, "missing/*.lua"))) == 0,
    "expected no matches through a missing directory")
end
test_glob_no_match_and_missing_dirs()

local function test_glob_root_failure()
  local paths, err = fs.glob(fs.join(root, "nonexistent"), "*.lua")
  assert(paths == nil and err ~= nil, "expected nil, err for missing root")
end
test_glob_root_failure()

local function test_glob_invalid_patterns()
  local paths, err = fs.glob(root, "/etc/*")
  assert(paths == nil and err ~= nil, "expected absolute pattern rejected")
  paths, err = fs.glob(root, "")
  assert(paths == nil and err ~= nil, "expected empty pattern rejected")
end
test_glob_invalid_patterns()

-- walk max_depth tests

local function collect_depth(max_depth: integer): {string}
  local seen: {string} = {}
  assert(fs.walk(root, function(path: string, _name: string, _st: WalkStat, acc: {string})
        table.insert(acc, fs.relpath(path, root))
      end, seen, {max_depth = max_depth}))
  table.sort(seen)
  return seen
end

local function has(list: {string}, want: string): boolean
  for _, v in ipairs(list) do
    if v == want then
      return true
    end
  end
  return false
end

local function test_walk_max_depth_one()
  local seen = collect_depth(1)
  assert(has(seen, "a.lua") and has(seen, "src"), "expected top-level entries")
  assert(not has(seen, "src/x.lua"), "expected no descent at max_depth=1")
end
test_walk_max_depth_one()

local function test_walk_max_depth_two()
  local seen = collect_depth(2)
  assert(has(seen, "src/x.lua") and has(seen, "src/deep"), "expected depth-2 entries")
  assert(not has(seen, "src/deep/z.lua"), "expected no depth-3 entries")
end
test_walk_max_depth_two()

local function test_walk_unlimited_by_default()
  local seen: {string} = {}
  assert(fs.walk(root, function(path: string, _name: string, _st: WalkStat, acc: {string})
        table.insert(acc, fs.relpath(path, root))
      end, seen))
  assert(has(seen, "src/deep/z.lua"), "expected full depth without opts")
  local zero = collect_depth(0)
  assert(has(zero, "src/deep/z.lua"), "expected max_depth=0 to mean unlimited")
end
test_walk_unlimited_by_default()

assert(fs.remove_all(root))
