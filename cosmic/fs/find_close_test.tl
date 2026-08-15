#!/usr/bin/env cosmic
--- find_iter()'s handle ownership, alone in its own file so
--- cosmic/fs/walk_test.tl stays under the 500-line cap.
---
--- The iterator OWNS the directory handles it opened, so a loop that
--- exits early has to say it is done with them. Draining closes them;
--- so do `iter:close()` and the `<close>` attribute its __close
--- metamethod backs. Collection is the backstop, not the contract.
--- The guard lives on the FileIter record itself, the same shape
--- cosmic.sqlite's Rows uses, so nothing rides in a slot past the
--- error return.
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
  -- Exhausting the iterator closes its own handle as it goes.
  local n = 0
  local iter = check.must(fs_find.find_iter("/proc/self/fd"))
  for _ in iter do n = n + 1 end
  return n
end

local function tree_with_open_subdirs(name: string): string
  local base = mksubdir(name)
  for i = 1, 3 do
    local sub = fs.join(base, "sub" .. i)
    assert(fs.make_dirs(sub))
    write_file(fs.join(sub, "f" .. i .. ".txt"), "x")
  end
  return base
end

local function test_find_iter_close_releases_handles()
  if not fs.is_dir("/proc/self/fd") then
    return -- fd accounting needs procfs; skip elsewhere
  end
  local base = tree_with_open_subdirs("files_close")

  local before = count_open_fds()
  local iter = check.must(fs_find.find_iter(base, {glob = "*.txt"}))
  for p in iter do
    assert(p, "expected a path")
    break -- abandon the walk with directories still open
  end
  iter:close()
  local after = count_open_fds()
  assert(after == before, string.format(
      "close() must release directory handles: %d fds before, %d after",
      before, after))
  iter:close() -- idempotent
end
test_find_iter_close_releases_handles()

local function test_find_iter_to_be_closed_scope()
  if not fs.is_dir("/proc/self/fd") then
    return
  end
  local base = tree_with_open_subdirs("files_tbc")

  local before = count_open_fds()
  local iter = check.must(fs_find.find_iter(base, {glob = "*.txt"}))
  for p in iter do
    assert(p, "expected a path")
    break
  end
  -- The repo build compiles Teal targeting 5.3 syntax, so exercise the
  -- __close metamethod directly instead of a `local iter <close> = ...`
  -- declaration (which works in user scripts on the 5.4 runtime); same
  -- reason cosmic/sqlite/close_test.tl does.
  local mt = getmetatable(iter) as {string: any} -- cast: raw metatable access
  local close_mm = mt["__close"] as function(any, any) -- cast: from any
  assert(close_mm, "FileIter must have a __close metamethod")
  close_mm(iter, nil)
  local after = count_open_fds()
  assert(after == before, string.format(
      "<close> must release directory handles: %d fds before, %d after",
      before, after))
  assert(iter() == nil, "a closed iterator yields nothing")
end
test_find_iter_to_be_closed_scope()

local function test_find_iter_abandoned_is_collected()
  if not fs.is_dir("/proc/self/fd") then
    return
  end
  local base = tree_with_open_subdirs("files_gc")

  local before = count_open_fds()
  for p in check.must(fs_find.find_iter(base, {glob = "*.txt"})) do
    assert(p, "expected a path")
    break -- no close(): the backstop has to catch this one
  end
  collectgarbage("collect")
  collectgarbage("collect")
  local after = count_open_fds()
  assert(after == before, string.format(
      "collection must release an abandoned iterator: %d fds before, %d after",
      before, after))
end
test_find_iter_abandoned_is_collected()
