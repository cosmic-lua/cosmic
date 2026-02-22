#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local path = require("cosmo.path")

local record Statfs
  type: function(self: Statfs): number
  bsize: function(self: Statfs): number
  blocks: function(self: Statfs): number
  bfree: function(self: Statfs): number
  bavail: function(self: Statfs): number
  files: function(self: Statfs): number
  ffree: function(self: Statfs): number
  fsid: function(self: Statfs): number, number
  namelen: function(self: Statfs): number
  frsize: function(self: Statfs): number
  flags: function(self: Statfs): number
end

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = path.join(TEST_TMPDIR, "fs_dir_test")
  unix.makedirs(test_dir)
  return test_dir
end

local function teardown(test_dir: string)
  if test_dir then
    unix.rmrf(test_dir)
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

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")

  -- Verify __close metamethod exists
  local mt = getmetatable(dir)
  assert(mt, "dir should have a metatable")
  assert(mt.__close, "dir metatable should have __close")

  -- Call __close directly to verify it works
  mt.__close(dir)
  assert(dir:closed(), "dir should be closed after __close")

  teardown(test_dir)
end
test_dir_has_close_metamethod()

local function test_dir_closed_method()
  local test_dir = setup()

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")

  assert(not dir:closed(), "dir should not be closed initially")
  dir:close()
  assert(dir:closed(), "dir should be closed after close()")

  teardown(test_dir)
end
test_dir_closed_method()

local function test_dir_close_idempotent()
  local test_dir = setup()

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")

  dir:close()
  assert(dir:closed(), "dir should be closed")

  -- Should not error when closing again
  dir:close()
  dir:close()
  assert(dir:closed(), "dir should still be closed")

  teardown(test_dir)
end
test_dir_close_idempotent()

local function test_dir_methods_after_close()
  local test_dir = setup()
  touch(path.join(test_dir, "file.txt"))

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")
  dir:close()

  -- read() returns nil when closed
  local entry = dir:read()
  assert(entry == nil, "read should return nil after close")

  -- fd() returns -1 when closed
  local fd = dir:fd()
  assert(fd == -1, "fd should return -1 after close")

  -- tell() returns -1 when closed
  local pos = dir:tell()
  assert(pos == -1, "tell should return -1 after close")

  -- rewind() should be a no-op when closed (no error)
  dir:rewind()

  teardown(test_dir)
end
test_dir_methods_after_close()

local function test_dir_rewind_and_tell()
  local test_dir = setup()
  touch(path.join(test_dir, "file1.txt"))
  touch(path.join(test_dir, "file2.txt"))

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")

  -- Read some entries
  local count = 0
  while dir:read() do
    count = count + 1
  end
  assert(count >= 2, "should read at least 2 entries")

  -- Tell should return a position
  local pos_end = dir:tell()
  assert(pos_end >= 0, "tell should return valid position")

  -- Rewind and count again
  dir:rewind()
  local count2 = 0
  while dir:read() do
    count2 = count2 + 1
  end
  assert(count2 == count, "should read same number of entries after rewind")

  dir:close()
  teardown(test_dir)
end
test_dir_rewind_and_tell()

local function test_dir_fd()
  local test_dir = setup()

  local dir = fs.opendir(test_dir)
  assert(dir, "opendir should succeed")

  local fd = dir:fd()
  assert(fd >= 0, "fd should be a valid file descriptor")

  dir:close()
  teardown(test_dir)
end
test_dir_fd()

-- Filesystem statistics tests

local function test_statfs()
  local raw_info, err = fs.statfs("/")
  assert(raw_info, "statfs should succeed: " .. (err or ""))
  local info = raw_info as Statfs

  -- Check that we can call all the methods
  assert(info:type() ~= nil, "type() should return a value")
  assert(info:bsize() > 0, "bsize() should be positive")
  assert(info:blocks() > 0, "blocks() should be positive")
  assert(info:bfree() >= 0, "bfree() should be non-negative")
  assert(info:bavail() >= 0, "bavail() should be non-negative")
  assert(info:files() >= 0, "files() should be non-negative")
  assert(info:ffree() >= 0, "ffree() should be non-negative")
  local fsid1, fsid2 = info:fsid()
  assert(fsid1 ~= nil, "fsid() should return first value")
  assert(fsid2 ~= nil, "fsid() should return second value")
  assert(info:namelen() > 0, "namelen() should be positive")
  assert(info:frsize() > 0, "frsize() should be positive")
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
  local fd = unix.open("/", unix.O_RDONLY | unix.O_DIRECTORY)
  assert(fd, "open should succeed")

  local raw_info, err = fs.fstatfs(fd)
  assert(raw_info, "fstatfs should succeed: " .. (err or ""))
  local info = raw_info as Statfs

  assert(info:bsize() > 0, "bsize() should be positive")
  assert(info:blocks() > 0, "blocks() should be positive")

  unix.close(fd)
end
test_fstatfs()

-- Device number utilities tests

local function test_major_minor()
  -- Test with /dev/null which should have rdev set
  local st = fs.stat("/dev/null")
  if st then
    local rdev = st:rdev()
    local maj = fs.major(rdev)
    local min = fs.minor(rdev)
    -- /dev/null is typically major 1, minor 3
    assert(maj ~= nil, "major() should return a value")
    assert(min ~= nil, "minor() should return a value")
    assert(maj >= 0, "major should be non-negative")
    assert(min >= 0, "minor should be non-negative")
  end
end
test_major_minor()

local function test_major_minor_regular_file()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath)

  local st = fs.stat(filepath)
  assert(st, "stat should succeed")

  -- Regular files have a dev (the filesystem device)
  local dev = st:dev()
  local maj = fs.major(dev)
  local min = fs.minor(dev)
  assert(maj ~= nil, "major() should return a value for dev")
  assert(min ~= nil, "minor() should return a value for dev")

  teardown(test_dir)
end
test_major_minor_regular_file()
