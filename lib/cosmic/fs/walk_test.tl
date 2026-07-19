#!/usr/bin/env cosmic
--- Tests for fs_walk module (symlink cycle safety)
local check = require("cosmic.check")
local fs_walk = require("cosmic.fs.walk")
local fs = require("cosmic.fs")
local user = require("cosmic.user")
local type WalkAction = fs_walk.WalkAction

local tmpdir = os.getenv("TEST_TMPDIR")

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
  for p in check.must(fs_walk.files(base, "*.lua")) do
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
  fs_walk.walk(base, function(_full_path: string, entry: string, _st: any, ctx: {string: boolean})
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
  -- #558a: strict, like collect — a typo'd directory must be an error,
  -- not an iterator that silently yields zero files.
  local missing = fs.join(tmpdir, "no", "such", "dir")
  local iter, err = fs_walk.files(missing)
  assert(iter == nil, "files() on a missing root should return nil")
  assert(err and err:match("ENOENT"),
    "files error should name ENOENT: " .. tostring(err))
end
test_files_missing_root_errors()

-- Error propagation: an unreadable subdirectory does not stop the walk,
-- but the error is surfaced alongside the context (issue #505) — a
-- partial walk must never be mistaken for a complete one.

local function test_walk_permission_denied_subdir_reports_error()
  if user.geteuid() == 0 then
    return -- root bypasses permission checks; nothing to observe
  end
  local base = mksubdir("walk_denied")
  local open_dir = fs.join(base, "open")
  local locked = fs.join(base, "locked")
  fs.makedirs(open_dir)
  fs.makedirs(locked)
  write_file(fs.join(open_dir, "seen.txt"), "x")
  write_file(fs.join(locked, "hidden.txt"), "x")
  assert(fs.chmod(locked, 0))

  local visited: {string: boolean} = {}
  local ctx, err = fs_walk.walk(base, function(_p: string, name: string,
        _st: any, c: {string: boolean})
      c[name] = true
    end, visited)
  assert(fs.chmod(locked, tonumber("755", 8)))

  assert(ctx ~= nil, "a denied subdir must not abort the walk")
  assert(visited["seen.txt"], "readable entries must still be visited")
  assert(err and err:match("EACCES"),
    "walk must surface the denied subdir: " .. tostring(err))
end
test_walk_permission_denied_subdir_reports_error()

-- #558b: visitor return protocol — "skip" prunes a subtree, "stop" ends
-- the walk. Visitors that return nothing keep today's behavior.

local record SkipCtx
  visited: {string: boolean}
end

local function test_walk_skip_prunes_subtree()
  local base = mksubdir("walk_skip")
  local keep = fs.join(base, "keep")
  local prune = fs.join(base, "prune")
  fs.makedirs(keep)
  fs.makedirs(prune)
  write_file(fs.join(keep, "a.txt"), "a")
  write_file(fs.join(prune, "b.txt"), "b")

  local ctx: SkipCtx = {visited = {}}
  local got, err = fs_walk.walk(base, function(_p: string, name: string,
        _st: any, c: SkipCtx): WalkAction
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
  local got, err = fs_walk.walk(base, function(_p: string, _n: string,
        _st: any, c: StopCtx): WalkAction
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
  fs.makedirs(subsub)
  write_file(fs.join(subsub, "deep.txt"), "x")
  write_file(fs.join(base, "top1.txt"), "x")
  write_file(fs.join(base, "top2.txt"), "x")

  local ctx: StopCtx = {count = 0, stopped = false, after = 0}
  fs_walk.walk(base, function(_p: string, name: string,
        _st: any, c: StopCtx): WalkAction
      if c.stopped then
        c.after = c.after + 1
      end
      if name == "deep.txt" then
        c.stopped = true
        return "stop"
      end
    end, ctx)
  assert(ctx.stopped, "deep.txt should have been visited")
  assert(ctx.after == 0, "no entry may be visited after stop, got "
    .. tostring(ctx.after))
end
test_walk_stop_in_subtree_aborts_walk()

local function test_walk_skip_with_symlink_cycle_terminates()
  local base = mksubdir("walk_skip_cycle")
  local sub = fs.join(base, "sub")
  fs.makedirs(sub)
  write_file(fs.join(sub, "real.txt"), "hello")
  fs.symlink("..", fs.join(sub, "loop"))

  local ctx: StopCtx = {count = 0, stopped = false, after = 0}
  local got, err = fs_walk.walk(base, function(_p: string, name: string,
        _st: any, c: StopCtx): WalkAction
      c.count = c.count + 1
      if name == "loop" then
        return "skip"
      end
    end, ctx)
  assert(got, "walk should succeed: " .. tostring(err))
  -- sub, real.txt, loop — pruning on top of cycle safety must terminate.
  assert(ctx.count == 3, "expected 3 entries, got " .. tostring(ctx.count))
end
test_walk_skip_with_symlink_cycle_terminates()

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
  local iter = check.must(fs_walk.files("/proc/self/fd"))
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
  for p in check.must(fs_walk.files(base, "*.txt")) do
    assert(p, "expected a path")
    break -- abandon the iterator with directories still open
  end
  local after = count_open_fds()
  assert(after == before, string.format(
      "early break must close directory handles: %d fds before, %d after",
      before, after))
end
test_files_early_break_closes_handles()
