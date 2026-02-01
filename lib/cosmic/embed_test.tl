#!/usr/bin/env cosmic
-- test cosmic --embed option

local path = require("cosmo.path")
local unix = require("cosmo.unix")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")
local zip = require("cosmo.zip")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Local declaration of Reader interface for type casting
local record Reader
  list: function(self: Reader): {string}
  read: function(self: Reader, name: string): string | nil, string | nil
  close: function(self: Reader)
end

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  local dir = path.dirname(filepath)
  if dir ~= tmpdir then
    unix.makedirs(dir)
  end
  cosmo.Barf(filepath, content)
  return filepath
end

-- Test basic embed of single file
local function test_embed_single_file()
  local input = write_temp("hello.txt", "hello world")
  local output = path.join(tmpdir, "cosmic-single")

  local ok, out = spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "cosmic --embed should succeed: " .. (out or ""))

  -- Verify output exists and is executable
  local stat = unix.stat(output)
  assert(stat, "output file should exist")
  assert(stat:mode() & 73 ~= 0, "output should be executable")

  -- Verify file is in the zip
  local data = cosmo.Slurp(output)
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
  local output = path.join(tmpdir, "cosmic-multi")

  local ok, out = spawn({cosmic, "--embed", file1, "--embed", file2, "--output", output}):read()
  assert(ok, "cosmic --embed with multiple files should succeed: " .. (out or ""))

  local data = cosmo.Slurp(output)
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
  local output = path.join(tmpdir, "subdir/myapp")
  unix.makedirs(path.dirname(output))

  local ok, out = spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "cosmic --embed with custom output path should succeed: " .. (out or ""))

  local stat = unix.stat(output)
  assert(stat, "custom output path should exist")
end
test_embed_custom_output()

-- Test error on missing input file
local function test_embed_missing_file()
  local output = path.join(tmpdir, "cosmic-missing")
  local ok, _out = spawn({cosmic, "--embed", "/nonexistent/file.txt", "--output", output}):read()
  assert(not ok, "cosmic --embed should fail on missing file")
end
test_embed_missing_file()

-- Test embedding lua files
local function test_embed_lua_file()
  local modfile = write_temp("mymod.lua", [[return { value = 42 }]])
  local output = path.join(tmpdir, "cosmic-lua")

  local ok, out = spawn({cosmic, "--embed", modfile, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Verify the lua file is in the zip with correct content
  local data = cosmo.Slurp(output)
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
  local output = path.join(tmpdir, "cosmic-binary")

  local ok, out = spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "embed binary should succeed: " .. (out or ""))

  local data = cosmo.Slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader
  local name = input:gsub("^/+", "")
  local content = reader:read(name)
  assert(content == binary, "binary content should be preserved exactly")
  reader:close()
end
test_embed_binary_file()

print("All embed tests passed!")
