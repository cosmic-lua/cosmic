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
