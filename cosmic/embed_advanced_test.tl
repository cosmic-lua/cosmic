#!/usr/bin/env cosmic
-- advanced embed tests: extract, roundtrip, overwrite, permissions, corruption

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local time = require("cosmic.time")
local child = require("cosmic.child")
local zip = require("cosmic.zip")
local embed = require("cosmic.embed")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Test --extract extracts zip contents
local function test_extract()
  local extractdir = fs.join(tmpdir, "extracted")

  local __r1 = check.must(check.must(child.start({cosmic, "--extract", extractdir})):wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "extract should succeed: " .. (out or ""))

  -- The entry and its argv, which every cosmic artifact carries.
  assert(fs.is_file(fs.join(extractdir, "main.lua")), "main.lua should be extracted")
  assert(fs.is_file(fs.join(extractdir, ".args")), ".args should be extracted")

  -- A directory, so extraction is shown to rebuild the tree and not
  -- just the root. `cosmic/` is the artifact's own modules; the base's
  -- `.lua/` is NOT the thing to assert here, because what a base
  -- contributes is the strip floor's business and a cosmic built on a
  -- bare runtime drops it.
  assert(fs.is_dir(fs.join(extractdir, "cosmic")), "cosmic/ should be extracted")
end
test_extract()

-- Test extract-then-embed roundtrip preserves file contents
local function test_extract_embed_roundtrip()
  -- Extract the cosmic binary
  local extractdir = fs.join(tmpdir, "roundtrip-extract")
  local __r2 = check.must(check.must(child.start({cosmic, "--extract", extractdir})):wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Read original main.lua from the zip
  local orig_data = fs.read(cosmic)
  local orig_reader = check.must(zip.open_bytes(orig_data))
  local orig_main = orig_reader:read("main.lua")
  assert(orig_main, "original should have main.lua")
  orig_reader:close()

  -- Read extracted main.lua from disk
  local extracted_main = fs.read(fs.join(extractdir, "main.lua"))
  assert(extracted_main == orig_main, "extracted main.lua should match original")

  -- Re-embed the extracted directory
  local output = fs.join(tmpdir, "roundtrip-output")
  local __r3 = check.must(check.must(child.start({cosmic, "--embed", extractdir, "--output", output})):wait())
  ok, out = __r3.ok, __r3.stdout
  assert(ok, "re-embed should succeed: " .. (out or ""))

  -- Read main.lua from the re-embedded binary
  local new_data = fs.read(output)
  local new_reader = check.must(zip.open_bytes(new_data))
  local new_main = new_reader:read("main.lua")
  assert(new_main == orig_main, "roundtripped main.lua should match original")
  new_reader:close()
end
test_extract_embed_roundtrip()

-- Test extract-modify-embed workflow
local function test_extract_modify_embed()
  -- Extract
  local extractdir = fs.join(tmpdir, "modify-extract")
  local __r4 = check.must(check.must(child.start({cosmic, "--extract", extractdir})):wait())
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Modify the entry — which is `main.user.lua` on an artifact whose
  -- `main.lua` is the embed wrapper, and `main.lua` otherwise.
  -- Overwriting a wrapper would destroy the boot the artifact needs, and
  -- embed refuses that combination rather than silently accepting it.
  local entry = fs.join(extractdir, "main.user.lua")
  if not fs.is_file(entry) then
    entry = fs.join(extractdir, "main.lua")
  end
  assert(fs.write(entry, 'io.write("modified\\n")\n'))

  -- Re-embed
  local output = fs.join(tmpdir, "modified-cosmic")
  local __r5 = check.must(check.must(child.start({cosmic, "--embed", extractdir, "--output", output})):wait())
  ok, out = __r5.ok, __r5.stdout
  assert(ok, "embed modified should succeed: " .. (out or ""))

  -- Run the modified executable
  local __r6 = check.must(check.must(child.start({output})):wait())
  ok, out = __r6.ok, __r6.stdout
  assert(ok, "modified executable should run: " .. (out or ""))
  assert(out:match("modified"), "should print modified output, got: " .. (out or ""))
end
test_extract_modify_embed()

-- Test that embed overwrites existing zip entries cleanly
local function test_embed_overwrites_cleanly()
  -- Read original zip file list
  local orig_data = fs.read(cosmic)
  local orig_reader = check.must(zip.open_bytes(orig_data))
  local orig_files: {string: boolean} = {}
  for _, entry in ipairs(orig_reader:list()) do
    -- Skip directory entries
    if entry.name:sub(-1) ~= "/" then
      orig_files[entry.name] = true
    end
  end
  orig_reader:close()

  -- Embed a directory that overrides main.lua
  local appdir = fs.join(tmpdir, "overwrite-app")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), 'print("new")\n'))

  local output = fs.join(tmpdir, "cosmic-overwrite")
  local __r7 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  -- The custom entry is wrapped: main.lua is the generated
  -- searcher wrapper; the user content lives at main.user.lua.
  local new_data = fs.read(output)
  local new_reader = check.must(zip.open_bytes(new_data))
  local new_main = new_reader:read("main.lua")
  assert(new_main and string.find(new_main, "cosmic-embed searcher wrapper", 1, true),
    "main.lua should be the embed wrapper: " .. tostring(new_main))
  local user_main = new_reader:read("main.user.lua")
  assert(user_main == 'print("new")\n', "main.user.lua should have the new content: " .. tostring(user_main))

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
  assert(fs.make_dirs(appdir))

  -- Create files with different modes
  local script = fs.join(appdir, "run.sh")
  local config = fs.join(appdir, "config.txt")
  local secret = fs.join(appdir, "secret.key")

  assert(fs.write(script, "#!/bin/sh\necho hello\n"))
  assert(fs.write(config, "setting=value\n"))
  assert(fs.write(secret, "private-key-data\n"))

  -- Set specific modes
  assert(fs.chmod(script, tonumber("755", 8)))
  assert(fs.chmod(config, tonumber("644", 8)))
  assert(fs.chmod(secret, tonumber("600", 8)))

  local output = fs.join(tmpdir, "cosmic-modes")
  local __r8 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  local ok, out = __r8.ok, __r8.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Check modes in the zip archive
  local data = fs.read(output)
  local reader = check.must(zip.open_bytes(data), "failed to open zip from data")

  local script_stat = check.must(reader:stat("run.sh"), "run.sh should exist in zip")
  local config_stat = check.must(reader:stat("config.txt"), "config.txt should exist in zip")
  local secret_stat = check.must(reader:stat("secret.key"), "secret.key should exist in zip")

  -- Check permission bits (mask with 0777 to get just permission bits)
  local script_mode = script_stat.mode & tonumber("777", 8)
  local config_mode = config_stat.mode & tonumber("777", 8)
  local secret_mode = secret_stat.mode & tonumber("777", 8)

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
  assert(fs.make_dirs(appdir))

  local script = fs.join(appdir, "run.sh")
  local secret = fs.join(appdir, "secret.key")

  assert(fs.write(script, "#!/bin/sh\necho hello\n"))
  assert(fs.write(secret, "private-key-data\n"))

  assert(fs.chmod(script, tonumber("755", 8)))
  assert(fs.chmod(secret, tonumber("600", 8)))

  local embedded = fs.join(tmpdir, "cosmic-extract-modes")
  local __r9 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", embedded})):wait())
  local ok, out = __r9.ok, __r9.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Extract to a new directory
  local extractdir = fs.join(tmpdir, "extracted-modes")
  local __r10 = check.must(check.must(child.start({embedded, "--extract", extractdir})):wait())
  ok, out = __r10.ok, __r10.stdout
  assert(ok, "extract should succeed: " .. (out or ""))

  -- Check modes of extracted files
  local script_stat = check.must(fs.stat(fs.join(extractdir, "run.sh")),
    "run.sh should exist after extract")
  local secret_stat = check.must(fs.stat(fs.join(extractdir, "secret.key")),
    "secret.key should exist after extract")

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
-- keeps the original inode valid for the running process.
local function test_embed_does_not_corrupt_running_process()
  -- Create a program that sleeps, then exercises code pages
  local appdir = fs.join(tmpdir, "running-app")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), [[
local time = require("cosmic.time")
-- Sleep to give the test time to overwrite the binary
time.sleep(1)
-- Exercise code paths that touch mmapped pages (string ops, table ops, format)
local t = {}
for i = 1, 100 do t[i] = string.format("item_%04d", i) end
local result = table.concat(t, ",")
-- Signal success
io.write("OK:" .. #result)
]]))

  local binary = fs.join(tmpdir, "cosmic-running")
  local __r11 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", binary})):wait())
  local ok, out = __r11.ok, __r11.stdout
  assert(ok, "initial embed should succeed: " .. (out or ""))

  -- Start the binary as a subprocess
  local handle = check.must(child.start({binary}))

  -- Wait briefly for the process to start and mmap its pages
  assert(time.sleep(0, 100000000)) -- 100ms

  -- Re-embed over the same path while the process is running.
  -- Without atomic write, this would corrupt the running process.
  local __r12 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", binary})):wait())
  local ok2, out2 = __r12.ok, __r12.stdout
  assert(ok2, "re-embed should succeed: " .. (out2 or ""))

  -- Wait for the original process to finish
  local __rh = check.must(handle:wait())
  local read_ok, stdout = __rh.ok, __rh.stdout

  -- The process should have exited cleanly, not crashed with SIGSEGV
  assert(read_ok, "running process should not crash after re-embed, got: " .. tostring(stdout))
  assert(stdout and stdout:match("^OK:"), "process should print OK, got: " .. tostring(stdout))
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
  local w = check.must(zip.create(safe), "should open zip for writing")
  assert(w:add("XX/escaped.txt", "pwned"))
  w:close()
  local raw = check.must(fs.read(safe))
  local patched = raw:gsub("XX/escaped%.txt", "../escaped.txt")
  local malicious = fs.join(tmpdir, "malicious.zip")
  assert(fs.write(malicious, patched))

  local outdir = fs.join(tmpdir, "extract-target")
  local result = embed.extract(outdir, malicious)
  assert(not result.ok, "extract should reject path traversal entry")
  assert(result.message:match("unsafe path"), "expected unsafe path error, got: " .. result.message)

  -- The escaping file must not have been written next to the target dir.
  local escaped = fs.join(tmpdir, "escaped.txt")
  assert(not fs.is_file(escaped), "traversal file should not be written outside target")
end
test_extract_rejects_path_traversal()

-- FIX 2: collect_dir must not recurse into symlinked directories.
-- A symlink loop inside the embed dir must terminate without error.
local function test_embed_symlink_loop_terminates()
  local appdir = fs.join(tmpdir, "symlinkloop")
  assert(fs.make_dirs(fs.join(appdir, "sub")))
  assert(fs.write(fs.join(appdir, "sub", "real.txt"), "data"))
  -- Create a cycle: sub/loop -> ..  (points back to appdir)
  assert(fs.symlink("..", fs.join(appdir, "sub", "loop")))

  -- embed.collect_dir is called internally; run via the module directly
  local result = embed.embed({appdir}, {output = fs.join(tmpdir, "cosmic-symlinkloop"), exe_path = cosmic})
  assert(result.ok, "embed of dir with symlink loop should succeed: " .. (result.message or ""))
  -- Only real.txt should be embedded, not any path through the loop
  local data = fs.read(fs.join(tmpdir, "cosmic-symlinkloop"))
  local reader = check.must(zip.open_bytes(data))
  local files = reader:list()
  for _, f in ipairs(files) do
    assert(not f.name:match("loop"), "embedded zip should not contain loop path: " .. f.name)
  end
  reader:close()
end
test_embed_symlink_loop_terminates()

-- FIX 2: a symlink to a file *outside* the embed dir must NOT be embedded.
local function test_embed_symlink_to_outside_file_skipped()
  -- Create a file outside the embed dir
  local outside = fs.join(tmpdir, "outside_secret.txt")
  assert(fs.write(outside, "secret-content"))

  local appdir = fs.join(tmpdir, "symlinkoutside")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), 'print("hi")\n'))
  -- Symlink inside the embed dir pointing outside
  assert(fs.symlink(outside, fs.join(appdir, "leaked.txt")))

  local result = embed.embed({appdir}, {output = fs.join(tmpdir, "cosmic-symlinkoutside"), exe_path = cosmic})
  assert(result.ok, "embed should succeed even with outside symlink: " .. (result.message or ""))
  -- "leaked.txt" (the symlink) must not appear in the zip
  local data = fs.read(fs.join(tmpdir, "cosmic-symlinkoutside"))
  local reader = check.must(zip.open_bytes(data))
  local files = reader:list()
  for _, f in ipairs(files) do
    assert(not f.name:match("leaked"), "symlink to outside file should not be embedded: " .. f.name)
  end
  reader:close()
end
test_embed_symlink_to_outside_file_skipped()

-- --exe operates on an existing app instead of the running executable
-- (F1): extract a produced app (restoring file modes), and layer
-- new files onto it, all without extract/re-embed gymnastics. Flag
-- order is free: --exe is collected before early-returning options.
local function test_exe_flag_extract_and_layer()
  local appdir = fs.join(tmpdir, "exeapp")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"),
      'print("v1", io.open("/zip/extra.txt") and "extra" or "noextra")\n'))
  assert(fs.write(fs.join(appdir, "tool.sh"), "#!/bin/sh\necho t\n"))
  assert(fs.chmod(fs.join(appdir, "tool.sh"), tonumber("755", 8)))

  local app1 = fs.join(tmpdir, "exe-app1")
  local __e1 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", app1})):wait())
  assert(__e1.ok, "embed app1: " .. tostring(__e1.stderr))

  -- Extract FROM the app (--exe after the early-returning --extract).
  local x = fs.join(tmpdir, "exe-x")
  local __e2 = check.must(check.must(child.start({cosmic, "--extract", x, "--exe", app1})):wait())
  assert(__e2.ok, "extract --exe: " .. tostring(__e2.stderr))
  local wrapper = fs.read(fs.join(x, "main.lua"))
  assert(wrapper and string.find(wrapper, "cosmic-embed searcher wrapper", 1, true),
    "extracted main.lua should be the wrapper")
  assert(fs.read(fs.join(x, "main.user.lua")), "user entry should extract")
  local st = check.must(fs.stat(fs.join(x, "tool.sh")), "tool.sh should extract")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("755", 8),
    "exec mode should be restored, got " .. string.format("%o", mode))

  -- Layer a file onto the existing app.
  local extra = fs.join(tmpdir, "extra.txt")
  assert(fs.write(extra, "x"))
  local app2 = fs.join(tmpdir, "exe-app2")
  local __e3 = check.must(check.must(
      child.start({cosmic, "--embed", extra, "--output", app2, "--exe", app1})):wait())
  assert(__e3.ok, "layer --exe: " .. tostring(__e3.stderr))
  local __e4 = check.must(check.must(child.start({app2})):wait())
  assert(__e4.ok and tostring(__e4.stdout):match("v1"),
    "layered app should run its entry: " .. tostring(__e4.stdout))
end
test_exe_flag_extract_and_layer()

print("All embed tests passed!")
