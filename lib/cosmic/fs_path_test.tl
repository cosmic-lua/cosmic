#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local path = require("cosmo.path")

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

local function teardown(test_dir: string)
  if test_dir then
    unix.rmrf(test_dir)
  end
end

-- Path manipulation tests

local function test_dirname_with_file()
  local result = fs.dirname("/usr/lib")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_dirname_with_file()

local function test_dirname_root()
  local result = fs.dirname("/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_dirname_root()

local function test_basename_with_file()
  local result = fs.basename("/usr/lib")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_basename_with_file()

local function test_join_basic()
  local result = fs.join("/usr", "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_basic()

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

-- Directory walking tests

local record WalkStat
  mode: function(self): number
end

local record WalkContext
  count: number
  dirs: number
end

local function setup_walk(): string
  local walk_dir = path.join(TEST_TMPDIR, "walk_test")
  unix.makedirs(path.join(walk_dir, "subdir"))
  unix.makedirs(path.join(walk_dir, "subdir/nested"))

  touch(path.join(walk_dir, "file1.lua"))
  touch(path.join(walk_dir, "file2.txt"))
  touch(path.join(walk_dir, "subdir/file3.lua"))
  touch(path.join(walk_dir, "subdir/nested/file4.lua"))

  return walk_dir
end

local function test_collect_with_glob()
  local walk_dir = setup_walk()
  local found = fs.collect(walk_dir, "*.lua")

  assert(#found == 3, "expected 3 lua files, got " .. #found)

  local names: {string: boolean} = {}
  for _, f in ipairs(found) do
    names[fs.basename(f)] = true
  end

  assert(names["file1.lua"], "expected file1.lua")
  assert(names["file3.lua"], "expected file3.lua")
  assert(names["file4.lua"], "expected file4.lua")
  teardown(walk_dir)
end
test_collect_with_glob()

local function test_collect_glob_escapes_brackets()
  -- A glob's [ ] must be literal, not a Lua class: "*[1].lua" matches nothing.
  local walk_dir = setup_walk()
  local found = fs.collect(walk_dir, "*[1].lua")
  assert(#found == 0, "expected brackets treated literally, got " .. #found)
  teardown(walk_dir)
end
test_collect_glob_escapes_brackets()

local function test_collect_with_lua_pattern()
  local walk_dir = setup_walk()
  local found = fs.collect(walk_dir, "%.txt$")

  assert(#found == 1, "expected 1 txt file, got " .. #found)
  assert(fs.basename(found[1]) == "file2.txt", "expected file2.txt")
  teardown(walk_dir)
end
test_collect_with_lua_pattern()

local function test_walk_with_visitor()
  local walk_dir = setup_walk()
  local ctx: WalkContext = {count = 0, dirs = 0}

  fs.walk(walk_dir, function(_full_path: string, _entry: string, st: any, c: any): boolean
      local wctx = c as WalkContext
      wctx.count = wctx.count + 1
      local stat_obj = st as WalkStat
      if unix.S_ISDIR(stat_obj:mode()) then
        wctx.dirs = wctx.dirs + 1
      end
      return true
    end, ctx)

  assert(ctx.count > 0, "expected count > 0")
  assert(ctx.dirs == 2, "expected 2 dirs, got " .. ctx.dirs)
  teardown(walk_dir)
end
test_walk_with_visitor()

local function test_collect_all()
  local walk_dir = setup_walk()
  local found = fs.collect_all(walk_dir)

  assert(found["file1.lua"] ~= nil, "expected file1.lua")
  assert(found["file2.txt"] ~= nil, "expected file2.txt")
  assert(found["subdir/file3.lua"] ~= nil, "expected subdir/file3.lua")
  assert(found["subdir/nested/file4.lua"] ~= nil, "expected subdir/nested/file4.lua")
  assert(found["file1.lua"].mode ~= nil, "expected mode property")
  teardown(walk_dir)
end
test_collect_all()

local function test_files_iterator()
  local walk_dir = setup_walk()
  local found: {string: boolean} = {}

  for filepath in fs.files(walk_dir, "*.lua") do
    found[fs.basename(filepath)] = true
  end

  assert(found["file1.lua"], "expected file1.lua")
  assert(found["file3.lua"], "expected file3.lua")
  assert(found["file4.lua"], "expected file4.lua")
  assert(not found["file2.txt"], "should not find file2.txt")
  teardown(walk_dir)
end
test_files_iterator()

local function test_files_iterator_all()
  local walk_dir = setup_walk()
  local count = 0

  for _ in fs.files(walk_dir) do
    count = count + 1
  end

  assert(count == 4, "expected 4 files, got " .. count)
  teardown(walk_dir)
end
test_files_iterator_all()

local function test_walk_empty_directory()
  local empty_dir = path.join(TEST_TMPDIR, "walk_empty")
  unix.makedirs(empty_dir)
  local found = fs.collect(empty_dir, "*.lua")
  assert(#found == 0, "expected 0 files, got " .. #found)
  unix.rmrf(empty_dir)
end
test_walk_empty_directory()

-- normalize tests

local function test_normalize_dot_component()
  local result = fs.normalize("/usr/./lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_normalize_dot_component()

local function test_normalize_dotdot_component()
  local result = fs.normalize("/usr/lib/../bin")
  assert(result == "/usr/bin", "expected '/usr/bin', got '" .. result .. "'")
end
test_normalize_dotdot_component()

local function test_normalize_relative_dotdot()
  local result = fs.normalize("a/b/../c")
  assert(result == "a/c", "expected 'a/c', got '" .. result .. "'")
end
test_normalize_relative_dotdot()

local function test_normalize_leading_dotdot()
  local result = fs.normalize("../foo")
  assert(result == "../foo", "expected '../foo', got '" .. result .. "'")
end
test_normalize_leading_dotdot()

local function test_normalize_redundant_slashes()
  local result = fs.normalize("//usr///lib//")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_normalize_redundant_slashes()

local function test_normalize_empty()
  local result = fs.normalize("")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_normalize_empty()

local function test_normalize_multiple_dotdot()
  local result = fs.normalize("a/b/c/../../d")
  assert(result == "a/d", "expected 'a/d', got '" .. result .. "'")
end
test_normalize_multiple_dotdot()

local function test_normalize_absolute_dotdot_at_root()
  local result = fs.normalize("/../foo")
  assert(result == "/foo", "expected '/foo', got '" .. result .. "'")
end
test_normalize_absolute_dotdot_at_root()

local function test_normalize_just_slashes()
  local result = fs.normalize("///")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_normalize_just_slashes()

local function test_normalize_just_dot()
  local result = fs.normalize(".")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_normalize_just_dot()

local function test_normalize_relative_multiple_leading_dotdot()
  local result = fs.normalize("../../foo/bar")
  assert(result == "../../foo/bar", "expected '../../foo/bar', got '" .. result .. "'")
end
test_normalize_relative_multiple_leading_dotdot()

local function test_normalize_simple_dotdot()
  local result = fs.normalize("a/../b")
  assert(result == "b", "expected 'b', got '" .. result .. "'")
end
test_normalize_simple_dotdot()

local function test_normalize_relative_leading_double_dotdot()
  local result = fs.normalize("../../a")
  assert(result == "../../a", "expected '../../a', got '" .. result .. "'")
end
test_normalize_relative_leading_double_dotdot()

local function test_normalize_absolute_double_dotdot()
  local result = fs.normalize("/../../a")
  assert(result == "/a", "expected '/a', got '" .. result .. "'")
end
test_normalize_absolute_double_dotdot()

local function test_normalize_multiple_up_and_down()
  local result = fs.normalize("a/b/../../c")
  assert(result == "c", "expected 'c', got '" .. result .. "'")
end
test_normalize_multiple_up_and_down()

-- abspath tests

local cwd = unix.getcwd()

local function test_abspath_relative()
  local result = fs.abspath("foo")
  assert(result == cwd .. "/foo", "expected '" .. cwd .. "/foo', got '" .. result .. "'")
end
test_abspath_relative()

local function test_abspath_dot_relative()
  local result = fs.abspath("./foo")
  assert(result == cwd .. "/foo", "expected '" .. cwd .. "/foo', got '" .. result .. "'")
end
test_abspath_dot_relative()

local function test_abspath_already_absolute()
  local result = fs.abspath("/usr/lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_abspath_already_absolute()

local function test_abspath_empty()
  local result = fs.abspath("")
  assert(result == cwd, "expected '" .. cwd .. "', got '" .. result .. "'")
end
test_abspath_empty()

local function test_abspath_normalizes()
  local result = fs.abspath("/usr/../lib")
  assert(result == "/lib", "expected '/lib', got '" .. result .. "'")
end
test_abspath_normalizes()

-- relpath tests

local function test_relpath_child()
  local result = fs.relpath("/usr/lib", "/usr")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_relpath_child()

local function test_relpath_sibling()
  local result = fs.relpath("/usr/lib", "/usr/bin")
  assert(result == "../lib", "expected '../lib', got '" .. result .. "'")
end
test_relpath_sibling()

local function test_relpath_different_tree()
  local result = fs.relpath("/foo", "/bar")
  assert(result == "../foo", "expected '../foo', got '" .. result .. "'")
end
test_relpath_different_tree()

local function test_relpath_same_path()
  local result = fs.relpath("/usr/lib", "/usr/lib")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_relpath_same_path()

local function test_relpath_deeper()
  local result = fs.relpath("/a/b/c/d", "/a/b")
  assert(result == "c/d", "expected 'c/d', got '" .. result .. "'")
end
test_relpath_deeper()

local function test_relpath_go_up_more()
  local result = fs.relpath("/a", "/a/b/c")
  assert(result == "../..", "expected '../..', got '" .. result .. "'")
end
test_relpath_go_up_more()

-- splitext tests

local function test_splitext_simple()
  local root, ext = fs.splitext("foo.txt")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_simple()

local function test_splitext_double_extension()
  local root, ext = fs.splitext("foo.tar.gz")
  assert(root == "foo.tar", "expected root 'foo.tar', got '" .. root .. "'")
  assert(ext == ".gz", "expected ext '.gz', got '" .. ext .. "'")
end
test_splitext_double_extension()

local function test_splitext_no_extension()
  local root, ext = fs.splitext("foo")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_no_extension()

local function test_splitext_hidden_file()
  local root, ext = fs.splitext(".bashrc")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_hidden_file()

local function test_splitext_with_path()
  local root, ext = fs.splitext("/path/to/f.txt")
  assert(root == "/path/to/f", "expected root '/path/to/f', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_with_path()

local function test_splitext_trailing_dot()
  local root, ext = fs.splitext("foo.")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".", "expected ext '.', got '" .. ext .. "'")
end
test_splitext_trailing_dot()

local function test_splitext_hidden_with_ext()
  local root, ext = fs.splitext(".bashrc.bak")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == ".bak", "expected ext '.bak', got '" .. ext .. "'")
end
test_splitext_hidden_with_ext()

-- ext tests

local function test_ext_simple()
  local result = fs.ext("foo.txt")
  assert(result == ".txt", "expected '.txt', got '" .. result .. "'")
end
test_ext_simple()

local function test_ext_double()
  local result = fs.ext("foo.tar.gz")
  assert(result == ".gz", "expected '.gz', got '" .. result .. "'")
end
test_ext_double()

local function test_ext_none()
  local result = fs.ext("foo")
  assert(result == "", "expected '', got '" .. result .. "'")
end
test_ext_none()

local function test_ext_hidden()
  local result = fs.ext(".bashrc")
  assert(result == "", "expected '', got '" .. result .. "'")
end
test_ext_hidden()

-- symlink behavior tests: exists follows symlinks (stat), isfile/isdir do not (lstat)

local function test_exists_symlink_to_file()
  local tmpdir = path.join(TEST_TMPDIR, "symlink_exists_test")
  unix.makedirs(tmpdir)
  local target = path.join(tmpdir, "real.txt")
  touch(target, "hello")
  local link = path.join(tmpdir, "link.txt")
  local ok = unix.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(fs.exists(link), "exists() should follow symlink and return true")
  unix.rmrf(tmpdir)
end
test_exists_symlink_to_file()

local function test_isfile_symlink_to_file()
  local tmpdir = path.join(TEST_TMPDIR, "symlink_isfile_test")
  unix.makedirs(tmpdir)
  local target = path.join(tmpdir, "real.txt")
  touch(target, "hello")
  local link = path.join(tmpdir, "link.txt")
  local ok = unix.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(not fs.isfile(link), "isfile() should return false for a symlink (uses lstat)")
  assert(fs.isfile(target), "isfile() should return true for the target file")
  unix.rmrf(tmpdir)
end
test_isfile_symlink_to_file()

local function test_isdir_symlink_to_dir()
  local tmpdir = path.join(TEST_TMPDIR, "symlink_isdir_test")
  unix.makedirs(tmpdir)
  local target = path.join(tmpdir, "realdir")
  unix.makedirs(target)
  local link = path.join(tmpdir, "linkdir")
  local ok = unix.symlink(target, link)
  assert(ok, "symlink creation should succeed")
  assert(not fs.isdir(link), "isdir() should return false for a symlink (uses lstat)")
  assert(fs.isdir(target), "isdir() should return true for the target dir")
  unix.rmrf(tmpdir)
end
test_isdir_symlink_to_dir()
