#!/usr/bin/env cosmic
local check = require("cosmic.check")
local source = require("cosmic.ast.source")
local analysis = require("cosmic.analysis")
local rules = require("cosmic.analysis.rules")

local function test_forbidden_call_rule_is_registered_and_reports()
  local rule = check.must(rules.forbidden_call("forbidden", "os.execute($X)",
    "process execution is forbidden"))
  local snapshot = check.must(source.parse("os.execute(command)\n", "rule.tl"))
  local result = analysis.run(snapshot, {rule})
  assert(result.complete, result.error or "rule should complete")
  assert(#result.diagnostics == 1)
  assert(result.diagnostics[1].message == "process execution is forbidden")
end
