#!/usr/bin/env cosmic
-- Tests for the import graph.
--
-- Two consumers depend on this being right, and they fail differently:
-- a closure that is too SMALL makes a test miss a rebuild (the graph)
-- and denies it a read (the fence); one that is too LARGE re-runs the
-- suite for unrelated edits and grants more than it should. So the
-- assertions are exact sets, not "contains".

local check = require("cosmic.check")
local deps = require("cosmic.make.deps")
local fs = require("cosmic.fs")
local project = require("cosmic.make.project")
local types = require("cosmic.make.types")

local type File = types.File
local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "deps-" .. name)
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

--- The file at rel.
local function file_at(proj: Project, rel: string): File
  for _, f in ipairs(proj.files) do
    if f.path == rel then
      return f
    end
  end
  error("no file at " .. rel)
end

--- The closure of rel, as one comparable string.
local function closure_of(proj: Project, rel: string): string
  local by_import = deps.index(proj)
  return table.concat(deps.closure(proj, file_at(proj, rel), by_import), " ")
end

-- Transitivity, and the exclusions that matter. `a_test` imports `db`,
-- which imports `util`; `other` is imported by nobody and must not
-- appear. cosmic.* leaves the project, so it is not an edge: it is not
-- an input the graph can schedule on or the fence can grant.
local function test_closure_is_transitive_and_exact()
  local proj = fixture("transitive", {
      ["db/init.tl"] = "local u = require('util')\nreturn u\n",
      ["util.tl"] = "local fs = require('cosmic.fs')\nreturn fs\n",
      ["other.tl"] = "return {}\n",
      ["db/a_test.tl"] = "local d = require('db')\nreturn d\n",
    })
  assert(closure_of(proj, "db/a_test.tl") == "o/db/init.lua o/util.lua",
    "got: " .. closure_of(proj, "db/a_test.tl"))
end
test_closure_is_transitive_and_exact()

-- A test importing nothing from the project has an empty closure, and
-- that is a real answer: it depends on no module, so no module's change
-- should re-run it.
local function test_a_leaf_test_has_no_dependencies()
  local proj = fixture("leaf", {
      ["a.tl"] = "return {}\n",
      ["b_test.tl"] = "assert(true)\n",
    })
  assert(closure_of(proj, "b_test.tl") == "", "got: " .. closure_of(proj, "b_test.tl"))
end
test_a_leaf_test_has_no_dependencies()

-- `.lua` sources are first-class, and they are copied rather than
-- compiled, so their built path keeps the extension.
local function test_lua_modules_are_dependencies_too()
  local proj = fixture("luadep", {
      ["legacy.lua"] = "return {}\n",
      ["x_test.tl"] = "local l = require('legacy')\nreturn l\n",
    })
  assert(closure_of(proj, "x_test.tl") == "o/legacy.lua",
    "got: " .. closure_of(proj, "x_test.tl"))
end
test_lua_modules_are_dependencies_too()

-- A cycle terminates. Whether a project SHOULD have one is the
-- validator's business; this function's business is not hanging.
local function test_a_cycle_terminates()
  local proj = fixture("cycle", {
      ["a.tl"] = "local b = require('b')\nreturn b\n",
      ["b.tl"] = "local a = require('a')\nreturn a\n",
      ["c_test.tl"] = "local a = require('a')\nreturn a\n",
    })
  assert(closure_of(proj, "c_test.tl") == "o/a.lua o/b.lua",
    "got: " .. closure_of(proj, "c_test.tl"))
end
test_a_cycle_terminates()

-- Built paths: .tl compiles, .lua is copied.
local function test_built_path()
  assert(deps.built_path("db/init.tl", "o") == "o/db/init.lua", "tl")
  assert(deps.built_path("legacy.lua", "o") == "o/legacy.lua", "lua")
end
test_built_path()

-- The index resolves import paths to files, and only for kinds a
-- require can land on: an asset or a `.d.tl` is not a module.
local function test_index_covers_only_resolvable_kinds()
  local proj = fixture("index", {
      ["db/init.tl"] = "return {}\n",
      ["types/x.d.tl"] = "local record x end\nreturn x\n",
      ["data.json"] = "{}\n",
    })
  local by_import = deps.index(proj)
  assert(by_import["db"], "a module is resolvable")
  assert(not by_import["types.x"], "a declaration is not a module")
  assert(not by_import["data"], "an asset is not a module")
end
test_index_covers_only_resolvable_kinds()

print("all deps tests passed")
