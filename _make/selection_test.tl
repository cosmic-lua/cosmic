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
local child = require("cosmic.child")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE")
  or "o/make")
-- Skip locally, FAIL in CI: a graph-test surface that silently becomes
-- green skips is the failure this guards.
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "select-" .. name)
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

--- A project with a package, an entry and a test.
local function app(name: string): string
  return fixture(name, {
      ["cmd/app/main.tl"] = "local db = require('db')\nprint(db.name())\n",
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
-- binaries, so `build cmd/foo` builds foo, rather than compiling a few
-- files, producing no artifact at all, and reporting PASS for it. And a
-- selected build stages what a full one would, so the compile is never
-- narrowed: that is the same invariant `test` states as "selection
-- changes which tests run, never what gets staged".
local function test_build_selects_binaries()
  local root = fixture("buildsel", {
      ["cmd/buildsel/main.tl"] = "print('root')\n",
      ["lib/x.tl"] = "return {}\n",
      ["cmd/tool/main.tl"] = "print('tool')\n",
    })
  local r = make(root, "build", "cmd/tool")
  assert(r.code == 0, "selecting a binary should build it: " .. r.err)
  assert(fs.is_file(fs.join(root, "o/bin/tool")),
    "the selected binary is built, not merely compiled: " .. r.out)
  assert(not fs.is_present(fs.join(root, "o/bin/buildsel")),
    "and the one that was not selected is not")
  -- The whole tree still compiled: staging must not depend on which
  -- binary was asked for.
  assert(fs.is_file(fs.join(root, "o/lib/x.lua")), "the tree compiled")

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

-- Every verb answers about paths. A verb that takes a selection
-- restricts to it; a verb that cannot says so. Ignoring one is the
-- third behaviour, and the only one that teaches a spelling which does
-- something else.
local function test_docs_restricts_to_its_selection()
  local root = app("docssel")
  local r = make(root, "docs", "db")
  assert(r.code == 0, "selected docs should succeed: " .. r.err)
  assert(fs.is_file(fs.join(root, "o/docs/db/init.md")),
    "the selected page is written: " .. r.out)
  assert(not fs.is_present(fs.join(root, "o/docs/main.md")),
    "and the unselected one is not: " .. r.out)
end
test_docs_restricts_to_its_selection()

-- `clean` removes the build directory and `ci` is the whole gate:
-- neither has an S-restriction, so both refuse a path and name why.
local function test_whole_project_verbs_refuse_paths()
  local root = app("wholeverbs")
  local c = make(root, "clean", "db")
  assert(c.code == 1, "clean must refuse a selection, not ignore it")
  assert(c.err:find("clean takes no paths", 1, true), "got: " .. c.err)
  assert(c.err:find("removes the build directory", 1, true),
    "the refusal says why: " .. c.err)

  local ci = make(root, "ci", "db")
  assert(ci.code == 1, "ci must refuse a selection")
  assert(ci.err:find("ci takes no paths", 1, true), "got: " .. ci.err)
end
test_whole_project_verbs_refuse_paths()

-- The refusal comes BEFORE the build. In a project whose own binary is
-- the toolchain the gate converges into, refusing after would price a
-- typo at a full rebuild before the two-line complaint; the model
-- already knows the answer, so the answer is given from the model.
local function test_a_bad_selection_refuses_before_building()
  local root = app("earlyrefusal")
  local r = make(root, "test", "nope")
  assert(r.code == 1, "an empty selection must fail")
  assert(r.err:find("nothing to do under: nope", 1, true), "got: " .. r.err)
  assert(not fs.is_present(fs.join(root, "o/bin")),
    "nothing is built to answer a question the model settles: " .. r.out)
end
test_a_bad_selection_refuses_before_building()

print("all selection tests passed")
