--- Rule registration and one-snapshot analysis/fix execution.
local source = require("cosmic.ast.source")
local walk = require("cosmic.ast.walk")
local pattern = require("cosmic.ast.pattern")
local diagnostics = require("cosmic.analysis.diagnostics")
local types = require("cosmic.analysis.types")
local edit = require("cosmic.edit")
local teal = require("cosmic.teal.analysis")
local bindings_mod = require("cosmic.ast.bindings")

local type Node = source.Node
local type Snapshot = source.Snapshot
local type Pattern = pattern.Pattern
local type Rule = types.Rule
local type Context = types.Context
local type Diagnostic = types.Diagnostic
local type Fix = edit.Fix
local type RunOptions = types.RunOptions
local type RunResult = types.RunResult
local type Capability = types.Capability
local type Severity = types.Severity
local type TealSession = teal.Session

local record RuleSpec
  id: string
  code: string | nil
  needs: {Capability}
  pattern: string | nil
  kinds: {string} | nil
  visit: types.Visitor
end

local record State
  snapshot: Snapshot
  revision: string
  rule_id: string
  rule_code: string
  diagnostics: {Diagnostic}
  fixes: {Fix}
  analysis: teal.Analysis | nil
  bindings: bindings_mod.Bindings | nil
  complete: boolean
  reason: string | nil
  last_diag: Diagnostic | nil
end

local EXPRESSION_ORDER <const>: {string} = {
  "variable", "identifier", "string", "number", "integer", "boolean", "nil", "op",
}

--- Compile a rule's owned pattern once. Visitor-only rules use `kinds` to
--- select buckets; a pattern is optional for those rules.
local function define(spec: RuleSpec): Rule | nil, string
  if spec.id == "" then return nil, "rule id must not be empty" end
  local compiled: Pattern | nil = nil
  if spec.pattern then
    local found, err = pattern.compile(spec.pattern)
    if not found then return nil, err end
    compiled = found
  elseif not spec.kinds or #spec.kinds == 0 then
    return nil, "rule requires a pattern or visitor kinds"
  end
  return {id = spec.id, code = spec.code or spec.id, needs = spec.needs,
    pattern = compiled, kinds = spec.kinds, visit = spec.visit}, nil
end

local function needs_capability(rule: Rule, wanted: Capability): boolean
  for _, capability in ipairs(rule.needs) do
    if capability == wanted then return true end
  end
  return false
end

local function missing(rule: Rule, opts: RunOptions): string | nil
  if needs_capability(rule, "project") then return "project capability is unavailable" end
  if needs_capability(rule, "bindings") and opts.bindings == false then
    return "rule requires bindings capability"
  end
  if needs_capability(rule, "types") and opts.teal == false then
    return "rule requires types capability"
  end
  return nil
end

local function report(state: State, message: string, node: Node,
    severity: Severity): Diagnostic
  local diag = diagnostics.make(state.snapshot, state.rule_id, state.rule_code,
    severity, message, node, state.revision)
  state.diagnostics[#state.diagnostics + 1] = diag
  state.last_diag = diag
  return diag
end

local function context(state: State): Context
  local ctx: Context = {
    snapshot = state.snapshot,
    analysis = state.analysis,
    bindings = state.bindings,
    report = function(self: Context, message: string, node?: Node,
        severity?: Severity): Diagnostic
      local target = node or self.snapshot.node
      return report(state, message, target, severity or "warning")
    end,
    incomplete = function(self: Context, message: string,
        node?: Node): Diagnostic
      local target = node or self.snapshot.node
      state.complete = false
      state.reason = state.reason or message
      return report(state, "incomplete: " .. message, target, "warning")
    end,
    propose = function(_self: Context, fix: Fix, diagnostic?: Diagnostic)
      state.fixes[#state.fixes + 1] = fix
      local linked = diagnostic or state.last_diag
      if linked then
        local id = state.rule_id .. ":fix:" .. tostring(#state.fixes)
        linked.fix_ids[#linked.fix_ids + 1] = id
      end
    end,
  }
  return ctx
end

local function candidates(rule: Rule, buckets: {string: {Node}}): {Node}
  if rule.kinds then
    local out: {Node} = {}
    for _, kind in ipairs(rule.kinds) do
      for _, node in ipairs(buckets[kind] or {}) do out[#out + 1] = node end
    end
    return out
  end
  local compiled = rule.pattern
  if not compiled then return {} end
  if compiled.wildcard then
    local out: {Node} = {}
    for _, kind in ipairs(EXPRESSION_ORDER) do
      for _, node in ipairs(buckets[kind] or {}) do out[#out + 1] = node end
    end
    return out
  end
  return buckets[compiled.root.kind] or {}
end

local function visit_rule(rule: Rule, state: State, buckets: {string: {Node}})
  local ctx = context(state)
  for _, node in ipairs(candidates(rule, buckets)) do
    local hit: types.Hit = {node = node, captures = {}}
    if rule.pattern then
      local captures = pattern.match(rule.pattern, node)
      if captures then hit.captures = captures else goto continue end
    end
    rule.visit(ctx, hit)
    ::continue::
  end
end

local function append_type_diagnostics(snapshot: Snapshot, diags: {Diagnostic},
    analysis: teal.Analysis, revision: string)
  for _, item in ipairs(analysis.diagnostics) do
    diags[#diags + 1] = diagnostics.issue(snapshot, "analysis", "analysis.type",
      item, revision)
  end
end

local function run_pass(snapshot: Snapshot, rules: {Rule}, opts: RunOptions,
    revision: string, teal_session: TealSession | nil): {Diagnostic}, {Fix},
    boolean, string | nil
  local all_diags: {Diagnostic} = {}
  local all_fixes: {Fix} = {}
  local pass_complete = true
  local pass_reason: string | nil = nil
  local teal_analysis: teal.Analysis | nil = nil
  local binding_analysis: bindings_mod.Bindings | nil = nil

  local type_needed = false
  local bindings_needed = false
  for _, rule in ipairs(rules) do
    type_needed = type_needed or needs_capability(rule, "types")
    bindings_needed = bindings_needed or needs_capability(rule, "bindings")
  end
  if type_needed and teal_session and opts.teal ~= false then
    teal_analysis = teal_session:analyze(snapshot)
    append_type_diagnostics(snapshot, all_diags, teal_analysis, revision)
    if not teal_analysis.complete then
      pass_complete = false
      pass_reason = teal_analysis.reason or "type analysis is incomplete"
    end
  end
  if bindings_needed and opts.bindings ~= false then
    local found, err = bindings_mod.analyze(snapshot)
    if found then binding_analysis = found else
      pass_complete = false
      pass_reason = pass_reason or err
    end
  end

  local buckets: {string: {Node}} = {}
  walk.walk(snapshot.node, function(node: Node)
      local bucket = buckets[node.kind]
      if not bucket then bucket = {}; buckets[node.kind] = bucket end
      bucket[#bucket + 1] = node
    end)
  for _, rule in ipairs(rules) do
    local reason = missing(rule, opts)
    if reason then
      pass_complete = false
      pass_reason = pass_reason or reason
      local state: State = {snapshot = snapshot, revision = revision,
        rule_id = rule.id, rule_code = rule.code, diagnostics = all_diags,
        fixes = all_fixes, analysis = nil, bindings = nil, complete = false,
        reason = reason, last_diag = nil}
      report(state, "incomplete: " .. reason, snapshot.node, "warning")
    else
      local state: State = {snapshot = snapshot, revision = revision,
        rule_id = rule.id, rule_code = rule.code, diagnostics = all_diags,
        fixes = all_fixes, analysis = teal_analysis, bindings = binding_analysis,
        complete = pass_complete, reason = pass_reason, last_diag = nil}
      visit_rule(rule, state, buckets)
      if not state.complete then
        pass_complete = false
        pass_reason = pass_reason or state.reason
      end
    end
  end
  return all_diags, all_fixes, pass_complete, pass_reason
end

local DEFAULTS: RunOptions = {teal = nil, bindings = nil, max_rounds = 3,
  format = false, apply_fixes = false}

local function safe_fixes(fixes: {Fix}): {Fix}
  local out: {Fix} = {}
  for _, fix in ipairs(fixes) do
    if fix.applicability == "safe" then out[#out + 1] = fix end
  end
  return out
end

local function has_type_rules(rules: {Rule}): boolean
  for _, rule in ipairs(rules) do
    if needs_capability(rule, "types") then return true end
  end
  return false
end

--- A safe edit is only accepted when the typed rules' postcondition remains
--- available on the candidate snapshot. The candidate is kept private until
--- this check succeeds, so a new type error never leaks as returned code.
local function type_postcondition(snapshot: Snapshot, rules: {Rule},
    opts: RunOptions, session: TealSession | nil): string | nil
  if opts.teal == false or not has_type_rules(rules) or not session then
    return nil
  end
  local checked = session:analyze(snapshot)
  if checked.complete then return nil end
  return checked.reason or "safe fix introduced type errors"
end

local function run(snapshot: Snapshot, rules: {Rule}, opts?: RunOptions): RunResult
  opts = opts or DEFAULTS
  local current = snapshot
  local final_diags: {Diagnostic} = {}
  local final_fixes: {Fix} = {}
  local rounds = 0
  local complete = true
  local err: string | nil = nil
  local seen: {string: boolean} = {[current.id] = true}
  local session: TealSession | nil = opts.teal_session
  if not session and opts.teal ~= false and has_type_rules(rules) then
    session = teal.session({include_dirs = opts.include_dirs or {}})
  end

  local function pass(): boolean
    local diags, fixes, ok, reason = run_pass(current, rules, opts,
      current.id, session)
    final_diags, final_fixes = diags, fixes
    if not ok then complete, err = false, reason end
    return ok
  end

  -- Checking is the default. Applying a safe Fix is an explicit operation.
  local apply_fixes = opts.apply_fixes == true
  local max_rounds = opts.max_rounds or DEFAULTS.max_rounds
  if not apply_fixes then
    rounds = 1
    pass()
  else
    local limit = max_rounds > 0 and max_rounds or 1
    local needs_final = false
    local cycle = false
    while true do
      rounds = rounds + 1
      if not pass() then break end
      local safe = safe_fixes(final_fixes)
      if #safe == 0 then break end
      local validated, validation_err = edit.validate(current, safe, current.source)
      if not validated then complete, err = false, validation_err; break end
      if #validated.parse.issues > 0 or not validated.parse.snapshot then
        complete, err = false, "fix candidate does not parse"; break
      end
      if not validated.application.changed then break end
      local candidate = validated.parse.snapshot
      local type_error = type_postcondition(candidate, rules, opts, session)
      if type_error then
        complete, err = false, "safe fix rejected: " .. type_error
        break
      end
      current = candidate
      if seen[current.id] then
        cycle, needs_final = true, true
        break
      end
      seen[current.id] = true
      if rounds >= limit then needs_final = true; break end
    end
    if needs_final then
      rounds = rounds + 1
      local ok = pass()
      if cycle then complete, err = false, "safe fix cycle detected"
      elseif ok then
        local safe = safe_fixes(final_fixes)
        local validated = edit.validate(current, safe, current.source)
        if not validated or validated.application.changed then
          complete, err = false, "fix round limit reached"
        end
      end
    end
  end

  if complete and opts.format then
    local formatter = require("cosmic.analysis.formatter")
    local formatted, formatted_snapshot = formatter.format_snapshot(current)
    if not formatted.ok or not formatted.code or not formatted_snapshot then
      complete, err = false, "formatting failed after fixes"
    else
      current = formatted_snapshot
      rounds = rounds + 1
      local ok = pass()
      if not ok then complete = false end
    end
  end
  diagnostics.sort(final_diags)
  local json, json_error = diagnostics.to_json(final_diags)
  if not json then
    complete, err = false, err or ("diagnostic JSON encoding failed: " .. json_error)
    json = ""
  end
  local ok = err == nil
  for _, diag in ipairs(final_diags) do
    if diag.severity == "error"
    or (diag.severity == "warning" and opts.werror ~= false) then
      ok = false
    end
  end
  return {ok = ok, diagnostics = final_diags, fixes = final_fixes,
    code = current.source, complete = complete, rounds = rounds, error = err,
    json = json}
end

local record RunnerModule
  type RuleSpec = RuleSpec
  define: function(RuleSpec): Rule | nil, string
  run: function(Snapshot, {Rule}, opts?: RunOptions): RunResult
end
local M: RunnerModule = {define = define, run = run}
return M
