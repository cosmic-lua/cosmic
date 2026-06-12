#!/usr/bin/env cosmic
--- Tests for fs_walk module (symlink cycle safety)
local fs_walk = require("cosmic.fs_walk")
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")

local tmpdir = os.getenv("TEST_TMPDIR") as string

-- Helper: create a directory under tmpdir
local function mksubdir(name: string): string
  local p = fs.join(tmpdir, name)
  fs.makedirs(p)
  return p
end

-- Helper: write a file
local function write_file(path: string, content: string)
  local f = io.open(path, "w")
  assert(f, "cannot open " .. path)
  f:write(content)
  f:close()
end

-- FIX 1a: walk() must not recurse into symlinked directories
-- A symlink loop (e.g. dir/loop -> ..) must terminate and not stack-overflow.
local function test_walk_symlink_cycle_terminates()
  local base = mksubdir("walk_cycle")
  local subdir = fs.join(base, "sub")
  fs.makedirs(subdir)
  write_file(fs.join(subdir, "real.txt"), "hello")
  -- Create a symlink cycle: sub/loop -> ..  (points back to base)
  unix.symlink("..", fs.join(subdir, "loop"))

  local count = 0
  local max_depth_seen = 0
  -- walk the base directory; collect all entries to detect infinite loop
  -- (the test harness has a timeout; if we don't hang this is fine)
  local results: {string} = {}
  fs_walk.walk(base, function(full_path: string, _entry: string, _st: any, ctx: {string})
      ctx[#ctx + 1] = full_path
    end, results)

  -- Must NOT contain any path that descends deeper than base/sub/
  -- (i.e. no base/sub/loop/sub/loop/... paths)
  for _, p in ipairs(results) do
    -- Count path separators relative to base to detect runaway depth
    local rel = p:sub(#base + 2)
    local depth = 0
    for _ in rel:gmatch("/") do depth = depth + 1 end
    if depth > max_depth_seen then max_depth_seen = depth end
  end
  -- A real.txt at base/sub/real.txt has depth 1. Symlink entries at base/sub
  -- should not be recursed, so max depth should be 1.
  assert(max_depth_seen <= 1,
    "walk recursed into symlink cycle: max depth " .. tostring(max_depth_seen))
end
test_walk_symlink_cycle_terminates()

-- FIX 1b: collect_all() must not recurse into symlinked directories
local function test_collect_all_symlink_cycle_terminates()
  local base = mksubdir("collect_all_cycle")
  local subdir = fs.join(base, "sub")
  fs.makedirs(subdir)
  write_file(fs.join(subdir, "real.txt"), "data")
  unix.symlink("..", fs.join(subdir, "loop"))

  local files = fs_walk.collect_all(base)
  -- Should contain sub/real.txt but NOT any path with loop/ in it
  for rel_path in pairs(files) do
    assert(not rel_path:match("loop"),
      "collect_all should not recurse into symlink loop, found: " .. rel_path)
  end
  assert(files["sub/real.txt"] ~= nil, "real.txt should be found")
end
test_collect_all_symlink_cycle_terminates()

-- FIX 1c: files() iterator must not recurse into symlinked directories
local function test_files_symlink_cycle_terminates()
  local base = mksubdir("files_cycle")
  local subdir = fs.join(base, "sub")
  fs.makedirs(subdir)
  write_file(fs.join(subdir, "real.lua"), "-- lua")
  unix.symlink("..", fs.join(subdir, "loop"))

  local collected: {string} = {}
  for p in fs_walk.files(base, "*.lua") do
    collected[#collected + 1] = p
    -- Safety: abort if we find more than a small number
    assert(#collected <= 10,
      "files() appears to iterate infinitely (>10 results from 1 real file)")
  end
  assert(#collected == 1, "expected 1 lua file, got " .. tostring(#collected))
  assert(collected[1]:match("real%.lua$"), "expected real.lua, got " .. tostring(collected[1]))
end
test_files_symlink_cycle_terminates()

-- FIX 1d: symlinked regular files should still be visited (not skipped)
-- Only symlinked *directories* are not recursed into.
local function test_walk_symlink_file_visited()
  local base = mksubdir("walk_symlink_file")
  write_file(fs.join(base, "real.txt"), "content")
  -- Symlink to a file in same dir
  unix.symlink("real.txt", fs.join(base, "alias.txt"))

  local found: {string: boolean} = {}
  fs_walk.walk(base, function(full_path: string, entry: string, _st: any, ctx: {string: boolean})
      ctx[entry] = true
    end, found)
  -- Both the real file and the symlink to a file should be visited
  -- (walk visits entries without distinguishing symlinked files from real ones,
  -- since we only skip recursion into symlinked dirs)
  assert(found["real.txt"], "real.txt should be visited")
  -- alias.txt: walk calls lstat, sees S_ISLNK (not S_ISDIR), visits it
  assert(found["alias.txt"], "symlinked file should be visited")
end
test_walk_symlink_file_visited()
