--- Typed contracts shared by the analysis rule runner.
local source = require("cosmic.ast.source")
local pattern = require("cosmic.ast.pattern")
local edit = require("cosmic.edit")

local type Node = source.Node
local type Snapshot = source.Snapshot
local type Pattern = pattern.Pattern
local type Fix = edit.Fix
local teal_mod = require("cosmic.teal.analysis")
local bindings_mod = require("cosmic.ast.bindings")
local type TealAnalysis = teal_mod.Analysis
local type TealSession = teal_mod.Session
local type Bindings = bindings_mod.Bindings

local enum Capability
  "text"
  "tokens"
  "syntax"
  "bindings"
  "types"
  "project"
end

local enum Severity
  "error"
  "warning"
  "info"
end

local record Hit
  node: Node
  captures: {string: Node}
end

local record Related
  file: string
  message: string
  range: source.Range | nil
end

local record Diagnostic
  rule: string
  code: string
  severity: Severity
  message: string
  file: string
  line: integer
  column: integer
  range: source.Range | nil
  related: {Related}
  fix_ids: {string}
  revision: string
end

local record Context
  snapshot: Snapshot
  analysis: TealAnalysis | nil
  bindings: Bindings | nil
  report: function(self: Context, message: string, node?: Node,
    severity?: Severity): Diagnostic
  incomplete: function(self: Context, message: string, node?: Node): Diagnostic
  propose: function(self: Context, fix: Fix, diagnostic?: Diagnostic)
end

local type Visitor = function(context: Context, hit: Hit)

local record Rule
  id: string
  code: string
  needs: {Capability}
  pattern: Pattern | nil
  kinds: {string} | nil
  visit: Visitor
end

local record RunOptions
  teal: boolean | nil
  bindings: boolean | nil
  max_rounds: integer | nil
  format: boolean | nil
  apply_fixes: boolean | nil
  include_dirs: {string} | nil
  werror: boolean | nil
  teal_session: TealSession | nil
end

local record RunResult
  ok: boolean
  diagnostics: {Diagnostic}
  fixes: {Fix}
  code: string
  complete: boolean
  rounds: integer
  error: string | nil
  json: string
end

local record TypesModule
  type Capability = Capability
  type Severity = Severity
  type Hit = Hit
  type Related = Related
  type Diagnostic = Diagnostic
  type TealSession = TealSession
  type Context = Context
  type Visitor = Visitor
  type Rule = Rule
  type RunOptions = RunOptions
  type RunResult = RunResult
end

local M: TypesModule = {}
return M
