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
  -- Through require() (#1001: the searcher VALUE is installed, never
  -- handed out) — the binary installed it at boot, so the require IS
  -- the resolve-compile-load path.
  local mod = require(name) as {string: integer} -- cast: from any
  assert(mod.answer == 42, "the module's own value must come back")
end
test_resolves_and_loads_a_tl_module()

-- A miss returns a STRING, which is what package.searchers expects of a
-- searcher that declines: require() then reports its own "module not
-- found" rather than this one erroring out of the whole chain.
local function test_a_miss_declines_rather_than_throws()
  -- The searcher VALUE is installed, never exported (#1001), and the
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
  local before = #(package.searchers as {any}) -- cast: package.searchers is untyped
  searcher.install()
  searcher.install()
  local after = #(package.searchers as {any}) -- cast: package.searchers is untyped
  assert(after <= before + 1,
    "install() must add at most one searcher, went " .. before .. " -> " .. after)
end
test_install_is_idempotent()

local env = require("cosmic.env")
assert(env.unset("TL_PATH"))
local _ = check

print("all searcher tests passed")
