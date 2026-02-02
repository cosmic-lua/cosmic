#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local path = require("cosmo.path")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = path.join(TEST_TMPDIR, "fs_test")
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

-- Stat operations

local function test_stat_file()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath, "hello")

  local st, err = fs.stat(filepath)
  assert(st, "stat should succeed: " .. (err or ""))
  assert(st:size() == 5, "expected size 5, got " .. st:size())
  assert(fs.is_file(st:mode()), "expected regular file")
  assert(not fs.is_dir(st:mode()), "expected not a directory")

  teardown(test_dir)
end
test_stat_file()

local function test_stat_directory()
  local test_dir = setup()

  local st, err = fs.stat(test_dir)
  assert(st, "stat should succeed: " .. (err or ""))
  assert(fs.is_dir(st:mode()), "expected directory")
  assert(not fs.is_file(st:mode()), "expected not a file")

  teardown(test_dir)
end
test_stat_directory()

local function test_stat_symlink()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
  local linkpath = path.join(test_dir, "link")
  touch(filepath, "hello")
  unix.symlink(filepath, linkpath)

  -- Follow symlinks by default
  local st = fs.stat(linkpath)
  assert(st, "stat should succeed")
  assert(fs.is_file(st:mode()), "expected regular file when following symlink")

  -- Don't follow symlinks
  local st2 = fs.stat(linkpath, false)
  assert(st2, "stat should succeed with follow_symlinks=false")
  assert(fs.is_link(st2:mode()), "expected symlink")

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
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath, "hello world")

  local fd = unix.open(filepath, unix.O_RDONLY)
  assert(fd, "open should succeed")

  local st, err = fs.fstat(fd)
  assert(st, "fstat should succeed: " .. (err or ""))
  assert(st:size() == 11, "expected size 11, got " .. st:size())

  unix.close(fd)
  teardown(test_dir)
end
test_fstat()

-- Directory operations

local function test_mkdir()
  local test_dir = setup()
  local newdir = path.join(test_dir, "newdir")

  local ok, err = fs.mkdir(newdir)
  assert(ok, "mkdir should succeed: " .. (err or ""))

  local st = fs.stat(newdir)
  assert(st, "stat should succeed after mkdir")
  assert(fs.is_dir(st:mode()), "expected directory")

  teardown(test_dir)
end
test_mkdir()

local function test_mkdir_with_mode()
  local test_dir = setup()
  local newdir = path.join(test_dir, "newdir")

  local ok, err = fs.mkdir(newdir, tonumber("700", 8))
  assert(ok, "mkdir should succeed: " .. (err or ""))

  local st = fs.stat(newdir)
  assert(st, "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("700", 8), "expected mode 700, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_mkdir_with_mode()

local function test_makedirs()
  local test_dir = setup()
  local nested = path.join(test_dir, "a", "b", "c")

  local ok, err = fs.makedirs(nested)
  assert(ok, "makedirs should succeed: " .. (err or ""))

  local st = fs.stat(nested)
  assert(st, "stat should succeed after makedirs")
  assert(fs.is_dir(st:mode()), "expected directory")

  teardown(test_dir)
end
test_makedirs()

local function test_rmdir()
  local test_dir = setup()
  local newdir = path.join(test_dir, "newdir")
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
  touch(path.join(test_dir, "file1.txt"))
  touch(path.join(test_dir, "file2.txt"))
  fs.mkdir(path.join(test_dir, "subdir"))

  local dir, err = fs.opendir(test_dir)
  assert(dir, "opendir should succeed: " .. (err or ""))

  local entries: {string:boolean} = {}
  while true do
    local entry = dir:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      entries[entry] = true
    end
  end
  dir:close()

  assert(entries["file1.txt"], "expected file1.txt")
  assert(entries["file2.txt"], "expected file2.txt")
  assert(entries["subdir"], "expected subdir")

  teardown(test_dir)
end
test_opendir()

-- File operations

local function test_unlink()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
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
  local oldpath = path.join(test_dir, "old.txt")
  local newpath = path.join(test_dir, "new.txt")
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
  local filepath = path.join(test_dir, "original.txt")
  local linkpath = path.join(test_dir, "hardlink.txt")
  touch(filepath, "content")

  local ok, err = fs.link(filepath, linkpath)
  assert(ok, "link should succeed: " .. (err or ""))

  local st1 = fs.stat(filepath)
  local st2 = fs.stat(linkpath)
  assert(st1 and st2, "both files should exist")
  assert(st1:nlink() == 2, "expected 2 hard links, got " .. st1:nlink())

  teardown(test_dir)
end
test_link()

local function test_symlink_and_readlink()
  local test_dir = setup()
  local filepath = path.join(test_dir, "target.txt")
  local linkpath = path.join(test_dir, "symlink")
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
  local subdir = path.join(test_dir, "subdir")
  fs.mkdir(subdir)

  -- Create a path with .. that should be resolved
  local messy_path = path.join(subdir, "..", "subdir")
  local resolved, err = fs.realpath(messy_path)
  assert(resolved, "realpath should succeed: " .. (err or ""))

  local expected = fs.realpath(subdir)
  assert(resolved == expected, "expected " .. (expected or "nil") .. ", got " .. resolved)

  teardown(test_dir)
end
test_realpath()

local function test_rmrf()
  local test_dir = setup()
  local nested = path.join(test_dir, "a", "b", "c")
  fs.makedirs(nested)
  touch(path.join(nested, "file.txt"))
  touch(path.join(test_dir, "a", "file.txt"))

  local ok, err = fs.rmrf(path.join(test_dir, "a"))
  assert(ok, "rmrf should succeed: " .. (err or ""))

  assert(fs.stat(path.join(test_dir, "a")) == nil, "directory tree should not exist")

  teardown(test_dir)
end
test_rmrf()

-- Permission operations

local function test_access()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath)

  assert(fs.access(filepath, fs.F_OK), "file should exist")
  assert(fs.access(filepath, fs.R_OK), "file should be readable")
  assert(fs.access(filepath, fs.W_OK), "file should be writable")
  assert(not fs.access("/nonexistent", fs.F_OK), "nonexistent file should not exist")

  teardown(test_dir)
end
test_access()

local function test_chmod()
  local test_dir = setup()
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath)

  local ok, err = fs.chmod(filepath, tonumber("600", 8))
  assert(ok, "chmod should succeed: " .. (err or ""))

  local st = fs.stat(filepath)
  assert(st, "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8), "expected mode 600, got " .. string.format("%o", mode))

  teardown(test_dir)
end
test_chmod()

-- Temporary file operations

local function test_mkdtemp()
  local tmpdir, err = fs.mkdtemp("/tmp/fs_test_XXXXXX")
  assert(tmpdir, "mkdtemp should succeed: " .. (err or ""))
  assert(tmpdir:match("^/tmp/fs_test_"), "expected /tmp/fs_test_ prefix")

  local st = fs.stat(tmpdir)
  assert(st, "temp dir should exist")
  assert(fs.is_dir(st:mode()), "expected directory")

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
  local filepath = path.join(test_dir, "file.txt")
  touch(filepath)
  local linkpath = path.join(test_dir, "link")
  unix.symlink(filepath, linkpath)

  local file_st = fs.stat(filepath)
  assert(file_st, "stat should succeed")
  assert(fs.is_file(file_st:mode()), "expected is_file true for regular file")
  assert(not fs.is_dir(file_st:mode()), "expected is_dir false for regular file")
  assert(not fs.is_link(file_st:mode()), "expected is_link false for regular file")

  local dir_st = fs.stat(test_dir)
  assert(dir_st, "stat should succeed")
  assert(fs.is_dir(dir_st:mode()), "expected is_dir true for directory")
  assert(not fs.is_file(dir_st:mode()), "expected is_file false for directory")

  local link_st = fs.stat(linkpath, false)
  assert(link_st, "stat should succeed")
  assert(fs.is_link(link_st:mode()), "expected is_link true for symlink")

  teardown(test_dir)
end
test_is_type_functions()

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
  local info, err = fs.statfs("/")
  assert(info, "statfs should succeed: " .. (err or ""))

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

  local info, err = fs.fstatfs(fd)
  assert(info, "fstatfs should succeed: " .. (err or ""))

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

-- Path manipulation tests (consolidated from cosmic.path)

local function test_dirname_with_file()
  local result = fs.dirname("/usr/lib")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_dirname_with_file()

local function test_dirname_trailing_slash()
  local result = fs.dirname("/usr/lib/")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_dirname_trailing_slash()

local function test_dirname_root()
  local result = fs.dirname("/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_dirname_root()

local function test_dirname_single_component()
  local result = fs.dirname("usr")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_dirname_single_component()

local function test_basename_with_file()
  local result = fs.basename("/usr/lib")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_basename_with_file()

local function test_basename_trailing_slash()
  local result = fs.basename("/usr/lib/")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_basename_trailing_slash()

local function test_basename_root()
  local result = fs.basename("/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_basename_root()

local function test_join_basic()
  local result = fs.join("/usr", "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_basic()

local function test_join_trailing_slash()
  local result = fs.join("/usr/", "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_trailing_slash()

local function test_join_absolute_resets()
  local result = fs.join("/usr/lib", "/lib")
  assert(result == "/lib", "expected '/lib', got '" .. result .. "'")
end
test_join_absolute_resets()

local function test_join_multiple()
  local result = fs.join("/usr", "local", "bin")
  assert(result == "/usr/local/bin", "expected '/usr/local/bin', got '" .. result .. "'")
end
test_join_multiple()

local function test_exists_current_dir()
  local result = fs.exists(".")
  assert(result == true, "expected current directory to exist")
end
test_exists_current_dir()

local function test_exists_nonexistent()
  local result = fs.exists("/nonexistent/path/that/does/not/exist")
  assert(result == false, "expected false for nonexistent path")
end
test_exists_nonexistent()

local function test_isfile_directory()
  local result = fs.isfile(".")
  assert(result == false, "expected false for directory")
end
test_isfile_directory()

local function test_isdir_current()
  local result = fs.isdir(".")
  assert(result == true, "expected true for current directory")
end
test_isdir_current()

local function test_islink_regular_dir()
  local result = fs.islink(".")
  assert(result == false, "expected false for regular directory")
end
test_islink_regular_dir()

-- Directory walking tests (consolidated from cosmic.walk)

local record WalkContext
  count: number
  dirs: number
end

local function setup_walk(): string
  local test_dir = path.join(TEST_TMPDIR, "walk_test")
  unix.makedirs(path.join(test_dir, "subdir"))
  unix.makedirs(path.join(test_dir, "subdir/nested"))

  touch(path.join(test_dir, "file1.lua"))
  touch(path.join(test_dir, "file2.txt"))
  touch(path.join(test_dir, "subdir/file3.lua"))
  touch(path.join(test_dir, "subdir/nested/file4.lua"))

  return test_dir
end

local function test_collect_finds_lua_files()
  local test_dir = setup_walk()
  local files = fs.collect(test_dir, "%.lua$")

  assert(#files == 3, "expected 3 lua files, got " .. #files)

  local found: {string:boolean} = {}
  for _, f in ipairs(files) do
    local name = path.basename(f)
    found[name] = true
  end

  assert(found["file1.lua"], "expected file1.lua to be found")
  assert(found["file3.lua"], "expected file3.lua to be found")
  assert(found["file4.lua"], "expected file4.lua to be found")
  assert(found["file2.txt"] == nil, "expected file2.txt not to be found")
  teardown(test_dir)
end
test_collect_finds_lua_files()

local function test_collect_finds_nested_files()
  local test_dir = setup_walk()
  local files = fs.collect(test_dir, "%.txt$")
  assert(#files == 1, "expected 1 txt file, got " .. #files)
  assert(path.basename(files[1]) == "file2.txt", "expected file2.txt, got " .. path.basename(files[1]))
  teardown(test_dir)
end
test_collect_finds_nested_files()

local function test_walk_with_visitor()
  local test_dir = setup_walk()
  local ctx: WalkContext = { count = 0, dirs = 0 }

  fs.walk(test_dir, function(_full_path: string, _entry: string, isdir: boolean, c: any): boolean
    local wctx = c as WalkContext
    wctx.count = wctx.count + 1
    if isdir then
      wctx.dirs = wctx.dirs + 1
    end
    return true
  end, ctx)

  assert(ctx.count > 0, "expected count > 0")
  assert(ctx.dirs == 2, "expected 2 dirs, got " .. ctx.dirs)
  teardown(test_dir)
end
test_walk_with_visitor()

local function test_collect_all()
  local test_dir = setup_walk()
  local files = fs.collect_all(test_dir)

  assert(files["file1.lua"] ~= nil, "expected file1.lua in results")
  assert(files["file2.txt"] ~= nil, "expected file2.txt in results")
  assert(files["subdir/file3.lua"] ~= nil, "expected subdir/file3.lua in results")
  assert(files["subdir/nested/file4.lua"] ~= nil, "expected subdir/nested/file4.lua in results")

  assert(files["file1.lua"].mode ~= nil, "expected mode property on file1.lua")
  assert(files["subdir"] == nil, "expected subdir not to be in results")
  teardown(test_dir)
end
test_collect_all()

local function test_walk_empty_directory()
  local empty_dir = path.join(TEST_TMPDIR, "walk_empty")
  unix.makedirs(empty_dir)
  local files = fs.collect(empty_dir, "%.lua$")
  assert(#files == 0, "expected 0 files, got " .. #files)
  unix.rmrf(empty_dir)
end
test_walk_empty_directory()
