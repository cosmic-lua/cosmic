#!/usr/bin/env cosmic
--- Tests for fs path predicates and symlink-following semantics.
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function touch(filepath: string, content?: string)
  local f = io.open(filepath, "w")
  if f then
    if content then
      f:write(content)
    end
    f:close()
  end
end

-- symlink behavior tests: exists, isfile, and isdir all follow symlinks
-- (stat), matching POSIX test -f/-d; islink inspects the link itself (lstat)

local function test_exists_symlink_to_file()
  local tmpdir = fs.join(TEST_TMPDIR, "symlink_exists_test")
  fs.makedirs(tmpdir)
  local target = fs.join(tmpdir, "real.txt")
  touch(target, "hello")
  local link = fs.join(tmpdir, "link.txt")
  local ok = fs.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(fs.exists(link), "exists() should follow symlink and return true")
  fs.rmrf(tmpdir)
end
test_exists_symlink_to_file()

local function test_isfile_symlink_to_file()
  local tmpdir = fs.join(TEST_TMPDIR, "symlink_isfile_test")
  fs.makedirs(tmpdir)
  local target = fs.join(tmpdir, "real.txt")
  touch(target, "hello")
  local link = fs.join(tmpdir, "link.txt")
  local ok = fs.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(fs.isfile(link), "isfile() should follow a symlink to a regular file")
  assert(fs.isfile(target), "isfile() should return true for the target file")
  assert(fs.islink(link), "islink() should detect the symlink itself")
  assert(not fs.islink(target), "islink() should be false for the target file")
  fs.rmrf(tmpdir)
end
test_isfile_symlink_to_file()

local function test_isfile_broken_symlink()
  local tmpdir = fs.join(TEST_TMPDIR, "symlink_broken_test")
  fs.makedirs(tmpdir)
  local link = fs.join(tmpdir, "dangling")
  local ok = fs.symlink(fs.join(tmpdir, "no-such-target"), link)
  assert(ok, "symlink creation should succeed")
  assert(not fs.isfile(link), "isfile() should be false for a broken symlink")
  assert(not fs.isdir(link), "isdir() should be false for a broken symlink")
  assert(not fs.exists(link), "exists() should be false for a broken symlink")
  assert(fs.islink(link), "islink() should be true for a broken symlink")
  fs.rmrf(tmpdir)
end
test_isfile_broken_symlink()

local function test_isdir_symlink_to_dir()
  local tmpdir = fs.join(TEST_TMPDIR, "symlink_isdir_test")
  fs.makedirs(tmpdir)
  local target = fs.join(tmpdir, "realdir")
  fs.makedirs(target)
  local link = fs.join(tmpdir, "linkdir")
  local ok = fs.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(fs.isdir(link), "isdir() should follow a symlink to a directory")
  assert(fs.isdir(target), "isdir() should return true for the target dir")
  assert(not fs.isfile(link), "isfile() should be false for a symlink to a dir")
  assert(fs.islink(link), "islink() should detect the symlink itself")
  fs.rmrf(tmpdir)
end
test_isdir_symlink_to_dir()
