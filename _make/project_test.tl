#!/usr/bin/env cosmic
-- Tests for _make.project: the walk and the classification.
--
-- The model is what every verb builds on, so these are fixture trees on
-- disk rather than unit calls on a synthetic list: what a project IS
-- has to be decidable from the bytes in a directory, and a fixture is
-- the only honest way to assert that.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")

local type File = types.File
local type Kind = types.Kind
local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree from a path -> contents map and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, name)
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

--- The file at rel, or nil.
local function find(proj: Project, rel: string): File | nil
  for _, f in ipairs(proj.files) do
    if f.path == rel then
      return f
    end
  end
  return nil
end

--- Assert a file exists with the given kind, and return it.
local function kind_of(proj: Project, rel: string, want: Kind): File
  local f = find(proj, rel)
  assert(f, "expected " .. rel .. " in the scan")
  local got = f as File -- cast: record union after the guard
  assert(got.kind == want,
    rel .. ": expected kind " .. want .. ", got " .. tostring(got.kind))
  return got
end

-- Every marker in the project-model table, in one tree. This is the
-- table's executable form: a marker that stops declaring what it
-- declares fails here.
local function test_every_marker_classifies()
  local proj = fixture("model", {
      ["main.tl"] = "print('x')\n",
      ["db/init.tl"] = "return {}\n",
      ["db/query.tl"] = "return {}\n",
      ["db/query_test.tl"] = "return {}\n",
      ["db/query_example.tl"] = "return {}\n",
      ["db/testdata/fixture.json"] = "{}\n",
      ["types/lpeg.d.tl"] = "local record lpeg end\nreturn lpeg\n",
      ["3p/lpeg/lpeg_pin.tl"] = "return {url = 'x'}\n",
      ["docs/index_gen.tl"] = "return {}\n",
      ["schema.sql"] = "CREATE TABLE t(x);\n",
      ["cmd/servit/main.tl"] = "print('s')\n",
      ["cmd/servit/routes.tl"] = "return {}\n",
      ["cmd/servit/embed_gen.tl"] = "return {}\n",
      ["cmd/servit/data_gen.tl"] = "return {}\n",
      ["embed_gen.tl"] = "return {}\n",
    })

  kind_of(proj, "main.tl", "entry")
  kind_of(proj, "db/init.tl", "module")
  kind_of(proj, "db/query.tl", "module")
  kind_of(proj, "db/query_test.tl", "test")
  kind_of(proj, "db/query_example.tl", "example")
  kind_of(proj, "db/testdata/fixture.json", "testdata")
  kind_of(proj, "types/lpeg.d.tl", "types")
  kind_of(proj, "3p/lpeg/lpeg_pin.tl", "pin")
  kind_of(proj, "docs/index_gen.tl", "gen")
  -- The reserved basename is its own kind: a BINARY's payload
  -- generator, scoped to the binary and run by `build`, not a
  -- subtree-scoped generation unit run by `regen`.
  kind_of(proj, "cmd/servit/embed_gen.tl", "payload-gen")
  kind_of(proj, "embed_gen.tl", "payload-gen")
  kind_of(proj, "cmd/servit/data_gen.tl", "gen")
  kind_of(proj, "schema.sql", "asset")
  kind_of(proj, "cmd/servit/main.tl", "entry")
  kind_of(proj, "cmd/servit/routes.tl", "module")
end
test_every_marker_classifies()

-- Import path = path relative to the root, extension dropped, / -> .,
-- with init naming its own directory. The project root is the module
-- root, and this rule holds inside the artifact too.
local function test_import_paths()
  local proj = fixture("imports", {
      ["db/init.tl"] = "return {}\n",
      ["db/query.tl"] = "return {}\n",
      ["util.lua"] = "return {}\n",
      ["_internal/log.tl"] = "return {}\n",
    })
  assert(kind_of(proj, "db/init.tl", "module").import == "db",
    "init.tl names its directory")
  assert(kind_of(proj, "db/query.tl", "module").import == "db.query",
    "/ becomes .")
  assert(kind_of(proj, "util.lua", "module").import == "util",
    ".lua sources are first-class")
  assert(kind_of(proj, "_internal/log.tl", "module").import == "_internal.log",
    "an internal module still has an import path; the rule is who may use it")
end
test_import_paths()

-- testdata/ is positional and wins over the suffix markers: its only
-- job is keeping fixtures out of artifacts, and a fixture named like a
-- test is still a fixture.
local function test_testdata_wins_over_suffixes()
  local proj = fixture("testdata", {
      ["db/testdata/sample_test.tl"] = "return {}\n",
      ["db/testdata/nested/deep.tl"] = "return {}\n",
    })
  kind_of(proj, "db/testdata/sample_test.tl", "testdata")
  kind_of(proj, "db/testdata/nested/deep.tl", "testdata")
end
test_testdata_wins_over_suffixes()

-- Binaries: the root entry takes the project's own name, a cmd/ entry
-- takes its directory's.
local function test_binaries()
  local proj = fixture("binaries", {
      ["main.tl"] = "print('x')\n",
      ["cmd/fetchit/main.tl"] = "print('f')\n",
      ["cmd/servit/main.tl"] = "print('s')\n",
    })
  assert(#proj.binaries == 3, "expected 3 binaries, got " .. #proj.binaries)
  local names: {string} = {}
  for _, b in ipairs(proj.binaries) do
    names[#names + 1] = b.name
  end
  assert(table.concat(names, ",") == "binaries,fetchit,servit",
    "got: " .. table.concat(names, ","))
  for _, b in ipairs(proj.binaries) do
    if b.name == "servit" then
      assert(b.dir == "cmd/servit", "cmd binary dir: " .. b.dir)
      assert(b.entry == "cmd/servit/main.tl", "cmd binary entry: " .. b.entry)
    elseif b.name == "binaries" then
      assert(b.dir == "", "the root binary's dir is the root")
    end
  end
end
test_binaries()

-- What the walk never sees. Each of these is a class of file that would
-- otherwise be embedded in an artifact at its relative path: CI
-- workflows, build output, and whatever the project excluded.
local function test_exclusions()
  local proj = fixture("exclusions", {
      [".github/workflows/ci.yml"] = "on: push\n",
      [".hidden"] = "x\n",
      ["o/lib/generated.lua"] = "return {}\n",
      ["build/artifact.bin"] = "x\n",
      ["notes.log"] = "x\n",
      ["vendor/dep/dep.tl"] = "return {}\n",
      ["keep.tl"] = "return {}\n",
      [".cosmicignore"] = "# excluded\nbuild/\n*.log\nvendor\n",
    })
  assert(#proj.files == 1,
    "expected only keep.tl, got " .. #proj.files .. " files")
  kind_of(proj, "keep.tl", "module")
end
test_exclusions()

-- A dot-directory is pruned, not merely skipped: nothing below it is
-- reachable either. Asserted separately because "the entry is
-- classified as an asset" and "the subtree is never walked" fail
-- differently.
local function test_dot_directories_are_pruned()
  local proj = fixture("pruned", {
      [".git/objects/ab/cdef"] = "binary\n",
      ["a.tl"] = "return {}\n",
    })
  assert(#proj.files == 1, "the .git subtree must not be walked")
end
test_dot_directories_are_pruned()

-- An empty project is a project. A fresh `cosmic --make check` in an
-- empty directory must not be an error.
local function test_empty_project()
  local proj = fixture("empty", {})
  assert(#proj.files == 0, "expected no files")
  assert(#proj.binaries == 0, "expected no binaries")
end
test_empty_project()

-- A missing root is a failure with a message, never an empty project:
-- an empty file list is what every verb reads as "nothing to do".
local function test_missing_root_fails()
  local proj, err = project.scan(fs.join(tmpdir, "no-such-project"))
  assert(not proj, "scanning a missing directory must fail")
  assert(err:find("not a directory", 1, true),
    "expected a not-a-directory error, got: " .. tostring(err))
end
test_missing_root_fails()

-- of_kind is how the verbs ask the model for their inputs.
local function test_of_kind()
  local proj = fixture("kinds", {
      ["a.tl"] = "return {}\n",
      ["a_test.tl"] = "return {}\n",
      ["b_test.tl"] = "return {}\n",
      ["c.sql"] = "x\n",
    })
  assert(#project.of_kind(proj, {"test"}) == 2, "two tests")
  assert(#project.of_kind(proj, {"module", "asset"}) == 2, "one module, one asset")
  assert(#project.of_kind(proj, {"entry"}) == 0, "no entry")
end
test_of_kind()

print("all project tests passed")

-- `embed/` is positional like `testdata/`, and for the mirror-image
-- reason: testdata exists to stay OUT of artifacts, payload exists to
-- go IN at a path the one layout rule cannot express. Both win over
-- the suffix markers, so a file under either is what its position says
-- and never what its name would otherwise make it.
local function test_embed_is_payload_whatever_it_is_named()
  assert(project.classify("embed/tl.lua") == "payload", "a payload file")
  assert(project.classify("embed/.tl/cosmic/fs.tl") == "payload",
    "a .tl under embed/ ships; it is not a module to compile")
  assert(project.classify("embed/x_gen.tl") == "payload",
    "a _gen.tl under embed/ ships; it is not a generator to run")
  assert(project.classify("embed/.types/cosmo.d.tl") == "payload",
    "a .d.tl under embed/ ships; it is not type-only")
  -- The directory itself is not payload, and neither is a module that
  -- merely starts with the same letters.
  assert(project.classify("embedded.tl") == "module",
    "a module whose name starts with 'embed' is still a module")
end
test_embed_is_payload_whatever_it_is_named()
