--- Session-owned optional Teal analysis over immutable source snapshots.

local source = require("cosmic.ast.source")
local engine = require("cosmic._teal_engine")
local session_engine = require("cosmic._teal_session_engine")
local ttypes = require("cosmic._teal_types")

local type Node = source.Node
local type Snapshot = source.Snapshot
local type Issue = engine.Issue
local type TypeRef = ttypes.TypeRef
local type TypeQuery = ttypes.TypeQuery
local type TypesQuery = ttypes.TypesQuery
local type BoolQuery = ttypes.BoolQuery
local type FieldQuery = ttypes.FieldQuery
local type Report = ttypes.Report
local type Map = {any: any}

local record AnalysisOptions
  include_dirs: {string}
end

local record Dependency
  module_name: string
  path: string
  digest: string
end

local record Analysis
  snapshot: Snapshot
  revision: integer
  complete: boolean
  reason: string | nil
  diagnostics: {Issue}
  _report: Report | nil
  _origins: {Node: any}

  type_of: function(self: Analysis, node: Node): TypeQuery
  declared_type: function(self: Analysis, node: Node): TypeQuery
  callee_signature: function(self: Analysis, node: Node): TypeQuery
  members: function(self: Analysis, tref: TypeRef): TypesQuery
  arguments: function(self: Analysis, tref: TypeRef): TypesQuery
  returns: function(self: Analysis, tref: TypeRef): TypesQuery
  fields: function(self: Analysis, tref: TypeRef): FieldQuery
  elements: function(self: Analysis, tref: TypeRef): TypeQuery
  contains_nil: function(self: Analysis, tref: TypeRef): BoolQuery
  is_fallible: function(self: Analysis, tref: TypeRef): BoolQuery
  describe: function(self: Analysis, tref: TypeRef): string
end

local record Session
  _include_dirs: {string}
  _revision: integer
  _cached_id: string | nil
  _cached: Analysis | nil
  _dependencies: {Dependency}

  analyze: function(self: Session, snapshot: Snapshot): Analysis
  invalidate: function(self: Session)
end

local function unknown_type(reason: string): TypeQuery
  return {state = "unknown", reason = reason}
end

local function unknown_types(reason: string): TypesQuery
  return {state = "unknown", reason = reason}
end

local function unknown_fields(reason: string): FieldQuery
  return {state = "unknown", reason = reason}
end

local function unknown_bool(reason: string): BoolQuery
  return {state = "unknown", reason = reason}
end

--- Copy a cyclic/shared AST graph and retain both identity directions.
local function copy_graph(value: any, copies: {any: any},
    origin_to_copy: {Node: any}, copy_to_origin: {any: Node}): any
  if not (value is Map) then
    return value
  end
  local prior = copies[value]
  if prior then
    return prior
  end
  local out: Map = {}
  copies[value] = out
  origin_to_copy[value as Node] = out -- cast: source AST graph tables are Nodes
  copy_to_origin[out] = value as Node -- cast: source AST graph tables are Nodes
  for key, item in pairs(value) do
    out[copy_graph(key, copies, origin_to_copy, copy_to_origin)] =
    copy_graph(item, copies, origin_to_copy, copy_to_origin)
  end
  return setmetatable(out, getmetatable(value))
end

local function report_or_reason(self: Analysis): Report | nil, string
  if not self.complete or not self._report then
    return nil, self.reason or "type analysis is unavailable"
  end
  return self._report
end

local EXPRESSION_KINDS < const >: {string: boolean} = {
  variable = true,
  string = true,
  number = true,
  integer = true,
  boolean = true,
  ["nil"] = true,
  op = true,
}

local function type_of(self: Analysis, node: Node): TypeQuery
  local report, err = report_or_reason(self)
  if not report then
    return unknown_type(err)
  end
  if not self._origins[node] then
    return unknown_type("node does not belong to this analysis snapshot")
  end
  if not EXPRESSION_KINDS[node.kind] then
    return unknown_type("node role has no verified expression type mapping")
  end
  if node.kind == "op" then
    return unknown_type(
      "compound expression type mapping is ambiguous in the position report")
  end
  return ttypes.type_at(report, self.snapshot.name, node.y, node.x)
end

local DECLARATION_KINDS < const >: {string: boolean} = {
  local_declaration = true,
  local_function = true,
  global_declaration = true,
  argument = true,
  identifier = true,
}

local function declared_type(self: Analysis, node: Node): TypeQuery
  local report, err = report_or_reason(self)
  if not report then
    return unknown_type(err)
  end
  if not self._origins[node] then
    return unknown_type("node does not belong to this analysis snapshot")
  end
  if not DECLARATION_KINDS[node.kind] then
    return unknown_type("node role has no verified declaration type mapping")
  end
  if (node.kind == "identifier" or node.kind == "argument")
  and not source.type_syntax(self.snapshot, node) then
    return unknown_type("declaration has no explicit type syntax")
  end
  return ttypes.type_at(report, self.snapshot.name, node.y, node.x)
end

local function callee_signature(self: Analysis, node: Node): TypeQuery
  local report, err = report_or_reason(self)
  if not report then
    return unknown_type(err)
  end
  if not self._origins[node] then
    return unknown_type("node does not belong to this analysis snapshot")
  end
  local op = node.op
  if node.kind ~= "op" or not op
  or (op.op ~= "@funcall" and op.op ~= "@method") then
    return unknown_type("node is not a call")
  end
  local callee = node.e1
  if not callee then
    return unknown_type("call has no callee")
  end
  local field = callee.e2
  if field then
    local found = ttypes.type_at(
      report, self.snapshot.name, field.y, field.x)
    if found.state == "known" then
      return found
    end
  end
  return ttypes.type_at(report, self.snapshot.name, callee.y, callee.x)
end

local function members(self: Analysis, tref: TypeRef): TypesQuery
  local report, err = report_or_reason(self)
  return report and ttypes.members(report, tref) or unknown_types(err)
end

local function arguments(self: Analysis, tref: TypeRef): TypesQuery
  local report, err = report_or_reason(self)
  return report and ttypes.arguments(report, tref) or unknown_types(err)
end

local function returns(self: Analysis, tref: TypeRef): TypesQuery
  local report, err = report_or_reason(self)
  return report and ttypes.returns(report, tref) or unknown_types(err)
end

local function fields(self: Analysis, tref: TypeRef): FieldQuery
  local report, err = report_or_reason(self)
  return report and ttypes.fields(report, tref) or unknown_fields(err)
end

local function elements(self: Analysis, tref: TypeRef): TypeQuery
  local report, err = report_or_reason(self)
  return report and ttypes.elements(report, tref) or unknown_type(err)
end

local function contains_nil(self: Analysis, tref: TypeRef): BoolQuery
  local report, err = report_or_reason(self)
  return report and ttypes.contains_nil(report, tref) or unknown_bool(err)
end

local function is_fallible(self: Analysis, tref: TypeRef): BoolQuery
  local report, err = report_or_reason(self)
  return report and ttypes.is_fallible(report, tref) or unknown_bool(err)
end

local function describe(self: Analysis, tref: TypeRef): string
  local report = self._report
  return report and ttypes.describe(report, tref) or "<unknown>"
end

local function read_digest(path: string): string | nil
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  if not text then
    return nil
  end
  return require("cosmic.hash").sha256_hex(text)
end

local function resolve(session: Session, module_name: string): string | nil
  local tl = require("tl")
  local saved = tl.path
  tl.path = engine.assemble_tl_path(session._include_dirs)
  local path, file = tl.search_module(module_name, false)
  tl.path = saved
  if file then
    file:close()
  end
  return path
end

local function dependencies_current(session: Session): boolean
  for _, dep in ipairs(session._dependencies) do
    if resolve(session, dep.module_name) ~= dep.path
    or read_digest(dep.path) ~= dep.digest then
      return false
    end
  end
  return true
end

local function collect_dependencies(proc: engine.ProcessResult): {Dependency}, boolean
  local found: {string: Dependency} = {}
  local env = proc.env
  if not (env is Map) then
    return {}, false
  end
  local loaded = env["loaded"]
  if not (loaded is Map) then
    return {}, false
  end
  for _, result in pairs(loaded) do
    if result is Map then
      local dependencies = result["dependencies"]
      if dependencies is Map then
        for module_name, path in pairs(dependencies) do
          if module_name is string and path is string then
            local digest = read_digest(path)
            if not digest then
              return {}, false
            end
            found[module_name] = {
              module_name = module_name,
              path = path,
              digest = digest,
            }
          end
        end
      end
    end
  end
  local out: {Dependency} = {}
  for _, dep in pairs(found) do
    out[#out + 1] = dep
  end
  table.sort(out, function(a: Dependency, b: Dependency): boolean
      return a.module_name < b.module_name
    end)
  return out, true
end

local function new_analysis(snapshot: Snapshot, revision: integer,
    proc: engine.ProcessResult, origins: {Node: any}): Analysis
  local diagnostics: {Issue} = {}
  local complete = true
  local reason: string = nil
  local report: Report = nil
  if proc.error then
    diagnostics[1] = proc.error
    complete = false
    reason = proc.error.message
  else
    local errors = engine.collect_errors(proc.tl_result, snapshot.name)
    diagnostics = errors
    for _, warning in ipairs(engine.collect_warnings(proc.tl_result, snapshot.name)) do
      diagnostics[#diagnostics + 1] = warning
    end
    if #errors > 0 then
      complete = false
      reason = "type checking reported errors"
    end
    local report_err: string
    report, report_err = ttypes.from_env(proc.env, revision)
    if not report then
      complete = false
      reason = report_err
    end
  end
  return {
    snapshot = snapshot,
    revision = revision,
    complete = complete,
    reason = reason,
    diagnostics = diagnostics,
    _report = report,
    _origins = origins,
    type_of = type_of,
    declared_type = declared_type,
    callee_signature = callee_signature,
    members = members,
    arguments = arguments,
    returns = returns,
    fields = fields,
    elements = elements,
    contains_nil = contains_nil,
    is_fallible = is_fallible,
    describe = describe,
  }
end

local function analyze(self: Session, snapshot: Snapshot): Analysis
  local cached = self._cached
  if cached and cached.snapshot == snapshot and self._cached_id == snapshot.id
  and dependencies_current(self) then
    return cached
  end
  self._revision = self._revision + 1
  if snapshot.lang ~= "tl" then
    local analysis = new_analysis(snapshot, self._revision,
      {error = {file = snapshot.name, line = 0, column = 0,
          message = "Teal analysis requires a tl snapshot", severity = "error"}}, {})
    self._cached = nil
    self._cached_id = nil
    self._dependencies = {}
    return analysis
  end
  local origin_to_copy: {Node: any} = {}
  local checked = copy_graph(snapshot.node, {}, origin_to_copy, {})
  local proc = session_engine.process_ast(checked, snapshot.name, self._include_dirs)
  local analysis = new_analysis(snapshot, self._revision, proc, origin_to_copy)
  local deps, cacheable = collect_dependencies(proc)
  cacheable = cacheable and analysis.complete
  self._cached = cacheable and analysis or nil
  self._cached_id = cacheable and snapshot.id or nil
  self._dependencies = deps
  return analysis
end

local function invalidate(self: Session)
  self._cached = nil
  self._cached_id = nil
  self._dependencies = {}
end

local function session(raw_opts?: any): Session
  -- cast: cosmic.teal validates the public AnalysisOptions nominal type
  local opts = (raw_opts or {}) as AnalysisOptions
  return {
    _include_dirs = engine.merge_include_dirs(opts.include_dirs),
    _revision = 0,
    _dependencies = {},
    analyze = analyze,
    invalidate = invalidate,
  }
end

local record TealAnalysisModule
  type AnalysisOptions = AnalysisOptions
  type Analysis = Analysis
  type Session = Session
  session: function(opts?: any): Session
end

local M: TealAnalysisModule = {session = session}
return M
