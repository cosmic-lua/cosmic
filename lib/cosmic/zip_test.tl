#!/usr/bin/env cosmic
--- Tests for cosmic.zip wrapper module.

local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs_types")
local zip = require("cosmic.zip")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Helper to create a zip file path
local function zip_path(name: string): string
  return fs.join(TEST_TMPDIR, name)
end

-- Basic write operations

local function test_writer()
  local p = zip_path("write_test.zip")
  local w, err = zip.writer(p)
  assert(w, "should open for writing: " .. tostring(err))
  local writer = w as zip.Writer
  local ok, add_err = writer:add("hello.txt", "Hello, World!")
  assert(ok, "should add file: " .. tostring(add_err))
  writer:close()

  -- Verify the file exists
  local data = fs.read(p)
  assert(data and #data > 0, "zip file should exist and have content")
end
test_writer()

local function test_writer_multiple_files()
  local p = zip_path("multi_test.zip")
  local w, err = zip.writer(p)
  assert(w, "should open for writing: " .. tostring(err))
  local writer = w as zip.Writer
  writer:add("file1.txt", "Content 1")
  writer:add("file2.txt", "Content 2")
  writer:add("subdir/file3.txt", "Content 3")
  writer:close()

  local data = fs.read(p)
  assert(data and #data > 0, "zip file should exist")
end
test_writer_multiple_files()

-- Basic read operations

local function test_reader()
  -- Create a zip first
  local p = zip_path("read_test.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("test.txt", "Test content")
  w:close()

  -- Now read it
  local r, err = zip.reader(p)
  assert(r, "should open for reading: " .. tostring(err))
  local reader = r as zip.Reader
  reader:close()
end
test_reader()

local function test_read_list()
  local p = zip_path("list_test.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("a.txt", "A")
  w:add("b.txt", "B")
  w:add("c/d.txt", "D")
  w:close()

  local r = zip.reader(p) as zip.Reader
  local files = r:list()
  r:close()

  assert(#files == 3, "should have 3 files, got " .. #files)
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
  local w = zip.writer(p) as zip.Writer
  w:add("hello.txt", "Hello, ZIP!")
  w:close()

  local r = zip.reader(p) as zip.Reader
  local content, err = r:read("hello.txt")
  r:close()

  assert(content, "should read content: " .. tostring(err))
  assert(content == "Hello, ZIP!", "content should match, got: " .. tostring(content))
end
test_read_content()

local function test_read_stat()
  local p = zip_path("stat_test.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("data.bin", "0123456789") -- 10 bytes
  w:close()

  local r = zip.reader(p) as zip.Reader
  local stat = r:stat("data.bin")
  r:close()

  assert(stat, "should get stat")
  local st = stat as zip.Stat
  assert(st.size == 10, "size should be 10, got " .. tostring(st.size))
end
test_read_stat()

local function test_read_nonexistent_file()
  local p = zip_path("nonexistent_test.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("exists.txt", "I exist")
  w:close()

  local r = zip.reader(p) as zip.Reader
  local content = r:read("does_not_exist.txt")
  r:close()

  assert(content == nil, "should not find nonexistent file")
end
test_read_nonexistent_file()

-- Append operations

local function test_appender()
  local p = zip_path("append_test.zip")

  -- Create initial zip
  local w = zip.writer(p) as zip.Writer
  w:add("first.txt", "First file")
  w:close()

  -- Append to it
  local a, err = zip.appender(p)
  assert(a, "should open for appending: " .. tostring(err))
  local appender = a as zip.Appender
  local ok, add_err = appender:add("second.txt", "Second file")
  assert(ok, "should add file: " .. tostring(add_err))
  appender:close()

  -- Verify both files exist
  local r = zip.reader(p) as zip.Reader
  local files = r:list()
  local first_content = r:read("first.txt")
  local second_content = r:read("second.txt")
  r:close()

  assert(#files == 2, "should have 2 files after append")
  assert(first_content == "First file", "first file content should match")
  assert(second_content == "Second file", "second file content should match")
end
test_appender()

-- In-memory reading with from()

local function test_from_memory()
  local p = zip_path("memory_test.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("mem.txt", "In-memory content")
  w:close()

  local zip_data = fs.read(p)
  assert(zip_data, "should read zip data")

  local r, err = zip.from(zip_data as string)
  assert(r, "should open from memory: " .. tostring(err))
  local rr = r as zip.Reader
  local content = rr:read("mem.txt")
  rr:close()

  assert(content == "In-memory content", "should read correct content from memory")
end
test_from_memory()

-- Error handling

local function test_reader_invalid_path()
  local r, err = zip.reader("/nonexistent/path/to/file.zip")
  assert(r == nil, "should fail on invalid path")
  assert(err, "should return error message")
end
test_reader_invalid_path()

local function test_appender_creates_missing_archive()
  -- append has create-or-append semantics: a missing archive is created.
  local p = zip_path("appender_creates.zip")
  local a, err = zip.appender(p)
  assert(a, "appender should create a missing archive: " .. tostring(err))
  local appender = a as zip.Appender
  appender:add("x.txt", "hi")
  appender:close()

  local r = zip.reader(p) as zip.Reader
  assert(r:read("x.txt") == "hi", "created archive should contain the entry")
  r:close()
end
test_appender_creates_missing_archive()

local function test_appender_invalid_path()
  local a, err = zip.appender("/nonexistent/dir/x.zip")
  assert(a == nil, "should fail when the parent directory is missing")
  assert(err, "should return error message")
end
test_appender_invalid_path()

local function test_from_invalid_data()
  local r, err = zip.from("not valid zip data")
  assert(r == nil, "should fail on invalid data")
  assert(err, "should return error message")
end
test_from_invalid_data()

-- Compression options

local function test_add_with_options()
  local p = zip_path("options_test.zip")
  local w = zip.writer(p) as zip.Writer
  -- Use larger content that will definitely compress
  local large_content = string.rep("Hello World! ", 100) -- 1300 bytes of repeated data
  local ok, err = w:add("stored.txt", large_content, {method = "store"})
  assert(ok, "should add with store method: " .. tostring(err))
  ok, err = w:add("deflated.txt", large_content, {method = "deflate"})
  assert(ok, "should add with deflate method: " .. tostring(err))
  w:close()

  local r = zip.reader(p) as zip.Reader
  local stored_stat = r:stat("stored.txt")
  local deflated_stat = r:stat("deflated.txt")
  r:close()

  assert(stored_stat, "should have stored.txt stat")
  assert(deflated_stat, "should have deflated.txt stat")
  local stored_st = stored_stat as zip.Stat
  local deflated_st = deflated_stat as zip.Stat
  -- Stored files should have method 0, deflated should have method 8
  assert(stored_st.method == 0, "stored method should be 0, got " .. tostring(stored_st.method))
  assert(deflated_st.method == 8, "deflated method should be 8, got " .. tostring(deflated_st.method))
  -- Verify deflated is actually smaller
  assert(deflated_st.compressed_size < deflated_st.size,
    "deflated should be smaller: " .. tostring(deflated_st.compressed_size) .. " < " .. tostring(deflated_st.size))
end
test_add_with_options()

local function test_writer_with_compression_level()
  local p = zip_path("level_test.zip")
  local w, err = zip.writer(p, {level = 9})
  assert(w, "should open with compression level: " .. tostring(err))
  local writer = w as zip.Writer
  -- Add a file that benefits from compression
  local content = string.rep("AAAA", 1000) -- 4000 bytes of repeated data
  writer:add("compressible.txt", content)
  writer:close()

  -- Verify it compressed
  local r = zip.reader(p) as zip.Reader
  local stat = r:stat("compressible.txt")
  r:close()

  assert(stat, "should have stat")
  local st = stat as zip.Stat
  assert(st.size == 4000, "uncompressed size should be 4000")
  assert(st.compressed_size < st.size, "compressed size should be smaller")
end
test_writer_with_compression_level()

-- extract(): safe extraction to a directory

local function test_extract_basic()
  local p = zip_path("extract_basic.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("top.txt", "top content")
  w:add("sub/dir/nested.txt", "nested content")
  w:add("run.sh", "#!/bin/sh\n", {mode = tonumber("755", 8)})
  w:close()

  local r = zip.reader(p) as zip.Reader
  local dest = zip_path("extract_basic_out")
  local ok, err = zip.extract(r, dest)
  r:close()
  assert(ok, "extract should succeed: " .. tostring(err))

  assert(fs.read(fs.join(dest, "top.txt")) == "top content", "top.txt should round-trip")
  assert(fs.read(fs.join(dest, "sub/dir/nested.txt")) == "nested content", "nested file should round-trip")
  local st = fs.stat(fs.join(dest, "run.sh"))
  assert(st, "run.sh should exist")
  local mode = (st as fs_types.Stat):mode() & tonumber("777", 8)
  assert(mode == tonumber("755", 8), "mode from the archive should apply, got " .. string.format("%o", mode))
end
test_extract_basic()

-- Craft an archive with a traversal entry. cosmic's own zip writer refuses
-- ".." names, so write a same-length placeholder name and byte-patch it
-- (no offsets change, so the zip stays valid): "XX/escaped.txt" ->
-- "../escaped.txt".
local function crafted_archive(patch_to: string): string
  local safe = zip_path("crafted_" .. patch_to:gsub("%W", "_") .. ".zip")
  local w = zip.writer(safe) as zip.Writer
  w:add("good.txt", "innocent")
  w:add("XX/escaped.txt", "pwned")
  w:close()
  local raw = fs.read(safe)
  assert(#patch_to == #"XX/escaped.txt", "patch must preserve name length")
  local patched = string.gsub(raw as string, "XX/escaped%.txt", patch_to)
  return patched
end

local function test_extract_rejects_traversal()
  local data = crafted_archive("../escaped.txt")
  local r = zip.from(data) as zip.Reader
  local dest = zip_path("traversal_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject a ../ entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
  -- Nothing may be written: not the escaping file, and not the innocent
  -- entry either (validation runs before any writes).
  assert(not fs.exists(fs.join(TEST_TMPDIR, "escaped.txt")), "escaping file must not be written")
  assert(not fs.exists(dest), "destination must stay untouched on rejection")
end
test_extract_rejects_traversal()

local function test_extract_rejects_absolute()
  local data = crafted_archive("/e/escaped.txt")
  local r = zip.from(data) as zip.Reader
  local dest = zip_path("absolute_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject an absolute entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
  assert(not fs.exists(dest), "destination must stay untouched on rejection")
end
test_extract_rejects_absolute()

local function test_extract_rejects_backslash_traversal()
  local data = crafted_archive("..\\escaped.txt")
  local r = zip.from(data) as zip.Reader
  local dest = zip_path("backslash_out")
  local ok, err = zip.extract(r, dest)
  r:close()

  assert(not ok, "extract should reject a ..\\ entry")
  assert(err and err:match("unsafe path"), "expected unsafe path error, got: " .. tostring(err))
end
test_extract_rejects_backslash_traversal()

local function test_extract_max_file_size()
  local p = zip_path("extract_size.zip")
  local w = zip.writer(p) as zip.Writer
  w:add("small.txt", "ok")
  w:add("big.txt", string.rep("x", 4096))
  w:close()

  local r = zip.reader(p) as zip.Reader
  local dest = zip_path("size_out")
  local ok, err = zip.extract(r, dest, {max_file_size = 1024})
  r:close()

  assert(not ok, "extract should reject oversized entries")
  assert(err and err:match("max_file_size"), "expected size error, got: " .. tostring(err))
  assert(not fs.exists(fs.join(dest, "small.txt")), "no partial output on size rejection")
end
test_extract_max_file_size()
