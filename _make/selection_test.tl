#!/usr/bin/env cosmic
-- What a PATH means to each verb.
--
-- One rule decides all of these: selection names targets of the verb's
-- own kind, and never changes what a target means. `test` states it as
-- "selection changes which tests run, never what gets staged"; `build`
-- takes binaries, `fmt` and `check` take sources. Split out of
-- build_test.tl when that file crossed the 500-line cap, on the seam it
-- already had -- these are the tests about selection, not about the
-- graph verbs' own behaviour.
--
-- Like build_test.tl these drive a REAL make over fixture projects,
-- because selection travels as a command-line variable override and
-- that is not observable from the Teal side.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/cosmo-make")
-- Skip locally, FAIL in CI (029): a graph-test surface that silently
-- becomes green skips is the failure this guards.
if not check.needs("the make engine at " .. make_bin, fs.isfile(make_bin)) then
  os.exit(2)
end

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "select-" .. name)
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

--- A project with a package, an entry and a test.
local function app(name: string): string
  return fixture(name, {
      ["main.tl"] = "local db = require('db')\nprint(db.name())\n",
      ["db/init.tl"] = "local record Db\n  name: function(): string\nend\n" ..
      "local M: Db = {name = function(): string return 'app' end}\nreturn M\n",
      ["db/db_test.tl"] = "local db = require('db')\n" ..
      "assert(db.name() == 'app', 'name')\n",
    })
end

-- Selection travels as a command-line variable override, which beats
-- the assignment in o/project.mk. No rule knows about selection, which
-- is what lets the rules file stay constant.
local function test_selection_narrows_the_graph()
  local root = app("selection")
  local r = make(root, "fmt", "db")
  assert(r.code == 0, "selected fmt should succeed: " .. r.err)
  assert(r.out:find("fmt: PASS (2 files)", 1, true),
    "db/ holds two formattable sources, got: " .. r.out)
end
test_selection_narrows_the_graph()

-- A selection matching nothing is an error before make is ever started.
local function test_empty_selection_fails()
  local root = app("badselection")
  local r = make(root, "fmt", "nope")
  assert(r.code == 1, "an empty selection must fail")
  assert(r.err:find("nothing to do under: nope", 1, true), "got: " .. r.err)
end
test_empty_selection_fails()

-- Selection names targets of the verb's OWN KIND. `build`'s targets are
-- binaries, so `build cmd/foo` builds foo -- it used to compile a few
-- files, produce no artifact at all, and report PASS for it. And a
-- selected build stages what a full one would, so the compile is never
-- narrowed: that is the same invariant `test` states as "selection
-- changes which tests run, never what gets staged".
local function test_build_selects_binaries()
  local root = fixture("buildsel", {
      ["main.tl"] = "print('root')\n",
      ["lib/x.tl"] = "return {}\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
    })
  local r = make(root, "build", "cmd/tool")
  assert(r.code == 0, "selecting a binary should build it: " .. r.err)
  assert(fs.isfile(fs.join(root, "o/bin/tool")),
    "the selected binary is built, not merely compiled: " .. r.out)
  assert(not fs.exists(fs.join(root, "o/bin/buildsel")),
    "and the one that was not selected is not")
  -- The whole tree still compiled: staging must not depend on which
  -- binary was asked for.
  assert(fs.isfile(fs.join(root, "o/lib/x.lua")), "the tree compiled")

  local byname = make(root, "build", "tool")
  assert(byname.code == 0, "a binary is selectable by name too: " .. byname.err)
end
test_build_selects_binaries()

-- A source path is not a binary, and `check` is the verb that takes
-- one. Refusing says so instead of reporting PASS for a compile the
-- user did not ask for.
local function test_build_refuses_a_source_path()
  local root = app("buildsrc")
  local r = make(root, "build", "db")
  assert(r.code == 1, "a source path must not select a binary")
  assert(r.err:find("no binary named by: db", 1, true), "got: " .. r.err)
  assert(r.err:find("use `check`", 1, true),
    "the refusal must point at the verb that does take sources: " .. r.err)
end
test_build_refuses_a_source_path()

print("all selection tests passed")
