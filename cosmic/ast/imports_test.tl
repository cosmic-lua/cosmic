local source = require("cosmic.ast.source")
local bindings_mod = require("cosmic.ast.bindings")
local imports = require("cosmic.ast.imports")

local type Bindings = bindings_mod.Bindings

local function analyze(code: string): Bindings
  local snapshot, parse_err = source.parse(code, "cosmic/example.tl")
  assert(snapshot, parse_err)
  local bindings, err = bindings_mod.analyze(snapshot)
  assert(bindings, err)
  return bindings
end

local function test_allow_prefix_accepts_descendant_module()
  local bindings = analyze("local source = require(\"cosmic.ast.source\")\n")
  local result = imports.check(bindings, {allow = {"cosmic.ast"}})
  assert(result.complete)
  assert(#result.violations == 0 and #result.unknown == 0)
end

local function test_allowlist_reports_cross_boundary_import()
  local bindings = analyze("local fs = require(\"cosmic.fs\")\n")
  local result = imports.check(bindings, {allow = {"cosmic.ast"}})
  assert(result.complete and #result.violations == 1)
  assert(result.violations[1].module == "cosmic.fs")
  assert(result.violations[1].message:match("configured boundary"))
end

local function test_deny_takes_precedence_over_allow()
  local bindings = analyze("local source = require(\"cosmic.ast.source\")\n")
  local result = imports.check(bindings, {
      allow = {"cosmic"},
      deny = {"cosmic.ast"},
    })
  assert(#result.violations == 1)
end

local function test_nil_allowlist_defaults_to_allow()
  local bindings = analyze("local fs = require(\"cosmic.fs\")\n")
  local result = imports.check(bindings, {})
  assert(result.complete and #result.violations == 0)
end

local function test_dynamic_import_is_explicitly_incomplete()
  local bindings = analyze("local mod = require(module_name)\n")
  local result = imports.check(bindings, {allow = {"cosmic"}})
  assert(not result.complete and #result.unknown == 1)
  assert(result.unknown[1].reason:match("dynamic"))
end

local function test_reassigned_import_is_explicitly_incomplete()
  local bindings = analyze([[
local fs = require("cosmic.fs")
fs = replacement
]])
  local result = imports.check(bindings, {allow = {"cosmic"}})
  assert(not result.complete and #result.unknown == 1)
  assert(result.unknown[1].reason:match("reassigned or mutated"))
end

local function test_shadowed_require_is_not_claimed_as_an_import()
  local bindings = analyze([[
do
  local _ENV = {require = function(_name) return {} end}
  local env_result = require("cosmic.hash")
end
local require = function(_name) return {} end
local local_result = require("cosmic.fs")
]])
  for _, binding in ipairs(bindings.all) do
    assert(not binding.is_import,
      "a lexical require or require supplied by local _ENV is not proven")
  end
end
