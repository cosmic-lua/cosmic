#!/usr/bin/env cosmic
-- test cosmic --embed and --extract options

local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local spawn = require("cosmic.child")
local zip = require("cosmic.zip")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Local declaration of Reader interface for type casting
local record Reader
  list: function(self: Reader): {string}
  read: function(self: Reader, name: string): string | nil, string | nil
  stat: function(self: Reader, name: string): Stat | nil
  close: function(self: Reader)
end

-- Stat record for file metadata
local record Stat
  mode: number
  method: number
  size: number
  compressed_size: number
end

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  local dir = fs.dirname(filepath)
  if dir ~= tmpdir then
    fs.makedirs(dir)
  end
  cio.barf(filepath, content)
  return filepath
end

-- Test basic embed of single file
local function test_embed_single_file()
  local input = write_temp("hello.txt", "hello world")
  local output = fs.join(tmpdir, "cosmic-single")

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "cosmic --embed should succeed: " .. (out or ""))

  -- Verify output exists and is executable
  local stat = fs.stat(output)
  assert(stat, "output file should exist")
  assert(stat:mode() & 73 ~= 0, "output should be executable")

  -- Verify file is in the zip
  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader
  local files = reader:list()

  local found = false
  local expected_name = input:gsub("^/+", "")
  for _, f in ipairs(files) do
    if f == expected_name then
      found = true
      break
    end
  end
  assert(found, "embedded file should be in zip: " .. expected_name)

  -- Verify content is correct
  local content = reader:read(expected_name)
  assert(content == "hello world", "embedded content should match")
  reader:close()
end
test_embed_single_file()

-- Test embed multiple files
local function test_embed_multiple_files()
  local file1 = write_temp("multi/one.txt", "content one")
  local file2 = write_temp("multi/two.txt", "content two")
  local output = fs.join(tmpdir, "cosmic-multi")

  local ok, out = spawn.spawn({cosmic, "--embed", file1, "--embed", file2, "--output", output}):read()
  assert(ok, "cosmic --embed with multiple files should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local name1 = file1:gsub("^/+", "")
  local name2 = file2:gsub("^/+", "")

  local c1 = reader:read(name1)
  local c2 = reader:read(name2)
  assert(c1 == "content one", "first file content should match")
  assert(c2 == "content two", "second file content should match")
  reader:close()
end
test_embed_multiple_files()

-- Test custom output path (covers the output option)
local function test_embed_custom_output()
  local input = write_temp("custom.txt", "custom content")
  local output = fs.join(tmpdir, "subdir/myapp")
  fs.makedirs(fs.dirname(output))

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "cosmic --embed with custom output path should succeed: " .. (out or ""))

  local stat = fs.stat(output)
  assert(stat, "custom output path should exist")
end
test_embed_custom_output()

-- Test error on missing input file
local function test_embed_missing_file()
  local output = fs.join(tmpdir, "cosmic-missing")
  local ok, _out = spawn.spawn({cosmic, "--embed", "/nonexistent/file.txt", "--output", output}):read()
  assert(not ok, "cosmic --embed should fail on missing file")
end
test_embed_missing_file()

-- Test embedding lua files
local function test_embed_lua_file()
  local modfile = write_temp("mymod.lua", [[return { value = 42 }]])
  local output = fs.join(tmpdir, "cosmic-lua")

  local ok, out = spawn.spawn({cosmic, "--embed", modfile, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Verify the lua file is in the zip with correct content
  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader
  local name = modfile:gsub("^/+", "")
  local content = reader:read(name)
  assert(content == [[return { value = 42 }]], "lua content should be preserved")
  reader:close()
end
test_embed_lua_file()

-- Test binary file embedding
local function test_embed_binary_file()
  -- Create a file with binary content
  local binary = "\x00\x01\x02\xff\xfe\xfd"
  local input = write_temp("binary.bin", binary)
  local output = fs.join(tmpdir, "cosmic-binary")

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "embed binary should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader
  local name = input:gsub("^/+", "")
  local content = reader:read(name)
  assert(content == binary, "binary content should be preserved exactly")
  reader:close()
end
test_embed_binary_file()

-- Test embedding a directory
local function test_embed_directory()
  -- Create a directory structure
  local appdir = fs.join(tmpdir, "testapp")
  fs.makedirs(fs.join(appdir, "lib"))
  cio.barf(fs.join(appdir, "main.lua"), 'print("hello")\n')
  cio.barf(fs.join(appdir, "lib/util.lua"), 'return {x=1}\n')
  cio.barf(fs.join(appdir, "data.txt"), "some data")

  local output = fs.join(tmpdir, "cosmic-dir")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed directory should succeed: " .. (out or ""))

  -- Verify files are stored relative to directory root
  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local c1 = reader:read("main.lua")
  assert(c1 == 'print("hello")\n', "main.lua should be at zip root: " .. tostring(c1))

  local c2 = reader:read("lib/util.lua")
  assert(c2 == 'return {x=1}\n', "lib/util.lua should be relative")

  local c3 = reader:read("data.txt")
  assert(c3 == "some data", "data.txt should be at zip root")

  reader:close()
end
test_embed_directory()

-- Test embedding a directory with nested subdirectories
local function test_embed_nested_directory()
  local appdir = fs.join(tmpdir, "nested")
  fs.makedirs(fs.join(appdir, "a/b/c"))
  cio.barf(fs.join(appdir, "top.txt"), "top")
  cio.barf(fs.join(appdir, "a/mid.txt"), "mid")
  cio.barf(fs.join(appdir, "a/b/c/deep.txt"), "deep")

  local output = fs.join(tmpdir, "cosmic-nested")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed nested directory should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  assert(reader:read("top.txt") == "top", "top-level file")
  assert(reader:read("a/mid.txt") == "mid", "mid-level file")
  assert(reader:read("a/b/c/deep.txt") == "deep", "deeply nested file")
  reader:close()
end
test_embed_nested_directory()

-- Test mixing directory and file embedding
local function test_embed_mixed()
  local appdir = fs.join(tmpdir, "mixapp")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), 'print("mixed")\n')

  local extra = write_temp("extra.txt", "extra content")
  local output = fs.join(tmpdir, "cosmic-mixed")

  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--embed", extra, "--output", output}):read()
  assert(ok, "embed mixed should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local c1 = reader:read("main.lua")
  assert(c1 == 'print("mixed")\n', "directory file should be present")

  local extra_name = extra:gsub("^/+", "")
  local c2 = reader:read(extra_name)
  assert(c2 == "extra content", "individual file should be present")
  reader:close()
end
test_embed_mixed()

-- Test that embedded directory produces a working executable
local function test_embed_directory_executable()
  local appdir = fs.join(tmpdir, "runapp")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), 'io.write("it works\\n")\n')

  local output = fs.join(tmpdir, "cosmic-runapp")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Run the custom executable
  ok, out = spawn.spawn({output}):read()
  assert(ok, "custom executable should run: " .. (out or ""))
  assert(out:match("it works"), "should print expected output, got: " .. (out or ""))
end
test_embed_directory_executable()

-- Test that embedded files use deflate compression (method=8)
local function test_embed_uses_deflate()
  -- Use compressible content (repeated pattern) to ensure deflate is applied
  local compressible = string.rep("abcdefghij", 100)
  local input = write_temp("deflate_test.txt", compressible)
  local output = fs.join(tmpdir, "cosmic-deflate")

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local name = input:gsub("^/+", "")
  local st = reader:stat(name)
  assert(st ~= nil, "stat should return metadata for embedded file")
  local stat = st as Stat
  assert(stat.method == 8,
    "embedded file should use deflate (method=8), got: " .. tostring(stat.method))
  assert(stat.compressed_size < stat.size,
    "deflate should reduce size: " .. tostring(stat.compressed_size) .. " >= " .. tostring(stat.size))
  reader:close()
end
test_embed_uses_deflate()
