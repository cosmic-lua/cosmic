#!/usr/bin/env cosmic
--- Tests for the walker (cosmic.fs.walk) and the find family
--- (cosmic.fs.find): symlink cycle safety, error slots, options.
local check = require("cosmic.check")
local fs_walk = require("cosmic.fs.walk")
local fs_find = require("cosmic.fs.find")
local fs = require("cosmic.fs")
local user = require("cosmic.user")
local type WalkAction = fs_walk.WalkAction

local tmpdir = os.getenv("TEST_TMPDIR")

-- Helper: create a directory under tmpdir
local function mksubdir(name: string): string
  local p = fs.join(tmpdir, name)
  assert(fs.make_dirs(p))
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
  assert(fs.make_dirs(subdir))
  write_file(fs.join(subdir, "real.txt"), "hello")
  -- Create a symlink cycle: sub/loop -> ..  (points back to base)
  assert(fs.symlink("..", fs.join(subdir, "loop")))

  local max_depth_seen = 0
  -- walk the base directory; collect all entries to detect infinite loop
  -- (the test harness has a timeout; if we don't hang this is fine)
  local results: {string} = {}
  assert(fs_walk.visit(base, function(e: fs_walk.Entry, ctx: {string})
        ctx[#ctx + 1] = e.path
      end, results))

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

-- FIX 1b: find_info() must not recurse into symlinked directories
local function test_find_all_symlink_cycle_terminates()
  local base = mksubdir("find_info_cycle")
  local subdir = fs.join(base, "sub")
  assert(fs.make_dirs(subdir))
  write_file(fs.join(subdir, "real.txt"), "data")
  assert(fs.symlink("..", fs.join(subdir, "loop")))

  local collected = check.must(fs_find.find_info(base))
  local files = collected.files
  -- Keys are FULL paths; none may contain loop/
  for full_path in pairs(files) do
    assert(not full_path:match("loop"),
      "find_info should not recurse into symlink loop, found: " .. full_path)
  end
  assert(files[fs.join(base, "sub/real.txt")] ~= nil, "real.txt should be found")
end
test_find_all_symlink_cycle_terminates()

-- FIX 1c: files() iterator must not recurse into symlinked directories
local function test_find_iter_symlink_cycle_terminates()
  local base = mksubdir("files_cycle")
  local subdir = fs.join(base, "sub")
  assert(fs.make_dirs(subdir))
  write_file(fs.join(subdir, "real.lua"), "-- lua")
  assert(fs.symlink("..", fs.join(subdir, "loop")))

  local collected: {string} = {}
  for p in check.must(fs_find.find_iter(base, {glob = "*.lua"})) do
    collected[#collected + 1] = p
    -- Safety: abort if we find more than a small number
    assert(#collected <= 10,
      "files() appears to iterate infinitely (>10 results from 1 real file)")
  end
  assert(#collected == 1, "expected 1 lua file, got " .. tostring(#collected))
  assert(collected[1]:match("real%.lua$"), "expected real.lua, got " .. tostring(collected[1]))
end
test_find_iter_symlink_cycle_terminates()

-- FIX 1d: symlinked regular files should still be visited (not skipped)
-- Only symlinked *directories* are not recursed into.
local function test_walk_symlink_file_visited()
  local base = mksubdir("walk_symlink_file")
  write_file(fs.join(base, "real.txt"), "content")
  -- Symlink to a file in same dir
  assert(fs.symlink("real.txt", fs.join(base, "alias.txt")))

  local found: {string: boolean} = {}
  assert(fs_walk.visit(base, function(e: fs_walk.Entry, ctx: {string: boolean})
        ctx[e.name] = true
      end, found))
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
  local ctx, err = fs_walk.visit(missing, function(_e: fs_walk.Entry,
        _c: {string}) end, {})
  assert(ctx == nil, "walk of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "walk error should name ENOENT: " .. tostring(err))
end
test_walk_missing_root_errors()

local function test_find_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local results, err = fs_find.find(missing, {glob = "*.lua"})
  assert(results == nil, "collect of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "collect error should name ENOENT: " .. tostring(err))
end
test_find_missing_root_errors()

local function test_find_all_missing_root_errors()
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local results, err = fs_find.find_info(missing)
  assert(results == nil, "find_info of a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "find_info error should name ENOENT: " .. tostring(err))
end
test_find_all_missing_root_errors()

local function test_find_iter_missing_root_errors()
  -- Strict, like find — a typo'd directory must be an error, not an
  -- iterator that silently yields zero files.
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local iter, err = fs_find.find_iter(missing)
  assert(iter == nil, "files() on a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "files error should name ENOENT: " .. tostring(err))
end
test_find_iter_missing_root_errors()

-- Error propagation: an unreadable subdirectory does not stop the walk,
-- but the error is surfaced alongside the context — a
-- partial walk must never be mistaken for a complete one.

local function test_walk_permission_denied_subdir_reports_error()
  if user.geteuid() == 0 then
    return -- root bypasses permission checks; nothing to observe
  end
  local base = mksubdir("walk_denied")
  local open_dir = fs.join(base, "open")
  local locked = fs.join(base, "locked")
  assert(fs.make_dirs(open_dir))
  assert(fs.make_dirs(locked))
  write_file(fs.join(open_dir, "seen.txt"), "x")
  write_file(fs.join(locked, "hidden.txt"), "x")
  assert(fs.set_mode(locked, 0))

  local visited: {string: boolean} = {}
  local walked = fs_walk.visit(base, function(e: fs_walk.Entry,
        c: {string: boolean})
      c[e.name] = true
    end, visited)
  assert(fs.set_mode(locked, tonumber("755", 8)))

  assert(walked, "a denied subdir must not abort the walk")
  local err = walked.errors and walked.errors[1]
  assert(visited["seen.txt"], "readable entries must still be visited")
  assert(err and err:match("EACCES"),
    "walk must surface the denied subdir: " .. tostring(err))
end
test_walk_permission_denied_subdir_reports_error()

-- files() gets the same contract as walk(): an unreadable subdirectory
-- does not stop iteration, and the first such error is surfaced once
-- the iterator itself is exhausted (see the doc comment on files()).
local function test_find_iter_permission_denied_subdir_reports_error()
  if user.geteuid() == 0 then
    return -- root bypasses permission checks; nothing to observe
  end
  local base = mksubdir("files_denied")
  local open_dir = fs.join(base, "open")
  local locked = fs.join(base, "locked")
  assert(fs.make_dirs(open_dir))
  assert(fs.make_dirs(locked))
  write_file(fs.join(open_dir, "seen.txt"), "x")
  write_file(fs.join(locked, "hidden.txt"), "x")
  assert(fs.set_mode(locked, 0))

  local iter = check.must(fs_find.find_iter(base))
  local seen: {string: boolean} = {}
  local f = iter()
  while f do
    seen[fs.basename(f)] = true
    f = iter()
  end
  assert(fs.set_mode(locked, tonumber("755", 8)))

  assert(seen["seen.txt"], "readable entries must still be yielded")
  -- The exhausted iterator reports the subtree-error LIST from then
  -- on; calling it again re-reports rather than resuming anything.
  local _, suberrs = iter()
  assert(suberrs and suberrs[1] and suberrs[1]:match("EACCES"),
    "find_iter must surface the denied subdir once exhausted: "
    .. tostring(suberrs and suberrs[1]))
end
test_find_iter_permission_denied_subdir_reports_error()

-- Visitor return protocol — "skip" prunes a subtree, "stop" ends
-- the walk. Visitors that return nothing keep the default behavior.

local record SkipCtx
  visited: {string: boolean}
end

local function test_walk_skip_prunes_subtree()
  local base = mksubdir("walk_skip")
  local keep = fs.join(base, "keep")
  local prune = fs.join(base, "prune")
  assert(fs.make_dirs(keep))
  assert(fs.make_dirs(prune))
  write_file(fs.join(keep, "a.txt"), "a")
  write_file(fs.join(prune, "b.txt"), "b")

  local ctx: SkipCtx = {visited = {}}
  local got, err = fs_walk.visit(base, function(e: fs_walk.Entry,
        c: SkipCtx): WalkAction
      local name = e.name
      c.visited[name] = true
      if name == "prune" then
        return "skip"
      end
      if name == "a.txt" then
        return "skip" -- "skip" on a file is a no-op
      end
    end, ctx)
  assert(got, "walk should succeed: " .. tostring(err))
  assert(ctx.visited["prune"], "the pruned dir itself is visited")
  assert(ctx.visited["keep"], "sibling dirs are visited")
  assert(ctx.visited["a.txt"], "children of kept dirs are visited")
  assert(not ctx.visited["b.txt"],
    "children of a skipped dir must not be visited")
end
test_walk_skip_prunes_subtree()

local record StopCtx
  count: integer
  stopped: boolean
  after: integer
end

local function test_walk_stop_ends_walk()
  local base = mksubdir("walk_stop")
  for i = 1, 5 do
    write_file(fs.join(base, "f" .. i .. ".txt"), "x")
  end

  local ctx: StopCtx = {count = 0, stopped = false, after = 0}
  local got, err = fs_walk.visit(base, function(_e: fs_walk.Entry,
        c: StopCtx): WalkAction
      c.count = c.count + 1
      return "stop"
    end, ctx)
  assert(got, "walk should return ctx after stop: " .. tostring(err))
  assert(ctx.count == 1,
    "stop must end the walk after the first visit, got " .. tostring(ctx.count))
end
test_walk_stop_ends_walk()

local function test_walk_stop_in_subtree_aborts_walk()
  local base = mksubdir("walk_stop_deep")
  local subsub = fs.join(base, "sub", "subsub")
  assert(fs.make_dirs(subsub))
  write_file(fs.join(subsub, "deep.txt"), "x")
  write_file(fs.join(base, "top1.txt"), "x")
  write_file(fs.join(base, "top2.txt"), "x")

  local ctx: StopCtx = {count = 0, stopped = false, after = 0}
  assert(fs_walk.visit(base, function(e: fs_walk.Entry,
          c: StopCtx): WalkAction
        if c.stopped then
          c.after = c.after + 1
        end
        if e.name == "deep.txt" then
          c.stopped = true
          return "stop"
        end
      end, ctx))
  assert(ctx.stopped, "deep.txt should have been visited")
  assert(ctx.after == 0, "no entry may be visited after stop, got "
    .. tostring(ctx.after))
end
test_walk_stop_in_subtree_aborts_walk()

local function test_walk_skip_with_symlink_cycle_terminates()
  local base = mksubdir("walk_skip_cycle")
  local sub = fs.join(base, "sub")
  assert(fs.make_dirs(sub))
  write_file(fs.join(sub, "real.txt"), "hello")
  assert(fs.symlink("..", fs.join(sub, "loop")))

  local ctx: StopCtx = {count = 0, stopped = false, after = 0}
  local got, err = fs_walk.visit(base, function(e: fs_walk.Entry,
        c: StopCtx): WalkAction
      c.count = c.count + 1
      if e.name == "loop" then
        return "skip"
      end
    end, ctx)
  assert(got, "walk should succeed: " .. tostring(err))
  -- sub, real.txt, loop — pruning on top of cycle safety must terminate.
  assert(ctx.count == 3, "expected 3 entries, got " .. tostring(ctx.count))
end
test_walk_skip_with_symlink_cycle_terminates()

local function test_find_success_has_no_error()
  local base = mksubdir("collect_ok")
  write_file(fs.join(base, "one.lua"), "-- 1")
  local results, err = fs_find.find(base, {glob = "*.lua"})
  assert(results, "find should succeed")
  assert(err == nil, "slot 2 is nil unless the root failed, got " .. tostring(err))
  assert(results.errors == nil, "a clean walk carries no .errors")
  assert(#(results) == 1, "expected exactly one match")
end
test_find_success_has_no_error()

-- visit(): the Entry record carries path/name/stat/depth, and the
-- subtree-error list rides on the result as `.errors` — never beside
-- it in a third slot.

local function test_visit_entry_and_depth()
  local base = mksubdir("visit_entry")
  local sub = fs.join(base, "sub")
  assert(fs.make_dirs(sub))
  write_file(fs.join(sub, "deep.txt"), "x")
  write_file(fs.join(base, "top.txt"), "x")

  local depths: {string: integer} = {}
  local walked, err = fs.visit(base, function(e: fs.Entry, c: {string: integer})
      assert(e.path:sub(1, #base) == base, "Entry.path is the full path")
      c[e.name] = e.depth
    end, depths)
  assert(walked ~= nil, "visit should succeed: " .. tostring(err))
  assert(walked.errors == nil, "clean walk carries no subtree errors")
  assert(depths["top.txt"] == 1, "top-level entries are depth 1")
  assert(depths["sub"] == 1, "the subdir itself is depth 1")
  assert(depths["deep.txt"] == 2, "entries one level down are depth 2")
end
test_visit_entry_and_depth()

local function test_visit_denied_subdir_lands_in_errors()
  if user.geteuid() == 0 then
    return -- root bypasses permission checks; nothing to observe
  end
  local base = mksubdir("visit_denied")
  local locked = fs.join(base, "locked")
  assert(fs.make_dirs(locked))
  assert(fs.set_mode(locked, 0))
  local walked, err = fs.visit(base, function(_e: fs.Entry, _c: {string}) end, {})
  assert(fs.set_mode(locked, tonumber("755", 8)))
  assert(walked ~= nil, "a denied subdir must not abort the walk")
  assert(err == nil, "slot 2 means the ROOT failed, and it did not")
  local suberrs = walked and walked.errors
  assert(suberrs and suberrs[1] and suberrs[1]:match("EACCES"),
    "the denied subdir must land in .errors: " .. tostring(suberrs and suberrs[1]))
end
test_visit_denied_subdir_lands_in_errors()

-- FindOptions: depth bounds, directory inclusion, sorting.

local function setup_depth_tree(): string
  local base = mksubdir("find_opts")
  local sub = fs.join(base, "bdir")
  assert(fs.make_dirs(sub))
  write_file(fs.join(base, "a.txt"), "x")
  write_file(fs.join(sub, "c.txt"), "x")
  return base
end

local function test_find_max_depth_and_recursive()
  local base = setup_depth_tree()
  local all = check.must(fs.find(base, {glob = "*.txt"}))
  assert(#all == 2, "unbounded find sees both files")
  local top = check.must(fs.find(base, {glob = "*.txt", max_depth = 1}))
  assert(#top == 1 and top[1]:match("a%.txt$"), "max_depth = 1 stays at the top")
  local flat = check.must(fs.find(base, {glob = "*.txt", recursive = false}))
  assert(#flat == 1, "recursive = false equals max_depth = 1")
end
test_find_max_depth_and_recursive()

local function test_find_include_dirs_and_sorted()
  local base = setup_depth_tree()
  local everything = check.must(fs.find(base, {include_dirs = true, sorted = true}))
  assert(#everything == 3, "include_dirs adds the directory itself")
  assert(everything[1]:match("a%.txt$"), "sorted: a.txt first")
  assert(everything[2]:match("bdir$"), "sorted: bdir second")
  assert(everything[3]:match("c%.txt$"), "sorted: c.txt last")
end
test_find_include_dirs_and_sorted()

local function test_find_iter_honors_depth_and_dirs()
  local base = setup_depth_tree()
  local names: {string: boolean} = {}
  for p in check.must(fs_find.find_iter(base, {include_dirs = true, max_depth = 1})) do
    names[fs.basename(p)] = true
  end
  assert(names["a.txt"] and names["bdir"], "top level yielded, dirs included")
  assert(not names["c.txt"], "max_depth = 1 must not descend")
end
test_find_iter_honors_depth_and_dirs()

local function test_find_info_full_paths_and_options()
  local base = setup_depth_tree()
  local info = check.must(fs.find_info(base, {glob = "*.txt", max_depth = 1})).files
  assert(info[fs.join(base, "a.txt")], "keys are full paths")
  assert(info[fs.join(base, "bdir/c.txt")] == nil, "max_depth bounds find_info too")
  assert(info[fs.join(base, "a.txt")].mode ~= nil, "FileInfo carries mode")
end
test_find_info_full_paths_and_options()
