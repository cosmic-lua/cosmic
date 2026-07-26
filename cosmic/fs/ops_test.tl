#!/usr/bin/env cosmic
--- Tests for fs file operations: copy, move, touch, write_atomic, tmpfile.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cfd = require("cosmic.fd")

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

  local st = check.must(fs.stat(dst), "stat dst should succeed")
  local mode = st:mode() & tonumber("777", 8)
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
  local before = check.must(fs.stat(p), "stat should succeed")
  local ok2, err2 = fs.touch(p)
  assert(ok2, "touch should succeed on existing file: " .. (err2 or ""))
  local after = check.must(fs.stat(p), "stat should succeed")
  local before_m = before:mtim()
  local after_m = after:mtim()
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

  local st = check.must(fs.stat(p), "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8),
    string.format("expected mode 600, got %o", mode))

  -- No temporary residue left behind.
  local leftovers = check.must(fs.collect(test_dir, "config.json.*"))
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

local function test_tmpfile_success_contract()
  local test_dir = setup()
  local h, path, err = fs.tmpfile(fs.join(test_dir, "fs_ops_XXXXXX"))
  assert(h, "tmpfile should succeed: " .. (err or ""))
  assert(path and path:match("fs_ops_"), "second return should be the path")
  assert(err == nil, "error slot should be nil on success")
  local hh = check.must(h)
  local st = fs.fstat(hh:fd())
  assert(st, "fstat on tmpfile fd should succeed")
  hh:close()
  teardown(test_dir)
end
test_tmpfile_success_contract()

-- utimensat/futimens: exact timestamp semantics, not just
-- "touch moved mtime forward".

local function test_utimensat_sets_exact_times()
  local test_dir = setup()
  local p = fs.join(test_dir, "stamped")
  touch(p, "x")

  local ok, err = fs.utimensat(p, 1234567890, 500000000, 987654321, 250000000)
  assert(ok, "utimensat should succeed: " .. (err or ""))

  local st = check.must(fs.stat(p), "stat should succeed")
  local a_s, a_ns = st:atim()
  local m_s, m_ns = st:mtim()
  assert(a_s == 1234567890 and a_ns == 500000000,
    "atime should be exactly what was set, got " .. a_s .. "." .. a_ns)
  assert(m_s == 987654321 and m_ns == 250000000,
    "mtime should be exactly what was set, got " .. m_s .. "." .. m_ns)

  teardown(test_dir)
end
test_utimensat_sets_exact_times()

local function test_utimensat_missing_path()
  local test_dir = setup()
  local ok, err = fs.utimensat(fs.join(test_dir, "absent"), 1, 0, 1, 0)
  assert(not ok, "utimensat on a missing path should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_utimensat_missing_path()

local function test_futimens_sets_exact_times()
  local test_dir = setup()
  local p = fs.join(test_dir, "fstamped")
  touch(p, "x")

  local hh = check.must(cfd.open(p, 0))
  local ok, err = fs.futimens(hh:fd(), 111, 0, 222, 0)
  assert(ok, "futimens should succeed: " .. (err or ""))

  local st = check.must(fs.fstat(hh:fd()), "fstat should succeed")
  local a_s, a_ns = st:atim()
  local m_s, m_ns = st:mtim()
  assert(a_s == 111 and a_ns == 0,
    "atime should be 111.0, got " .. a_s .. "." .. a_ns)
  assert(m_s == 222 and m_ns == 0,
    "mtime should be 222.0, got " .. m_s .. "." .. m_ns)
  hh:close()

  teardown(test_dir)
end
test_futimens_sets_exact_times()

local function test_futimens_bad_fd()
  local ok, err = fs.futimens(9999, 1, 0, 1, 0)
  assert(not ok, "futimens on a bad fd should fail")
  assert(err and err:match("EBADF"), "error should name EBADF: " .. (err or ""))
end
test_futimens_bad_fd()

-- rmrf failure path: a path whose parent component is a
-- regular file fails with ENOTDIR regardless of privileges.

local function test_rmrf_failure_reports_error()
  local test_dir = setup()
  local blocker = fs.join(test_dir, "afile")
  touch(blocker, "x")
  local ok, err = fs.rmrf(fs.join(blocker, "child"))
  assert(not ok, "rmrf through a file component should fail")
  assert(err and err:match("ENOTDIR"), "error should name ENOTDIR: " .. (err or ""))
  assert(fs.isfile(blocker), "the blocking file must be untouched")
  teardown(test_dir)
end
test_rmrf_failure_reports_error()

local function test_tmpfile_failure_contract()
  -- The second return is always the path (nil on failure); the error is
  -- always in the third slot.
  local h, path, err = fs.tmpfile("/no/such/dir/fs_ops_XXXXXX")
  assert(h == nil, "tmpfile should fail in a missing directory")
  assert(path == nil, "path slot must be nil on failure, got " .. tostring(path))
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
end
test_tmpfile_failure_contract()
