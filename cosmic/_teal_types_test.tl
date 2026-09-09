#!/usr/bin/env cosmic
-- Real checked reports and absent-data boundaries for the internal lookup.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")
local types = require("cosmic._teal_types")
local tl = require("tl")

local type Node = types.Node
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local SOURCE < const > = [[
local function maybe(): string | nil
  return nil
end
local plain: string = "value"
local optional = maybe()
local nothing = nil
print(plain, optional, nothing)
]]

local function fixture(report_types: boolean): Node, string
  local path = fs.join(tmpdir, report_types and "types.tl" or "no_types.tl")
  assert(fs.write(path, SOURCE))
  local checked = teal.check_file(path)
  assert(checked.ok and #checked.errors == 0)
  local env = check.must(tl.new_env({defaults = {
          feat_lax = "off", feat_arity = "on", gen_target = "5.4", gen_compat = "off",
        }}))
  env.report_types = report_types
  local result = tl.process_string(check.must(fs.read(path)), false, env, path)
  assert(#result.syntax_errors == 0 and #result.type_errors == 0)
  return env as Node, path -- cast: tl environment is opaque report plumbing
end

local function test_checked_use_positions_report_plain_union_and_nil_types()
  local env, path = fixture(true)
  local report = check.must(types.get_report(env))
  local plain = check.must(types.type_info_at(report, path, 7, 7))
  assert(plain["str"] == "string")
  assert(types.type_str_at(report, path, 7, 7) == "string",
    "the shared lookup must not filter out non-function types")
  assert(not types.is_nilable_at(report, path, 7, 7))
  assert(types.type_str_at(report, path, 7, 14) == "string | nil")
  assert(types.is_nilable_at(report, path, 7, 14),
    "the local's use position retains its nil union member")
  assert(types.type_str_at(report, path, 7, 24) == "nil")
  assert(types.is_nilable_at(report, path, 7, 24))
end

local function test_missing_report_or_position_is_absent()
  local unreported = fixture(false)
  assert(types.get_report(unreported) == nil)
  local env, path = fixture(true)
  local report = check.must(types.get_report(env))
  assert(types.type_info_at(report, "unknown.tl", 7, 7) == nil)
  assert(types.type_str_at(report, path, 999, 7) == nil)
  assert(not types.is_nilable_at(report, path, 7, 999))
end

local function test_incomplete_report_shapes_are_fail_soft()
  assert(types.get_report({}) == nil)
  assert(types.get_report({reporter = {}}) == nil)
  assert(types.get_report({reporter = {get_report = "missing"}}) == nil)
  assert(types.get_report({reporter = {get_report = function(_self: any): any
            return false
          end}}) == nil)
  assert(types.type_info_at({}, "probe", 1, 1) == nil)
  local report: Node = {by_pos = {probe = {[1] = {[1] = 1}}}, types = {}}
  assert(types.type_info_at(report, "probe", 1, 1) == nil)
  report["types"] = {[1] = {str = 42}}
  assert(types.type_str_at(report, "probe", 1, 1) == nil)
  report["types"] = {[1] = {str = "nil-like", types = {2}}, [2] = {str = "string"}}
  assert(not types.is_nilable_at(report, "probe", 1, 1),
    "nilability comes from member types, not substrings")
end
