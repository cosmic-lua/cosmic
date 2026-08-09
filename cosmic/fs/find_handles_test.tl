#!/usr/bin/env cosmic
--- find_iter()'s handle discipline, alone in its own file so
--- cosmic/fs/walk_test.tl stays under the 500-line cap.
---
--- The property: the iterator NEVER holds a directory handle across a
--- yield. Each directory is read in full and closed before a path
--- comes back, so an abandoned iterator — `break`, an error, dropping
--- it — owns nothing to leak, with no guard to forward and no close to
--- remember. That is what lets find_iter return two slots (D20 rule 11,
--- #1063) without trading a descriptor leak for them: the previous
--- shape held one handle per level and released them through a fourth
--- return value the generic `for` adopted as its closing slot.
---
--- These tests measure real descriptors through /proc/self/fd, and
--- none of them collect first: needing a GC pass would mean the
--- property does not hold.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_find = require("cosmic.fs.find")

local tmpdir = os.getenv("TEST_TMPDIR")

local function mksubdir(name: string): string
  local p = fs.join(tmpdir, name)
  assert(fs.make_dirs(p))
  return p
end

local function write_file(path: string, content: string)
  local f = io.open(path, "w")
  assert(f, "cannot open " .. path)
  f:write(content)
  f:close()
end

local function count_open_fds(): integer
  local n = 0
  for _ in check.must(fs_find.find_iter("/proc/self/fd")) do
    n = n + 1
  end
  return n
end

--- A tree deep and wide enough that the old walker would have held
--- several handles at once partway through it.
local function tree_with_subdirs(name: string): string
  local base = mksubdir(name)
  for i = 1, 3 do
    local sub = fs.join(base, "sub" .. i)
    local nested = fs.join(sub, "nested")
    assert(fs.make_dirs(nested))
    write_file(fs.join(sub, "f" .. i .. ".txt"), "x")
    write_file(fs.join(nested, "deep" .. i .. ".txt"), "x")
  end
  return base
end

local function test_find_iter_holds_nothing_mid_iteration()
  if not fs.is_dir("/proc/self/fd") then
    return -- fd accounting needs procfs; skip elsewhere
  end
  local base = tree_with_subdirs("iter_midway")

  local before = count_open_fds()
  local iter = check.must(fs_find.find_iter(base, {glob = "*.txt"}))
  local seen = 0
  for p in iter do
    assert(p, "expected a path")
    seen = seen + 1
    if seen == 2 then
      break -- suspended INSIDE the walk, subdirectories still pending
    end
  end
  local during = count_open_fds()
  assert(during == before, string.format(
      "a suspended iterator must hold no handles: %d fds before, %d during",
      before, during))
  -- and it is still a working iterator: holding nothing is not the
  -- same as having given up
  local rest = 0
  for _ in iter do
    rest = rest + 1
  end
  assert(seen + rest == 6, "the walk resumes and completes, got " ..
    tostring(seen + rest))
end
test_find_iter_holds_nothing_mid_iteration()

local function test_find_iter_abandoned_holds_nothing()
  if not fs.is_dir("/proc/self/fd") then
    return
  end
  local base = tree_with_subdirs("iter_abandoned")

  local before = count_open_fds()
  for p in check.must(fs_find.find_iter(base, {glob = "*.txt"})) do
    assert(p, "expected a path")
    break -- no close(), no <close>, and deliberately no collection
  end
  local after = count_open_fds()
  assert(after == before, string.format(
      "an abandoned iterator must leak nothing WITHOUT a GC pass: "
      .. "%d fds before, %d after", before, after))
end
test_find_iter_abandoned_holds_nothing()

local function test_find_iter_drains_without_growing_fds()
  if not fs.is_dir("/proc/self/fd") then
    return
  end
  local base = tree_with_subdirs("iter_drain")

  local before = count_open_fds()
  local n = 0
  for _ in check.must(fs_find.find_iter(base, {glob = "*.txt"})) do
    n = n + 1
  end
  local after = count_open_fds()
  assert(n == 6, "expected 6 matches, got " .. tostring(n))
  assert(after == before, string.format(
      "a drained walk leaves the descriptor table where it found it: "
      .. "%d before, %d after", before, after))
end
test_find_iter_drains_without_growing_fds()

--- Depth-first order and depth bounding still hold with the entries
--- buffered per level rather than streamed from an open handle.
local function test_find_iter_depth_bound_survives_buffering()
  local base = tree_with_subdirs("iter_depth")
  local names: {string: boolean} = {}
  for p in check.must(fs_find.find_iter(base, {glob = "*.txt", max_depth = 2})) do
    names[fs.basename(p)] = true
  end
  assert(names["f1.txt"], "depth-2 entries are still visited")
  assert(not names["deep1.txt"], "max_depth still bounds the descent")
end
test_find_iter_depth_bound_survives_buffering()
