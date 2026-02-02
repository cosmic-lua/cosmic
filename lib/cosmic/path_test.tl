#!/usr/bin/env cosmic
local path = require("cosmic.path")

-- dirname tests

local function test_dirname_with_file()
  local result = path.dirname("/usr/lib")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_dirname_with_file()

local function test_dirname_trailing_slash()
  local result = path.dirname("/usr/lib/")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_dirname_trailing_slash()

local function test_dirname_root()
  local result = path.dirname("/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_dirname_root()

local function test_dirname_single_component()
  local result = path.dirname("usr")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_dirname_single_component()

local function test_dirname_dot()
  local result = path.dirname(".")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_dirname_dot()

local function test_dirname_dotdot()
  local result = path.dirname("..")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_dirname_dotdot()

local function test_dirname_only_slash()
  local result = path.dirname("/usr/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_dirname_only_slash()

-- basename tests

local function test_basename_with_file()
  local result = path.basename("/usr/lib")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_basename_with_file()

local function test_basename_trailing_slash()
  local result = path.basename("/usr/lib/")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_basename_trailing_slash()

local function test_basename_root()
  local result = path.basename("/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_basename_root()

local function test_basename_single_component()
  local result = path.basename("usr")
  assert(result == "usr", "expected 'usr', got '" .. result .. "'")
end
test_basename_single_component()

local function test_basename_dot()
  local result = path.basename(".")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_basename_dot()

local function test_basename_dotdot()
  local result = path.basename("..")
  assert(result == "..", "expected '..', got '" .. result .. "'")
end
test_basename_dotdot()

-- join tests

local function test_join_basic()
  local result = path.join("/usr", "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_basic()

local function test_join_trailing_slash()
  local result = path.join("/usr/", "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_trailing_slash()

local function test_join_absolute_resets()
  local result = path.join("/usr/lib", "/lib")
  assert(result == "/lib", "expected '/lib', got '" .. result .. "'")
end
test_join_absolute_resets()

local function test_join_root()
  local result = path.join("/", "/")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_join_root()

local function test_join_multiple()
  local result = path.join("/usr", "local", "bin")
  assert(result == "/usr/local/bin", "expected '/usr/local/bin', got '" .. result .. "'")
end
test_join_multiple()

local function test_join_with_nil()
  local result = path.join("/usr", nil, "lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_join_with_nil()

local function test_join_all_nil()
  local result = path.join(nil, nil)
  assert(result == nil, "expected nil, got '" .. tostring(result) .. "'")
end
test_join_all_nil()

local function test_join_single()
  local result = path.join("/usr")
  assert(result == "/usr", "expected '/usr', got '" .. result .. "'")
end
test_join_single()

-- exists tests

local function test_exists_current_dir()
  local result = path.exists(".")
  assert(result == true, "expected current directory to exist")
end
test_exists_current_dir()

local function test_exists_nonexistent()
  local result = path.exists("/nonexistent/path/that/does/not/exist")
  assert(result == false, "expected false for nonexistent path")
end
test_exists_nonexistent()

-- isfile tests

local function test_isfile_directory()
  local result = path.isfile(".")
  assert(result == false, "expected false for directory")
end
test_isfile_directory()

local function test_isfile_nonexistent()
  local result = path.isfile("/nonexistent/file")
  assert(result == false, "expected false for nonexistent path")
end
test_isfile_nonexistent()

-- isdir tests

local function test_isdir_current()
  local result = path.isdir(".")
  assert(result == true, "expected true for current directory")
end
test_isdir_current()

local function test_isdir_nonexistent()
  local result = path.isdir("/nonexistent/dir")
  assert(result == false, "expected false for nonexistent path")
end
test_isdir_nonexistent()

-- islink tests

local function test_islink_regular_dir()
  local result = path.islink(".")
  assert(result == false, "expected false for regular directory")
end
test_islink_regular_dir()

local function test_islink_nonexistent()
  local result = path.islink("/nonexistent/link")
  assert(result == false, "expected false for nonexistent path")
end
test_islink_nonexistent()

-- normalize tests

local function test_normalize_dot_component()
  local result = path.normalize("/usr/./lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_normalize_dot_component()

local function test_normalize_dotdot_component()
  local result = path.normalize("/usr/lib/../bin")
  assert(result == "/usr/bin", "expected '/usr/bin', got '" .. result .. "'")
end
test_normalize_dotdot_component()

local function test_normalize_relative_dotdot()
  local result = path.normalize("a/b/../c")
  assert(result == "a/c", "expected 'a/c', got '" .. result .. "'")
end
test_normalize_relative_dotdot()

local function test_normalize_leading_dotdot()
  local result = path.normalize("../foo")
  assert(result == "../foo", "expected '../foo', got '" .. result .. "'")
end
test_normalize_leading_dotdot()

local function test_normalize_redundant_slashes()
  local result = path.normalize("//usr///lib//")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_normalize_redundant_slashes()

local function test_normalize_empty()
  local result = path.normalize("")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_normalize_empty()

local function test_normalize_multiple_dotdot()
  local result = path.normalize("a/b/c/../../d")
  assert(result == "a/d", "expected 'a/d', got '" .. result .. "'")
end
test_normalize_multiple_dotdot()

local function test_normalize_absolute_dotdot_at_root()
  local result = path.normalize("/../foo")
  assert(result == "/foo", "expected '/foo', got '" .. result .. "'")
end
test_normalize_absolute_dotdot_at_root()

local function test_normalize_just_slashes()
  local result = path.normalize("///")
  assert(result == "/", "expected '/', got '" .. result .. "'")
end
test_normalize_just_slashes()

local function test_normalize_just_dot()
  local result = path.normalize(".")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_normalize_just_dot()

local function test_normalize_relative_multiple_leading_dotdot()
  local result = path.normalize("../../foo/bar")
  assert(result == "../../foo/bar", "expected '../../foo/bar', got '" .. result .. "'")
end
test_normalize_relative_multiple_leading_dotdot()

-- abspath tests

local unix = require("cosmo.unix")
local cwd = unix.getcwd()

local function test_abspath_relative()
  local result = path.abspath("foo")
  assert(result == cwd .. "/foo", "expected '" .. cwd .. "/foo', got '" .. result .. "'")
end
test_abspath_relative()

local function test_abspath_dot_relative()
  local result = path.abspath("./foo")
  assert(result == cwd .. "/foo", "expected '" .. cwd .. "/foo', got '" .. result .. "'")
end
test_abspath_dot_relative()

local function test_abspath_already_absolute()
  local result = path.abspath("/usr/lib")
  assert(result == "/usr/lib", "expected '/usr/lib', got '" .. result .. "'")
end
test_abspath_already_absolute()

local function test_abspath_empty()
  local result = path.abspath("")
  assert(result == cwd, "expected '" .. cwd .. "', got '" .. result .. "'")
end
test_abspath_empty()

local function test_abspath_normalizes()
  local result = path.abspath("/usr/../lib")
  assert(result == "/lib", "expected '/lib', got '" .. result .. "'")
end
test_abspath_normalizes()

-- relpath tests

local function test_relpath_child()
  local result = path.relpath("/usr/lib", "/usr")
  assert(result == "lib", "expected 'lib', got '" .. result .. "'")
end
test_relpath_child()

local function test_relpath_sibling()
  local result = path.relpath("/usr/lib", "/usr/bin")
  assert(result == "../lib", "expected '../lib', got '" .. result .. "'")
end
test_relpath_sibling()

local function test_relpath_different_tree()
  local result = path.relpath("/foo", "/bar")
  assert(result == "../foo", "expected '../foo', got '" .. result .. "'")
end
test_relpath_different_tree()

local function test_relpath_same_path()
  local result = path.relpath("/usr/lib", "/usr/lib")
  assert(result == ".", "expected '.', got '" .. result .. "'")
end
test_relpath_same_path()

local function test_relpath_deeper()
  local result = path.relpath("/a/b/c/d", "/a/b")
  assert(result == "c/d", "expected 'c/d', got '" .. result .. "'")
end
test_relpath_deeper()

local function test_relpath_go_up_more()
  local result = path.relpath("/a", "/a/b/c")
  assert(result == "../..", "expected '../..', got '" .. result .. "'")
end
test_relpath_go_up_more()

-- splitext tests

local function test_splitext_simple()
  local root, ext = path.splitext("foo.txt")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_simple()

local function test_splitext_double_extension()
  local root, ext = path.splitext("foo.tar.gz")
  assert(root == "foo.tar", "expected root 'foo.tar', got '" .. root .. "'")
  assert(ext == ".gz", "expected ext '.gz', got '" .. ext .. "'")
end
test_splitext_double_extension()

local function test_splitext_no_extension()
  local root, ext = path.splitext("foo")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_no_extension()

local function test_splitext_hidden_file()
  local root, ext = path.splitext(".bashrc")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_hidden_file()

local function test_splitext_with_path()
  local root, ext = path.splitext("/path/to/f.txt")
  assert(root == "/path/to/f", "expected root '/path/to/f', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_with_path()

local function test_splitext_trailing_dot()
  local root, ext = path.splitext("foo.")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".", "expected ext '.', got '" .. ext .. "'")
end
test_splitext_trailing_dot()

local function test_splitext_hidden_with_ext()
  local root, ext = path.splitext(".bashrc.bak")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == ".bak", "expected ext '.bak', got '" .. ext .. "'")
end
test_splitext_hidden_with_ext()

-- ext tests

local function test_ext_simple()
  local result = path.ext("foo.txt")
  assert(result == ".txt", "expected '.txt', got '" .. result .. "'")
end
test_ext_simple()

local function test_ext_double()
  local result = path.ext("foo.tar.gz")
  assert(result == ".gz", "expected '.gz', got '" .. result .. "'")
end
test_ext_double()

local function test_ext_none()
  local result = path.ext("foo")
  assert(result == "", "expected '', got '" .. result .. "'")
end
test_ext_none()

local function test_ext_hidden()
  local result = path.ext(".bashrc")
  assert(result == "", "expected '', got '" .. result .. "'")
end
test_ext_hidden()
