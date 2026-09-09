--- Small registered rules demonstrating syntax and typed capabilities.
local types = require("cosmic.analysis.types")
local runner = require("cosmic.analysis.runner")
local source = require("cosmic.ast.source")

local type Rule = types.Rule
local type RuleSpec = runner.RuleSpec

--- Register a syntax-only forbidden call policy.
local function forbidden_call(id: string, pattern_source: string,
    message: string): Rule | nil, string
  local spec: RuleSpec = {
    id = id,
    needs = {"syntax"},
    pattern = pattern_source,
    visit = function(ctx: types.Context, hit: types.Hit)
      ctx:report(message, hit.node, "error")
    end,
  }
  return runner.define(spec)
end

--- Register a conservative discarded-error policy. The Teal session owns
--- the structured return query; unavailable facts become incomplete rather
--- than a clean result.
local function fallible_statement(id: string, message: string): Rule | nil, string
  local spec: RuleSpec = {
    id = id,
    needs = {"syntax", "types"},
    pattern = "$CALL($$$ARGS)",
    visit = function(ctx: types.Context, hit: types.Hit)
      local parent = source.parent(ctx.snapshot, hit.node)
      -- Only a discarded call statement is this policy's subject. Calls in
      -- arguments, assignments, returns, and conditions are consumed by
      -- another expression and must not be reported as discarded results.
      if not parent or parent.kind ~= "statements" then return end
      local analysis = ctx.analysis
      if not analysis then
        ctx:incomplete("type analysis is unavailable", hit.node)
        return
      end
      local signature = analysis:callee_signature(hit.node)
      local signature_value = signature.value
      if signature.state ~= "known" or not signature_value then
        ctx:incomplete(signature.reason or "callee signature is unknown", hit.node)
        return
      end
      local fact = analysis:is_fallible(signature_value)
      if fact.state == "unknown" then
        ctx:incomplete(fact.reason or "fallibility is unknown", hit.node)
      elseif fact.value then
        ctx:report(message, hit.node, "error")
      end
    end,
  }
  return runner.define(spec)
end

local record RulesModule
  forbidden_call: function(string, string, string): Rule | nil, string
  fallible_statement: function(string, string): Rule | nil, string
end
local M: RulesModule = {
  forbidden_call = forbidden_call,
  fallible_statement = fallible_statement,
}
return M
