#!/usr/bin/env cosmic
-- End-to-end tests for the graph verbs: build, test, fmt, clean.
--
-- These drive a REAL make over fixture projects, because everything
-- interesting about this slice is in the seam: the trailing `;` that
-- makes SHELL interception happen at all, the closed verb vocabulary a
-- recipe line has to be, selection travelling as a command-line
-- variable override, and incrementality. None of that is observable
-- from the Teal side.
--
-- The engine is named through COSMIC_MAKE, since cosmic does not carry
-- one yet. When there is none to name, the file skips rather than
-- fails: it is testing the graph, not the availability of a make.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local mk = require("cosmic.make")
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "bin/cosmo-make")
if not fs.isfile(make_bin) then
  print("skip: no make binary at " .. make_bin)
  os.exit(2)
end

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "build-" .. name)
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

--- A project with a package, an entry, a test, a .lua source, and an
--- asset -- one of everything the rules have a pattern for.
local function app(name: string): string
  return fixture(name, {
      ["main.tl"] = "local db = require('db')\nprint(db.name())\n",
      ["db/init.tl"] = "local record Db\n  name: function(): string\nend\n" ..
      "local M: Db = {name = function(): string return 'app' end}\nreturn M\n",
      ["db/db_test.tl"] = "local db = require('db')\n" ..
      "assert(db.name() == 'app', 'name')\n",
      ["legacy.lua"] = "return { x = 1 }\n",
      ["schema.sql"] = "CREATE TABLE t(x);\n",
    })
end

-- build: every source lands in o/ as compiled Lua, and the .lua source
-- is copied rather than compiled. The artifact itself is 2c; what this
-- slice owns is the tree being built at all.
local function test_build_compiles_the_tree()
  local root = app("compile")
  local r = make(root, "build")
  assert(r.code == 0, "build should succeed, got " .. r.code .. ": " .. r.err)
  assert(r.out:find("build: PASS", 1, true), "got: " .. r.out)
  for _, rel in ipairs({"o/main.lua", "o/db/init.lua", "o/db/db_test.lua",
      "o/legacy.lua", "o/cosmic.mk", "o/project.mk"}) do
    assert(fs.isfile(fs.join(root, rel)), "expected " .. rel)
  end
  -- schema.sql is an asset: the artifact embeds it (2c), the graph does
  -- not compile it.
  assert(not fs.exists(fs.join(root, "o/schema.lua")), "assets are not compiled")
end
test_build_compiles_the_tree()

-- Incrementality is the reason there is a graph at all: a second build
-- with nothing changed must do no work.
local function test_build_is_incremental()
  local root = app("incremental")
  assert(make(root, "build").code == 0, "first build")
  local again = make(root, "build")
  assert(again.code == 0, "second build")
  assert(again.out:find("Nothing to be done", 1, true) or
    again.err:find("Nothing to be done", 1, true),
    "a second build must do nothing, got: " .. again.out .. again.err)
end
test_build_is_incremental()

-- A compile error fails the build and names the file. Strict is not
-- optional: nothing lands in o/ that the checker rejected.
local function test_build_fails_on_a_type_error()
  local root = fixture("typeerror", {
      ["a.tl"] = "local x: integer = 'nope'\nprint(x)\n",
    })
  local r = make(root, "build")
  assert(r.code == 1, "a type error must fail the build, got " .. r.code)
  assert(r.err:find("a.tl", 1, true), "the error must name the file: " .. r.err)
  assert(not fs.exists(fs.join(root, "o/a.lua")),
    "a rejected source must not land in o/")
end
test_build_fails_on_a_type_error()

-- test: runs against the compiled tree and reports. A passing run ends
-- in the verdict line, like every verb.
local function test_test_runs_and_reports()
  local root = app("test")
  local r = make(root, "test")
  assert(r.code == 0, "tests should pass, got " .. r.code .. ": " .. r.err)
  assert(r.out:find("1 checks: 1 passed", 1, true),
    "the report should count one test, got: " .. r.out)
  assert(r.out:find("test: PASS (1 file)", 1, true), "got: " .. r.out)
end
test_test_runs_and_reports()

-- A failing test fails the run WITHOUT stopping the others: the test
-- verb records the result and returns 0, and the report grades. That
-- is the whole reason the verb does not propagate its child's code.
local function test_a_failing_test_does_not_stop_the_run()
  local root = app("failing")
  assert(fs.write(fs.join(root, "db/bad_test.tl"), "assert(false, 'boom')\n"))
  assert(fs.write(fs.join(root, "db/also_test.tl"), "assert(true)\n"))
  local r = make(root, "test")
  assert(r.code == 1, "a failing test must fail the run, got " .. r.code)
  local both = r.out .. r.err
  assert(both:find("boom", 1, true), "the failure must be reported: " .. both)
  -- Every test ran: three .got files, not one and an abort.
  for _, rel in ipairs({"o/db/bad_test.tl.test.got", "o/db/also_test.tl.test.got",
      "o/db/db_test.tl.test.got"}) do
    assert(fs.isfile(fs.join(root, rel)), "expected " .. rel .. " to exist")
  end
end
test_a_failing_test_does_not_stop_the_run()

-- Skip semantics survive the trip through make. `--test` propagates
-- exit 2, so a rule shaped that way would read a deliberate skip as a
-- failed rule; the verb records it instead, and the report grades it as
-- a skip.
local function test_a_skipping_test_is_a_skip_not_a_failure()
  local root = app("skipping")
  assert(fs.write(fs.join(root, "db/skip_test.tl"), "os.exit(2)\n"))
  local r = make(root, "test")
  assert(r.code == 0, "a skip must not fail the run, got " ..
    r.code .. ": " .. r.err)
  assert(r.out:find("1 skipped", 1, true),
    "the report must grade it as a skip, got: " .. r.out)
end
test_a_skipping_test_is_a_skip_not_a_failure()

-- fmt gates every .tl source, and fails on one that is misformatted.
local function test_fmt_gates_formatting()
  local root = app("fmt")
  local clean = make(root, "fmt")
  assert(clean.code == 0, "a formatted tree should pass: " .. clean.err)
  assert(clean.out:find("fmt: PASS", 1, true), "got: " .. clean.out)

  assert(fs.write(fs.join(root, "ugly.tl"), "local x=1\nprint(x)\n"))
  local bad = make(root, "fmt")
  assert(bad.code == 1, "a misformatted file must fail fmt, got " .. bad.code)
  assert((bad.out .. bad.err):find("ugly", 1, true),
    "the failure must name the file")
end
test_fmt_gates_formatting()

-- Selection travels as a command-line variable override, which beats
-- the assignment in o/project.mk. No rule knows about selection, which
-- is what lets the rules file stay constant.
local function test_selection_narrows_the_graph()
  local root = app("selection")
  local r = make(root, "build", "db")
  assert(r.code == 0, "selected build should succeed: " .. r.err)
  assert(r.out:find("build: PASS (2 files)", 1, true),
    "db/ holds two sources, got: " .. r.out)
  assert(fs.isfile(fs.join(root, "o/db/init.lua")), "db/ was built")
  assert(not fs.exists(fs.join(root, "o/main.lua")),
    "main.tl was not selected, so it must not be built")
end
test_selection_narrows_the_graph()

-- A selection matching nothing is an error before make is ever started.
local function test_empty_selection_fails()
  local root = app("badselection")
  local r = make(root, "build", "nope")
  assert(r.code == 1, "an empty selection must fail")
  assert(r.err:find("nothing to do under: nope", 1, true), "got: " .. r.err)
end
test_empty_selection_fails()

-- Validation gates the graph too, and for a sharper reason than it
-- gates check: a filename carrying whitespace would be split across two
-- arguments of a recipe line, so it must never reach make.
local function test_validation_gates_the_graph()
  local root = app("validation")
  assert(fs.write(fs.join(root, "my notes.tl"), "return {}\n"))
  local r = make(root, "build")
  assert(r.code == 1, "a validation error must fail the build")
  assert(r.err:find("path contains whitespace", 1, true), "got: " .. r.err)
  assert(r.out:find("build: FAIL (1 validation error)", 1, true),
    "got: " .. r.out)
end
test_validation_gates_the_graph()

-- The no-network posture, end to end: a project whose pin points at a
-- dead port still builds. Building is not fetching, and a pin that has
-- never been resolved is not a build error. (The structural half --
-- that fetch.tl is the only module that can open a socket at all --
-- is asserted in pin_test.tl, which needs no engine for it.)
local function test_build_never_resolves_a_pin()
  local root = app("pinned")
  assert(fs.makedirs(fs.join(root, "3p")))
  assert(fs.write(fs.join(root, "3p/blob.pin.tl"),
      'return {\n  url = "http://127.0.0.1:1/blob.bin",\n' ..
      '  sha256 = "e0997b6447e07ef18b6304a2b88ded9b24106e5bd67b40fab' ..
      'b73e7c1fff37d22",\n}\n'))
  local r = make(root, "build")
  assert(r.code == 0, "a build must not resolve pins, got " ..
    r.code .. ": " .. r.err)
  assert(not fs.exists(fs.join(root, "3p/blob.bin")),
    "build must not have fetched anything")
end
test_build_never_resolves_a_pin()

-- 2e, end to end: no engine named, nothing installed, and the build
-- still runs. This is the promise the whole design is for -- one
-- binary, offline, no host toolchain -- and it is the only test here
-- that deliberately does NOT set COSMIC_MAKE.
local function test_builds_with_no_engine_named()
  local root = app("embedded")
  local argv: {string} = {cosmic, "--make", "build"}
  local h = check.must(spawn.spawn(argv, {
        cwd = root,
        -- PATH stays: the extracted engine is a fat APE whose shell
        -- stub needs a POSIX environment to reach its loader. What is
        -- withheld is COSMIC_MAKE, and find_make never consults PATH
        -- (asserted in graph_test), so the engine can only have come
        -- out of the binary -- which o/make below is the evidence for.
        env = {"PATH=" .. (os.getenv("PATH") or ""),
          "TMPDIR=" .. tmpdir, "NO_COLOR=1", "COSMIC_NO_WELCOME=1"},
      }))
  local r = check.must(h:wait())
  local out = (r.stdout or "") .. (r.stderr or "")
  assert(r.code == 0, "a build with no engine named must work: " .. out)
  assert(fs.isfile(fs.join(root, "o/make")),
    "the engine should have extracted itself to o/make")
  assert(fs.isfile(fs.join(root, "o/bin/build-embedded")),
    "…and produced the artifact")
end
test_builds_with_no_engine_named()

-- The test fence, portable half: a test's temp directory lands inside
-- its own step, not in a shared /tmp. This is what stops tests
-- colliding through the temp directory at all, and unlike the kernel
-- half it holds on every platform -- which is why it is asserted here
-- rather than only in the enforce lane's canary.
local function test_a_test_gets_its_own_scratch_directory()
  local root = app("scratch")
  assert(fs.write(fs.join(root, "db/tmp_test.tl"),
      'local t = os.getenv("TEST_TMPDIR")\n' ..
      'assert(t, "TEST_TMPDIR must be set")\n' ..
      'print("tmpdir=" .. t)\n'))
  local r = make(root, "test")
  assert(r.code == 0, "tests should pass: " .. r.err)
  local got = check.must(fs.read(
      fs.join(root, "o/db/tmp_test.tl.test.out")))
  local where = got:match("tmpdir=([^\n]+)")
  assert(where, "the test should report its TEST_TMPDIR, got: " .. got)
  assert(where:find("o/db/tmp_test.tl.test.tmp.d", 1, true),
    "a test's scratch must live inside its own step, got: " .. where)
end
test_a_test_gets_its_own_scratch_directory()

-- clean removes o/ in process: driving it through a graph whose rules
-- live in o/ is a knot with no payoff.
local function test_clean_removes_the_build_directory()
  local root = app("clean")
  assert(make(root, "build").code == 0, "build first")
  assert(fs.isdir(fs.join(root, "o")), "o/ should exist")
  local r = make(root, "clean")
  assert(r.code == 0, "clean should succeed: " .. r.err)
  assert(not fs.exists(fs.join(root, "o")), "o/ should be gone")
  local again = make(root, "clean")
  assert(again.code == 0, "cleaning a clean tree is not an error")
  assert(again.out:find("nothing to remove", 1, true), "got: " .. again.out)
end
test_clean_removes_the_build_directory()

-- The same verbs in process, against a named root. A spawned child's
-- lines are attributed to the binary's embedded copy and vanish from
-- coverage, so without this the graph half of --make reads as dead
-- code -- and it is the other real calling convention besides the CLI.
--
-- It is also the regression test for resolving this binary before the
-- chdir: the test process is invoked as a RELATIVE path from a cwd that
-- is not the fixture, so a path resolved after --make enters the root
-- lands on a nonexistent o/bin/cosmic inside the project. That is the
-- shape of the layout the design recommends downstream (`./cosmic
-- --make ci` from a committed binary), which is why it is asserted
-- rather than left to the CLI tests, where the path is absolute.
local function in_process(root: string, ...: string): integer
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  cenv.set("COSMIC_MAKE", make_bin)
  local argv: {string} = {}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local code = mk.run(argv)
  cenv.unset("COSMIC_MAKE_ROOT")
  cenv.unset("COSMIC_MAKE")
  assert(fs.chdir(cwd))
  return code
end

local function test_in_process_graph_verbs()
  local root = app("inproc")
  assert(in_process(root, "build") == 0, "build in process")
  assert(in_process(root, "test") == 0, "test in process")
  assert(in_process(root, "fmt") == 0, "fmt in process")
  assert(in_process(root, "build", "db") == 0, "selection in process")
  assert(in_process(root, "build", "nope") == 1, "a bad selection fails")
  assert(in_process(root, "clean") == 0, "clean in process")

  local broken = fixture("inproc-invalid", {["my notes.tl"] = "return {}\n"})
  assert(in_process(broken, "build") == 1, "validation gates the graph")
end
test_in_process_graph_verbs()

print("all build tests passed")
