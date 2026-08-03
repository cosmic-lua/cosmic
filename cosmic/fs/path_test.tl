#!/usr/bin/env cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

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
    fs.rmrf(test_dir)
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

-- join semantics: pin the documented edge cases so a change
-- in the underlying C binding surfaces as a failure, not silent drift.

local function test_join_absolute_later_arg_resets()
  assert(fs.join("a", "/abs") == "/abs",
    "an absolute later component must reset the result")
end
test_join_absolute_later_arg_resets()

local function test_join_empty_components_skipped()
  assert(fs.join("a", "", "b") == "a/b", "empty middle component is skipped")
  assert(fs.join("", "b") == "b", "empty first component is skipped")
end
test_join_empty_components_skipped()

local function test_join_no_doubled_separator()
  assert(fs.join("a/", "b") == "a/b",
    "a trailing slash on the left must not double the separator")
end
test_join_no_doubled_separator()

local function test_join_single_component()
  assert(fs.join("a") == "a", "a single component joins to itself")
end
test_join_single_component()

local function test_join_does_not_normalize()
  -- join concatenates; it does not resolve ".." (that is normalize's job).
  assert(fs.join("a", "..", "b") == "a/../b",
    "join must not collapse '..' segments")
end
test_join_does_not_normalize()

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

local type WalkStat = fs_types.WalkStat

local record WalkContext
  count: number
  dirs: number
end

local function setup_walk(): string
  local walk_dir = fs.join(TEST_TMPDIR, "walk_test")
  fs.makedirs(fs.join(walk_dir, "subdir"))
  fs.makedirs(fs.join(walk_dir, "subdir/nested"))

  touch(fs.join(walk_dir, "file1.lua"))
  touch(fs.join(walk_dir, "file2.txt"))
  touch(fs.join(walk_dir, "subdir/file3.lua"))
  touch(fs.join(walk_dir, "subdir/nested/file4.lua"))

  return walk_dir
end

local function test_collect_with_glob()
  local walk_dir = setup_walk()
  -- cast: or fallback does not narrow
  local found = (fs.collect(walk_dir, "*.lua") or {}) as {string}

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
  -- cast: or fallback does not narrow
  local found = (fs.collect(walk_dir, "*[1].lua") or {}) as {string}
  assert(#found == 0, "expected brackets treated literally, got " .. #found)
  teardown(walk_dir)
end
test_collect_glob_escapes_brackets()

local function test_collect_with_lua_pattern()
  local walk_dir = setup_walk()
  -- cast: or fallback does not narrow
  local found = (fs.collect_matching(walk_dir, "%.txt$") or {}) as {string}

  assert(#found == 1, "expected 1 txt file, got " .. #found)
  assert(fs.basename(found[1]) == "file2.txt", "expected file2.txt")
  teardown(walk_dir)
end
test_collect_with_lua_pattern()

local function test_walk_with_visitor()
  local walk_dir = setup_walk()
  local ctx: WalkContext = {count = 0, dirs = 0}

  fs.walk(walk_dir, function(_full_path: string, _entry: string, st: any, c: any)
      local wctx = c as WalkContext -- cast: from any
      wctx.count = wctx.count + 1
      local stat_obj = st as WalkStat -- cast: from any
      if stat_obj:is_dir() then
        wctx.dirs = wctx.dirs + 1
      end
    end, ctx)

  assert(ctx.count > 0, "expected count > 0")
  assert(ctx.dirs == 2, "expected 2 dirs, got " .. ctx.dirs)
  teardown(walk_dir)
end
test_walk_with_visitor()

local function test_collect_all()
  local walk_dir = setup_walk()
  local collected = fs.collect_all(walk_dir)
  assert(collected, "collect_all should succeed")
  local found = collected as {string: fs_types.FileInfo} -- cast: record union after guard

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

  for filepath in check.must(fs.files(walk_dir, "*.lua")) do
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

  for _ in check.must(fs.files(walk_dir)) do
    count = count + 1
  end

  assert(count == 4, "expected 4 files, got " .. count)
  teardown(walk_dir)
end
test_files_iterator_all()

local function test_walk_empty_directory()
  local empty_dir = fs.join(TEST_TMPDIR, "walk_empty")
  fs.makedirs(empty_dir)
  -- cast: or fallback does not narrow
  local found = (fs.collect(empty_dir, "*.lua") or {}) as {string}
  assert(#found == 0, "expected 0 files, got " .. #found)
  fs.rmrf(empty_dir)
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

local cwd = fs.getcwd()

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
