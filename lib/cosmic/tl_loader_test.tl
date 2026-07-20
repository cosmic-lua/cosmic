#!/usr/bin/env cosmic
-- test that tl_package_loader is not at position 2 in package.searchers
-- (issue #377: tl_package_loader recompiles .tl sources when TL_PATH is set)

local check = require("cosmic.check")
local spawn = require("cosmic.child")
local fs = require("cosmic.fs")
local fstypes = require("cosmic.fs.types")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

--- Test that tl_package_loader is not at position 2 in package.searchers.
--- It should be appended after all default searchers so that pre-compiled
--- .lua files are found first by the default Lua file searcher.
local function test_tl_loader_not_at_position_2()
  local script = write_temp("check_pos.lua", [[
-- Detect whether package.searchers[2] is the tl_package_loader.
-- tl_package_loader calls tl.search_module, which looks for .tl files.
-- The default Lua searcher uses package.searchpath with package.path.
--
-- We can distinguish them: call searcher[2] with a module name that
-- has a .tl file in /zip/.tl/ but also a .lua file in /zip/.lua/.
-- The default Lua searcher returns a function + filename ending in .lua.
-- tl_package_loader returns a function + filename ending in .tl.
local searchers = package.searchers
local n = 0
for _ in ipairs(searchers) do n = n + 1 end
io.write("searcher_count=" .. n .. "\n")

-- Call searcher[2] directly with a known cosmic module.
-- If it's the default Lua searcher, it returns (loader, path_to_lua).
-- If it's tl_package_loader, it returns (loader, path_to_tl).
local result, path_or_err = searchers[2]("cosmic.json")
if type(result) == "function" and type(path_or_err) == "string" then
  io.write("searcher2_path=" .. path_or_err .. "\n")
  if path_or_err:match("%.tl$") then
    io.write("FAIL: searcher[2] is tl_package_loader (found .tl file)\n")
    os.exit(1)
  else
    io.write("PASS: searcher[2] is default lua searcher\n")
  end
elseif type(result) == "string" then
  -- searcher returned an error string (module not found by this searcher)
  io.write("searcher2_error=" .. result .. "\n")
  io.write("PASS: searcher[2] did not find cosmic.json as .tl\n")
else
  io.write("PASS: searcher[2] returned unexpected type, not tl_package_loader\n")
end
]])

  local h1 = check.must(spawn.spawn({cosmic, script}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "script should succeed: " .. tostring(out))
  assert(out:find("PASS"),
    "searcher[2] should not be tl_package_loader: " .. tostring(out))
end
test_tl_loader_not_at_position_2()

--- Test that the tl_package_loader is still present (as a later searcher)
--- so that .tl-only modules can still be loaded.
local function test_tl_loader_still_available()
  -- Create a .tl-only module (no .lua version). The type annotation
  -- makes it invalid as raw Lua, so only the cosmic .tl searcher can
  -- load it — the default Lua searcher grabbing it would error.
  -- Resolution goes through TL_PATH (never package.path: the default
  -- Lua searcher consults package.path FIRST and would loadfile the
  -- raw .tl as Lua).
  local moddir = fs.join(tmpdir, "tlonly")
  fs.makedirs(moddir)
  fs.write(fs.join(moddir, "mymod.tl"), [[
local answer: integer = 42
return { answer = answer }
]])

  local script = write_temp("use_tlonly.tl", [[
local mymod = require("mymod")
print("answer=" .. tostring(mymod.answer))
]])

  -- keep PATH: a replacement env with no PATH strands the APE stub —
  -- it can't find the staged `ape` loader and falls back to extracting
  -- into ${TMPDIR:-${HOME:-.}}, none of which the test sandbox grants
  local h2 = check.must(spawn.spawn({cosmic, script}, {
        env = {"TL_PATH=" .. moddir .. "/?.tl", "PATH=" .. os.getenv("PATH")},
      }))
  local __r2 = check.must(h2:wait())
  local ok2a, out2a = __r2.ok, __r2.stdout
  assert(ok2a, ".tl-only require should succeed: " .. tostring(__r2.stderr))
  assert(out2a:find("answer=42", 1, true),
    ".tl-only module should load and run: " .. tostring(out2a))

  local check_script = write_temp("check_tl_exists.lua", [[
local searchers = package.searchers
local n = 0
for _ in ipairs(searchers) do n = n + 1 end
-- With fix: 5 searchers (4 default + tl_package_loader at end)
-- Without tl.loader(): 4 searchers
if n >= 5 then
  io.write("PASS: tl_package_loader is present (" .. n .. " searchers)\n")
else
  io.write("FAIL: expected 5+ searchers, got " .. n .. "\n")
  os.exit(1)
end
]])

  local h3 = check.must(spawn.spawn({cosmic, check_script}))
  local __r3 = check.must(h3:wait())
  local ok2, out2 = __r3.ok, __r3.stdout
  assert(ok2, "check script should succeed: " .. tostring(out2))
  assert(out2:find("PASS"),
    "tl_package_loader should still be present: " .. tostring(out2))
end
test_tl_loader_still_available()

--- A required .tl module that fails to compile must fail the require()
--- with the compile issues — tl's old loader type-checked and then
--- generated code anyway, silently running broken modules (#669).
local function test_require_fails_on_compile_error()
  local baddir = fs.join(tmpdir, "tlbad")
  fs.makedirs(baddir)
  fs.write(fs.join(baddir, "badmod.tl"), [[
local x: string = 42
return { x = x }
]])
  local script = write_temp("use_bad.tl", [[
local badmod = require("badmod")
print("should not get here: " .. tostring(badmod))
]])
  local h = check.must(spawn.spawn({cosmic, script}, {
        env = {"TL_PATH=" .. baddir .. "/?.tl"},
      }))
  local r = check.must(h:wait())
  assert(not r.ok, "require of a broken .tl module must fail")
  local err = tostring(r.stderr)
  assert(err:find("badmod", 1, true) and err:find("got integer", 1, true),
    "failure should carry the compile issue: " .. err)
  local out = tostring(r.stdout)
  assert(not out:find("should not get here", 1, true),
    "broken module must not run: " .. out)
end
test_require_fails_on_compile_error()

--- Required .tl modules go through the content-hash compile cache, so a
--- script's require tree compiles once per content+build, not per run.
local function test_require_uses_compile_cache()
  local gooddir = fs.join(tmpdir, "tlgood")
  fs.makedirs(gooddir)
  fs.write(fs.join(gooddir, "goodmod.tl"), [[
local value: string = "cached"
return { value = value }
]])
  local script = write_temp("use_good.tl", [[
print("value=" .. require("goodmod").value)
]])
  local cachedir = fs.join(tmpdir, "tlcache")
  local h = check.must(spawn.spawn({cosmic, script}, {
        env = {
          "TL_PATH=" .. gooddir .. "/?.tl",
          "COSMIC_TL_CACHE_DIR=" .. cachedir,
        },
      }))
  local r = check.must(h:wait())
  assert(r.ok, "good .tl require should succeed: " .. tostring(r.stderr))
  assert(tostring(r.stdout):find("value=cached", 1, true))
  local counted = fs.walk(cachedir, function(_path: string, _name: string, _st: fstypes.WalkStat, acc: {integer})
      acc[1] = acc[1] + 1
    end, {0})
  local n = check.must(counted, "cache dir should exist and be walkable")
  assert(n[1] > 0,
    "compile cache should hold the required module's output")
end
test_require_uses_compile_cache()

print("All tl_loader tests passed!")
