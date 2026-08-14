#!/usr/bin/env cosmic
--- Tests for cosmic.zip wrapper module.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local zip = require("cosmic.zip")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Helper to create a zip file path
local function zip_path(name: string): string
  return fs.join(TEST_TMPDIR, name)
end

-- Basic write operations

local function test_writer()
  local p = zip_path("write_test.zip")
  local writer = check.must(zip.open(p, {mode = "write"}))
  local ok, add_err = writer:add("hello.txt", "Hello, World!")
  assert(ok, "should add file: " .. tostring(add_err))
  -- close is where the archive lands on disk, so it is fallible; a
  -- second close is a no-op that also reports true
  local cok, cerr = writer:close()
  assert(cok, "close should succeed: " .. tostring(cerr))
  assert(writer:close(), "second close should be a true no-op")

  -- Verify the file exists
  local data = fs.read(p)
  assert(data and #data > 0, "zip file should exist and have content")
end
test_writer()

local function test_writer_multiple_files()
  local p = zip_path("multi_test.zip")
  local writer = check.must(zip.open(p, {mode = "write"}))
  assert(writer:add("file1.txt", "Content 1"))
  assert(writer:add("file2.txt", "Content 2"))
  assert(writer:add("subdir/file3.txt", "Content 3"))
  assert(writer:close())

  local data = fs.read(p)
  assert(data and #data > 0, "zip file should exist")
end
test_writer_multiple_files()

-- Basic read operations

local function test_reader()
  -- Create a zip first
  local p = zip_path("read_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("test.txt", "Test content"))
  assert(w:close())

  -- Now read it
  local reader = check.must(zip.open(p))
  assert(reader:close())
end
test_reader()

local function test_read_list()
  local p = zip_path("list_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("a.txt", "A"))
  assert(w:add("b.txt", "B"))
  assert(w:add("c/d.txt", "D"))
  assert(w:close())

  local r = check.must(zip.open(p))
  local files = check.must(r:list())
  assert(r:close())

  assert(#files == 3, "should have 3 files, got " .. #files)
  local found_a, found_b, found_d = false, false, false
  for _, entry in ipairs(files) do
    if entry.name == "a.txt" then
      found_a = true
      assert(entry.size == 1, "a.txt should report size 1, got " .. tostring(entry.size))
    end
    if entry.name == "b.txt" then found_b = true end
    if entry.name == "c/d.txt" then found_d = true end
  end
  assert(found_a, "should contain a.txt")
  assert(found_b, "should contain b.txt")
  assert(found_d, "should contain c/d.txt")
end
test_read_list()

local function test_read_content()
  local p = zip_path("content_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("hello.txt", "Hello, ZIP!"))
  assert(w:close())

  local r = check.must(zip.open(p))
  local content, err = r:read("hello.txt")
  assert(r:close())

  assert(content, "should read content: " .. tostring(err))
  assert(content == "Hello, ZIP!", "content should match, got: " .. tostring(content))
end
test_read_content()

local function test_read_stat()
  local p = zip_path("stat_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("data.bin", "0123456789")) -- 10 bytes
  assert(w:close())

  local r = check.must(zip.open(p))
  local st = check.must(r:stat("data.bin"), "should get stat")
  assert(r:close())

  assert(st.size == 10, "size should be 10, got " .. tostring(st.size))
end
test_read_stat()

local function test_read_nonexistent_file()
  local p = zip_path("nonexistent_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("exists.txt", "I exist"))
  assert(w:close())

  local r = check.must(zip.open(p))
  local content = r:read("does_not_exist.txt")
  assert(r:close())

  assert(content == nil, "should not find nonexistent file")
end
test_read_nonexistent_file()

-- Append operations

local function test_appender()
  local p = zip_path("append_test.zip")

  -- Create initial zip
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("first.txt", "First file"))
  assert(w:close())

  -- Append to it
  local appender = check.must(zip.open(p, {mode = "append"}))
  local ok, add_err = appender:add("second.txt", "Second file")
  assert(ok, "should add file: " .. tostring(add_err))
  assert(appender:close())

  -- Verify both files exist
  local r = check.must(zip.open(p))
  local files = check.must(r:list())
  local first_content = r:read("first.txt")
  local second_content = r:read("second.txt")
  assert(r:close())

  assert(#files == 2, "should have 2 files after append")
  assert(first_content == "First file", "first file content should match")
  assert(second_content == "Second file", "second file content should match")
end
test_appender()

-- Appender:remove.

local function test_appender_remove()
  local p = zip_path("remove_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("gone.txt", "delete me"))
  assert(w:add("kept.txt", "keep me"))
  assert(w:close())

  local appender = check.must(zip.open(p, {mode = "append"}))
  local ok, remove_err = appender:remove("gone.txt")
  assert(ok, "remove of an existing entry should succeed: " .. tostring(remove_err))
  assert(appender:close())

  local r = check.must(zip.open(p))
  local files = check.must(r:list())
  assert(#files == 1, "archive should have 1 entry after remove, got " .. #files)
  assert(files[1].name == "kept.txt",
    "the surviving entry should be kept.txt, got " .. tostring(files[1].name))
  local kept = r:read("kept.txt")
  assert(kept == "keep me", "surviving entry content must be intact")
  local gone, read_err = r:read("gone.txt")
  assert(gone == nil, "the removed entry must not be readable")
  assert(read_err and string.match(read_err, "not found"),
    "reading a removed entry should say not found, got: " .. tostring(read_err))
  assert(r:close())
end
test_appender_remove()

local function test_appender_remove_missing_entry()
  local p = zip_path("remove_missing_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("only.txt", "here"))
  assert(w:close())

  local appender = check.must(zip.open(p, {mode = "append"}))
  local ok, err = appender:remove("no-such-entry.txt")
  assert(not ok, "remove of a missing entry should fail")
  assert(err and string.match(err, "not found"),
    "error should say the entry was not found, got: " .. tostring(err))
  assert(appender:close())

  -- The archive is untouched by the failed remove.
  local r = check.must(zip.open(p))
  assert(r:read("only.txt") == "here", "existing entry must survive a failed remove")
  assert(r:close())
end
test_appender_remove_missing_entry()

-- In-memory reading with from()

local function test_from_memory()
  local p = zip_path("memory_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("mem.txt", "In-memory content"))
  assert(w:close())

  local zip_data = check.must(fs.read(p), "should read zip data")

  local rr = check.must(zip.open_string(zip_data))
  local content = rr:read("mem.txt")
  assert(rr:close())

  assert(content == "In-memory content", "should read correct content from memory")
end
test_from_memory()

-- Error handling

local function test_reader_invalid_path()
  local r, err = zip.open("/nonexistent/path/to/file.zip")
  assert(r == nil, "should fail on invalid path")
  assert(err, "should return error message")
end
test_reader_invalid_path()

local function test_appender_creates_missing_archive()
  -- append has create-or-append semantics: a missing archive is created.
  local p = zip_path("appender_creates.zip")
  local appender = check.must(zip.open(p, {mode = "append"}), "appender should create a missing archive")
  assert(appender:add("x.txt", "hi"))
  assert(appender:close())

  local r = check.must(zip.open(p))
  assert(r:read("x.txt") == "hi", "created archive should contain the entry")
  assert(r:close())
end
test_appender_creates_missing_archive()

local function test_appender_invalid_path()
  local a, err = zip.open("/nonexistent/dir/x.zip", {mode = "append"})
  assert(a == nil, "should fail when the parent directory is missing")
  assert(err, "should return error message")
end
test_appender_invalid_path()

local function test_from_invalid_data()
  local r, err = zip.open_string("not valid zip data")
  assert(r == nil, "should fail on invalid data")
  assert(err, "should return error message")
end
test_from_invalid_data()

-- Compression options

local function test_add_with_options()
  local p = zip_path("options_test.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  -- Use larger content that will definitely compress
  local large_content = string.rep("Hello World! ", 100) -- 1300 bytes of repeated data
  local ok, err = w:add("stored.txt", large_content, {method = "store"})
  assert(ok, "should add with store method: " .. tostring(err))
  ok, err = w:add("deflated.txt", large_content, {method = "deflate"})
  assert(ok, "should add with deflate method: " .. tostring(err))
  assert(w:close())

  local r = check.must(zip.open(p))
  local stored_st = check.must(r:stat("stored.txt"), "should have stored.txt stat")
  local deflated_st = check.must(r:stat("deflated.txt"), "should have deflated.txt stat")
  assert(r:close())
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
  local writer = check.must(zip.open(p, {mode = "write", level = 9}))
  -- Add a file that benefits from compression
  local content = string.rep("AAAA", 1000) -- 4000 bytes of repeated data
  assert(writer:add("compressible.txt", content))
  assert(writer:close())

  -- Verify it compressed
  local r = check.must(zip.open(p))
  local st = check.must(r:stat("compressible.txt"), "should have stat")
  assert(r:close())

  assert(st.size == 4000, "uncompressed size should be 4000")
  assert(st.compressed_size < st.size, "compressed size should be smaller")
end
test_writer_with_compression_level()

-- Mode dispatch: one Archive answers every operation, and an operation
-- outside the archive's mode fails with an error naming the mode.

local function test_mode_field_and_default()
  local p = zip_path("mode_field.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  check.equal(w.mode, "write", "write archive should carry its mode")
  assert(w:add("m.txt", "m"))
  assert(w:close())

  local r = check.must(zip.open(p))
  check.equal(r.mode, "read", "open() should default to read mode")
  assert(r:close())
end
test_mode_field_and_default()

local function test_mode_errors_name_the_mode()
  local p = zip_path("mode_errors.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  local listed, list_err = w:list()
  assert(listed == nil, "list must not answer on a write archive")
  assert(list_err and list_err:find("requires a read archive", 1, true)
    and list_err:find("mode=write", 1, true),
    "list error should name both modes, got: " .. tostring(list_err))
  assert(w:add("a.txt", "a"))
  assert(w:close())

  local r = check.must(zip.open(p))
  local added, add_err = r:add("b.txt", "b")
  assert(not added, "add must not answer on a read archive")
  assert(add_err and add_err:find("requires a write or append archive", 1, true),
    "add error should name the modes that answer, got: " .. tostring(add_err))
  local removed, remove_err = r:remove("a.txt")
  assert(not removed, "remove must not answer on a read archive")
  assert(remove_err and remove_err:find("requires an append archive", 1, true),
    "remove error should name append, got: " .. tostring(remove_err))
  assert(r:close())
end
test_mode_errors_name_the_mode()

local function test_remove_needs_append_not_write()
  local p = zip_path("mode_remove_write.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("a.txt", "a"))
  local removed, remove_err = w:remove("a.txt")
  assert(not removed, "remove must not answer on a write archive")
  assert(remove_err and remove_err:find("requires an append archive", 1, true),
    "remove error should name append, got: " .. tostring(remove_err))
  assert(w:close())
end
test_remove_needs_append_not_write()

local function test_closed_archive_refuses_and_close_is_idempotent()
  local p = zip_path("closed.zip")
  local w = check.must(zip.open(p, {mode = "write"}))
  assert(w:add("a.txt", "a"))
  assert(w:close())
  assert(w:close(), "idempotent: a second close is a no-op that reports true")
  local ok, err = w:add("b.txt", "b")
  assert(not ok, "a closed archive must refuse operations")
  assert(err and err:find("closed", 1, true),
    "error should say the archive is closed, got: " .. tostring(err))
end
test_closed_archive_refuses_and_close_is_idempotent()

local function test_open_string_is_read_only()
  local a, err = zip.open_string("irrelevant", {mode = "write"})
  assert(a == nil, "open_string must reject a non-read mode")
  assert(err and err:find("read%-only"),
    "error should say read-only, got: " .. tostring(err))
end
test_open_string_is_read_only()
