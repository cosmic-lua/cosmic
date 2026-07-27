#!/usr/bin/env cosmic
-- Tests for _make.graph: the two files make reads.
--
-- The design rests on one property -- the rules are CONSTANT and only
-- the facts are generated -- so that is what these assert directly:
-- o/cosmic.mk is byte-identical for two different projects and equal to
-- the copy in the tree, and o/project.mk contains variable assignments
-- and nothing else. A rule that leaked into the generated file would
-- pass every behavioural test and still break the design.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "graph-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  local proj = check.must(project.scan(root))
  return proj
end

--- Run fn with cwd inside dir, restoring it afterward.
local function in_dir<T>(dir: string, fn: function(): T): T
  local cwd = check.must(fs.getcwd())
  assert(fs.chdir(dir))
  local got = fn()
  assert(fs.chdir(cwd))
  return got
end

local app = fixture("app", {
    ["main.tl"] = "print('x')\n",
    ["db/init.tl"] = "return {}\n",
    ["db/db_test.tl"] = "return {}\n",
    ["db/thing_example.tl"] = "return {}\n",
    ["types/lpeg.d.tl"] = "local record l end\nreturn l\n",
    ["legacy.lua"] = "return {}\n",
    ["schema.sql"] = "x\n",
    ["db/testdata/f.json"] = "{}\n",
  })

-- Variables and nothing else. A generated file that can only assign
-- cannot encode a rule, which is what keeps the rules constant and
-- keeps this repo's makefile ratchets from having to scan recipe text.
local function test_project_mk_is_assignments_only()
  local text = graph.project_mk(app, "/bin/cosmic")
  local n = 0
  for line in string.gmatch(text, "[^\n]+") do
    if line:sub(1, 1) ~= "#" then
      n = n + 1
      -- A make variable name may hold anything but whitespace, `:`,
      -- `=` and `#`, and the per-test dependency variables use the
      -- test's path as their name (`deps_db/a_test`).
      assert(line:match("^[^%s:=#]+ :=") ~= nil,
        "not an assignment: " .. line)
    end
    assert(not line:find("\t", 1, true),
      "a tab means a recipe line: " .. line)
  end
  assert(n >= 8, "expected the fact variables, got " .. n)
end
test_project_mk_is_assignments_only()

-- The facts themselves: what the walk found, spelled relative to the
-- root, sorted so the file is a function of the tree and nothing else.
local function test_project_mk_facts()
  local text = graph.project_mk(app, "/bin/cosmic")
  local function value(name: string): string
    return text:match("\n" .. name .. " := ([^\n]*)") or
    text:match("^" .. name .. " := ([^\n]*)") or ""
  end
  assert(value("COSMIC") == "/bin/cosmic", "got: " .. value("COSMIC"))
  assert(value("O") == "o", "got: " .. value("O"))
  assert(value("project") == "graph-app", "got: " .. value("project"))
  assert(value("tl_sources") ==
    "db/db_test.tl db/init.tl db/thing_example.tl main.tl",
    "compiled sources, sorted: " .. value("tl_sources"))
  assert(value("lua_sources") == "legacy.lua", "got: " .. value("lua_sources"))
  assert(value("tests") == "db/db_test.tl", "got: " .. value("tests"))
  assert(value("examples") == "db/thing_example.tl", "got: " .. value("examples"))
  assert(value("assets") == "schema.sql", "got: " .. value("assets"))
  -- fmt covers every .tl, declarations included; testdata never appears
  -- anywhere, which is its only job.
  assert(value("fmt_sources"):find("types/lpeg.d.tl", 1, true),
    "fmt covers .d.tl: " .. value("fmt_sources"))
  assert(not text:find("testdata", 1, true),
    "testdata must not reach the graph: " .. text)
end
test_project_mk_facts()

-- One dependency closure per test, so a test re-runs for what it
-- imports and nothing else -- and the fence grants the same set. This
-- is the whole reason the facts are computed in Teal: a makefile cannot
-- follow a require() edge.
local function test_project_mk_carries_per_test_closures()
  local proj = fixture("closures", {
      ["db/init.tl"] = "local u = require('util')\nreturn u\n",
      ["util.tl"] = "return {}\n",
      ["lonely.tl"] = "return {}\n",
      ["db/a_test.tl"] = "local d = require('db')\nreturn d\n",
      ["b_test.tl"] = "assert(true)\n",
    })
  local text = graph.project_mk(proj, "/bin/cosmic")
  assert(text:find("deps_db/a_test := o/db/init.lua o/util.lua", 1, true),
    "the closure is transitive: " .. text)
  assert(text:match("deps_b_test :=%s*\n"),
    "a test importing nothing gets an empty closure: " .. text)
  -- lonely.tl is a source, so it appears in the source lists; what it
  -- must never appear in is a closure.
  for line in string.gmatch(text, "[^\n]+") do
    if line:sub(1, 5) == "deps_" then
      assert(not line:find("lonely", 1, true),
        "a module nobody imports is in no closure: " .. line)
    end
  end
end
test_project_mk_carries_per_test_closures()

-- Deterministic: same tree, same bytes. Sorting is what makes the file
-- a function of the project rather than of directory order.
local function test_project_mk_is_deterministic()
  local a = graph.project_mk(app, "/bin/cosmic")
  local b = graph.project_mk(app, "/bin/cosmic")
  assert(a == b, "project.mk must not depend on iteration order")
end
test_project_mk_is_deterministic()

-- The rules file is constant. Two different projects, byte-identical
-- o/cosmic.mk -- and it is the file in the tree, so what ships and what
-- is reviewed are the same bytes.
local function test_rules_are_constant()
  local other = fixture("other", {["cmd/x/main.tl"] = "print('y')\n"})
  local first = in_dir(app.root, function(): string
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local text = check.must(fs.read("o/cosmic.mk"))
      return text
    end)
  local second = in_dir(other.root, function(): string
      assert(check.must(graph.materialize(other, "/bin/cosmic")))
      local text = check.must(fs.read("o/cosmic.mk"))
      return text
    end)
  assert(first == second, "the rules file must not vary by project")
  local packed = check.must(fs.read(graph.RULES_ZIP))
  assert(first == packed, "o/cosmic.mk must be the packed copy verbatim")
  local source = check.must(fs.read("embed/cosmic.mk"))
  assert(packed == source,
    "the packed rules must be the file in the tree, not a stale copy")
end
test_rules_are_constant()

-- Write-if-changed: re-running a verb must not invalidate the graph it
-- just built. Content decides; mtime only schedules.
local function test_materialize_does_not_touch_unchanged_files()
  in_dir(app.root, function(): boolean
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local before = check.must(fs.stat("o/project.mk"))
      local sec, nsec = before:mtim()
      assert(fs.utimensat("o/project.mk", 0, 0, 0, 0))
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local after = check.must(fs.stat("o/project.mk"))
      local sec2 = after:mtim()
      assert(sec2 == 0, "unchanged facts must not be rewritten")
      assert(sec ~= nil and nsec ~= nil, "stat should report a time")
      return true
    end)
end
test_materialize_does_not_touch_unchanged_files()

-- The engine is named or it is pinned, never guessed. A `make` sitting
-- on PATH must not be picked up: a build whose engine came from the
-- host is a build nobody can reproduce.
local function test_find_make_never_searches_path()
  local box = fs.join(tmpdir, "graph-nomake")
  fs.rmrf(box)
  assert(fs.makedirs(fs.join(box, "bin")))
  assert(fs.write(fs.join(box, "bin", "make"), "#!/bin/sh\nexit 0\n",
      tonumber("755", 8) as integer)) -- cast: octal is integral
  local saved_path = cenv.get("PATH")
  local saved_make = cenv.get("COSMIC_MAKE")
  cenv.unset("COSMIC_MAKE")
  cenv.set("PATH", fs.join(box, "bin"))
  local found = in_dir(box, function(): string
      local g = graph.find_make()
      return g or ""
    end)
  cenv.set("PATH", saved_path or "")
  if saved_make then
    cenv.set("COSMIC_MAKE", saved_make)
  end
  -- Not "" any more: with the engine embedded, find_make extracts one.
  -- What must never happen is picking up the host's.
  assert(found ~= fs.join(box, "bin", "make"),
    "PATH must not be searched, but the host's make was chosen: " .. found)
  assert(found == fs.join(box, "o", "make"),
    "the engine must be the extracted one, got: " .. found)
end
test_find_make_never_searches_path()

-- COSMIC_MAKE names it; a name that is not there fails by name rather
-- than falling back to something else.
local function test_find_make_honors_the_override()
  local saved = cenv.get("COSMIC_MAKE")
  local real = fs.join(tmpdir, "graph-make-stub")
  assert(fs.write(real, "#!/bin/sh\nexit 0\n"))
  cenv.set("COSMIC_MAKE", real)
  local got = check.must(graph.find_make())
  assert(got == fs.abspath(real), "got: " .. got)

  cenv.set("COSMIC_MAKE", fs.join(tmpdir, "graph-no-such-make"))
  local missing, err = graph.find_make()
  assert(not missing, "a named make that is absent must fail")
  assert(err:find("COSMIC_MAKE names no such file", 1, true),
    "got: " .. tostring(err))

  cenv.unset("COSMIC_MAKE")
  if saved then
    cenv.set("COSMIC_MAKE", saved)
  end
end
test_find_make_honors_the_override()

-- The engine ships in the binary, so a project needs nothing
-- installed. Amends D13, whose rejection reasoned from THIS repo --
-- where both pins are already in hand -- and does not survive the user
-- case, where one binary in a bare sandbox has nothing to find.
local function test_the_engine_ships_in_the_binary()
  local bytes = fs.read(graph.MAKE_ZIP)
  assert(bytes, "the binary must carry an engine at " .. graph.MAKE_ZIP)
  local engine = bytes as string -- cast: scalar narrowing after the guard
  assert(#engine > 100000, "too small to be an engine: " .. #engine)
end
test_the_engine_ships_in_the_binary()

-- Extraction produces something executable. A non-executable engine is
-- the one failure that reads as "no make binary" rather than as a
-- permissions problem.
local function test_extract_make_is_executable()
  local to = fs.join(tmpdir, "graph-engine", "make")
  fs.rmrf(fs.dirname(to))
  local ok, err = graph.extract_make(to)
  assert(ok, "extraction should succeed: " .. tostring(err))
  assert(fs.isfile(to), "the engine should land at " .. to)
  local st = check.must(fs.stat(to))
  local exec_bit = tonumber("100", 8) as integer -- cast: octal is integral
  assert(st:mode() & exec_bit ~= 0, "the extracted engine must be executable")
  assert(not fs.exists(to .. ".tmp"), "the temp file must not survive")
end
test_extract_make_is_executable()

-- With nothing named, find_make extracts rather than refusing. That is
-- the difference between --make being usable and being a demo.
local function test_find_make_extracts_when_nothing_is_named()
  local box = fs.join(tmpdir, "graph-embedded")
  fs.rmrf(box)
  assert(fs.makedirs(box))
  local saved = cenv.get("COSMIC_MAKE")
  cenv.unset("COSMIC_MAKE")
  local found = in_dir(box, function(): string
      local g = graph.find_make()
      return g or ""
    end)
  if saved then
    cenv.set("COSMIC_MAKE", saved)
  end
  assert(found ~= "", "find_make must extract the embedded engine")
  assert(found == fs.join(box, "o/make"), "got: " .. found)
  assert(fs.isfile(found), "…and it must be there")
end
test_find_make_extracts_when_nothing_is_named()

-- Everything is parallel by default; the count is overridable.
local function test_jobs_flag()
  local saved = cenv.get("COSMIC_JOBS")
  cenv.set("COSMIC_JOBS", "3")
  assert(graph.jobs_flag() == "-j3", "got: " .. graph.jobs_flag())
  cenv.set("COSMIC_JOBS", "not a number")
  local derived = graph.jobs_flag()
  assert(derived:match("^%-j%d+$"), "got: " .. derived)
  cenv.unset("COSMIC_JOBS")
  if saved then
    cenv.set("COSMIC_JOBS", saved)
  end
end
test_jobs_flag()

-- The directories a coverage report scans for files no test loaded.
-- Compiled kinds only: a `testdata/` fixture or an `embed/` payload
-- directory holding a .tl is not a source directory, and scanning one
-- would report a deliberately-broken fixture as 0% covered.
local function test_source_dirs_are_the_compiled_ones()
  local proj: types.Project = {
    root = "/p",
    binaries = {},
    files = {
      {path = "main.tl", kind = "entry"} as types.File, -- cast: partial record fixture
      {path = "pkg/a.tl", kind = "module"} as types.File, -- cast: partial record fixture
      {path = "pkg/a_test.tl", kind = "test"} as types.File, -- cast: partial record fixture
      {path = "pkg/testdata/broken.tl", kind = "testdata"} as types.File, -- cast: partial record fixture
      {path = "embed/vendor.tl", kind = "payload"} as types.File, -- cast: partial record fixture
      {path = "README.md", kind = "asset"} as types.File, -- cast: partial record fixture
    },
  }
  local got = table.concat(graph.source_dirs(proj), " ")
  assert(got == ". pkg", "got: " .. got)
end
test_source_dirs_are_the_compiled_ones()

print("all graph tests passed")
