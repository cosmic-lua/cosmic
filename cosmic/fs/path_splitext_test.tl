#!/usr/bin/env cosmic
--- Tests for splitext/ext, split out of path_test.tl to stay under the
--- 500-line file limit.
local fs = require("cosmic.fs")

-- splitext tests

local function test_splitext_simple()
  local root, ext = fs.split_extension("foo.txt")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_simple()

local function test_splitext_double_extension()
  local root, ext = fs.split_extension("foo.tar.gz")
  assert(root == "foo.tar", "expected root 'foo.tar', got '" .. root .. "'")
  assert(ext == ".gz", "expected ext '.gz', got '" .. ext .. "'")
end
test_splitext_double_extension()

local function test_splitext_no_extension()
  local root, ext = fs.split_extension("foo")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_no_extension()

local function test_splitext_hidden_file()
  local root, ext = fs.split_extension(".bashrc")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == "", "expected ext '', got '" .. ext .. "'")
end
test_splitext_hidden_file()

local function test_splitext_with_path()
  local root, ext = fs.split_extension("/path/to/f.txt")
  assert(root == "/path/to/f", "expected root '/path/to/f', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_with_path()

local function test_splitext_trailing_dot()
  local root, ext = fs.split_extension("foo.")
  assert(root == "foo", "expected root 'foo', got '" .. root .. "'")
  assert(ext == ".", "expected ext '.', got '" .. ext .. "'")
end
test_splitext_trailing_dot()

local function test_splitext_hidden_with_ext()
  local root, ext = fs.split_extension(".bashrc.bak")
  assert(root == ".bashrc", "expected root '.bashrc', got '" .. root .. "'")
  assert(ext == ".bak", "expected ext '.bak', got '" .. ext .. "'")
end
test_splitext_hidden_with_ext()

local function test_splitext_file_under_root()
  local root, ext = fs.split_extension("/a.txt")
  assert(root == "/a", "expected root '/a', got '" .. root .. "'")
  assert(ext == ".txt", "expected ext '.txt', got '" .. ext .. "'")
end
test_splitext_file_under_root()

local function test_splitext_hidden_file_under_root()
  local root, ext = fs.split_extension("/.bashrc.bak")
  assert(root == "/.bashrc", "expected root '/.bashrc', got '" .. root .. "'")
  assert(ext == ".bak", "expected ext '.bak', got '" .. ext .. "'")
end
test_splitext_hidden_file_under_root()

-- fs.ext does not exist; the extension is split_extension's second
-- return.

local function test_extension_via_split()
  local _, e1 = fs.split_extension("foo.txt")
  assert(e1 == ".txt", "expected '.txt', got '" .. e1 .. "'")
  local _, e2 = fs.split_extension("foo.tar.gz")
  assert(e2 == ".gz", "expected '.gz', got '" .. e2 .. "'")
  local _, e3 = fs.split_extension("foo")
  assert(e3 == "", "expected '', got '" .. e3 .. "'")
  local _, e4 = fs.split_extension(".bashrc")
  assert(e4 == "", "expected '', got '" .. e4 .. "'")
end
test_extension_via_split()
