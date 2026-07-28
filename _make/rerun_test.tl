#!/usr/bin/env cosmic
-- What re-runs, and what does not: per-target invalidation, end to end.
--
-- Beside build_test.tl and driving the same real make, because the
-- claim here is not "the graph builds" but "the graph schedules the
-- right targets" -- and both ways of getting that wrong are quiet. Too
-- LITTLE and a stage reports the previous run's result as this run's
-- pass, which is what a ratchet over a committed file hit: nothing
-- imports `.github/workflows/*.yml`, so nothing re-ran when one
-- changed. Too MUCH and every edit re-runs the whole suite, which is
-- exactly when you are iterating and least want it.
--
-- The engine is named through COSMIC_MAKE so the test drives a known
-- binary rather than whatever `/zip/make` this build embeds. When there
-- is none to name, the file skips rather than fails: it is testing the
-- graph, not the availability of a make.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/make")
-- Skip locally, FAIL in CI. A cold checkout should not fail for lacking
-- a build; CI always provisions the engine, so its absence there means
-- provisioning broke -- and the whole `--make` graph-test surface
-- silently becoming green skips is the failure this guards (029).
if not check.needs("the make engine at " .. make_bin, fs.isfile(make_bin)) then
  os.exit(check.EXIT_SKIP)
end

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "rerun-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  return root
end

--- Run `cosmic --make …` inside dir, with the engine named.
local function make(dir: string, ...: string): Run
  local argv: {string} = {cosmic, "--make"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

-- Per-test incrementality: a test re-runs when something it IMPORTS
-- changes, and not when anything else does. Before the import closure
-- landed, every test depended on every compiled file, so editing any
-- module re-ran the whole suite -- which is exactly when you are
-- iterating and least want it.
local function test_a_test_reruns_only_for_what_it_imports()
  local root = fixture("incremental-deps", {
      ["main.tl"] = "print('x')\n",
      ["db/init.tl"] = "local record D\n  n: function(): integer\nend\n" ..
      "local M: D = {n = function(): integer return 1 end}\nreturn M\n",
      ["db/a_test.tl"] = "local d = require('db')\nassert(d.n() == 1)\n",
      ["db/b_test.tl"] = "assert(true)\n",
    })
  assert(make(root, "test").code == 0, "first run")

  -- main.tl is imported by neither test.
  assert(fs.write(fs.join(root, "main.tl"), "print('changed')\n"))
  local unrelated = make(root, "test")
  assert(unrelated.code == 0, "second run: " .. unrelated.err)
  assert(not unrelated.out:find("record o/db/", 1, true),
    "no test imports main.tl, so none should re-run: " .. unrelated.out)

  -- db/init.tl is imported by a_test only.
  assert(fs.write(fs.join(root, "db/init.tl"),
      "local record D\n  n: function(): integer\nend\n" ..
      "local M: D = {n = function(): integer return 1 end}\n-- edit\nreturn M\n"))
  local related = make(root, "test")
  assert(related.code == 0, "third run: " .. related.err)
  assert(related.out:find("record o/db/a_test", 1, true),
    "the importer must re-run: " .. related.out)
  assert(not related.out:find("record o/db/b_test", 1, true),
    "a test that does not import it must NOT re-run: " .. related.out)
  -- And the closure travels in the line, which is what the fence
  -- grants. Asserted against the FACTS rather than a recipe echo:
  -- `o/project.mk` is where the closure is computed and the rule reads
  -- it as `--deps $(deps_$*)`. make runs silently (`-s`), so a recipe
  -- echo is not a place this claim can be read -- and the facts file
  -- is the better one regardless.
  local facts = check.must(fs.read(fs.join(root, "o/project.mk")))
  assert(facts:find("deps_db/a_test := o/db/init.lua", 1, true),
    "a_test's closure is its import, computed into the facts: " .. facts)
  assert(facts:find("deps_db/b_test :=", 1, true)
    and not facts:find("deps_db/b_test := o/", 1, true),
    "b_test imports nothing, so its closure names no module: " .. facts)
end
test_a_test_reruns_only_for_what_it_imports()

-- The other half of the same claim, for the files a test READS. A
-- ratchet's subject is not an import, so nothing scheduled on it: an
-- incremental run left the target up to date and the stage reported
-- the previous run's pass, and only a fresh tree caught the drift.
-- Three edits, because the failures differ -- a changed file, a new
-- one, and a deleted one, the last of which no surviving prerequisite
-- can show.
local function test_a_test_reruns_for_the_data_it_declares()
  local root = fixture("declared-reads", {
      ["main.tl"] = "print('x')\n",
      ["docs/a.md"] = "a\n",
      ["ratchet_test.tl"] = "-- @reads docs/*.md\nassert(true)\n",
      ["other_test.tl"] = "assert(true)\n",
    })
  assert(make(root, "test").code == 0, "first run")

  assert(fs.write(fs.join(root, "docs/a.md"), "edited\n"))
  local edited = make(root, "test")
  assert(edited.code == 0, "second run: " .. edited.err)
  assert(edited.out:find("record o/ratchet_test", 1, true),
    "an edited subject must re-run its reader: " .. edited.out)
  assert(not edited.out:find("record o/other_test", 1, true),
    "and nothing else: " .. edited.out)

  assert(fs.write(fs.join(root, "docs/b.md"), "b\n"))
  local added = make(root, "test")
  assert(added.code == 0, "third run: " .. added.err)
  assert(added.out:find("record o/ratchet_test", 1, true),
    "a new subject must re-run the reader: " .. added.out)

  assert(fs.unlink(fs.join(root, "docs/b.md")))
  local removed = make(root, "test")
  assert(removed.code == 0, "fourth run: " .. removed.err)
  assert(removed.out:find("record o/ratchet_test", 1, true),
    "and so must a deleted one -- the case every surviving file's " ..
    "mtime hides: " .. removed.out)

  -- The declaration is a prerequisite and NOT part of the recipe line:
  -- the fence already grants a test the project it belongs to, so this
  -- channel claims scheduling and nothing more.
  local facts = check.must(fs.read(fs.join(root, "o/project.mk")))
  assert(facts:find("datadeps_ratchet_test := docs docs/a.md", 1, true),
    "the declaration is a fact about the tree: " .. facts)
  -- Matched from the line's start, or `datadeps_…` answers for
  -- `deps_…` and the claim tests nothing.
  local closure = facts:match("\ndeps_ratchet_test := ([^\n]*)")
  assert(closure == "", "the import closure stays imports only, got: " ..
    tostring(closure))
end
test_a_test_reruns_for_the_data_it_declares()

print("all rerun tests passed")
