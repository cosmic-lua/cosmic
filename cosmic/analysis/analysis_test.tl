#!/usr/bin/env cosmic
--- Contract tests for rule registration, capability gating, traversal, and
--- atomic safe fix rounds.
local check = require("cosmic.check")
local source = require("cosmic.ast.source")
local analysis = require("cosmic.analysis")
local edit = require("cosmic.edit")

local type Snapshot = source.Snapshot
local type Rule = analysis.Rule

local function parsed(text: string): Snapshot
  return check.must(source.parse(text, "analysis_fixture.tl"))
end

local function rule(spec: analysis.RuleSpec): Rule
  return check.must(analysis.define(spec))
end

local function test_runner_buckets_pattern_roots_and_reports_stable_findings()
  local calls = rule({
    id = "call-check",
    needs = {"syntax"},
    pattern = "print($X)",
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      ctx:report("check this call", hit.node, "info")
    end,
  })
  local result = analysis.run(parsed("print(1)\nother()\nprint(2)\n"), {calls})
  assert(result.complete, result.error or "analysis unexpectedly incomplete")
  assert(#result.diagnostics == 2, "expected two print diagnostics")
  assert(result.diagnostics[1].rule == "call-check")
  assert(result.diagnostics[1].severity == "info")
  local first_range = result.diagnostics[1].range
  local second_range = result.diagnostics[2].range
  if not first_range or not second_range then error("diagnostic ranges missing") end
  assert(first_range.start_byte < second_range.start_byte)
  assert(result.json:find('"rule":"call-check"', 1, true) ~= nil,
    "JSON diagnostics must carry the stable rule id")
end

local function test_missing_required_capability_cannot_report_clean_success()
  local typed = rule({
    id = "typed-check",
    needs = {"syntax", "types"},
    pattern = "print($X)",
    visit = function(_ctx: analysis.Context, _hit: analysis.Hit) end,
  })
  local result = analysis.run(parsed("print(1)\n"), {typed}, {
    teal = false, bindings = false, max_rounds = 3, format = false,
  })
  assert(not result.complete, "missing types must make the run incomplete")
  assert(result.error == "rule requires types capability")
end

local function test_wildcard_and_visitor_kind_rules_select_expected_nodes()
  local wildcard = rule({
    id = "wildcard",
    needs = {"syntax"},
    pattern = "$X",
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      ctx:report("expression", hit.node, "info")
    end,
  })
  local visitor = rule({
    id = "ops",
    needs = {"syntax"},
    pattern = nil,
    kinds = {"op"},
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      ctx:report("operator", hit.node, "info")
    end,
  })
  local result = analysis.run(parsed("print(1 + 2)\n"), {wildcard, visitor})
  assert(result.complete, result.error or "syntax rules should complete")
  assert(#result.diagnostics > 3, "wildcard should visit all expression nodes")
end

local function test_safe_fix_round_reparses_and_stops_at_a_fixpoint()
  local rename = rule({
    id = "rename-call",
    needs = {"syntax"},
    pattern = "foo()",
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      local range = check.must(source.range(ctx.snapshot, hit.node))
      local replacement = check.must(edit.replace(ctx.snapshot, range, "bar()"))
      ctx:propose(edit.fix("rename foo", "safe", {replacement}))
    end,
  })
  local checked = analysis.run(parsed("foo()\n"), {rename})
  assert(checked.code == "foo()\n", "checking must not apply safe fixes")
  local result = analysis.run(parsed("foo()\n"), {rename}, {
    teal = false, bindings = false, max_rounds = 3, format = false,
    apply_fixes = true,
  })
  assert(result.complete, result.error or "safe fix should complete")
  assert(result.code == "bar()\n", "safe fix candidate was not applied")
  assert(result.rounds == 2, "runner should recheck one applied round")
end

local function test_default_type_capability_and_error_verdict()
  local typed = rule({
    id = "typed-default", needs = {"types"}, kinds = {"integer"},
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      assert(ctx.analysis and ctx.analysis.complete, "types must be inferred on demand")
      ctx:report("policy violation", hit.node, "error")
    end,
  })
  local result = analysis.run(parsed("return 1\n"), {typed})
  assert(result.complete, result.error or "type analysis must complete")
  assert(not result.ok and #result.diagnostics == 1)
end

local function test_type_invalid_fix_does_not_escape_as_output()
  local replacement = rule({
    id = "bad-typed-fix", needs = {"types"}, kinds = {"integer"},
    visit = function(ctx: analysis.Context, hit: analysis.Hit)
      local range = check.must(source.range(ctx.snapshot, hit.node))
      local changed = check.must(edit.replace(ctx.snapshot, range, "'wrong'"))
      ctx:propose(edit.fix("change value", "safe", {changed}))
    end,
  })
  local original = "local x: integer = 1\nreturn x\n"
  local result = analysis.run(parsed(original), {replacement}, {apply_fixes = true})
  assert(not result.complete and not result.ok)
  assert(result.code == original, "type-invalid candidate must remain private")
end
