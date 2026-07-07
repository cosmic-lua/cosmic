#!/usr/bin/env cosmic
--- Tests for fs file operations: copy, move, touch, write_atomic, mkstemp.
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = fs.join(TEST_TMPDIR, "fs_ops_test")
  fs.makedirs(test_dir)
  return test_dir
end

local function teardown(test_dir: string)
  if test_dir then
    fs.rmrf(test_dir)
  end
end

local function touch(filepath: string, content?: string)
  local f = io.open(filepath, "w")
  if f then
    if content then
      f:write(content)
    end
    f:close()
  end
end

local function test_copy_preserves_mode()
  local test_dir = setup()
  local src = fs.join(test_dir, "src.sh")
  touch(src, "#!/bin/sh\necho hi\n")
  assert(fs.chmod(src, tonumber("755", 8)))
  local dst = fs.join(test_dir, "dst.sh")

  local ok, err = fs.copy(src, dst)
  assert(ok, "copy should succeed: " .. (err or ""))

  local f = io.open(dst, "r")
  assert(f, "destination should exist")
  local content = f:read("*a")
  f:close()
  assert(content == "#!/bin/sh\necho hi\n", "content should match")

  local st = fs.stat(dst)
  assert(st, "stat dst should succeed")
  local mode = (st as fs_types.Stat):mode() & tonumber("777", 8)
  assert(mode == tonumber("755", 8),
    string.format("expected mode 755, got %o", mode))

  teardown(test_dir)
end
test_copy_preserves_mode()

local function test_copy_missing_source()
  local test_dir = setup()
  local ok, err = fs.copy(fs.join(test_dir, "absent"), fs.join(test_dir, "out"))
  assert(not ok, "copy of missing source should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_copy_missing_source()

local function test_move_same_filesystem()
  local test_dir = setup()
  local src = fs.join(test_dir, "a.txt")
  touch(src, "payload")
  local dst = fs.join(test_dir, "b.txt")

  local ok, err = fs.move(src, dst)
  assert(ok, "move should succeed: " .. (err or ""))
  assert(not fs.exists(src), "source should be gone")
  local f = io.open(dst, "r")
  assert(f, "destination should exist")
  assert(f:read("*a") == "payload", "content should move intact")
  f:close()

  teardown(test_dir)
end
test_move_same_filesystem()

local function test_move_missing_source()
  local test_dir = setup()
  local ok, err = fs.move(fs.join(test_dir, "absent"), fs.join(test_dir, "out"))
  assert(not ok, "move of missing source should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_move_missing_source()

local function test_touch_creates_and_updates()
  local test_dir = setup()
  local p = fs.join(test_dir, "stamp")
  assert(not fs.exists(p), "file should not exist yet")

  local ok, err = fs.touch(p)
  assert(ok, "touch should create the file: " .. (err or ""))
  assert(fs.isfile(p), "touch should create a regular file")

  -- Backdate mtime, then touch again: mtime must move forward.
  assert(fs.utimensat(p, 1000, 0, 1000, 0))
  local before = fs.stat(p)
  assert(before, "stat should succeed")
  local ok2, err2 = fs.touch(p)
  assert(ok2, "touch should succeed on existing file: " .. (err2 or ""))
  local after = fs.stat(p)
  assert(after, "stat should succeed")
  local before_m = (before as fs_types.Stat):mtim()
  local after_m = (after as fs_types.Stat):mtim()
  assert(after_m > before_m,
    "touch should update mtime: " .. before_m .. " -> " .. after_m)

  teardown(test_dir)
end
test_touch_creates_and_updates()

local function test_write_atomic_roundtrip()
  local test_dir = setup()
  local p = fs.join(test_dir, "config.json")
  touch(p, "old")

  local ok, err = fs.write_atomic(p, "new contents", tonumber("600", 8))
  assert(ok, "write_atomic should succeed: " .. (err or ""))
  local f = io.open(p, "r")
  assert(f, "file should exist")
  assert(f:read("*a") == "new contents", "contents should be replaced")
  f:close()

  local st = fs.stat(p)
  assert(st, "stat should succeed")
  local mode = (st as fs_types.Stat):mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8),
    string.format("expected mode 600, got %o", mode))

  -- No temporary residue left behind.
  local leftovers = (fs.collect(test_dir, "config.json.*") or {}) as {string}
  assert(#leftovers == 0, "no temp files should remain: " .. tostring(leftovers[1]))

  teardown(test_dir)
end
test_write_atomic_roundtrip()

local function test_write_atomic_failure_keeps_original()
  local test_dir = setup()
  local original = fs.join(test_dir, "keep.txt")
  touch(original, "original")

  -- A destination in a missing directory fails before touching anything.
  local p = fs.join(test_dir, "no-such-subdir", "f.txt")
  local ok, err = fs.write_atomic(p, "data")
  assert(not ok, "write_atomic into a missing directory should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))

  local f = io.open(original, "r")
  assert(f, "unrelated file should be untouched")
  assert(f:read("*a") == "original", "original contents should survive")
  f:close()

  teardown(test_dir)
end
test_write_atomic_failure_keeps_original()

local function test_mkstemp_success_contract()
  local test_dir = setup()
  local fd, path, err = fs.mkstemp(fs.join(test_dir, "fs_ops_XXXXXX"))
  assert(fd, "mkstemp should succeed: " .. (err or ""))
  assert(path and path:match("fs_ops_"), "second return should be the path")
  assert(err == nil, "error slot should be nil on success")
  local handle = fs.fstat(fd)
  assert(handle, "fstat on mkstemp fd should succeed")
  require("cosmo.unix").close(fd)
  teardown(test_dir)
end
test_mkstemp_success_contract()

local function test_mkstemp_failure_contract()
  -- The second return is always the path (nil on failure); the error is
  -- always in the third slot.
  local fd, path, err = fs.mkstemp("/no/such/dir/fs_ops_XXXXXX")
  assert(fd == nil, "mkstemp should fail in a missing directory")
  assert(path == nil, "path slot must be nil on failure, got " .. tostring(path))
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
end
test_mkstemp_failure_contract()
