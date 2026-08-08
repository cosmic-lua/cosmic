#!/usr/bin/env cosmic
-- The fixture projects: small, committed, hello-world-sized trees, each
-- exercising one thing `cosmic --make` promises.
--
-- The other --make tests write their fixtures inline, which is right for
-- asserting a rule in isolation but wrong for the question these ask:
-- does a project a person would actually write check, build, and RUN?
-- These live on disk (_make/testdata/**) so they can be read as
-- examples, edited by hand, and built by hand with the same two commands
-- a user would type.
--
-- Each is copied to a scratch directory before building: `--make` writes
-- `o/` into the project root, and the repo's own tree stays clean.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local here = fs.join("_make", "testdata")

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE")
  or "o/make")
-- Skip locally, FAIL in CI. A cold checkout should not fail for lacking
-- a build; CI always provisions the engine, so its absence there means
-- provisioning broke -- and the whole `--make` graph-test surface
-- silently becoming green skips is the failure this guards (029).
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

--- Copy a fixture out of the tree and return its scratch root.
---
--- The directory keeps the fixture's own name only for readability: a
--- binary is named by its `cmd/<name>/` position, not by the checkout
--- directory, so `o/bin/hello` is `o/bin/hello` no matter what the
--- staging parent is called -- which is the property this whole tree
--- exists to hold.
local function staged(name: string): string
  local root = fs.join(tmpdir, "fixtures", name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.dirname(root)))
  local ok, err = fs.copy_tree(fs.join(here, name), root)
  assert(ok, "cannot stage fixture " .. name .. ": " .. tostring(err))
  return root
end

--- `cosmic --make <verb>` inside a fixture.
local function make(dir: string, verb: string): integer, string
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(child.start({cosmic, "--make", verb}, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Run a built artifact hermetically (see artifact_test on why the
--- environment is named rather than inherited).
local function run(path: string): integer, string
  local env: {string} = {"PATH=" .. (os.getenv("PATH") or ""), "NO_COLOR=1"}
  local h = check.must(child.start({fs.absolute_path(path)}, {env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- check + build + run one fixture, asserting each artifact's output.
--- @param name string Fixture directory under testdata/
--- @param want {string: string} Binary name -> a line its output contains
local function fixture(name: string, want: {string: string}): string
  local root = staged(name)

  local code, out = make(root, "check")
  assert(code == 0, name .. ": --make check should pass:\n" .. out)

  code, out = make(root, "build")
  assert(code == 0, name .. ": --make build should pass:\n" .. out)

  for bin, expect in pairs(want) do
    local path = fs.join(root, "o/bin/" .. bin)
    assert(fs.is_file(path), name .. ": expected artifact " .. path .. "\n" .. out)
    local rc, ran = run(path)
    assert(rc == 0, name .. "/" .. bin .. ": artifact should run, got " ..
      rc .. ": " .. ran)
    assert(ran:find(expect, 1, true),
      name .. "/" .. bin .. ": expected " .. expect .. ", got: " .. ran)
  end
  return root
end

-- The smallest project that is a project.
fixture("hello", {hello = "hello from hello"})

-- Import path is position: greet/init.tl is `greet`, greet/loud.tl is
-- `greet.loud`, and nothing declares either.
fixture("pkg", {pkg = "hi pkg"})

-- Two binaries from one tree, each with the root packages plus its own
-- cmd subtree.
fixture("multi", {one = "one: shared", two = "two: shared plus"})

-- `.lua` sources are first-class: this project has no `.tl` at all.
local luaonly_root = fixture("luaonly", {luaonly = "hello from lua only"})

-- First-class means the MARKERS work too. `main_test.lua` classified
-- as a module, so `--make test` saw a project with no tests and
-- `--make build` embedded the test file into the binary -- both
-- silently.
local function test_lua_markers_are_first_class()
  local code, out = make(luaonly_root, "test")
  assert(code == 0, "a .lua test should run: " .. out)
  assert(out:find("1 file", 1, true) or out:find("1 test", 1, true),
    "and be counted, got: " .. out)

  local zip = require("cosmic.zip")
  local reader = check.must(zip.open(fs.join(luaonly_root, "o/bin/luaonly")))
  local shipped = false
  for _, e in ipairs((check.must(reader:list()))) do
    if e.name:find("main_test", 1, true) then shipped = true end
  end
  reader:close()
  assert(not shipped, "a test file must never be embedded in the artifact")
end
test_lua_markers_are_first_class()

-- Shipping is opt-in: `embed/**` ships, and a file that merely sits in
-- the repo does not — asserted from inside the artifact, which is the
-- only place the distinction is observable, and from the running
-- binary, which is where a user meets it.
local assets_root = fixture("assets",
  {assets = "asset: shipped\n\nreadme: absent\n"})

local function test_only_declared_payload_ships()

  -- The other side of the payload promise: a TEST sees `/zip/R` too. The
  -- fixture's note_test.tl reads /zip/data/note.txt directly — under the
  -- test runner (this cosmic plus the root payload), not by spawning the
  -- artifact — so `--make test` passing here is the whole claim.
  local function test_tests_see_the_payload_at_zip()
    local code, out = make(assets_root, "test")
    assert(code == 0, "a test reading /zip payload should pass:\n" .. out)
    assert(fs.is_file(fs.join(assets_root, "o/.testrun/cosmic")),
      "the payload test runner should exist after --make test")
  end
  test_tests_see_the_payload_at_zip()
  local zip = require("cosmic.zip")
  local reader = check.must(zip.open(fs.join(assets_root, "o/bin/assets")))
  local saw: {string: boolean} = {}
  for _, e in ipairs((check.must(reader:list()))) do
    saw[e.name] = true
    assert(not e.name:find("testdata", 1, true),
      "testdata/ must never reach an artifact: " .. e.name)
  end
  reader:close()
  assert(saw["data/note.txt"],
    "payload ships at its path inside embed/")
  assert(not saw["README.md"],
    "a file that is merely IN the repo is not IN the artifact")
end
test_only_declared_payload_ships()

-- The closure a `.lua` target gets is what makes it re-run when an
-- import changes and what its fence grants it a read of. The variable
-- is named after the make STEM -- the path without its extension -- so
-- emitting `deps_main_test.lua` left every `.lua` test with an empty
-- one, silently: never rebuilt, never granted, still green.
local function test_lua_targets_get_their_import_closure()
  local mk = check.must(fs.read(fs.join(luaonly_root, "o/project.mk")))
  assert(mk:find("\ndeps_main_test :=", 1, true),
    "a .lua test's closure is named for its extensionless stem, got:\n" .. mk)
  assert(mk:find("deps_main_test := o/greet.lua", 1, true),
    "and holds what it imports, got:\n" .. mk)
end
test_lua_targets_get_their_import_closure()

-- `--make benchmark` end to end, from a cold tree: a benchmark is
-- `test`'s third sibling, so it gets the same closure -- which is what
-- builds the modules it requires before it runs. With no closure
-- emitted at all, this fixture's `require("greet")` had nothing to
-- resolve.
local function test_benchmark_runs_against_the_stage()
  local root = staged("pkg")
  local code, out = make(root, "benchmark")
  assert(code == 0, "--make benchmark should succeed: " .. out)
  assert(out:find("benchmark: PASS", 1, true), "got: " .. out)
  local mk = check.must(fs.read(fs.join(root, "o/project.mk")))
  assert(mk:find("deps_greet/greet_benchmark := o/greet/init.lua", 1, true),
    "a benchmark gets the built closure of what it imports, got:\n" .. mk)
end
test_benchmark_runs_against_the_stage()

print("all fixture tests passed")
