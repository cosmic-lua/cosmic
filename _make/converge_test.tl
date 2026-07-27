#!/usr/bin/env cosmic
-- Convergence: a project that builds its own toolchain gates under it.
--
-- The unit under test is the DECISION, not the re-exec: whether this
-- project is a cosmic, and whether the artifact moved. The re-exec
-- itself is exercised end to end by every gate this repo runs.

local check = require("cosmic.check")
local converge = require("_make.converge")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A scanned project from a file map.
local function scan(name: string, files: {string: string}): types.Project
  local root = fs.join(tmpdir, "converge-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, body in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, body))
  end
  -- Bound before must(): scan returns more than one value, and a
  -- multi-return call spreads into the parameter list it sits in.
  local scanned = project.scan(root)
  local proj = check.must(scanned)
  return proj
end

-- Both halves have to be true. A project with a `cosmic/` package is
-- not a toolchain unless it also ships a cosmic, and a project that
-- ships a binary called `cosmic` is not one unless it defines the
-- namespace -- rebuilding either before a gate is a rule nobody asked
-- for.
local function test_only_a_cosmic_converges()
  local plain = scan("plain", {
      ["main.tl"] = "print('x')\n",
      ["lib.tl"] = "return {}\n",
    })
  assert(not converge.toolchain_of(plain),
    "an ordinary project has no toolchain to converge on")

  local vendored = scan("vendored", {
      ["main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  assert(not converge.toolchain_of(vendored),
    "defining the namespace without shipping a cosmic is not a toolchain")

  local tool = scan("tool", {
      ["cmd/cosmic/main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  local found = converge.toolchain_of(tool)
  assert(found, "a project that defines cosmic/ and builds cosmic is one")
  assert((found as types.Binary).name == "cosmic", -- cast: guard above
    "and it is the binary the gate would run under")
end
test_only_a_cosmic_converges()

-- The cap is what makes non-convergence a failure rather than a spin.
local function test_the_generation_cap_refuses()
  local tool = scan("cap", {
      ["cmd/cosmic/main.tl"] = "print('x')\n",
      ["cosmic/init.tl"] = "return {}\n",
    })
  local cenv = require("cosmic.env")
  cenv.set(converge.GEN_ENV, tostring(converge.MAX_GEN))
  local ok, err = converge.to_the_tree(tool, {"check"}, "/nonexistent/cosmic")
  cenv.unset(converge.GEN_ENV)
  assert(not ok, "the cap must refuse rather than build again")
  assert(err:find("not a fixpoint", 1, true), "got: " .. err)
end
test_the_generation_cap_refuses()
