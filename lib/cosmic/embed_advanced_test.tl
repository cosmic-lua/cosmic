#!/usr/bin/env cosmic
-- advanced embed tests: extract, roundtrip, overwrite, permissions, corruption

local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs_types")
local cio = require("cosmic.io")
local time = require("cosmic.time")
local spawn = require("cosmic.child")
local zip = require("cosmic.zip")
local embed = require("cosmic.embed")

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
end

-- Writer interface for crafting test archives
local record Writer
  add: function(self: Writer, name: string, content: string): boolean, string
  close: function(self: Writer)
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

-- Test --extract extracts zip contents
local function test_extract()
  local extractdir = fs.join(tmpdir, "extracted")

  local ok, out = (spawn.spawn({cosmic, "--extract", extractdir}) as spawn.Handle):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- main.lua should be extracted
  assert(fs.isfile(fs.join(extractdir, "main.lua")), "main.lua should be extracted")

  -- .args should be extracted
  assert(fs.isfile(fs.join(extractdir, ".args")), ".args should be extracted")

  -- bundled libraries should be extracted
  assert(fs.isdir(fs.join(extractdir, ".lua")), ".lua directory should be extracted")
end
test_extract()

-- Test extract-then-embed roundtrip preserves file contents
local function test_extract_embed_roundtrip()
  -- Extract the cosmic binary
  local extractdir = fs.join(tmpdir, "roundtrip-extract")
  local ok, out = (spawn.spawn({cosmic, "--extract", extractdir}) as spawn.Handle):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Read original main.lua from the zip
  local orig_data = cio.slurp(cosmic)
  local orig_reader = zip.from(orig_data) as Reader
  local orig_main = orig_reader:read("main.lua")
  assert(orig_main, "original should have main.lua")
  orig_reader:close()

  -- Read extracted main.lua from disk
  local extracted_main = cio.slurp(fs.join(extractdir, "main.lua"))
  assert(extracted_main == orig_main, "extracted main.lua should match original")

  -- Re-embed the extracted directory
  local output = fs.join(tmpdir, "roundtrip-output")
  ok, out = (spawn.spawn({cosmic, "--embed", extractdir, "--output", output}) as spawn.Handle):read()
  assert(ok, "re-embed should succeed: " .. (out or ""))

  -- Read main.lua from the re-embedded binary
  local new_data = cio.slurp(output)
  local new_reader = zip.from(new_data) as Reader
  local new_main = new_reader:read("main.lua")
  assert(new_main == orig_main, "roundtripped main.lua should match original")
  new_reader:close()
end
test_extract_embed_roundtrip()

-- Test extract-modify-embed workflow
local function test_extract_modify_embed()
  -- Extract
  local extractdir = fs.join(tmpdir, "modify-extract")
  local ok, out = (spawn.spawn({cosmic, "--extract", extractdir}) as spawn.Handle):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Modify main.lua
  cio.barf(fs.join(extractdir, "main.lua"), 'io.write("modified\\n")\n')

  -- Re-embed
  local output = fs.join(tmpdir, "modified-cosmic")
  ok, out = (spawn.spawn({cosmic, "--embed", extractdir, "--output", output}) as spawn.Handle):read()
  assert(ok, "embed modified should succeed: " .. (out or ""))

  -- Run the modified executable
  ok, out = (spawn.spawn({output}) as spawn.Handle):read()
  assert(ok, "modified executable should run: " .. (out or ""))
  assert(out:match("modified"), "should print modified output, got: " .. (out or ""))
end
test_extract_modify_embed()

-- Test that embed overwrites existing zip entries cleanly
local function test_embed_overwrites_cleanly()
  -- Read original zip file list
  local orig_data = cio.slurp(cosmic)
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
  local appdir = fs.join(tmpdir, "overwrite-app")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), 'print("new")\n')

  local output = fs.join(tmpdir, "cosmic-overwrite")
  local ok, out = (spawn.spawn({cosmic, "--embed", appdir, "--output", output}) as spawn.Handle):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- The new zip should have main.lua with the new content
  local new_data = cio.slurp(output)
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
  local appdir = fs.join(tmpdir, "modeapp")
  fs.makedirs(appdir)

  -- Create files with different modes
  local script = fs.join(appdir, "run.sh")
  local config = fs.join(appdir, "config.txt")
  local secret = fs.join(appdir, "secret.key")

  cio.barf(script, "#!/bin/sh\necho hello\n")
  cio.barf(config, "setting=value\n")
  cio.barf(secret, "private-key-data\n")

  -- Set specific modes
  fs.chmod(script, tonumber("755", 8))
  fs.chmod(config, tonumber("644", 8))
  fs.chmod(secret, tonumber("600", 8))

  local output = fs.join(tmpdir, "cosmic-modes")
  local ok, out = (spawn.spawn({cosmic, "--embed", appdir, "--output", output}) as spawn.Handle):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Check modes in the zip archive
  local data = cio.slurp(output)
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
  local appdir = fs.join(tmpdir, "extract-modeapp")
  fs.makedirs(appdir)

  local script = fs.join(appdir, "run.sh")
  local secret = fs.join(appdir, "secret.key")

  cio.barf(script, "#!/bin/sh\necho hello\n")
  cio.barf(secret, "private-key-data\n")

  fs.chmod(script, tonumber("755", 8))
  fs.chmod(secret, tonumber("600", 8))

  local embedded = fs.join(tmpdir, "cosmic-extract-modes")
  local ok, out = (spawn.spawn({cosmic, "--embed", appdir, "--output", embedded}) as spawn.Handle):read()
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Extract to a new directory
  local extractdir = fs.join(tmpdir, "extracted-modes")
  ok, out = (spawn.spawn({embedded, "--extract", extractdir}) as spawn.Handle):read()
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Check modes of extracted files
  local script_stat = fs.stat(fs.join(extractdir, "run.sh"))
  local secret_stat = fs.stat(fs.join(extractdir, "secret.key"))

  assert(script_stat, "run.sh should exist after extract")
  assert(secret_stat, "secret.key should exist after extract")

  local script_mode = (script_stat as fs_types.Stat):mode() & tonumber("777", 8)
  local secret_mode = (secret_stat as fs_types.Stat):mode() & tonumber("777", 8)

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
  local appdir = fs.join(tmpdir, "running-app")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), [[
local time = require("cosmic.time")
-- Sleep to give the test time to overwrite the binary
time.sleep(1)
-- Exercise code paths that touch mmapped pages (string ops, table ops, format)
local t = {}
for i = 1, 100 do t[i] = string.format("item_%04d", i) end
local result = table.concat(t, ",")
-- Signal success
io.write("OK:" .. #result)
]])

  local binary = fs.join(tmpdir, "cosmic-running")
  local ok, out = (spawn.spawn({cosmic, "--embed", appdir, "--output", binary}) as spawn.Handle):read()
  assert(ok, "initial embed should succeed: " .. (out or ""))

  -- Start the binary as a subprocess
  local handle = (spawn.spawn({binary}) as spawn.Handle)

  -- Wait briefly for the process to start and mmap its pages
  time.sleep(0, 100000000) -- 100ms

  -- Re-embed over the same path while the process is running.
  -- Without atomic write, this would corrupt the running process.
  local ok2, out2 = (spawn.spawn({cosmic, "--embed", appdir, "--output", binary}) as spawn.Handle):read()
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
  local safe = fs.join(tmpdir, "patched.zip")
  local w = zip.open(safe, "w") as Writer
  assert(w, "should open zip for writing")
  w:add("XX/escaped.txt", "pwned")
  w:close()
  local raw = cio.slurp(safe)
  local patched = (raw as string):gsub("XX/escaped%.txt", "../escaped.txt")
  local malicious = fs.join(tmpdir, "malicious.zip")
  cio.barf(malicious, patched)

  local outdir = fs.join(tmpdir, "extract-target")
  local result = embed.extract(outdir, malicious)
  assert(not result.ok, "extract should reject path traversal entry")
  assert(result.message:match("unsafe path"), "expected unsafe path error, got: " .. result.message)

  -- The escaping file must not have been written next to the target dir.
  local escaped = fs.join(tmpdir, "escaped.txt")
  assert(not fs.isfile(escaped), "traversal file should not be written outside target")
end
test_extract_rejects_path_traversal()

-- FIX 2: collect_dir must not recurse into symlinked directories.
-- A symlink loop inside the embed dir must terminate without error.
local function test_embed_symlink_loop_terminates()
  local appdir = fs.join(tmpdir, "symlinkloop")
  fs.makedirs(fs.join(appdir, "sub"))
  cio.barf(fs.join(appdir, "sub", "real.txt"), "data")
  -- Create a cycle: sub/loop -> ..  (points back to appdir)
  fs.symlink("..", fs.join(appdir, "sub", "loop"))

  -- embed.collect_dir is called internally; run via the module directly
  local result = embed.run({appdir}, fs.join(tmpdir, "cosmic-symlinkloop"), cosmic)
  assert(result.ok, "embed of dir with symlink loop should succeed: " .. (result.message or ""))
  -- Only real.txt should be embedded, not any path through the loop
  local data = cio.slurp(fs.join(tmpdir, "cosmic-symlinkloop"))
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
  local outside = fs.join(tmpdir, "outside_secret.txt")
  cio.barf(outside, "secret-content")

  local appdir = fs.join(tmpdir, "symlinkoutside")
  fs.makedirs(appdir)
  cio.barf(fs.join(appdir, "main.lua"), 'print("hi")\n')
  -- Symlink inside the embed dir pointing outside
  fs.symlink(outside, fs.join(appdir, "leaked.txt"))

  local result = embed.run({appdir}, fs.join(tmpdir, "cosmic-symlinkoutside"), cosmic)
  assert(result.ok, "embed should succeed even with outside symlink: " .. (result.message or ""))
  -- "leaked.txt" (the symlink) must not appear in the zip
  local data = cio.slurp(fs.join(tmpdir, "cosmic-symlinkoutside"))
  local reader = zip.from(data) as Reader
  local files = reader:list()
  for _, f in ipairs(files) do
    assert(not f:match("leaked"), "symlink to outside file should not be embedded: " .. f)
  end
  reader:close()
end
test_embed_symlink_to_outside_file_skipped()

print("All embed tests passed!")
