#!/usr/bin/env cosmic
--- Tests for splitext/ext, split out of path_test.tl to stay under the
--- 500-line file limit.
local fs = require("cosmic.fs")

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

local function test_splitext_file_under_root()
  local root, ext = fs.splitext("/a.txt")
  assert(root == "/a", "expected root '/a', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_file_under_root()

local function test_splitext_hidden_file_under_root()
  local root, ext = fs.splitext("/.bashrc.bak")
  assert(root == "/.bashrc", "expected root '/.bashrc', got '" .. root .. "'")
  assert(ext == ".bak", "expected ext '.bak', got '" .. ext .. "'")
end
test_splitext_hidden_file_under_root()

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
