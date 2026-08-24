#!/usr/bin/env cosmic
-- Tests for the runtime .tl searcher (cosmic.searcher).
--
-- This is the last searcher in package.searchers: the path a
-- `require("mod")` takes when no compiled `mod.lua` exists anywhere, so
-- it is how every user script's .tl imports resolve. It needs direct
-- tests: the repo's own suite loads compiled `.lua` (each test takes
-- its import closure as a prerequisite), so nothing here exercises the
-- searcher incidentally. Incidental coverage of a module that answers
-- every require() would not be the right arrangement anyway;
-- these assert the three guarantees it makes over tl's own loader.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local searcher = require("cosmic.searcher")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Put a .tl module in a directory the searcher will consult, and
--- return the module name. TL_PATH takes precedence over everything in
--- cosmic.teal's assembled path, which is what makes the fixture
--- reachable without disturbing the real tree.
local function fixture(name: string, source: string): string
  local dir = fs.join(tmpdir, "searcher")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, name .. ".tl"), source))
  local env = require("cosmic.env")
  assert(env.set("TL_PATH", fs.join(dir, "?.tl")))
  return name
end

-- Resolve, compile, load: the whole path, and the value the module
-- returns must survive it.
local function test_resolves_and_loads_a_tl_module()
  local name = fixture("searcher_ok",
    "local record M\n  answer: integer\nend\n" ..
    "local m: M = {answer = 42}\nreturn m\n")
  -- Through require() — the searcher VALUE is installed, never handed
  -- out — the binary installed it at boot, so the require IS
  -- the resolve-compile-load path.
  local mod = require(name) as {string: integer} -- cast: from any
  assert(mod.answer == 42, "the module's own value must come back")
end
test_resolves_and_loads_a_tl_module()

-- A miss returns a STRING, which is what package.searchers expects of a
-- searcher that declines: require() then reports its own "module not
-- found" rather than this one erroring out of the whole chain.
local function test_a_miss_declines_rather_than_throws()
  -- The searcher VALUE is installed, never exported, and the
  -- dispatcher's require_hints rewrites require's aggregate error, so
  -- ask the installed chain directly: one of its entries must decline
  -- this (computed, deliberately unresolvable) name with a string.
  local missing = "cosmic_searcher_" .. "no_such_module_here"
  local found = false
  for _, s in ipairs(package.searchers) do
    -- cast: package.searchers entries are untyped
    local ok, why = pcall((s as function(string): any), missing)
    if ok and why is string and why:find("no .tl source found", 1, true) then
      found = true
      break
    end
  end
  assert(found, "the installed .tl searcher must decline with its message")
end
test_a_miss_declines_rather_than_throws()

-- Loud failures are the point of owning the searcher: tl's own
-- loader ran tl.check and generated code without ever looking at the
-- type errors, so a broken module loaded and failed later, somewhere
-- else. This one fails the require() with the issues.
local function test_a_compile_error_fails_the_require()
  local name = fixture("searcher_broken", "local x: integer = \"nope\"\nreturn x\n")
  local ok, err = pcall(require, name)
  assert(not ok, "a module that does not compile must not load")
  assert(tostring(err):find(name, 1, true),
    "the failure must name the module, got: " .. tostring(err))
end
test_a_compile_error_fails_the_require()

-- install() is idempotent: the embed wrapper installs it before an app
-- entry that may itself be the dispatcher, which installs it too.
local function test_install_is_idempotent()
  local before = #package.searchers
  searcher.install()
  searcher.install()
  local after = #package.searchers
  assert(after <= before + 1,
    "install() must add at most one searcher, went " .. before .. " -> " .. after)
end
test_install_is_idempotent()

--- Ask the searcher at `seat` about a module, the way require does.
--- @param seat integer Index into package.searchers
--- @param name string Module name
--- @return any A loader function, or the searcher's miss string
--- @return any The loader data (a filename, on a hit)
local function ask(seat: integer, name: string): any, any
  local s: function(string): (any, any) = package.searchers[seat]
  return s(name)
end

--- The first seat whose miss message satisfies `want`, or 0.
---
--- Both searchers this file asserts about are VALUES, never exported,
--- and their seats move: the in-project searcher inserts at the same
--- index and demotes the /zip one, which is exactly what `--make test`
--- does to this process. So identify them by how they decline.
local function seat_declining(want: function(string): boolean): integer
  local missing = "cosmic_searcher_" .. "no_zip_module_here"
  for i in ipairs(package.searchers) do
    local ok, why = pcall(ask, i, missing)
    if ok and why is string and want(why) then
      return i
    end
  end
  return 0
end

--- The /zip searcher declines with the EMPTY string, so require's
--- aggregate error stays the default file searcher's.
local function zip_seat(): integer
  return seat_declining(function(why: string): boolean
      return why == ""
    end)
end

-- The /zip searcher resolves a module the binary carries by LOADING it:
-- one zipos open, where the stock file searcher probes with
-- package.searchpath and then reopens the winner.
local function test_the_zip_searcher_loads_a_carried_module()
  local seat = zip_seat()
  assert(seat > 0, "the /zip searcher must be installed at boot")
  local chunk, path = ask(seat, "cosmic.json")
  assert(chunk is function, "a carried module must resolve to a loader")
  assert(path == "/zip/cosmic/json.lua",
    "and to its /zip path, got: " .. tostring(path))
end
test_the_zip_searcher_loads_a_carried_module()

-- It sits AHEAD of the default file searcher, or it would resolve
-- nothing the binary already carries -- the whole point of the seat.
local function test_the_zip_searcher_outranks_the_file_searcher()
  local file_seat = seat_declining(function(why: string): boolean
      return why:find("no file '", 1, true) ~= nil
    end)
  assert(file_seat > 0, "the default file searcher must be in the chain")
  assert(zip_seat() < file_seat,
    "the /zip searcher must sit ahead of it, got " ..
    zip_seat() .. " vs " .. file_seat)
end
test_the_zip_searcher_outranks_the_file_searcher()

-- install_zip() de-duplicates the zip templates: the embed wrapper and
-- the dispatcher each prepend the pair, and a wrapped artifact runs
-- both. Boot already called it, so the path carries one of each.
local function test_the_zip_templates_appear_once_on_the_path()
  for _, template in ipairs({"/zip/?.lua", "/zip/?/init.lua"}) do
    local seen = 0
    for field in (package.path .. ";"):gmatch("([^;]*);") do
      if field == template then
        seen = seen + 1
      end
    end
    assert(seen == 1,
      template .. " must appear exactly once on package.path, saw " .. seen)
  end
end
test_the_zip_templates_appear_once_on_the_path()

-- install_zip() is idempotent for the same reason install() is: the
-- wrapper installs it before an entry that may install it again.
local function test_install_zip_is_idempotent()
  local before = #package.searchers
  searcher.install_zip()
  searcher.install_zip()
  assert(#package.searchers == before,
    "install_zip() must not add a second searcher, went " ..
    before .. " -> " .. #package.searchers)
end
test_install_zip_is_idempotent()

local env = require("cosmic.env")
assert(env.unset("TL_PATH"))
local _ = check

print("all searcher tests passed")
