#!/usr/bin/env cosmic
-- test cosmic --embed and --extract options

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local zip = require("cosmic.zip")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  local dir = fs.dirname(filepath)
  if dir ~= tmpdir then
    assert(fs.make_dirs(dir))
  end
  assert(fs.write(filepath, content))
  return filepath
end

-- Test basic embed of single file
local function test_embed_single_file()
  local input = write_temp("hello.txt", "hello world")
  local output = fs.join(tmpdir, "cosmic-single")

  local __r1 = check.must(check.must(child.start({cosmic, "--embed", input, "--output", output})):wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --embed should succeed: " .. (out or ""))

  -- Verify output exists and is executable
  local stat = check.must(fs.stat(output), "output file should exist")
  assert(stat:mode() & 73 ~= 0, "output should be executable")

  -- Verify file is in the zip
  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")
  local files = check.must(reader:list())

  local found = false
  local expected_name = input:gsub("^/+", "")
  for _, f in ipairs(files) do
    if f.name == expected_name then
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

  local __r2 = check.must(check.must(child.start({cosmic, "--embed", file1, "--embed", file2, "--output", output})):wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic --embed with multiple files should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

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
  assert(fs.make_dirs(fs.dirname(output)))

  local __r3 = check.must(check.must(child.start({cosmic, "--embed", input, "--output", output})):wait())
  local ok, out = __r3.ok, __r3.stdout
  assert(ok, "cosmic --embed with custom output path should succeed: " .. (out or ""))

  local stat = fs.stat(output)
  assert(stat, "custom output path should exist")
end
test_embed_custom_output()

-- Test error on missing input file
local function test_embed_missing_file()
  local output = fs.join(tmpdir, "cosmic-missing")
  local __r4 = check.must(check.must(child.start({cosmic, "--embed", "/nonexistent/file.txt", "--output", output})):wait())
  local ok, _out = __r4.ok, __r4.stdout
  assert(not ok, "cosmic --embed should fail on missing file")
end
test_embed_missing_file()

-- Test embedding lua files
local function test_embed_lua_file()
  local modfile = write_temp("mymod.lua", [[return { value = 42 }]])
  local output = fs.join(tmpdir, "cosmic-lua")

  local __r5 = check.must(check.must(child.start({cosmic, "--embed", modfile, "--output", output})):wait())
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Verify the lua file is in the zip with correct content
  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")
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

  local __r6 = check.must(check.must(child.start({cosmic, "--embed", input, "--output", output})):wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "embed binary should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")
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
  assert(fs.make_dirs(fs.join(appdir, "lib")))
  assert(fs.write(fs.join(appdir, "main.lua"), 'print("hello")\n'))
  assert(fs.write(fs.join(appdir, "lib/util.lua"), 'return {x=1}\n'))
  assert(fs.write(fs.join(appdir, "data.txt"), "some data"))

  local output = fs.join(tmpdir, "cosmic-dir")
  local __r7 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "embed directory should succeed: " .. (out or ""))

  -- Verify files are stored relative to directory root
  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

  -- A custom entry is wrapped: main.lua is the generated
  -- searcher-installing wrapper; the user entry is byte-identical at
  -- main.user.lua.
  local c1 = reader:read("main.lua")
  assert(c1 and string.find(c1, "cosmic-embed searcher wrapper", 1, true),
    "main.lua should be the embed wrapper: " .. tostring(c1))
  local cu = reader:read("main.user.lua")
  assert(cu == 'print("hello")\n', "main.user.lua should hold the user entry: " .. tostring(cu))

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
  assert(fs.make_dirs(fs.join(appdir, "a/b/c")))
  assert(fs.write(fs.join(appdir, "top.txt"), "top"))
  assert(fs.write(fs.join(appdir, "a/mid.txt"), "mid"))
  assert(fs.write(fs.join(appdir, "a/b/c/deep.txt"), "deep"))

  local output = fs.join(tmpdir, "cosmic-nested")
  local __r8 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  local ok, out = __r8.ok, __r8.stdout
  assert(ok, "embed nested directory should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

  assert(reader:read("top.txt") == "top", "top-level file")
  assert(reader:read("a/mid.txt") == "mid", "mid-level file")
  assert(reader:read("a/b/c/deep.txt") == "deep", "deeply nested file")
  reader:close()
end
test_embed_nested_directory()

-- Test mixing directory and file embedding
local function test_embed_mixed()
  local appdir = fs.join(tmpdir, "mixapp")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), 'print("mixed")\n'))

  local extra = write_temp("extra.txt", "extra content")
  local output = fs.join(tmpdir, "cosmic-mixed")

  local __r9 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--embed", extra, "--output", output})):wait())
  local ok, out = __r9.ok, __r9.stdout
  assert(ok, "embed mixed should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

  local c1 = reader:read("main.user.lua")
  assert(c1 == 'print("mixed")\n', "directory entry should be present (wrapped, #687)")

  local extra_name = extra:gsub("^/+", "")
  local c2 = reader:read(extra_name)
  assert(c2 == "extra content", "individual file should be present")
  reader:close()
end
test_embed_mixed()

-- Test that embedded directory produces a working executable
local function test_embed_directory_executable()
  local appdir = fs.join(tmpdir, "runapp")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "main.lua"), 'io.write("it works\\n")\n'))

  local output = fs.join(tmpdir, "cosmic-runapp")
  local __r10 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  local ok, out = __r10.ok, __r10.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  -- Run the custom executable
  local __r11 = check.must(check.must(child.start({output})):wait())
  ok, out = __r11.ok, __r11.stdout
  assert(ok, "custom executable should run: " .. (out or ""))
  assert(out:match("it works"), "should print expected output, got: " .. (out or ""))
end
test_embed_directory_executable()

-- An app can require its own embedded modules beside main.lua with no
-- configuration: .lua via the wrapper's package.path prepend,
-- .tl via the searcher's /zip include dir. A broken embedded .tl fails
-- the require with the compile issue (the guarantee, in-app).
local function test_embed_app_local_requires()
  local appdir = fs.join(tmpdir, "localmods")
  assert(fs.make_dirs(appdir))
  assert(fs.write(fs.join(appdir, "greet.tl"),
      'local function hi(n: string): string\n  return "hi " .. n\nend\n'
      .. "return { hi = hi }\n"))
  assert(fs.write(fs.join(appdir, "util.lua"), 'return { v = "lua-mod" }\n'))
  assert(fs.write(fs.join(appdir, "bad.tl"), "local x: string = 42\nreturn { x = x }\n"))
  assert(fs.write(fs.join(appdir, "main.lua"),
      'print(require("greet").hi("zip"), require("util").v)\n'
      .. 'local ok, err = pcall(require, "bad")\n'
      .. 'print("bad:", ok, err)\n'))

  local output = fs.join(tmpdir, "cosmic-localmods")
  local __r12 = check.must(check.must(child.start({cosmic, "--embed", appdir, "--output", output})):wait())
  assert(__r12.ok, "embed should succeed: " .. tostring(__r12.stderr))

  local __r13 = check.must(check.must(child.start({output})):wait())
  local out = tostring(__r13.stdout)
  assert(__r13.ok, "app should run: " .. tostring(__r13.stderr))
  assert(out:match("hi zip"), "embedded .tl module should resolve: " .. out)
  assert(out:match("lua%-mod"), "embedded .lua module should resolve: " .. out)
  assert(out:match("bad:%s+false"), "broken .tl require should fail: " .. out)
  assert(out:match("got integer"), "failure should carry the compile issue: " .. out)
end
test_embed_app_local_requires()

-- Test that embedded non-.lua files use deflate compression (method=8)
local function test_embed_uses_deflate()
  -- Use compressible content (repeated pattern) to ensure deflate is applied
  local compressible = string.rep("abcdefghij", 100)
  local input = write_temp("deflate_test.txt", compressible)
  local output = fs.join(tmpdir, "cosmic-deflate")

  local __r12 = check.must(check.must(child.start({cosmic, "--embed", input, "--output", output})):wait())
  local ok, out = __r12.ok, __r12.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

  local name = input:gsub("^/+", "")
  local stat = check.must(reader:stat(name),
    "stat should return metadata for embedded file")
  assert(stat.method == 8,
    "embedded file should use deflate (method=8), got: " .. tostring(stat.method))
  assert(stat.compressed_size < stat.size,
    "deflate should reduce size: " .. tostring(stat.compressed_size) .. " >= " .. tostring(stat.size))
  reader:close()
end
test_embed_uses_deflate()

-- Test that embedded .lua files are stored uncompressed (method=0): the
-- produced executable loads them at boot, so storing skips a per-launch
-- inflate() (see whilp/cosmic#487, backlog entry 24).
local function test_embed_stores_lua()
  -- Compressible content that deflate WOULD shrink, to prove the store is a
  -- deliberate .lua policy and not just deflate declining to grow the file.
  local compressible = "-- " .. string.rep("abcdefghij", 100) .. "\nreturn 1\n"
  local input = write_temp("store_test.lua", compressible)
  local output = fs.join(tmpdir, "cosmic-store")

  local __r13 = check.must(check.must(child.start({cosmic, "--embed", input, "--output", output})):wait())
  local ok, out = __r13.ok, __r13.stdout
  assert(ok, "embed should succeed: " .. (out or ""))

  local data = fs.read(output)
  local reader = check.must(zip.open_string(data), "failed to open zip from data")

  local name = input:gsub("^/+", "")
  local stat = check.must(reader:stat(name),
    "stat should return metadata for embedded file")
  assert(stat.method == 0,
    "embedded .lua should be stored (method=0), got: " .. tostring(stat.method))
  assert(stat.compressed_size == stat.size,
    "stored .lua should not be compressed: " .. tostring(stat.compressed_size) .. " vs " .. tostring(stat.size))
  -- Content must still round-trip identically.
  assert(reader:read(name) == compressible, "stored .lua content should match")
  reader:close()
end
test_embed_stores_lua()

-- Zip-slip: extract() must reject any entry that would land outside the
-- output directory. cosmic executables also extract on Windows, so the
-- guard treats "\" as a separator and rejects drive-letter roots too.
local function test_extract_rejects_zip_slip()
  local unsafe = {
    "/etc/passwd", -- POSIX absolute
    "../evil", -- POSIX traversal
    "a/../../evil", -- traversal mid-path
    "a/..", -- traversal at tail
    "..", -- bare traversal
    "\\windows\\system32", -- Windows/UNC absolute
    "..\\evil", -- Windows traversal
    "a\\..\\..\\evil", -- Windows traversal mid-path
    "C:\\evil", -- drive-letter absolute
    "C:/evil", -- drive-letter, forward slash
    "c:evil", -- drive-letter, no separator
    -- Control characters cannot escape the root, but an
    -- archive-controlled name travels into formats that read one as
    -- structure -- `--make fetch`'s unpack manifest is a line per
    -- product, so a newline here becomes two names that do not exist
    -- and an unpack that repeats on every run, silently, forever.
    "a\nb.txt", -- newline: the manifest delimiter
    "a\0b.txt", -- NUL
    "tab\there", -- any other control character
  }
  for _, name in ipairs(unsafe) do
    assert(fs.is_unsafe_entry_name(name), "should reject unsafe entry: " .. name)
  end
  local safe = {
    "main.lua", "sub/dir/file.txt", "a..b/c", "...", "a/b..c/d",
  }
  for _, name in ipairs(safe) do
    assert(not fs.is_unsafe_entry_name(name), "should accept safe entry: " .. name)
  end
end
test_extract_rejects_zip_slip()

-- The floor is a KEEP list, and a keep list that keeps more than it
-- names is one that silently ships whatever a base grows next to a
-- kept file. `.args` is file-shaped, so matching it as a prefix also
-- matched `.argsX`; only directory entries may match by prefix.
local function test_floor_matches_files_exactly()
  local floor = require("cosmic.embed.floor")
  assert(floor.in_floor(".args"), "a named file is kept")
  assert(not floor.in_floor(".argsX"),
    "but not something merely starting with its name")
  assert(floor.in_floor("cosmic/fs.lua"), "a directory prefix keeps what is under it")
  assert(floor.in_floor("cosmic"), "and its own marker")
  assert(not floor.in_floor("cosmicX/fs.lua"),
    "but not a sibling whose name starts the same way")
end
test_floor_matches_files_exactly()

-- cosmic/init.tl flattens to cosmic.lua at the zip root — outside the
-- cosmic/ prefix — and a stripped artifact must still boot cosmic.main.
local function test_floor_keeps_the_cosmic_module_itself()
  local floor = require("cosmic.embed.floor")
  assert(floor.in_floor("cosmic.lua"), "require('cosmic') must survive a strip")
  assert(not floor.in_floor("cosmic.luaX"), "file-shaped: exact match only")
  -- A project that provides the namespace supersedes the module file
  -- along with the directory.
  assert(not floor.in_floor("cosmic.lua", {cosmic = true}),
    "a cosmic claim supersedes the flattened module file too")
  assert(not floor.in_floor("cosmic/fs.lua", {cosmic = true}),
    "and the directory, as before")
end
test_floor_keeps_the_cosmic_module_itself()
