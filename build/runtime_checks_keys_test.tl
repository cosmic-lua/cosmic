--- A compile with run-time checks ([`importer.compile`]'s `checks`) and one
--- without share no cache entry: not the working database's, and not the
--- compiles every checkout shares ([`build.shared_compiles`]). Each is
--- keyed by a compiler of its own ([`importer.checked_tool`]), so a module
--- taken from either cache is the Lua the run asked for.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local derivation = require("build.derivation")
local importer = require("build.importer")
local Sqlite = require("cosmic.sqlite")
local type Compiler = require("build.compiler")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

local library = table.concat({
  "local record Lib",
  "end",
  "function Lib.double(n: integer): integer",
  "  return n * 2",
  "end",
  "return Lib",
  "",
}, "\n")

--- A fixture project of one typed module under `root`.
local function project(root: string)
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/lib.tl", library))
end

--- Compiles the project at `root` with or without checks, through the
--- compiles shared by the cache at `cache`, and answers the result.
local function compile(root: string, cache: string, checks: boolean): importer.Result
  project(root)
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result, trouble = importer.compile(handle, built, "keys-test", false,
    shared_compiles.for_build({ COSMIC_BUILD_CACHE = cache }), nil, checks)
  work.close(handle)
  return (assert(result, trouble))
end

--- The module `lib` of `result`.
local function lib(result: importer.Result): importer.Module
  for _, m in ipairs(result.modules) do
    if m.path == "lib" then return m end
  end
  error("no module lib compiled")
end

local function checks_in(m: importer.Module): boolean
  return (m.lua or ""):find("__cosmic_tc", 1, true) ~= nil
end

--- The compiler a checked compile is keyed by is not the one it is
--- without, and is one value for one: no key a checked compile makes is
--- a key an unchecked one makes.
local function test_a_checked_compile_is_keyed_by_a_compiler_of_its_own()
  assert(importer.checked_tool("t") ~= "t")
  assert(importer.checked_tool("t") == importer.checked_tool("t"))
  assert(importer.checked_tool("t") ~= importer.checked_tool("u"))
end

--- The checks the new checker's generator writes (the calls of `__fact`) are another Lua than the fork's, and so another
--- compiler of a key: a compile cached with one is never taken for the other, or for none.
local function test_a_compile_with_fact_wraps_is_keyed_apart_from_the_forks_checks_and_from_none()
  local wraps = importer.checked_tool("t", true)
  assert(wraps ~= importer.checked_tool("t") and wraps ~= "t")
  assert(wraps == importer.checked_tool("t", true))
  assert(wraps ~= importer.checked_tool("u", true))
  assert(importer.checked_tool("t", false) == importer.checked_tool("t"))
end

--- The same source compiles to two keys and two Luas, and the shared
--- cache gives neither to the other: a compile of one kind is taken from
--- it only when an entry of that kind was kept.
local function test_no_cache_entry_is_shared_between_the_two(tmp: string)
  local cache = tmp .. "/cache/cache.db"
  local plain = compile(tmp .. "/plain", cache, false)
  assert(plain.compiled > 0 and plain.shared == 0)
  local first = lib(plain)
  assert(not checks_in(first), "an unchecked compile carries a check")

  -- Nothing the unchecked compile kept answers the checked one.
  local checked = compile(tmp .. "/checked", cache, true)
  assert(checked.shared == 0 and checked.compiled > 0,
    "a checked compile took an unchecked entry: " .. checked.shared .. " shared")
  local second = lib(checked)
  assert(checks_in(second), "a checked compile carries no check")
  assert(first.key ~= second.key, "one key for a module with and without checks")
  assert(checked.tool == importer.checked_tool("keys-test") and plain.tool == "keys-test")

  -- Each kind then stands on the entry of its own.
  local plain_again = compile(tmp .. "/plain-again", cache, false)
  assert(plain_again.compiled == 0 and plain_again.shared == #plain_again.modules,
    plain_again.compiled .. " compiled, " .. plain_again.shared .. " shared")
  assert(not checks_in(lib(plain_again)), "an unchecked compile took a checked entry")
  local checked_again = compile(tmp .. "/checked-again", cache, true)
  assert(checked_again.compiled == 0 and checked_again.shared == #checked_again.modules,
    checked_again.compiled .. " compiled, " .. checked_again.shared .. " shared")
  assert(checks_in(lib(checked_again)), "a checked compile took an unchecked entry")
end

--- The working database holds both kinds under their own keys, and a
--- compile of one kind in a database that held the other compiles again
--- rather than reading its rows.
local function test_the_working_database_keeps_the_two_apart(tmp: string)
  local root = tmp .. "/project"
  project(root)
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local plain = assert(importer.compile(handle, built, "keys-test", false, nil, nil, false))
  local checked = assert(importer.compile(handle, built, "keys-test", false, nil, nil, true))
  assert(checked.compiled == #checked.modules and checked.cached == 0,
    "a checked compile read the unchecked rows: " .. checked.cached .. " cached")
  assert(checks_in(lib(checked)) and not checks_in(lib(plain)))
  local again = assert(importer.compile(handle, built, "keys-test", false, nil, nil, false))
  assert(again.compiled == #again.modules, "the rows of the checked compile answered an unchecked one")
  assert(not checks_in(lib(again)) and lib(again).key == lib(plain).key)
  work.close(handle)
end

--- The module that holds the hook the checks call is compiled without
--- them: with, its own typed functions would call the hook, which would
--- call itself, and every test of a checked run would fail.
local function test_the_module_holding_the_hook_is_compiled_without_checks(tmp: string)
  local root = tmp .. "/project"
  project(root)
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/test_worker.tl", library))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result, trouble = importer.compile(handle, built, "keys-test", false, nil, nil, true)
  work.close(handle)
  assert(result ~= nil, trouble)
  local seen: {string:boolean} = {}
  for _, m in ipairs(result.modules) do seen[m.path] = checks_in(m) end
  assert(seen.lib == true, "a module was not checked")
  assert(seen["build.test_worker"] == false, "the hook's module carries checks")
end

--- A pool compiles in environments that write no checks, so a checked
--- compile is refused one rather than keyed as checked and not be.
local function test_a_checked_compile_takes_no_pool(tmp: string)
  local root = tmp .. "/project"
  project(root)
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local closed = { value = 0 }
  local pool: importer.Workers = {
    ready = function(_: integer): boolean return false end,
    parse = function(_: Sqlite.Handle, _: Compiler, _: {derivation.Fresh}, _: derivation.Parses,
                     _: {derivation.Source}, _?: {derivation.Broken}): boolean, string
      return true, ""
    end,
    compile = function(_: Sqlite.Handle, _: string, _: {importer.Module}, _: {string:boolean},
                       _: boolean, _: boolean): importer.Ahead | nil, string
      return nil, ""
    end,
    close = function() closed.value = closed.value + 1 end,
  }
  local result, trouble = importer.compile(handle, built, "keys-test", false, nil, pool, true)
  work.close(handle)
  assert(result == nil and trouble:find("takes no pool", 1, true), tostring(trouble))
  assert(closed.value == 1, "the pool was not closed")
end
