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
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local here = fs.join("_make", "testdata")

local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/cosmo-make")
if not fs.isfile(make_bin) then
  print("skip: no make binary at " .. make_bin)
  os.exit(2)
end

--- Copy a fixture out of the tree and return its scratch root.
---
--- The directory keeps the fixture's own name, under a parent: the
--- artifact is named after the project directory, so staging to
--- `fixture-hello/` would build `o/bin/fixture-hello` and quietly test
--- a different thing than the one on disk.
local function staged(name: string): string
  local root = fs.join(tmpdir, "fixtures", name)
  fs.rmrf(root)
  assert(fs.makedirs(fs.dirname(root)))
  local ok, err = fs.copytree(fs.join(here, name), root)
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
  local h = check.must(spawn.spawn({cosmic, "--make", verb}, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Run a built artifact hermetically (see artifact_test on why the
--- environment is named rather than inherited).
local function run(path: string): integer, string
  local env: {string} = {"PATH=" .. (os.getenv("PATH") or ""), "NO_COLOR=1"}
  local h = check.must(spawn.spawn({fs.abspath(path)}, {env = env}))
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
    assert(fs.isfile(path), name .. ": expected artifact " .. path .. "\n" .. out)
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
fixture("luaonly", {luaonly = "hello from lua only"})

-- An asset ships at its relative path and testdata/ does not ship at
-- all — asserted from inside the artifact, which is the only place the
-- distinction is observable.
local assets_root = fixture("assets", {assets = "asset: shipped"})

local function test_testdata_never_ships()
  local zip = require("cosmic.zip")
  local reader = check.must(zip.reader(fs.join(assets_root, "o/bin/assets")))
  local saw_asset, saw_testdata = false, false
  for _, e in ipairs(reader:list()) do
    if e.name == "data/note.txt" then saw_asset = true end
    if e.name:find("testdata", 1, true) then saw_testdata = true end
  end
  reader:close()
  assert(saw_asset, "an asset ships at its relative path")
  assert(not saw_testdata, "testdata/ must never reach an artifact")
end
test_testdata_never_ships()

print("all fixture tests passed")
