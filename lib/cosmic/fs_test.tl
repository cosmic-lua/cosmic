#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs_types")
local unix = require("cosmo.unix")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = fs.join(TEST_TMPDIR, "fs_test")
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

-- Stat operations

local function test_stat_file()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath, "hello")

  local st, err = fs.stat(filepath)
  assert(st, "stat should succeed: " .. (err or ""))
  local s = st as fs_types.Stat
  assert(s:size() == 5, "expected size 5, got " .. s:size())
  assert(fs.is_file(s:mode()), "expected regular file")
  assert(not fs.is_dir(s:mode()), "expected not a directory")

  teardown(test_dir)
end
test_stat_file()

local function test_stat_directory()
  local test_dir = setup()

  local st, err = fs.stat(test_dir)
  assert(st, "stat should succeed: " .. (err or ""))
  local s = st as fs_types.Stat
  assert(fs.is_dir(s:mode()), "expected directory")
  assert(not fs.is_file(s:mode()), "expected not a file")

  teardown(test_dir)
end
test_stat_directory()

local function test_stat_symlink()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  local linkpath = fs.join(test_dir, "link")
  touch(filepath, "hello")
  fs.symlink(filepath, linkpath)

  -- stat always follows symlinks
  local st = fs.stat(linkpath)
  assert(st, "stat should succeed")
  local s = st as fs_types.Stat
  assert(fs.is_file(s:mode()), "expected regular file when following symlink")
  assert(s:size() == 5, "stat should describe the target, got size " .. s:size())

  -- lstat never follows symlinks
  local st2 = fs.lstat(linkpath)
  assert(st2, "lstat should succeed")
  local s2 = st2 as fs_types.Stat
  assert(fs.is_link(s2:mode()), "expected symlink")

  teardown(test_dir)
end
test_stat_symlink()

local function test_stat_nonexistent()
  local st, err = fs.stat("/nonexistent/path/that/does/not/exist")
  assert(st == nil, "stat should fail for nonexistent path")
  assert(err, "should return error message")
end
test_stat_nonexistent()

local function test_fstat()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath, "hello world")

  local fd = unix.open(filepath, unix.O_RDONLY)
  assert(fd, "open should succeed")

  local st, err = fs.fstat(fd)
  assert(st, "fstat should succeed: " .. (err or ""))
  local s = st as fs_types.Stat
  assert(s:size() == 11, "expected size 11, got " .. s:size())

  unix.close(fd)
  teardown(test_dir)
end
test_fstat()

-- Directory operations

local function test_mkdir()
  local test_dir = setup()
  local newdir = fs.join(test_dir, "newdir")

  local ok, err = fs.mkdir(newdir)
  assert(ok, "mkdir should succeed: " .. (err or ""))

  local st = fs.stat(newdir)
  assert(st, "stat should succeed after mkdir")
  assert(fs.is_dir((st as fs_types.Stat):mode()), "expected directory")

  teardown(test_dir)
end
test_mkdir()

local function test_mkdir_with_mode()
  local test_dir = setup()
  local newdir = fs.join(test_dir, "newdir")

  local ok, err = fs.mkdir(newdir, tonumber("700", 8))
  assert(ok, "mkdir should succeed: " .. (err or ""))

  local st = fs.stat(newdir)
  assert(st, "stat should succeed")
  local mode = (st as fs_types.Stat):mode() & tonumber("777", 8)
  assert(mode == tonumber("700", 8), "expected mode 700, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_mkdir_with_mode()

local function test_makedirs()
  local test_dir = setup()
  local nested = fs.join(test_dir, "a", "b", "c")

  local ok, err = fs.makedirs(nested)
  assert(ok, "makedirs should succeed: " .. (err or ""))

  local st = fs.stat(nested)
  assert(st, "stat should succeed after makedirs")
  assert(fs.is_dir((st as fs_types.Stat):mode()), "expected directory")

  teardown(test_dir)
end
test_makedirs()

local function test_mkdir_error_message()
  local test_dir = setup()

  -- mkdir with missing parent should fail with descriptive error
  local missing_parent = fs.join(test_dir, "no", "such", "parent") as string
  local ok, err = fs.mkdir(missing_parent)
  assert(not ok, "mkdir should fail when parent doesn't exist")
  assert(err, "should return error message")
  assert(err:find(missing_parent, 1, true), "error should contain path, got: " .. err)
  -- Error should contain errno details, not just a generic message
  assert(not err:match("^mkdir: " .. missing_parent:gsub("[%-]", "%%-") .. "$"),
    "error should include errno details, got: " .. err)
end
test_mkdir_error_message()

local function test_mkdir_eexist_error()
  local test_dir = setup()

  -- mkdir on existing directory should fail with descriptive error
  local ok, err = fs.mkdir(test_dir)
  assert(not ok, "mkdir should fail when directory already exists")
  assert(err, "should return error message")
  assert(err:find(test_dir, 1, true), "error should contain path, got: " .. err)
  assert(not err:match("^mkdir: " .. test_dir:gsub("[%-]", "%%-") .. "$"),
    "error should include errno details, got: " .. err)

  teardown(test_dir)
end
test_mkdir_eexist_error()

local function test_makedirs_error_message()
  local test_dir = setup()

  -- Create a regular file, then try to makedirs through it
  local blocker = fs.join(test_dir, "blocker")
  local f = io.open(blocker, "w")
  if f then f:close() end

  local through_file = fs.join(blocker, "subdir") as string
  local ok, err = fs.makedirs(through_file)
  assert(not ok, "makedirs should fail when path component is a file")
  assert(err, "should return error message")
  assert(err:find(through_file, 1, true), "error should contain path, got: " .. err)
  -- Error should contain errno details, not just a generic message
  assert(not err:match("^makedirs: " .. through_file:gsub("[%-]", "%%-") .. "$"),
    "error should include errno details, got: " .. err)

  teardown(test_dir)
end
test_makedirs_error_message()

local function test_rmdir()
  local test_dir = setup()
  local newdir = fs.join(test_dir, "newdir")
  fs.mkdir(newdir)

  local ok, err = fs.rmdir(newdir)
  assert(ok, "rmdir should succeed: " .. (err or ""))

  local st = fs.stat(newdir)
  assert(st == nil, "directory should not exist after rmdir")

  teardown(test_dir)
end
test_rmdir()

local function test_getcwd_and_chdir()
  local original_cwd = fs.getcwd()
  assert(original_cwd, "getcwd should succeed")

  local test_dir = setup()

  local ok, err = fs.chdir(test_dir)
  assert(ok, "chdir should succeed: " .. (err or ""))

  local new_cwd = fs.getcwd()
  assert(new_cwd, "getcwd should succeed after chdir")
  -- Use realpath to normalize both paths (handles symlinks in /tmp on some systems)
  local resolved_test = fs.realpath(test_dir)
  local resolved_cwd = fs.realpath(new_cwd)
  assert(resolved_cwd == resolved_test, "expected cwd to match test_dir")

  -- Restore original cwd
  fs.chdir(original_cwd)
  teardown(test_dir)
end
test_getcwd_and_chdir()

local function test_opendir()
  local test_dir = setup()
  touch(fs.join(test_dir, "file1.txt"))
  touch(fs.join(test_dir, "file2.txt"))
  fs.mkdir(fs.join(test_dir, "subdir"))

  local dir, err = fs.opendir(test_dir)
  assert(dir, "opendir should succeed: " .. (err or ""))
  local d = dir as fs_types.Dir

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
  assert(entries["subdir"], "expected subdir")

  teardown(test_dir)
end
test_opendir()

-- File operations

local function test_unlink()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath)

  local ok, err = fs.unlink(filepath)
  assert(ok, "unlink should succeed: " .. (err or ""))

  local st = fs.stat(filepath)
  assert(st == nil, "file should not exist after unlink")

  teardown(test_dir)
end
test_unlink()

local function test_rename()
  local test_dir = setup()
  local oldpath = fs.join(test_dir, "old.txt")
  local newpath = fs.join(test_dir, "new.txt")
  touch(oldpath, "content")

  local ok, err = fs.rename(oldpath, newpath)
  assert(ok, "rename should succeed: " .. (err or ""))

  assert(fs.stat(oldpath) == nil, "old path should not exist")
  assert(fs.stat(newpath), "new path should exist")

  teardown(test_dir)
end
test_rename()

local function test_link()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "original.txt")
  local linkpath = fs.join(test_dir, "hardlink.txt")
  touch(filepath, "content")

  local ok, err = fs.link(filepath, linkpath)
  assert(ok, "link should succeed: " .. (err or ""))

  local st1 = fs.stat(filepath)
  local st2 = fs.stat(linkpath)
  assert(st1 and st2, "both files should exist")
  local s1 = st1 as fs_types.Stat
  assert(s1:nlink() == 2, "expected 2 hard links, got " .. s1:nlink())

  teardown(test_dir)
end
test_link()

local function test_symlink_and_readlink()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "target.txt")
  local linkpath = fs.join(test_dir, "symlink")
  touch(filepath, "content")

  local ok, err = fs.symlink(filepath, linkpath)
  assert(ok, "symlink should succeed: " .. (err or ""))

  local target, read_err = fs.readlink(linkpath)
  assert(target, "readlink should succeed: " .. (read_err or ""))
  assert(target == filepath, "expected target " .. filepath .. ", got " .. target)

  teardown(test_dir)
end
test_symlink_and_readlink()

local function test_realpath()
  local test_dir = setup()
  local subdir = fs.join(test_dir, "subdir")
  fs.mkdir(subdir)

  -- Create a path with .. that should be resolved
  local messy_path = fs.join(subdir, "..", "subdir")
  local resolved, err = fs.realpath(messy_path)
  assert(resolved, "realpath should succeed: " .. (err or ""))

  local expected = fs.realpath(subdir)
  assert(resolved == expected, "expected " .. (expected or "nil") .. ", got " .. resolved)

  teardown(test_dir)
end
test_realpath()

local function test_rmrf()
  local test_dir = setup()
  local nested = fs.join(test_dir, "a", "b", "c")
  fs.makedirs(nested)
  touch(fs.join(nested, "file.txt"))
  touch(fs.join(test_dir, "a", "file.txt"))

  local ok, err = fs.rmrf(fs.join(test_dir, "a"))
  assert(ok, "rmrf should succeed: " .. (err or ""))

  assert(fs.stat(fs.join(test_dir, "a")) == nil, "directory tree should not exist")

  teardown(test_dir)
end
test_rmrf()

-- Permission operations

local function test_access()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath)

  assert(fs.access(filepath, fs.F_OK), "file should exist")
  assert(fs.access(filepath, fs.R_OK), "file should be readable")
  assert(fs.access(filepath, fs.W_OK), "file should be writable")
  assert(not fs.access(fs.join(test_dir, "does_not_exist"), fs.F_OK), "nonexistent file should not exist")

  teardown(test_dir)
end
test_access()

local function test_chmod()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath)

  local ok, err = fs.chmod(filepath, tonumber("600", 8))
  assert(ok, "chmod should succeed: " .. (err or ""))

  local st = fs.stat(filepath)
  assert(st, "stat should succeed")
  local mode = (st as fs_types.Stat):mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8), "expected mode 600, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_chmod()

-- Temporary file operations

local function test_mkdtemp()
  local tmpdir, err = fs.mkdtemp("/tmp/fs_test_XXXXXX")
  assert(tmpdir, "mkdtemp should succeed: " .. (err or ""))
  assert(string.match(tmpdir as string, "^/tmp/fs_test_"), "expected /tmp/fs_test_ prefix")

  local st = fs.stat(tmpdir)
  assert(st, "temp dir should exist")
  assert(fs.is_dir((st as fs_types.Stat):mode()), "expected directory")

  fs.rmrf(tmpdir)
end
test_mkdtemp()

local function test_mkstemp()
  local fd, result = fs.mkstemp("/tmp/fs_test_XXXXXX")
  assert(fd, "mkstemp should succeed: " .. (result or ""))

  local filepath = result
  assert(filepath:match("^/tmp/fs_test_"), "expected /tmp/fs_test_ prefix")

  local st = fs.fstat(fd)
  assert(st, "fstat should succeed")

  unix.close(fd)
  fs.unlink(filepath)
end
test_mkstemp()

local function test_tmpfd()
  local fd, err = fs.tmpfd()
  assert(fd, "tmpfd should succeed: " .. (err or ""))

  local st = fs.fstat(fd)
  assert(st, "fstat should succeed on tmpfd")

  unix.close(fd)
end
test_tmpfd()

-- Type checking functions

local function test_is_type_functions()
  local test_dir = setup()
  local filepath = fs.join(test_dir, "file.txt")
  touch(filepath)
  local linkpath = fs.join(test_dir, "link")
  fs.symlink(filepath, linkpath)

  local file_st = fs.stat(filepath)
  assert(file_st, "stat should succeed")
  local file_s = file_st as fs_types.Stat
  assert(fs.is_file(file_s:mode()), "expected is_file true for regular file")
  assert(not fs.is_dir(file_s:mode()), "expected is_dir false for regular file")
  assert(not fs.is_link(file_s:mode()), "expected is_link false for regular file")

  local dir_st = fs.stat(test_dir)
  assert(dir_st, "stat should succeed")
  local dir_s = dir_st as fs_types.Stat
  assert(fs.is_dir(dir_s:mode()), "expected is_dir true for directory")
  assert(not fs.is_file(dir_s:mode()), "expected is_file false for directory")

  local link_st = fs.lstat(linkpath)
  assert(link_st, "lstat should succeed")
  local link_s = link_st as fs_types.Stat
  assert(fs.is_link(link_s:mode()), "expected is_link true for symlink")

  teardown(test_dir)
end
test_is_type_functions()
