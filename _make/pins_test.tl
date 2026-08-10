#!/usr/bin/env cosmic
-- The REAL committed pins, resolved — offline.
--
-- Every other pin test builds a fixture pin, which means the machinery
-- a release actually depends on (the `platforms` table, `{platform}`
-- and `{version}` substitution, the landing path) never runs against
-- the two files a cold checkout has to resolve before it can build
-- anything. It broke that way once during development: `--make fetch`
-- refused both real pins, and nothing failed until someone ran the
-- fixpoint by hand.
--
-- No network: resolution is a pure function of the committed file, and
-- that is the half worth gating on every commit. The online half — a
-- real `--make fetch` against these pins — is a step in the CI lane
-- that already has a network for the bootstrap.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local pin = require("_make.pin")
local project = require("_make.project")

--- The pins this repo commits, which are the ones a release resolves.
local PINS < const >: {string} = {
  "3p/cosmos/cosmos_pin.tl",
  "3p/tl/tl_pin.tl",
}

--- Every platform key a pin declares, in sorted order. A pin with no
--- `platforms` table resolves the same way everywhere, which this
--- reports as the single key "".
--- @param path string The pin file
--- @return {string} The declared keys
local function platform_keys(path: string): {string}
  local fields = check.must(literal.parse_file(path, {noun = "pin"}))
  local platforms = fields.platforms
  if not (platforms is {string: any}) then
    return {""}
  end
  local out: {string} = {}
  for key in pairs(platforms) do
    out[#out + 1] = key
  end
  table.sort(out)
  assert(#out > 0, path .. ": a platforms table with no rows")
  return out
end

-- Every declared row resolves, not only the row this machine matches.
-- A release runs on one platform at a time, so a broken row is
-- invisible until the day it is the one being built.
local function test_every_declared_platform_resolves()
  for _, path in ipairs(PINS) do
    assert(fs.is_file(path), "missing committed pin: " .. path)
    for _, key in ipairs(platform_keys(path)) do
      local host = key ~= "" and key or "x86_64-linux"
      local got, err = pin.read(path, host)
      assert(got, path .. " [" .. host .. "]: " .. tostring(err))
      assert(#got.sha256 == 64 and got.sha256:match("^%x+$"),
        path .. " [" .. host .. "]: sha256 must be 64 hex, got " .. got.sha256)

      -- Substitution is complete: a leftover placeholder is a url that
      -- 404s at fetch time rather than failing here.
      assert(not got.url:find("{", 1, true),
        path .. " [" .. host .. "]: unsubstituted placeholder in " .. got.url)
      assert(got.url:match("^https://"),
        path .. " [" .. host .. "]: a pin's url must be https: " .. got.url)

      -- The landing path mirrors the pin's POSITION under the build
      -- directory. Everything downstream (the payload generator, the
      -- fixpoint's seeding) names files relative to it.
      assert(fs.dirname(got.output) == fs.dirname(path),
        path .. " [" .. host .. "]: output must mirror the pin's position, got " ..
        got.output)
      assert(got.output:sub(1, #project.BUILD_DIR + 1) ~= project.BUILD_DIR .. "/",
        path .. ": a pin names an asset; where it lands is the build's business")
    end
  end
end
test_every_declared_platform_resolves()

-- `{platform}` substitution is what makes a per-host pin one file. When
-- a pin uses it, the resolved url must carry the key that was asked
-- for — the failure it guards against is a pin resolving to SOME
-- platform's bytes rather than to this one's.
local function test_platform_substitution_uses_the_key_it_resolved()
  local seen = false
  for _, path in ipairs(PINS) do
    local raw = check.must(fs.read(path))
    if raw:find("{platform}", 1, true) then
      for _, key in ipairs(platform_keys(path)) do
        if key ~= "" and key ~= "*" then
          seen = true
          local got = check.must(pin.read(path, key))
          assert(got.url:find(key, 1, true),
            path .. ": resolving for " .. key ..
            " produced a url that does not name it: " .. got.url)
        end
      end
    end
  end
  -- Not an assertion that some pin uses it: today none does, and this
  -- test is here so the day one starts, the substitution is covered.
  if not seen then
    io.write("no committed pin uses {platform} yet\n")
  end
end
test_platform_substitution_uses_the_key_it_resolved()

-- A pin naming a platform nobody declared is refused, by name. The
-- alternative — silently falling through to some other row — is how a
-- build ends up running another architecture's bytes.
local function test_an_undeclared_platform_is_refused()
  for _, path in ipairs(PINS) do
    local keys = platform_keys(path)
    if keys[1] ~= "" and not (keys[1] == "*" and #keys == 1) then
      local got, err = pin.read(path, "sparc-plan9")
      assert(not got, path .. ": an undeclared platform must be refused")
      assert(err:find("no platform row", 1, true), "got: " .. tostring(err))
    end
  end
end
test_an_undeclared_platform_is_refused()

-- A pin that declares `*` resolves for ANY host, which is the whole
-- point of that spelling.
local function test_the_star_row_matches_every_host()
  for _, path in ipairs(PINS) do
    local fields = check.must(literal.parse_file(path, {noun = "pin"}))
    local platforms = fields.platforms
    if platforms is {string: any} and platforms["*"] ~= nil then
      for _, host in ipairs({"x86_64-linux", "aarch64-macos", "x86_64-windows"}) do
        local got = check.must(pin.read(path, host))
        assert(got.platform == "*",
          path .. ": " .. host .. " should resolve through '*', got " ..
          tostring(got.platform))
      end
    end
  end
end
test_the_star_row_matches_every_host()

print("all committed-pin tests passed")
