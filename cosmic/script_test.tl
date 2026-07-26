#!/usr/bin/env cosmic
-- test cosmic script execution with .tl and .lua files

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Create a unique subdirectory for this test run to avoid conflicts
local test_subdir = fs.mkdtemp(fs.join(tmpdir, "cosmic_script_test_XXXXXX"))

local function write_temp(name: string, content: string): string
  local filepath = fs.join(test_subdir, name)
  fs.write(filepath, content)

  -- Verify the file was written correctly
  local written = fs.read(filepath)
  assert(written == content, "write_temp: file content mismatch for " .. name)

  return filepath
end

-- Test basic execution of .tl file
local function test_execute_teal_file()
  local script = write_temp("hello.tl", [[
local x: number = 42
print("answer=" .. x)
]])

  local h1 = check.must(spawn.spawn({cosmic, script}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic should execute .tl file")
  assert(out:find("answer=42"), "output should contain expected result")
end
test_execute_teal_file()

-- Test execution of .lua file (regression test)
local function test_execute_lua_file()
  local script = write_temp("hello.lua", [[
local x = 99
print("value=" .. x)
]])

  local h2 = check.must(spawn.spawn({cosmic, script}))
  local __r2 = check.must(h2:wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic should execute .lua file")
  assert(out:find("value=99"), "output should contain expected result")
end
test_execute_lua_file()

-- Test .tl file with type error should fail gracefully
local function test_teal_type_error()
  local script = write_temp("type_error.tl", [[
local x: number = "wrong type"
print(x)
]])

  -- the type-error diagnostic lands on stderr
  local h3 = check.must(spawn.spawn({cosmic, script}))
  local __r3 = check.must(h3:wait())
  local ok, out = __r3.ok, __r3.stderr
  assert(not ok, "cosmic should fail on .tl file with type error")
  assert(out:find("type_error.tl"), "error should reference the file name")
end
test_teal_type_error()

-- Test .tl file with syntax error should fail gracefully
local function test_teal_syntax_error()
  local script = write_temp("syntax_error.tl", [[
if if if
]])

  local h4 = check.must(spawn.spawn({cosmic, script}))
  local __r4 = check.must(h4:wait())
  local ok = __r4.ok
  assert(not ok, "cosmic should fail on .tl file with syntax error")
end
test_teal_syntax_error()

-- Test .tl file with records
local function test_teal_with_records()
  local script = write_temp("records.tl", [[
local record Point
  x: number
  y: number
end

local p: Point = { x = 10, y = 20 }
print("point=" .. p.x .. "," .. p.y)
]])

  local h5 = check.must(spawn.spawn({cosmic, script}))
  local __r5 = check.must(h5:wait())
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "cosmic should execute .tl file with records")
  assert(out:find("point=10,20"), "output should contain expected result")
end
test_teal_with_records()

-- Test .tl file with generics
local function test_teal_with_generics()
  local script = write_temp("generics.tl", [[
local function identity<T>(x: T): T
  return x
end
print("result=" .. identity(123))
]])

  local h6 = check.must(spawn.spawn({cosmic, script}))
  local __r6 = check.must(h6:wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "cosmic should execute .tl file with generics")
  assert(out:find("result=123"), "output should contain expected result")
end
test_teal_with_generics()

-- Test .tl file can require cosmic modules
local function test_teal_require_cosmic()
  local script = write_temp("require_cosmic.tl", [[
local cosmo = require("cosmo")
local data: string = cosmo.Slurp("/dev/null") or ""
print("bytes=" .. #data)
]])

  local h7 = check.must(spawn.spawn({cosmic, script}))
  local __r7 = check.must(h7:wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "cosmic should execute .tl file with cosmic module requires")
  assert(out:find("bytes=0"), "output should contain expected result")
end
test_teal_require_cosmic()

-- Test script arguments are passed correctly to .tl files
local function test_teal_script_args()
  local script = write_temp("args.tl", [[
print("arg0=" .. arg[0])
print("arg1=" .. (arg[1] or "nil"))
print("arg2=" .. (arg[2] or "nil"))
]])

  local h8 = check.must(spawn.spawn({cosmic, script, "first", "second"}))
  local __r8 = check.must(h8:wait())
  local ok, out = __r8.ok, __r8.stdout
  assert(ok, "cosmic should execute .tl file with args")
  assert(out:find("arg0=" .. script), "arg[0] should be script path")
  assert(out:find("arg1=first"), "arg[1] should be first argument")
  assert(out:find("arg2=second"), "arg[2] should be second argument")
end
test_teal_script_args()

-- Test script arguments are passed correctly to .lua files (regression)
local function test_lua_script_args()
  local script = write_temp("args.lua", [[
print("arg0=" .. arg[0])
print("arg1=" .. (arg[1] or "nil"))
]])

  local h9 = check.must(spawn.spawn({cosmic, script, "test"}))
  local __r9 = check.must(h9:wait())
  local ok, out = __r9.ok, __r9.stdout
  assert(ok, "cosmic should execute .lua file with args")
  assert(out:find("arg0=" .. script), "arg[0] should be script path")
  assert(out:find("arg1=test"), "arg[1] should be argument")
end
test_lua_script_args()

-- Test .tl file with shebang
local function test_teal_with_shebang()
  local script = write_temp("shebang.tl", [[#!/usr/bin/env cosmic
local x: number = 777
print("shebang=" .. x)
]])

  -- Verify the file exists and has correct content
  local verify = check.must(fs.read(script))
  assert(verify:find("shebang="), "script file should contain shebang test code, got: " .. verify:sub(1, 100))

  local h10 = check.must(spawn.spawn({cosmic, script}))
  local __r10 = check.must(h10:wait())
  local ok, out = __r10.ok, __r10.stdout .. __r10.stderr
  assert(ok, "cosmic should execute .tl file with shebang, got: " .. tostring(out))
  assert(out:find("shebang=777"), "output should contain expected result, got: " .. tostring(out))
end
test_teal_with_shebang()

-- Test that running a .tl script twice reuses cosmic._script_cache's
-- compiled output (a cache hit), and that changing the script's content
-- (and so its mtime) invalidates the cache and picks up the new output.
local function test_script_cache_reuse_and_invalidation()
  local env = require("cosmic.env")
  env.set("COSMIC_TL_CACHE_DIR", fs.join(test_subdir, "tl-cache"), true)

  local script = write_temp("cached.tl", [[
local x: number = 1
print("value=" .. x)
]])

  for _ = 1, 2 do
    local h11 = check.must(spawn.spawn({cosmic, script}))
    local __r11 = check.must(h11:wait())
    local ok, out = __r11.ok, __r11.stdout
    assert(ok, "cosmic should execute .tl file: " .. tostring(out))
    assert(out:find("value=1"), "expected value=1, got: " .. tostring(out))
  end

  -- Overwrite with different content; the mtime change must invalidate
  -- the cached compiled output from the runs above.
  fs.write(script, [[
local x: number = 2
print("value=" .. x)
]])
  local h12 = check.must(spawn.spawn({cosmic, script}))
  local __r12 = check.must(h12:wait())
  local ok, out = __r12.ok, __r12.stdout
  assert(ok, "cosmic should execute changed .tl file: " .. tostring(out))
  assert(out:find("value=2"),
    "expected value=2 after script change (stale cache?), got: " .. tostring(out))
end
test_script_cache_reuse_and_invalidation()

print("All script tests passed!")

-- The compile cache holds CODE THAT WILL BE EXECUTED, and its key --
-- sha256(path .. content .. build id) -- is computable by anyone who
-- can see the script. In a world-writable directory that means another
-- local user can plant `<key>.lua` and choose what this process runs,
-- with no compile and no error. The reach is every `.tl` module every
-- embedded artifact requires at boot, since cosmic.searcher goes
-- through the same cache.
--
-- Both directions are asserted, because only the pair is evidence: the
-- SAME planted file must execute from a directory we own privately
-- (proving the key is right and the attack is real) and must be
-- ignored from a group/world-writable one.
local function plant(dir: string, script: string, code: string)
  local hash = require("cosmic.hash")
  local content = check.must(fs.read(script))
  -- Non-literal module name: cosmic._version is generated at build
  -- time, so there is no type information for it in the tree.
  local mod = "cosmic._version"
  local ok, ver = pcall(require, mod)
  local id = ok and tostring((ver as {string: string}).cosmic) or "unknown" -- cast: from any
  local key = hash.sha256_hex(script .. "\0" .. content .. "\0" .. id)
  assert(fs.write(fs.join(dir, key .. ".lua"), code))
end

--- Run `script` with the cache pointed at `dir`, returning stdout.
local function run_cached(dir: string, script: string): string
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_TL_CACHE_DIR=" .. dir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn({cosmic, script}, {env = env}))
  local r = check.must(h:wait())
  return (r.stdout or "") .. (r.stderr or "")
end

local function test_cache_refuses_a_shared_directory()
  local script = write_temp("cached.tl", 'print("compiled fresh")\n')
  local dir = fs.join(test_subdir, "cache")
  assert(fs.makedirs(dir))
  plant(dir, script, 'print("PLANTED")\n')

  assert(fs.chmod(dir, tonumber("700", 8) as integer)) -- cast: octal is integral
  local owned = run_cached(dir, script)
  assert(owned:find("PLANTED", 1, true),
    "a private cache is used, so the planted key is the right one: " .. owned)

  assert(fs.chmod(dir, tonumber("777", 8) as integer)) -- cast: octal is integral
  local shared = run_cached(dir, script)
  assert(shared:find("compiled fresh", 1, true),
    "a world-writable cache must be bypassed, not trusted: " .. shared)
  assert(not shared:find("PLANTED", 1, true),
    "and must never execute what it holds: " .. shared)
end
test_cache_refuses_a_shared_directory()

-- The cache key is the bytes that were COMPILED, not the bytes present
-- when the entry is written. A source edited between those two moments
-- would otherwise bind the compiled code to the NEW content's key, and
-- every later run of that file would execute code it does not hold.
local function test_cache_never_binds_stale_code_to_new_content()
  local cache = require("cosmic._script_cache")
  local path = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "keyed.tl")
  assert(fs.write(path, "return 1\n"))
  cache.store(path, "return 1\n", "-- compiled from v1\n")
  assert(cache.load(path, "return 1\n") == "-- compiled from v1\n",
    "the entry is found by the bytes it was compiled from")
  assert(not cache.load(path, "return 2\n"),
    "and different bytes are a miss, whatever is on disk now")
end
test_cache_never_binds_stale_code_to_new_content()
