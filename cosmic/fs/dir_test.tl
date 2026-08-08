#!/usr/bin/env cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local cfd = require("cosmic.fd")
local unix = require("cosmo.unix")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = fs.join(TEST_TMPDIR, "fs_dir_test")
  assert(fs.make_dirs(test_dir))
  return test_dir
end

local function teardown(test_dir: string)
  if test_dir then
    assert(fs.remove_all(test_dir))
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

-- Dir __close tests

local function test_dir_has_close_metamethod()
  local test_dir = setup()

  local dir = fs.open_dir(test_dir)
  assert(dir, "opendir should succeed")
  local d = dir

  -- Verify __close metamethod exists
  local mt = getmetatable(dir)
  assert(mt, "dir should have a metatable")
  assert(mt.__close, "dir metatable should have __close")

  -- Call __close directly to verify it works, the way <close> would: a
  -- plain function call, not a method send (the patched checker narrows
  -- `dir` here and would flag the method-as-function invocation).
  local close = mt.__close as function(fs_types.Dir) -- cast: metamethod as plain function
  close(d)
  assert(d:closed(), "dir should be closed after __close")

  teardown(test_dir)
end
test_dir_has_close_metamethod()

local function test_dir_closed_method()
  local test_dir = setup()

  local d = check.must(fs.open_dir(test_dir), "opendir should succeed")

  assert(not d:closed(), "dir should not be closed initially")
  d:close()
  assert(d:closed(), "dir should be closed after close()")

  teardown(test_dir)
end
test_dir_closed_method()

local function test_dir_close_idempotent()
  local test_dir = setup()

  local d = check.must(fs.open_dir(test_dir), "opendir should succeed")

  d:close()
  assert(d:closed(), "dir should be closed")

  -- Should not error when closing again
  d:close()
  d:close()
  assert(d:closed(), "dir should still be closed")

  teardown(test_dir)
end
test_dir_close_idempotent()

local function test_dir_methods_after_close()
  local test_dir = setup()
  touch(fs.join(test_dir, "file.txt"))

  local d = check.must(fs.open_dir(test_dir), "opendir should succeed")
  d:close()

  -- read() returns nil when closed
  local entry = d:read()
  assert(entry == nil, "read should return nil after close")

  -- fd() returns -1 when closed
  local fd = d:fd()
  assert(fd == -1, "fd should return -1 after close")

  -- tell() returns -1 when closed
  local pos = d:tell()
  assert(pos == -1, "tell should return -1 after close")

  -- rewind() should be a no-op when closed (no error)
  d:rewind()

  teardown(test_dir)
end
test_dir_methods_after_close()

local function test_dir_rewind_and_tell()
  local test_dir = setup()
  touch(fs.join(test_dir, "file1.txt"))
  touch(fs.join(test_dir, "file2.txt"))

  local d = check.must(fs.open_dir(test_dir), "opendir should succeed")

  -- Read some entries
  local count = 0
  while d:read() do
    count = count + 1
  end
  assert(count >= 2, "should read at least 2 entries")

  -- Tell should return a position
  local pos_end = d:tell()
  assert(pos_end >= 0, "tell should return valid position")

  -- Rewind and count again
  d:rewind()
  local count2 = 0
  while d:read() do
    count2 = count2 + 1
  end
  assert(count2 == count, "should read same number of entries after rewind")

  d:close()
  teardown(test_dir)
end
test_dir_rewind_and_tell()

local function test_dir_fd()
  local test_dir = setup()

  local d = check.must(fs.open_dir(test_dir), "opendir should succeed")

  local fd = d:fd()
  assert(fd >= 0, "fd should be a valid file descriptor")

  d:close()
  teardown(test_dir)
end
test_dir_fd()

-- Filesystem statistics tests

local function test_statfs()
  local info = check.must(fs.statfs("/"))

  -- Check that we can call all the methods
  assert(info:type() ~= nil, "type() should return a value")
  assert(info:block_size_bytes() > 0, "block_size_bytes() should be positive")
  assert(info:total_blocks() > 0, "total_blocks() should be positive")
  assert(info:free_blocks() >= 0, "free_blocks() should be non-negative")
  assert(info:available_blocks() >= 0, "available_blocks() should be non-negative")
  assert(info:total_files() >= 0, "total_files() should be non-negative")
  assert(info:free_files() >= 0, "free_files() should be non-negative")
  local fsid1, fsid2 = info:id()
  assert(fsid1 ~= nil, "id() should return first value")
  assert(fsid2 ~= nil, "id() should return second value")
  assert(info:max_name_bytes() > 0, "max_name_bytes() should be positive")
  assert(info:fragment_size_bytes() > 0, "fragment_size_bytes() should be positive")
  assert(info:flags() ~= nil, "flags() should return a value")
end
test_statfs()

local function test_statfs_nonexistent()
  local info, err = fs.statfs("/nonexistent/path/that/does/not/exist")
  assert(info == nil, "statfs should fail for nonexistent path")
  assert(err, "should return error message")
end
test_statfs_nonexistent()

local function test_fstatfs()
  -- open the test dir, not "/": the sandboxed test lane unveils
  -- only the build tree and TEST_TMPDIR, and any granted dir works here
  local fd = unix.open(TEST_TMPDIR, unix.O_RDONLY | unix.O_DIRECTORY)
  assert(fd, "open should succeed")

  local info = check.must(fs.statfs_fd(fd))

  assert(info:block_size_bytes() > 0, "block_size_bytes() should be positive")
  assert(info:total_blocks() > 0, "total_blocks() should be positive")

  unix.close(fd)
end
test_fstatfs()

-- fs.major/fs.minor are deleted (#988): zero callers; use
-- cosmo.unix.major/minor for raw device-number math.

local function test_fdopendir()
  local test_dir = setup()
  touch(fs.join(test_dir, "file1.txt"))
  touch(fs.join(test_dir, "file2.txt"))

  -- fdopendir must return a working Dir (not an error) on success; it
  -- takes ownership of the fd and closes it via dir:close().
  local h = check.must(cfd.open(test_dir, cfd.O_RDONLY | cfd.O_DIRECTORY))
  local d = check.must(fs.open_dir_fd(h:fd()))

  local entries: {string: boolean} = {}
  while true do
    local entry = d:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      entries[entry] = true
    end
  end
  d:close()

  assert(entries["file1.txt"], "expected file1.txt")
  assert(entries["file2.txt"], "expected file2.txt")

  teardown(test_dir)
end
test_fdopendir()

local function test_fdopendir_bad_fd()
  -- An invalid fd must return nil + error, never throw from the binding.
  local dir, err = fs.open_dir_fd(-1)
  assert(dir == nil, "fdopendir(-1) should fail, not return a Dir")
  assert(type(err) == "string", "failure must carry an error string")
end
test_fdopendir_bad_fd()

-- #988 surfaces: Timespec-valued stat times that round-trip through
-- set_times, spelled Statfs methods, and temp_dir's default template.

local function test_stat_times_round_trip()
  local test_dir = setup()
  local src = fs.join(test_dir, "src.txt")
  local dst = fs.join(test_dir, "dst.txt")
  touch(src)
  touch(dst)
  assert(fs.set_times(src, {mtime = {secs = 1000000, nsecs = 0}}))

  local st = check.must(fs.stat(src))
  local mt = st:modify_time()
  assert(mt.secs == 1000000, "modify_time carries the stamped seconds")

  -- The round trip the record exists for: a stat's times feed
  -- set_times without hand-packing.
  assert(fs.set_times(dst, st:times()))
  local dst_st = check.must(fs.stat(dst))
  assert(dst_st:modify_time().secs == 1000000,
    "set_times(dst, stat(src):times()) round-trips mtime")
  assert(dst_st:access_time().secs == st:access_time().secs,
    "and atime")

  teardown(test_dir)
end
test_stat_times_round_trip()

local function test_statfs_spelled_methods()
  local test_dir = setup()
  local sf = check.must(fs.statfs(test_dir))
  assert(sf:block_size_bytes() > 0, "block_size_bytes is positive")
  assert(sf:total_blocks() >= sf:free_blocks(), "total >= free blocks")
  assert(sf:free_blocks() >= sf:available_blocks(),
    "free >= available (root reserve)")
  assert(sf:max_name_bytes() > 0, "max_name_bytes is positive")
  teardown(test_dir)
end
test_statfs_spelled_methods()

local function test_temp_dir_default_template()
  local d = check.must(fs.temp_dir())
  assert(fs.is_dir(d), "temp_dir() with no template creates a directory")
  assert(fs.remove_all(d))
end
test_temp_dir_default_template()
