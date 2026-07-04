#!/usr/bin/env cosmic
--- Tests for cosmic.zip wrapper module.

local cio = require("cosmic.io")
local fs = require("cosmic.fs")
local zip = require("cosmic.zip")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Helper to create a zip file path
local function zip_path(name: string): string
  return fs.join(TEST_TMPDIR, name)
end

-- Basic write operations

local function test_open_write()
  local p = zip_path("write_test.zip")
  local w, err = zip.open(p, "w")
  assert(w, "should open for writing: " .. tostring(err))
  local writer = w as zip.Writer
  local ok, add_err = writer:add("hello.txt", "Hello, World!")
  assert(ok, "should add file: " .. tostring(add_err))
  writer:close()

  -- Verify the file exists
  local data = cio.slurp(p)
  assert(data and #data > 0, "zip file should exist and have content")
end
test_open_write()

local function test_open_write_multiple_files()
  local p = zip_path("multi_test.zip")
  local w, err = zip.open(p, "w")
  assert(w, "should open for writing: " .. tostring(err))
  local writer = w as zip.Writer
  writer:add("file1.txt", "Content 1")
  writer:add("file2.txt", "Content 2")
  writer:add("subdir/file3.txt", "Content 3")
  writer:close()

  local data = cio.slurp(p)
  assert(data and #data > 0, "zip file should exist")
end
test_open_write_multiple_files()

-- Basic read operations

local function test_open_read()
  -- Create a zip first
  local p = zip_path("read_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("test.txt", "Test content")
  w:close()

  -- Now read it
  local r, err = zip.open(p, "r")
  assert(r, "should open for reading: " .. tostring(err))
  local reader = r as zip.Reader
  reader:close()
end
test_open_read()

local function test_read_list()
  local p = zip_path("list_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("a.txt", "A")
  w:add("b.txt", "B")
  w:add("c/d.txt", "D")
  w:close()

  local r = zip.open(p, "r") as zip.Reader
  local files = r:list()
  r:close()

  assert(#files == 3, "should have 3 files, got " .. #files)
  -- Files should be sorted or in order
  local found_a, found_b, found_d = false, false, false
  for _, name in ipairs(files) do
    if name == "a.txt" then found_a = true end
    if name == "b.txt" then found_b = true end
    if name == "c/d.txt" then found_d = true end
  end
  assert(found_a, "should contain a.txt")
  assert(found_b, "should contain b.txt")
  assert(found_d, "should contain c/d.txt")
end
test_read_list()

local function test_read_content()
  local p = zip_path("content_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("hello.txt", "Hello, ZIP!")
  w:close()

  local r = zip.open(p, "r") as zip.Reader
  local content, err = r:read("hello.txt")
  r:close()

  assert(content, "should read content: " .. tostring(err))
  assert(content == "Hello, ZIP!", "content should match, got: " .. content)
end
test_read_content()

local function test_read_stat()
  local p = zip_path("stat_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("data.bin", "0123456789") -- 10 bytes
  w:close()

  local r = zip.open(p, "r") as zip.Reader
  local stat = r:stat("data.bin")
  r:close()

  assert(stat, "should get stat")
  assert(stat.size == 10, "size should be 10, got " .. tostring(stat.size))
end
test_read_stat()

local function test_read_nonexistent_file()
  local p = zip_path("nonexistent_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("exists.txt", "I exist")
  w:close()

  local r = zip.open(p, "r") as zip.Reader
  local content, err = r:read("does_not_exist.txt")
  r:close()

  assert(content == nil, "should not find nonexistent file")
end
test_read_nonexistent_file()

-- Append operations

local function test_open_append()
  local p = zip_path("append_test.zip")

  -- Create initial zip
  local w = zip.open(p, "w") as zip.Writer
  w:add("first.txt", "First file")
  w:close()

  -- Append to it
  local a, err = zip.open(p, "a")
  assert(a, "should open for appending: " .. tostring(err))
  local appender = a as zip.Appender
  local ok, add_err = appender:add("second.txt", "Second file")
  assert(ok, "should add file: " .. tostring(add_err))
  appender:close()

  -- Verify both files exist
  local r = zip.open(p, "r") as zip.Reader
  local files = r:list()
  local first_content = r:read("first.txt")
  local second_content = r:read("second.txt")
  r:close()

  assert(#files == 2, "should have 2 files after append")
  assert(first_content == "First file", "first file content should match")
  assert(second_content == "Second file", "second file content should match")
end
test_open_append()

-- In-memory reading with from()

local function test_from_memory()
  -- Create a zip file first
  local p = zip_path("memory_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("mem.txt", "In-memory content")
  w:close()

  -- Read the zip data
  local zip_data = cio.slurp(p)
  assert(zip_data, "should read zip data")

  -- Open from memory
  local r, err = zip.from(zip_data)
  assert(r, "should open from memory: " .. tostring(err))
  local content = r:read("mem.txt")
  r:close()

  assert(content == "In-memory content", "should read correct content from memory")
end
test_from_memory()

-- Error handling

local function test_open_invalid_path()
  local r, err = zip.open("/nonexistent/path/to/file.zip", "r")
  assert(r == nil, "should fail on invalid path")
  assert(err, "should return error message")
end
test_open_invalid_path()

local function test_from_invalid_data()
  local r, err = zip.from("not valid zip data")
  assert(r == nil, "should fail on invalid data")
  assert(err, "should return error message")
end
test_from_invalid_data()

-- Compression options

local function test_add_with_options()
  local p = zip_path("options_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  -- Use larger content that will definitely compress
  local large_content = string.rep("Hello World! ", 100) -- 1300 bytes of repeated data
  local ok, err = w:add("stored.txt", large_content, {method = "store"})
  assert(ok, "should add with store method: " .. tostring(err))
  ok, err = w:add("deflated.txt", large_content, {method = "deflate"})
  assert(ok, "should add with deflate method: " .. tostring(err))
  w:close()

  local r = zip.open(p, "r") as zip.Reader
  local stored_stat = r:stat("stored.txt")
  local deflated_stat = r:stat("deflated.txt")
  r:close()

  assert(stored_stat, "should have stored.txt stat")
  assert(deflated_stat, "should have deflated.txt stat")
  -- Stored files should have method 0, deflated should have method 8
  assert(stored_stat.method == 0, "stored method should be 0, got " .. tostring(stored_stat.method))
  assert(deflated_stat.method == 8, "deflated method should be 8, got " .. tostring(deflated_stat.method))
  -- Verify deflated is actually smaller
  assert(deflated_stat.compressed_size < deflated_stat.size,
    "deflated should be smaller: " .. tostring(deflated_stat.compressed_size) .. " < " .. tostring(deflated_stat.size))
end
test_add_with_options()

local function test_open_with_compression_level()
  local p = zip_path("level_test.zip")
  local w, err = zip.open(p, "w", {level = 9})
  assert(w, "should open with compression level: " .. tostring(err))
  local writer = w as zip.Writer
  -- Add a file that benefits from compression
  local content = string.rep("AAAA", 1000) -- 4000 bytes of repeated data
  writer:add("compressible.txt", content)
  writer:close()

  -- Verify it compressed
  local r = zip.open(p, "r") as zip.Reader
  local stat = r:stat("compressible.txt")
  r:close()

  assert(stat, "should have stat")
  assert(stat.size == 4000, "uncompressed size should be 4000")
  assert(stat.compressed_size < stat.size, "compressed size should be smaller")
end
test_open_with_compression_level()

-- Default mode is read

local function test_default_mode_is_read()
  local p = zip_path("default_mode_test.zip")
  local w = zip.open(p, "w") as zip.Writer
  w:add("test.txt", "Test")
  w:close()

  -- Open without specifying mode
  local r, err = zip.open(p)
  assert(r, "should open in default mode: " .. tostring(err))
  local reader = r as zip.Reader
  local files = reader:list()
  reader:close()
  assert(#files == 1, "should list files in default read mode")
end
test_default_mode_is_read()
