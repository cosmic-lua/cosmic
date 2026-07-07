#!/usr/bin/env cosmic
--- Tests for fs_walk module (symlink cycle safety)
local fs_walk = require("cosmic.fs_walk")
local fs = require("cosmic.fs")

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
  fs.symlink("..", fs.join(subdir, "loop"))

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
  fs.symlink("..", fs.join(subdir, "loop"))

  local collected = fs_walk.collect_all(base)
  assert(collected, "collect_all should succeed")
  local files = collected as {string: any}
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
  fs.symlink("..", fs.join(subdir, "loop"))

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
  fs.symlink("real.txt", fs.join(base, "alias.txt"))

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

-- Error propagation: a missing root is an error, not an empty result.

local function test_walk_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local ctx, err = fs_walk.walk(missing, function(_p: string, _n: string,
        _st: any, _c: {string}) end, {})
  assert(ctx == nil, "walk of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "walk error should name ENOENT: " .. tostring(err))
end
test_walk_missing_root_errors()

local function test_collect_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local results, err = fs_walk.collect(missing, "*.lua")
  assert(results == nil, "collect of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "collect error should name ENOENT: " .. tostring(err))
end
test_collect_missing_root_errors()

local function test_collect_all_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local results, err = fs_walk.collect_all(missing)
  assert(results == nil, "collect_all of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "collect_all error should name ENOENT: " .. tostring(err))
end
test_collect_all_missing_root_errors()

local function test_files_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local iter, err = fs_walk.files(missing)
  assert(iter() == nil, "iterator over a missing root should be empty")
  assert(err and err:match("ENOENT"),
    "files error should name ENOENT: " .. tostring(err))
end
test_files_missing_root_errors()

local function test_collect_success_has_no_error()
  local base = mksubdir("collect_ok")
  write_file(fs.join(base, "one.lua"), "-- 1")
  local results, err = fs_walk.collect(base, "*.lua")
  assert(results, "collect should succeed")
  assert(err == nil, "no error expected on a clean walk, got " .. tostring(err))
  assert(#(results as {string}) == 1, "expected exactly one match")
end
test_collect_success_has_no_error()

-- files(): early loop exit must release directory handles via the
-- generic-for closing slot (Lua 5.4), not wait for the GC.

local function count_open_fds(): integer
  -- Exhausting the iterator closes its own handle as it goes.
  local n = 0
  local iter = fs_walk.files("/proc/self/fd")
  for _ in iter do n = n + 1 end
  return n
end

local function test_files_early_break_closes_handles()
  if not fs.isdir("/proc/self/fd") then
    return -- fd accounting needs procfs; skip elsewhere
  end
  local base = mksubdir("files_close")
  for i = 1, 3 do
    local sub = fs.join(base, "sub" .. i)
    fs.makedirs(sub)
    write_file(fs.join(sub, "f" .. i .. ".txt"), "x")
  end

  local before = count_open_fds()
  for p in fs_walk.files(base, "*.txt") do
    assert(p, "expected a path")
    break -- abandon the iterator with directories still open
  end
  local after = count_open_fds()
  assert(after == before, string.format(
      "early break must close directory handles: %d fds before, %d after",
      before, after))
end
test_files_early_break_closes_handles()
