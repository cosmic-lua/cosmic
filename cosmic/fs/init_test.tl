#!/usr/bin/env cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
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

  local s = check.must(fs.stat(filepath))
  assert(s:size() == 5, "expected size 5, got " .. s:size())
  assert(s:is_file(), "expected regular file")
  assert(not s:is_dir(), "expected not a directory")

  teardown(test_dir)
end
test_stat_file()

local function test_stat_directory()
  local test_dir = setup()

  local s = check.must(fs.stat(test_dir))
  assert(s:is_dir(), "expected directory")
  assert(not s:is_file(), "expected not a file")

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
  local s = check.must(fs.stat(linkpath), "stat should succeed")
  assert(s:is_file(), "expected regular file when following symlink")
  assert(s:size() == 5, "stat should describe the target, got size " .. s:size())

  -- lstat never follows symlinks
  local s2 = check.must(fs.lstat(linkpath), "lstat should succeed")
  assert(s2:is_link(), "expected symlink")

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

  local s = check.must(fs.fstat(fd))
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

  local st = check.must(fs.stat(newdir), "stat should succeed after mkdir")
  assert(st:is_dir(), "expected directory")

  teardown(test_dir)
end
test_mkdir()

local function test_mkdir_with_mode()
  local test_dir = setup()
  local newdir = fs.join(test_dir, "newdir")

  local ok, err = fs.mkdir(newdir, tonumber("700", 8))
  assert(ok, "mkdir should succeed: " .. (err or ""))

  local st = check.must(fs.stat(newdir), "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("700", 8), "expected mode 700, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_mkdir_with_mode()

local function test_makedirs()
  local test_dir = setup()
  local nested = fs.join(test_dir, "a", "b", "c")

  local ok, err = fs.makedirs(nested)
  assert(ok, "makedirs should succeed: " .. (err or ""))

  local st = check.must(fs.stat(nested), "stat should succeed after makedirs")
  assert(st:is_dir(), "expected directory")

  teardown(test_dir)
end
test_makedirs()

local function test_mkdir_error_message()
  local test_dir = setup()

  -- mkdir with missing parent should fail with descriptive error
  local missing_parent = fs.join(test_dir, "no", "such", "parent")
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

  local through_file = fs.join(blocker, "subdir")
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

  local d = check.must(fs.opendir(test_dir))

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

  local s1 = check.must(fs.stat(filepath), "both files should exist")
  assert(fs.stat(linkpath), "both files should exist")
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

  local st = check.must(fs.stat(filepath), "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8), "expected mode 600, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_chmod()

-- Temporary file operations

-- Template bases come from the test's own scratch, not a literal
-- /tmp: the fence does not grant the system scratch, on purpose.
local tmp_base = os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"

local function test_mkdtemp()
  local tmpdir = check.must(fs.mkdtemp(fs.join(tmp_base, "fs_test_XXXXXX")))
  assert(string.match(tmpdir, "fs_test_"), "expected fs_test_ in path")

  local st = check.must(fs.stat(tmpdir), "temp dir should exist")
  assert(st:is_dir(), "expected directory")

  fs.rmrf(tmpdir)
end
test_mkdtemp()

local function test_tmpfile()
  local tf = check.must(fs.tmpfile(fs.join(tmp_base, "fs_test_XXXXXX")))
  local hh = tf.handle

  assert(tf.path:match("fs_test_"), "expected fs_test_ in path")
  local st = fs.fstat(hh:fd())
  assert(st, "fstat should succeed")

  hh:close()
  fs.unlink(tf.path)
end
test_tmpfile()

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

  local file_s = check.must(fs.stat(filepath), "stat should succeed")
  assert(file_s:is_file(), "expected is_file true for regular file")
  assert(not file_s:is_dir(), "expected is_dir false for regular file")
  assert(not file_s:is_link(), "expected is_link false for regular file")

  local dir_s = check.must(fs.stat(test_dir), "stat should succeed")
  assert(dir_s:is_dir(), "expected is_dir true for directory")
  assert(not dir_s:is_file(), "expected is_file false for directory")

  local link_s = check.must(fs.lstat(linkpath), "lstat should succeed")
  assert(link_s:is_link(), "expected is_link true for symlink")

  teardown(test_dir)
end
test_is_type_functions()
