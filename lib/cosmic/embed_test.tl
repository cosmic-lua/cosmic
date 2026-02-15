#!/usr/bin/env cosmic
-- test cosmic --embed and --extract options

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
  stat: function(self: Reader, name: string): Stat | nil
  close: function(self: Reader)
end

-- Stat record for file metadata
local record Stat
  mode: number
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

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
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

  local ok, out = spawn.spawn({cosmic, "--embed", file1, "--embed", file2, "--output", output}):read()
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

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
  assert(ok, "cosmic --embed with custom output path should succeed: " .. (out or ""))

  local stat = unix.stat(output)
  assert(stat, "custom output path should exist")
end
test_embed_custom_output()

-- Test error on missing input file
local function test_embed_missing_file()
  local output = path.join(tmpdir, "cosmic-missing")
  local ok, _out = spawn.spawn({cosmic, "--embed", "/nonexistent/file.txt", "--output", output}):read()
  assert(not ok, "cosmic --embed should fail on missing file")
end
test_embed_missing_file()

-- Test embedding lua files
local function test_embed_lua_file()
  local modfile = write_temp("mymod.lua", [[return { value = 42 }]])
  local output = path.join(tmpdir, "cosmic-lua")

  local ok, out = spawn.spawn({cosmic, "--embed", modfile, "--output", output}):read()
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

  local ok, out = spawn.spawn({cosmic, "--embed", input, "--output", output}):read()
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

-- Test embedding a directory
local function test_embed_directory()
  -- Create a directory structure
  local appdir = path.join(tmpdir, "testapp")
  unix.makedirs(path.join(appdir, "lib"))
  cosmo.Barf(path.join(appdir, "main.lua"), 'print("hello")\n')
  cosmo.Barf(path.join(appdir, "lib/util.lua"), 'return {x=1}\n')
  cosmo.Barf(path.join(appdir, "data.txt"), "some data")

  local output = path.join(tmpdir, "cosmic-dir")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed directory should succeed: " .. (out or ""))

  -- Verify files are stored relative to directory root
  local data = cosmo.Slurp(output)
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
  local appdir = path.join(tmpdir, "nested")
  unix.makedirs(path.join(appdir, "a/b/c"))
  cosmo.Barf(path.join(appdir, "top.txt"), "top")
  cosmo.Barf(path.join(appdir, "a/mid.txt"), "mid")
  cosmo.Barf(path.join(appdir, "a/b/c/deep.txt"), "deep")

  local output = path.join(tmpdir, "cosmic-nested")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed nested directory should succeed: " .. (out or ""))

  local data = cosmo.Slurp(output)
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
  local appdir = path.join(tmpdir, "mixapp")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), 'print("mixed")\n')

  local extra = write_temp("extra.txt", "extra content")
  local output = path.join(tmpdir, "cosmic-mixed")

  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--embed", extra, "--output", output}):read()
  assert(ok, "embed mixed should succeed: " .. (out or ""))

  local data = cosmo.Slurp(output)
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
  local appdir = path.join(tmpdir, "runapp")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), 'io.write("it works\\n")\n')

  local output = path.join(tmpdir, "cosmic-runapp")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Run the custom executable
  ok, out = spawn.spawn({output}):read()
  assert(ok, "custom executable should run: " .. (out or ""))
  assert(out:match("it works"), "should print expected output, got: " .. (out or ""))
end
test_embed_directory_executable()

-- Test --extract extracts zip contents
local function test_extract()
  local extractdir = path.join(tmpdir, "extracted")

  local ok, out = spawn.spawn({cosmic, "--extract", extractdir}):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- main.lua should be extracted
  assert(path.isfile(path.join(extractdir, "main.lua")), "main.lua should be extracted")

  -- .args should be extracted
  assert(path.isfile(path.join(extractdir, ".args")), ".args should be extracted")

  -- bundled libraries should be extracted
  assert(path.isdir(path.join(extractdir, ".lua")), ".lua directory should be extracted")
end
test_extract()

-- Test extract-then-embed roundtrip preserves file contents
local function test_extract_embed_roundtrip()
  -- Extract the cosmic binary
  local extractdir = path.join(tmpdir, "roundtrip-extract")
  local ok, out = spawn.spawn({cosmic, "--extract", extractdir}):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Read original main.lua from the zip
  local orig_data = cosmo.Slurp(cosmic)
  local orig_reader = zip.from(orig_data) as Reader
  local orig_main = orig_reader:read("main.lua")
  assert(orig_main, "original should have main.lua")
  orig_reader:close()

  -- Read extracted main.lua from disk
  local extracted_main = cosmo.Slurp(path.join(extractdir, "main.lua"))
  assert(extracted_main == orig_main, "extracted main.lua should match original")

  -- Re-embed the extracted directory
  local output = path.join(tmpdir, "roundtrip-output")
  ok, out = spawn.spawn({cosmic, "--embed", extractdir, "--output", output}):read()
  assert(ok, "re-embed should succeed: " .. (out or ""))

  -- Read main.lua from the re-embedded binary
  local new_data = cosmo.Slurp(output)
  local new_reader = zip.from(new_data) as Reader
  local new_main = new_reader:read("main.lua")
  assert(new_main == orig_main, "roundtripped main.lua should match original")
  new_reader:close()
end
test_extract_embed_roundtrip()

-- Test extract-modify-embed workflow
local function test_extract_modify_embed()
  -- Extract
  local extractdir = path.join(tmpdir, "modify-extract")
  local ok, out = spawn.spawn({cosmic, "--extract", extractdir}):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Modify main.lua
  cosmo.Barf(path.join(extractdir, "main.lua"), 'io.write("modified\\n")\n')

  -- Re-embed
  local output = path.join(tmpdir, "modified-cosmic")
  ok, out = spawn.spawn({cosmic, "--embed", extractdir, "--output", output}):read()
  assert(ok, "embed modified should succeed: " .. (out or ""))

  -- Run the modified executable
  ok, out = spawn.spawn({output}):read()
  assert(ok, "modified executable should run: " .. (out or ""))
  assert(out:match("modified"), "should print modified output, got: " .. (out or ""))
end
test_extract_modify_embed()

-- Test that embed overwrites existing zip entries cleanly
local function test_embed_overwrites_cleanly()
  -- Read original zip file list
  local orig_data = cosmo.Slurp(cosmic)
  local orig_reader = zip.from(orig_data) as Reader
  local orig_files: {string: boolean} = {}
  for _, name in ipairs(orig_reader:list()) do
    -- Skip directory entries
    if name:sub(-1) ~= "/" then
      orig_files[name] = true
    end
  end
  orig_reader:close()

  -- Embed a directory that overrides main.lua
  local appdir = path.join(tmpdir, "overwrite-app")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), 'print("new")\n')

  local output = path.join(tmpdir, "cosmic-overwrite")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- The new zip should have main.lua with the new content
  local new_data = cosmo.Slurp(output)
  local new_reader = zip.from(new_data) as Reader
  local new_main = new_reader:read("main.lua")
  assert(new_main == 'print("new")\n', "main.lua should have new content: " .. tostring(new_main))

  -- All original files should still be present
  for name in pairs(orig_files) do
    local content = new_reader:read(name)
    assert(content, "original file should still be accessible: " .. name)
  end

  new_reader:close()
end
test_embed_overwrites_cleanly()

-- Test that file modes are preserved in the zip archive
local function test_embed_preserves_file_modes()
  local appdir = path.join(tmpdir, "modeapp")
  unix.makedirs(appdir)

  -- Create files with different modes
  local script = path.join(appdir, "run.sh")
  local config = path.join(appdir, "config.txt")
  local secret = path.join(appdir, "secret.key")

  cosmo.Barf(script, "#!/bin/sh\necho hello\n")
  cosmo.Barf(config, "setting=value\n")
  cosmo.Barf(secret, "private-key-data\n")

  -- Set specific modes
  unix.chmod(script, tonumber("755", 8))
  unix.chmod(config, tonumber("644", 8))
  unix.chmod(secret, tonumber("600", 8))

  local output = path.join(tmpdir, "cosmic-modes")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", output}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Check modes in the zip archive
  local data = cosmo.Slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local script_stat = reader:stat("run.sh")
  local config_stat = reader:stat("config.txt")
  local secret_stat = reader:stat("secret.key")

  assert(script_stat, "run.sh should exist in zip")
  assert(config_stat, "config.txt should exist in zip")
  assert(secret_stat, "secret.key should exist in zip")

  -- Check permission bits (mask with 0777 to get just permission bits)
  local script_mode = (script_stat as Stat).mode & tonumber("777", 8)
  local config_mode = (config_stat as Stat).mode & tonumber("777", 8)
  local secret_mode = (secret_stat as Stat).mode & tonumber("777", 8)

  assert(script_mode == tonumber("755", 8),
    "run.sh should have mode 755, got " .. string.format("%o", script_mode))
  assert(config_mode == tonumber("644", 8),
    "config.txt should have mode 644, got " .. string.format("%o", config_mode))
  assert(secret_mode == tonumber("600", 8),
    "secret.key should have mode 600, got " .. string.format("%o", secret_mode))

  reader:close()
end
test_embed_preserves_file_modes()

-- Test that file modes are restored on extract
local function test_extract_preserves_file_modes()
  -- First embed files with specific modes
  local appdir = path.join(tmpdir, "extract-modeapp")
  unix.makedirs(appdir)

  local script = path.join(appdir, "run.sh")
  local secret = path.join(appdir, "secret.key")

  cosmo.Barf(script, "#!/bin/sh\necho hello\n")
  cosmo.Barf(secret, "private-key-data\n")

  unix.chmod(script, tonumber("755", 8))
  unix.chmod(secret, tonumber("600", 8))

  local embedded = path.join(tmpdir, "cosmic-extract-modes")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", embedded}):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Extract to a new directory
  local extractdir = path.join(tmpdir, "extracted-modes")
  ok, out = spawn.spawn({embedded, "--extract", extractdir}):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Check modes of extracted files
  local script_stat = unix.stat(path.join(extractdir, "run.sh"))
  local secret_stat = unix.stat(path.join(extractdir, "secret.key"))

  assert(script_stat, "run.sh should exist after extract")
  assert(secret_stat, "secret.key should exist after extract")

  local script_mode = script_stat:mode() & tonumber("777", 8)
  local secret_mode = secret_stat:mode() & tonumber("777", 8)

  assert(script_mode == tonumber("755", 8),
    "run.sh should have mode 755 after extract, got " .. string.format("%o", script_mode))
  assert(secret_mode == tonumber("600", 8),
    "secret.key should have mode 600 after extract, got " .. string.format("%o", secret_mode))
end
test_extract_preserves_file_modes()

-- Test that embed does not corrupt a running process.
-- The APE loader mmaps code pages from the executable via MAP_PRIVATE.
-- If embed wrote directly to the output path, the running process would
-- get corrupted pages and crash (SIGSEGV). Atomic rename via mkstemp
-- ensures the old inode stays valid for the running process.
local function test_embed_does_not_corrupt_running_process()
  -- Create a program that sleeps, then exercises code pages
  local appdir = path.join(tmpdir, "running-app")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), [[
local unix = require("cosmo.unix")
-- Sleep to give the test time to overwrite the binary
unix.nanosleep(1)
-- Exercise code paths that touch mmapped pages (string ops, table ops, format)
local t = {}
for i = 1, 100 do t[i] = string.format("item_%04d", i) end
local result = table.concat(t, ",")
-- Signal success
io.write("OK:" .. #result)
]]
  )

  local binary = path.join(tmpdir, "cosmic-running")
  local ok, out = spawn.spawn({cosmic, "--embed", appdir, "--output", binary}):read()
  assert(ok, "initial embed should succeed: " .. (out or ""))

  -- Start the binary as a subprocess
  local handle = spawn.spawn({binary})

  -- Wait briefly for the process to start and mmap its pages
  unix.nanosleep(0, 100000000) -- 100ms

  -- Re-embed over the same path while the process is running.
  -- Without atomic write, this would corrupt the running process.
  local ok2, out2 = spawn.spawn({cosmic, "--embed", appdir, "--output", binary}):read()
  assert(ok2, "re-embed should succeed: " .. (out2 or ""))

  -- Wait for the original process to finish
  local read_ok, stdout = handle:read()

  -- The process should have exited cleanly, not crashed with SIGSEGV
  assert(read_ok, "running process should not crash after re-embed, got: " .. tostring(stdout))
  assert(stdout and (stdout as string):match("^OK:"), "process should print OK, got: " .. tostring(stdout))
end
test_embed_does_not_corrupt_running_process()

print("All embed tests passed!")
