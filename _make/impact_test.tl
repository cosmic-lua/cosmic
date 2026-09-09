#!/usr/bin/env cosmic
--- Changed inputs must select their callers, including cycles and deletions.
local check = require("cosmic.check")
local deps = require("_make.deps")
local fs = require("cosmic.fs")
local impact = require("_make.impact")
local project = require("_make.project")
local scope = require("_make.check_scope")
local types = require("_make.types")

local function fixture(name: string, files: {string: string}): types.Project
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "impact-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for path, code in pairs(files) do
    assert(fs.make_dirs(fs.dirname(fs.join(root, path))))
    assert(fs.write(fs.join(root, path), code))
  end
  return check.must(project.scan(root))
end

local function names(files: {types.File}): string
  return table.concat(deps.source_paths(files), " ")
end

local function test_reverse_impact_and_forward_inputs_are_distinct()
  local p = fixture("reverse", {
      ["a.tl"] = "return 1\n",
      ["b.tl"] = "local a = require('a')\nlocal x = require('x')\nreturn a + x\n",
      ["c.tl"] = "return require('b')\n",
      ["x.tl"] = "return 2\n",
      ["unrelated.tl"] = "return 3\n",
    })
  local r = impact.affected(p, {"a.tl"})
  check.equal(names(r.roots), "a.tl")
  check.equal(names(r.selected), "a.tl b.tl c.tl")
  check.equal(names(r.dependencies), "x.tl")
  check.equal(names(r.excluded), "unrelated.tl")
  assert(not r.conservative)
end

local function test_deleted_input_cannot_silently_exclude_old_callers()
  local p = fixture("deleted", {
      ["caller.tl"] = "return require('gone')\n",
      ["other.tl"] = "return 1\n",
    })
  local r = impact.affected(p, {"gone.tl"})
  assert(r.conservative)
  check.equal(names(r.selected), "caller.tl other.tl")
  check.equal(#r.excluded, 0)
end

local function test_cycle_and_declaration_inputs()
  local p = fixture("cycle", {
      ["a.tl"] = "return require('b')\n",
      ["b.tl"] = "return require('a')\n",
      ["ffi.lua"] = "return {}\n",
      ["ffi.d.tl"] = "local record F end\nreturn F\n",
      ["c.tl"] = "return require('ffi')\n",
    })
  check.equal(names(impact.affected(p, {"a.tl"}).selected), "a.tl b.tl")
  local d = impact.affected(p, {"ffi.d.tl"})
  check.equal(names(d.selected), "c.tl ffi.d.tl")
  check.equal(names(d.dependencies), "ffi.lua")
end

local function test_non_module_inputs_invalidate_the_project()
  local p = fixture("config", {["a.tl"] = "return 1\n", ["data.json"] = "{}\n"})
  local r = impact.affected(p, {"data.json"})
  assert(r.conservative)
  check.equal(names(r.selected), "a.tl data.json")
end

local function test_changed_flag_is_scoped_and_resets_between_runs()
  check.equal(table.concat(check.must(scope.extract("check", {"--changed", "a.tl"})), " "), "a.tl")
  assert(scope.changed())
  assert(scope.extract("check", {}))
  assert(not scope.changed())
  assert(not scope.extract("lint", {"--changed", "a.tl"}))
  assert(not scope.extract("check", {"--changed"}))
end
