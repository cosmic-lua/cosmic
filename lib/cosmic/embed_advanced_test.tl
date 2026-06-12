#!/usr/bin/env cosmic
-- advanced embed tests: extract, roundtrip, overwrite, permissions, corruption

local path = require("cosmo.path")
local unix = require("cosmo.unix")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")
local zip = require("cosmo.zip")
local embed = require("cosmic.embed")

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

-- Writer interface for crafting test archives
local record Writer
  add: function(self: Writer, name: string, content: string): boolean, string
  close: function(self: Writer)
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
]])

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

-- Test --extract rejects archive entries that escape the output directory
-- (zip-slip). A crafted archive with a "../" entry must not write outside
-- the target directory.
local function test_extract_rejects_path_traversal()
  -- cosmic's own zip writer refuses ".." names, so simulate an archive
  -- produced by another tool: write a same-length placeholder name and
  -- byte-patch it to a traversal name (no offsets change, so the zip stays
  -- valid). "XX/escaped.txt" -> "../escaped.txt".
  local safe = path.join(tmpdir, "patched.zip")
  local w = zip.open(safe, "w") as Writer
  assert(w, "should open zip for writing")
  w:add("XX/escaped.txt", "pwned")
  w:close()
  local raw = cosmo.Slurp(safe)
  local patched = (raw as string):gsub("XX/escaped%.txt", "../escaped.txt")
  local malicious = path.join(tmpdir, "malicious.zip")
  cosmo.Barf(malicious, patched)

  local outdir = path.join(tmpdir, "extract-target")
  local result = embed.extract(outdir, malicious)
  assert(not result.ok, "extract should reject path traversal entry")
  assert(result.message:match("unsafe path"), "expected unsafe path error, got: " .. result.message)

  -- The escaping file must not have been written next to the target dir.
  local escaped = path.join(tmpdir, "escaped.txt")
  assert(not path.isfile(escaped), "traversal file should not be written outside target")
end
test_extract_rejects_path_traversal()

-- FIX 2: collect_dir must not recurse into symlinked directories.
-- A symlink loop inside the embed dir must terminate without error.
local function test_embed_symlink_loop_terminates()
  local appdir = path.join(tmpdir, "symlinkloop")
  unix.makedirs(path.join(appdir, "sub"))
  cosmo.Barf(path.join(appdir, "sub", "real.txt"), "data")
  -- Create a cycle: sub/loop -> ..  (points back to appdir)
  unix.symlink("..", path.join(appdir, "sub", "loop"))

  -- embed.collect_dir is called internally; run via the module directly
  local result = embed.run({appdir}, path.join(tmpdir, "cosmic-symlinkloop"), cosmic)
  assert(result.ok, "embed of dir with symlink loop should succeed: " .. (result.message or ""))
  -- Only real.txt should be embedded, not any path through the loop
  local data = cosmo.Slurp(path.join(tmpdir, "cosmic-symlinkloop"))
  local reader = zip.from(data) as Reader
  local files = reader:list()
  for _, f in ipairs(files) do
    assert(not f:match("loop"), "embedded zip should not contain loop path: " .. f)
  end
  reader:close()
end
test_embed_symlink_loop_terminates()

-- FIX 2: a symlink to a file *outside* the embed dir must NOT be embedded.
local function test_embed_symlink_to_outside_file_skipped()
  -- Create a file outside the embed dir
  local outside = path.join(tmpdir, "outside_secret.txt")
  cosmo.Barf(outside, "secret-content")

  local appdir = path.join(tmpdir, "symlinkoutside")
  unix.makedirs(appdir)
  cosmo.Barf(path.join(appdir, "main.lua"), 'print("hi")\n')
  -- Symlink inside the embed dir pointing outside
  unix.symlink(outside, path.join(appdir, "leaked.txt"))

  local result = embed.run({appdir}, path.join(tmpdir, "cosmic-symlinkoutside"), cosmic)
  assert(result.ok, "embed should succeed even with outside symlink: " .. (result.message or ""))
  -- "leaked.txt" (the symlink) must not appear in the zip
  local data = cosmo.Slurp(path.join(tmpdir, "cosmic-symlinkoutside"))
  local reader = zip.from(data) as Reader
  local files = reader:list()
  for _, f in ipairs(files) do
    assert(not f:match("leaked"), "symlink to outside file should not be embedded: " .. f)
  end
  reader:close()
end
test_embed_symlink_to_outside_file_skipped()

print("All embed tests passed!")
