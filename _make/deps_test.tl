#!/usr/bin/env cosmic
-- Tests for the import graph.
--
-- Two consumers depend on this being right, and they fail differently:
-- a closure that is too SMALL makes a test miss a rebuild (the graph)
-- and denies it a read (the fence); one that is too LARGE re-runs the
-- suite for unrelated edits and grants more than it should. So the
-- assertions are exact sets, not "contains".

local check = require("cosmic.check")
local deps = require("_make.deps")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")

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

--- The closure of rel as BUILT paths, in one comparable string.
local function closure_of(proj: Project, rel: string): string
  local by_import = deps.index(proj)
  local files = deps.closure(proj, file_at(proj, rel), by_import)
  return table.concat(deps.built_paths(files), " ")
end

--- The same closure as SOURCE paths.
local function sources_of(proj: Project, rel: string): string
  local by_import = deps.index(proj)
  local files = deps.closure(proj, file_at(proj, rel), by_import)
  return table.concat(deps.source_paths(files), " ")
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

-- The two flavours are not interchangeable, and getting them backwards
-- is the difference between an incremental build that catches a broken
-- contract and one that ships past it: a COMPILE checks against the
-- sources it imports (the type checker resolves require() to `.tl`),
-- while a TEST runs against compiled Lua.
local function test_source_and_built_flavours()
  local proj = fixture("flavours", {
      ["util.tl"] = "return {}\n",
      ["main.tl"] = "local u = require('util')\nreturn u\n",
    })
  assert(sources_of(proj, "main.tl") == "util.tl",
    "a compile depends on SOURCES: " .. sources_of(proj, "main.tl"))
  assert(closure_of(proj, "main.tl") == "o/util.lua",
    "a test depends on BUILT output: " .. closure_of(proj, "main.tl"))
end
test_source_and_built_flavours()

-- Built paths: .tl compiles, .lua is copied.
local function test_built_path()
  assert(deps.built_path("db/init.tl", "o") == "o/db/init.lua", "tl")
  assert(deps.built_path("legacy.lua", "o") == "o/legacy.lua", "lua")
end
test_built_path()

-- The index resolves import paths to files, for every kind a require
-- can land on. A `.d.tl` is one of them -- the checker resolves
-- `require("x")` to `x.d.tl` -- which this test used to deny. That
-- denial WAS the bug: excluded from the closure, a declaration could
-- change its contract without any listed prerequisite's mtime moving,
-- so importers were never re-checked and an incremental build kept
-- output a clean build rejects. An asset is still not a module.
local function test_index_covers_resolvable_kinds()
  local proj = fixture("index", {
      ["db/init.tl"] = "return {}\n",
      ["types/x.d.tl"] = "local record x end\nreturn x\n",
      ["data.json"] = "{}\n",
    })
  local by_import = deps.index(proj)
  assert(by_import["db"], "a module is resolvable")
  assert(by_import["types.x"], "and so is a declaration")
  assert(not by_import["data"], "an asset is not")
end
test_index_covers_resolvable_kinds()

-- A declaration is a SOURCE dependency and nothing else: it compiles
-- to no file, so naming `o/…/x.lua` for it would name a target nothing
-- builds. Both halves of one name are carried when both exist.
local function test_a_declaration_is_a_source_dependency_only()
  local proj = fixture("dtl-closure", {
      ["ffi.lua"] = "return {}\n",
      ["ffi.d.tl"] = "local record ffi end\nreturn ffi\n",
      ["main.tl"] = "local ffi = require('ffi')\nprint(ffi)\n",
    })
  local by_import = deps.index(proj)
  local files = deps.closure(proj, file_at(proj, "main.tl"), by_import)
  local srcs = table.concat(deps.source_paths(files), " ")
  assert(srcs:find("ffi.d.tl", 1, true),
    "the declaration is a source dependency: " .. srcs)
  assert(srcs:find("ffi.lua", 1, true),
    "and so is the implementation beside it: " .. srcs)

  local built = table.concat(deps.built_paths(files), " ")
  assert(not built:find("ffi.d", 1, true),
    "but a declaration builds to nothing: " .. built)
  assert(built:find("o/ffi.lua", 1, true),
    "while the implementation still does: " .. built)
end
test_a_declaration_is_a_source_dependency_only()

print("all deps tests passed")
