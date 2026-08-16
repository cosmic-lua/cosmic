#!/usr/bin/env cosmic
--- reads: cosmic
--- reads: _build/public_surface_baseline.tl
-- Ratchet over the published module surface.
--
-- Position is the manifest, so a new public module costs one file and
-- no conversation. That is the right rule for a tree people work in and
-- the wrong one for a promise people depend on: every name under
-- `cosmic.` is API, documented, tested and kept forever. This gate
-- holds the surface against a committed set in both directions — a name
-- the tree has and the set does not is growth nobody agreed to, and a
-- name the set has and the tree does not is a set gone stale — so the
-- surface only moves when someone rewrites the set and says why.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local surface = require("_build.public_surface")

local REGEN < const > =
"run: bin/cosmic --make run _build/public_surface.tl --baseline, " ..
"commit it, and say why in the PR"

local function test_the_surface_matches_the_committed_baseline()
  local tree = surface.modules(".")
  local base = check.must(surface.baseline())
  local known: {string: boolean} = {}
  for _, name in ipairs(base) do
    known[name] = true
  end
  local present: {string: boolean} = {}
  local added: {string} = {}
  for _, name in ipairs(tree) do
    present[name] = true
    if not known[name] then
      added[#added + 1] = "new public module " .. name ..
      ": the surface grows only deliberately — " .. REGEN
    end
  end
  local gone: {string} = {}
  for _, name in ipairs(base) do
    if not present[name] then
      gone[#gone + 1] = "stale baseline: " .. name ..
      " is no longer in the tree — " .. REGEN
    end
  end
  assert(#tree > 20, "expected a substantial public surface, got " ..
    #tree .. " — the enumeration found nothing to gate")
  assert(#added == 0, table.concat(added, "\n  "))
  assert(#gone == 0, table.concat(gone, "\n  "))
end
test_the_surface_matches_the_committed_baseline()

-- What the enumeration actually reads. The fixture holds each shape
-- that decides a name: a plain module, an underscore module the
-- visibility rule drops, a directory that is a module because it has an
-- `init.tl`, a directory that is not one because it does not, and a
-- test file, which is not a module at all.
local function test_modules_reads_the_tree_by_position()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "surface")
  for _, dir in ipairs({"cosmic/box", "cosmic/loose"}) do
    assert(fs.make_dirs(fs.join(root, dir)))
  end
  assert(fs.write(fs.join(root, "cosmic", "shiny.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "cosmic", "_internal.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "cosmic", "shiny_test.tl"), "print(1)\n"))
  assert(fs.write(fs.join(root, "cosmic", "shiny_example.tl"), "print(1)\n"))
  assert(fs.write(fs.join(root, "cosmic", "init.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "cosmic", "box", "init.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "cosmic", "box", "shard.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "cosmic", "loose", "note.tl"), "return {}\n"))

  local got = table.concat(surface.modules(root), " ")
  assert(got == "cosmic.box cosmic.shiny", "got: " .. got)
end
test_modules_reads_the_tree_by_position()

-- A tree with no `cosmic/` has no surface, rather than an error the
-- gate above would have to decide what to do with.
local function test_a_tree_without_cosmic_has_no_surface()
  local root = check.must(os.getenv("TEST_TMPDIR"))
  local got = surface.modules(fs.join(root, "nowhere"))
  assert(#got == 0, "expected no names, got " .. #got)
end
test_a_tree_without_cosmic_has_no_surface()

print("all public surface ratchet tests passed")
