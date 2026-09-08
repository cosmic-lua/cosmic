#!/usr/bin/env cosmic
-- Actual-source probes for the typed adapter over Teal v0.24.8's report.

local ttypes = require("cosmic._teal_types")
local type Report = ttypes.Report
local type TypeRef = ttypes.TypeRef
local type Node = {any: any}

local SOURCE < const > = [[local function f(v: string): string | nil, string
  return v
end
local maybe: string | nil = f("x")
local function consume(uncertain: any)
  print(uncertain)
end
local interface Failure
  message: string
  metamethod __tostring: function(Failure): string
end
local record Problem is Failure
  message: string
  metamethod __tostring: function(Problem): string
end
local function structured(): boolean, Problem
  return false, {message = "no"} as Problem
end
local ok, problem = structured()
consume(maybe)
print(ok, problem)
]]

local function checked(): Node, Report
  local tl = require("tl")
  local env = assert(require("cosmic._teal_ast").new_env({
        feat_lax = "off",
        feat_arity = "on",
        gen_target = "5.4",
        gen_compat = "off",
      }))
  env.report_types = true
  local result = tl.process_string(SOURCE, false, env, "types_fixture.tl")
  assert(#result.syntax_errors == 0 and #result.type_errors == 0)
  -- cast: tl's curated Result.ast is opaque; this test walks its map shape
  return result.ast as Node, assert(ttypes.from_env(env, 7))
end

local function find(node: any, kind: string, token: string,
    seen?: {any: boolean}): Node | nil
  seen = seen or {}
  if node is Node then
    if seen[node] then
      return nil
    end
    seen[node] = true
    if node["kind"] == kind and node["tk"] == token then
      return node
    end
    for key, value in pairs(node) do
      if key ~= "expected" and key ~= "decltuple" then
        local found = find(value, kind, token, seen)
        if found then
          return found
        end
      end
    end
  end
  return nil
end

local function ref_at(report: Report, node: Node): TypeRef
  local query = ttypes.type_at(
    report, "types_fixture.tl", node["y"], node["x"])
  assert(query.state == "known", query.reason)
  return assert(query.value)
end

local function test_structured_function_returns_and_arguments()
  local ast, report = checked()
  local fn = assert(find(ast, "statements", "local"))
  local fn_ref = ref_at(report, fn)
  local args = ttypes.arguments(report, fn_ref)
  local rets = ttypes.returns(report, fn_ref)
  local arg_values = args.values
  local ret_values = rets.values
  assert(args.state == "known" and not args.variadic)
  assert(arg_values)
  assert(#arg_values == 1)
  assert(ttypes.describe(report, arg_values[1]) == "string")
  assert(rets.state == "known" and not rets.variadic)
  assert(ret_values)
  assert(#ret_values == 2)
  assert(ttypes.describe(report, ret_values[2]) == "string")
  local fallible = ttypes.is_fallible(report, fn_ref)
  assert(fallible.state == "known" and fallible.value)
end

local function test_union_nil_fact_is_structured()
  local ast, report = checked()
  local maybe = assert(find(ast, "identifier", "maybe"))
  local maybe_ref = ref_at(report, maybe)
  local members = ttypes.members(report, maybe_ref)
  local member_values = members.values
  assert(members.state == "known" and member_values and #member_values == 2)
  local nilable = ttypes.contains_nil(report, maybe_ref)
  assert(nilable.state == "known" and nilable.value)
end

local function test_missing_and_stale_facts_are_unknown()
  local ast, report = checked()
  local missing = ttypes.type_at(report, "types_fixture.tl", 99, 99)
  assert(missing.state == "unknown" and missing.value == nil)

  local maybe = assert(find(ast, "identifier", "maybe"))
  local maybe_ref = ref_at(report, maybe)
  local _, other_report = checked()
  local stale = ttypes.contains_nil(other_report, maybe_ref)
  assert(stale.state == "unknown",
    "a ref from another report must not become a false nilability fact")
end

local function test_any_nilability_is_unknown()
  local ast, report = checked()
  local uncertain = assert(find(ast, "variable", "uncertain"))
  local fact = ttypes.contains_nil(report, ref_at(report, uncertain))
  assert(fact.state == "unknown" and fact.value == nil)
end

local function test_structured_failure_return_is_fallible()
  local ast, report = checked()
  local callee = assert(find(ast, "variable", "structured"))
  local fact = ttypes.is_fallible(report, ref_at(report, callee))
  assert(fact.state == "known" and fact.value,
    "D24 Failure-shaped slot 2 should be recognized structurally")
end

local function test_unavailable_report_is_explicit()
  local report, reason = ttypes.from_env({})
  assert(report == nil)
  assert(reason:find("reporter", 1, true))
end
