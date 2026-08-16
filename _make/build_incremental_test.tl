#!/usr/bin/env cosmic
-- Incremental-build tests for the graph verbs: staleness detection,
-- dependency propagation, and per-test rerun scope. Split out of
-- build_test.tl on the seam it already had -- these are the tests
-- about WHAT triggers a rebuild, not about a verb's end-to-end
-- behaviour.
--
-- Like build_test.tl these drive a REAL make over fixture projects,
-- because incrementality is not observable from the Teal side. The
-- engine is named through COSMIC_MAKE, exactly as in build_test.tl.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE")
  or "o/make")
-- Skip locally, FAIL in CI. A cold checkout should not fail for lacking
-- a build; CI always provisions the engine, so its absence there means
-- provisioning broke -- and the whole `--make` graph-test surface
-- silently becoming green skips is the failure this guards (029).
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "incr-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  -- A directory is not a project until it says so. Fixtures that
  -- declare a root themselves keep theirs; the rest get the marker
  -- that means "yes, this one" so the fixture tests what it is about.
  if not fs.is_file(fs.join(root, "main.tl"))
  and not fs.is_file(fs.join(root, "main.lua"))
  and not fs.is_file(fs.join(root, ".cosmicignore")) then
    assert(fs.write(fs.join(root, ".cosmicignore"), ""))
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
  local h = check.must(child.start(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

--- A project with a package, an entry, a test, a .lua source, and an
--- asset -- one of everything the rules have a pattern for.
local function app(name: string): string
  local files: {string: string} = {
    ["db/init.tl"] = "local record Db\n  name: function(): string\nend\n" ..
    "local M: Db = {name = function(): string return 'app' end}\nreturn M\n",
    ["db/db_test.tl"] = "local db = require('db')\n" ..
    "assert(db.name() == 'app', 'name')\n",
    ["legacy.lua"] = "return { x = 1 }\n",
    ["schema.sql"] = "CREATE TABLE t(x);\n",
  }
  -- The binary lives at cmd/<name>/, named for the tree, so the artifact
  -- is `build-<name>` no matter what the scratch directory is called.
  files["cmd/build-" .. name .. "/main.tl"] =
  "local db = require('db')\nprint(db.name())\n"
  return fixture(name, files)
end

-- Incrementality is the reason there is a graph at all: a second build
-- with nothing changed must do no work.
--
-- Asserted on the STEPS, not on make's phrasing. The driver prints one
-- short line per step it runs, so "no work" is "no step lines" -- the
-- claim worth making, and it survives make running silently (`-s`
-- suppresses "Nothing to be done" along with the recipe echo).
local function test_build_is_incremental()
  local root = app("incremental")
  local first = make(root, "build")
  assert(first.code == 0, "first build")
  assert(first.out:find("compile ", 1, true),
    "the first build compiles something, got: " .. first.out)
  local again = make(root, "build")
  assert(again.code == 0, "second build")
  assert(not again.out:find("compile ", 1, true),
    "a second build must run no steps, got: " .. again.out .. again.err)
  assert(not again.out:find("copy ", 1, true),
    "not even a copy, got: " .. again.out .. again.err)
end
test_build_is_incremental()

-- A strict compile checks against the SOURCES it imports, so changing a
-- module's contract must recompile its importers. Before srcdeps landed
-- this was a stale-build bug of the worst kind: a clean build FAILED and
-- the incremental build PASSED, so `o/` kept output the checker rejects.
local function test_a_changed_contract_recompiles_its_importers()

  -- The same property for a DECLARATION. The checker resolves
  -- `require("ffi")` to `ffi.d.tl` when one sits beside `ffi.lua` -- the
  -- pattern the validator explicitly protects -- so a closure that
  -- excludes `.d.tl` means editing the declaration moves no listed
  -- prerequisite's mtime and importers are never re-checked:
  -- incremental PASS, clean FAIL, on one tree.
  local function test_a_changed_declaration_recompiles_its_importers()
    local root = fixture("declaration", {
        ["ffi.lua"] = 'return { greet = function(n) return "hi " .. n end }\n',
        ["ffi.d.tl"] = "local record ffi\n" ..
        "  greet: function(name: string): string\nend\nreturn ffi\n",
        ["cmd/app/main.tl"] = "local ffi = require('ffi')\nprint(ffi.greet('world'))\n",
      })
    assert(make(root, "build").code == 0, "the declaration holds at first")

    -- greet is gone from the contract; main still calls it.
    assert(fs.write(fs.join(root, "ffi.d.tl"),
        "local record ffi\n  other: function(name: string): string\n" ..
        "end\nreturn ffi\n"))
    local r = make(root, "build")
    assert(r.code == 1,
      "a broken declaration must fail the incremental build: " .. r.out .. r.err)
    assert(r.err:find("greet", 1, true),
      "and it must be the importer's error about the missing key: " .. r.err)
  end
  test_a_changed_declaration_recompiles_its_importers()
  local root = fixture("contract", {
      ["util.tl"] = "local record U\n  n: function(): integer\nend\n" ..
      "local M: U = {n = function(): integer return 1 end}\nreturn M\n",
      ["cmd/app/main.tl"] = "local u = require('util')\n" ..
      "local x: integer = u.n()\nprint(x)\n",
    })
  assert(make(root, "build").code == 0, "the contract holds at first")

  -- util now returns a string; main still assigns it to an integer.
  assert(fs.write(fs.join(root, "util.tl"),
      "local record U\n  n: function(): string\nend\n" ..
      "local M: U = {n = function(): string return 'one' end}\nreturn M\n"))
  local r = make(root, "build")
  assert(r.code == 1,
    "a broken contract must fail the incremental build: " .. r.out .. r.err)
  assert(r.err:find("expected integer", 1, true),
    "and it must be the importer's type error: " .. r.err)
end
test_a_changed_contract_recompiles_its_importers()

-- The dependency list is named for the fence, never handed to the
-- child. Forwarding it was a silent disaster: a bare path lands as the
-- child's first positional, getopt stops parsing there, and the compile
-- runs the DEPENDENCY as a script -- writing its stdout as the output
-- and reporting a pass for a check that never ran. Same shape as.
local function test_dependencies_never_reach_the_child()
  local root = fixture("depsarg", {
      ["util.tl"] = "return {}\n",
      ["cmd/app/main.tl"] = "local u = require('util')\nprint('main ran', u)\n",
    })
  assert(make(root, "build").code == 0, "build")
  local out = check.must(fs.read(fs.join(root, "o/cmd/app/main.lua")))
  assert(out:find("main ran", 1, true),
    "o/cmd/app/main.lua must be COMPILED main.tl, not some child's stdout: " .. out)
end
test_dependencies_never_reach_the_child()

-- Per-test incrementality: a test RUNS again when something it
-- imports changes, and not when anything else does. Under batched
-- compiles a group edit restamps sibling outputs, so an unrelated
-- test's record STEP may spawn to content-skip -- what it must not do
-- is really re-run, and the probe below reads exactly that: the `.in`
-- record's mtime moves only when the step ran for real.
local function test_a_test_reruns_only_for_what_it_imports()
  local function in_mtime(root: string, name: string): string
    local mt = check.must(
      fs.stat(fs.join(root, "o/db/" .. name .. ".tl.test.in"))):modify_time()
    return tostring(mt.secs) .. "." .. tostring(mt.nsecs)
  end
  local root = fixture("incremental-deps", {
      ["cmd/app/main.tl"] = "print('x')\n",
      ["db/init.tl"] = "local record D\n  n: function(): integer\nend\n" ..
      "local M: D = {n = function(): integer return 1 end}\nreturn M\n",
      ["db/a_test.tl"] = "local d = require('db')\nassert(d.n() == 1)\n",
      ["db/b_test.tl"] = "assert(true)\n",
    })
  assert(make(root, "test").code == 0, "first run")
  local a1 = in_mtime(root, "a_test")
  local b1 = in_mtime(root, "b_test")

  -- main.tl is imported by neither test.
  assert(fs.write(fs.join(root, "cmd/app/main.tl"), "print('changed')\n"))
  local unrelated = make(root, "test")
  assert(unrelated.code == 0, "second run: " .. unrelated.err)
  assert(in_mtime(root, "a_test") == a1 and in_mtime(root, "b_test") == b1,
    "no test imports main.tl, so none should really re-run")

  -- db/init.tl is imported by a_test only.
  assert(fs.write(fs.join(root, "db/init.tl"),
      "local record D\n  n: function(): integer\nend\n" ..
      "local M: D = {n = function(): integer return 1 end}\n-- edit\nreturn M\n"))
  local related = make(root, "test")
  assert(related.code == 0, "third run: " .. related.err)
  assert(in_mtime(root, "a_test") ~= a1, "the importer must really re-run")
  assert(in_mtime(root, "b_test") == b1,
    "a non-importer may spawn to content-skip, never really re-run")
  -- And the closure travels in the line, which is what the fence
  -- grants. Asserted against the FACTS (`o/project.mk`, which the rule
  -- reads as `--deps $(deps_$*)`) rather than a recipe echo.
  local facts = check.must(fs.read(fs.join(root, "o/project.mk")))
  assert(facts:find("deps_db/a_test := o/db/init.lua", 1, true),
    "a_test's closure is its import, computed into the facts: " .. facts)
  assert(facts:find("deps_db/b_test :=", 1, true)
    and not facts:find("deps_db/b_test := o/", 1, true),
    "b_test imports nothing, so its closure names no module: " .. facts)
end
test_a_test_reruns_only_for_what_it_imports()

print("all build incremental tests passed")
