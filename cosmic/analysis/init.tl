--- Public facade for typed analysis rules and execution.
local source = require("cosmic.ast.source")
local types = require("cosmic.analysis.types")
local runner = require("cosmic.analysis.runner")
local diagnostics = require("cosmic.analysis.diagnostics")

local record AnalysisModule
  type Capability = types.Capability
  type Severity = types.Severity
  type Hit = types.Hit
  type Related = types.Related
  type Diagnostic = types.Diagnostic
  type Context = types.Context
  type Rule = types.Rule
  type RuleSpec = runner.RuleSpec
  type RunOptions = types.RunOptions
  type RunResult = types.RunResult
  type Snapshot = source.Snapshot
  define: function(RuleSpec): Rule | nil, string
  run: function(Snapshot, {Rule}, opts?: RunOptions): RunResult
  diagnostics_json: function({Diagnostic}): string | nil, string
end

local M: AnalysisModule = {
  define = runner.define,
  run = runner.run,
  diagnostics_json = diagnostics.to_json,
}
return M
