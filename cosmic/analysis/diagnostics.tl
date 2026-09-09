--- Stable diagnostic construction and JSON rendering.
local json = require("cosmic.json")
local source = require("cosmic.ast.source")
local types = require("cosmic.analysis.types")
local teal = require("cosmic.teal")

local type Node = source.Node
local type Snapshot = source.Snapshot
local type Diagnostic = types.Diagnostic
local type Related = types.Related
local type Severity = types.Severity

local function position_range(snapshot: Snapshot, line: integer,
    column: integer): source.Range | nil
  local start = snapshot.line_starts[line]
  if not start then return nil end
  start = math.min(start + math.max(column, 1) - 1, #snapshot.source + 1)
  return {start_byte = start, end_byte = start}
end

local function make(snapshot: Snapshot, rule: string, code: string,
    severity: Severity, message: string, node: Node,
    revision: string): Diagnostic
  local range = snapshot.ranges[node]
  return {rule = rule, code = code, severity = severity, message = message,
    file = snapshot.name, line = node.y, column = node.x, range = range,
    related = {}, fix_ids = {},
    revision = revision}
end

--- Keep dependency diagnostics at their original file and position.
local function issue(snapshot: Snapshot, rule: string, code: string,
    item: teal.Issue, revision: string): Diagnostic
  local line, column, file = item.line, item.column, item.file
  local range: source.Range | nil = nil
  if file == snapshot.name then range = position_range(snapshot, line, column) end
  local severity: Severity = item.severity == "error" and "error" or "warning"
  local message = item.message
  return {rule = rule, code = code, severity = severity, message = message,
    file = file, line = line, column = column, range = range,
    related = {}, fix_ids = {},
    revision = revision}
end

local function related(diag: Diagnostic, file: string, message: string,
    range: source.Range | nil): Diagnostic
  local item: Related = {file = file, message = message, range = range}
  diag.related[#diag.related + 1] = item
  return diag
end

local function json_value(diag: Diagnostic): {string: any}
  local rel: {any} = {}
  for _, item in ipairs(diag.related) do
    local item_range: any = nil
    if item.range then
      item_range = {start_byte = item.range.start_byte, end_byte = item.range.end_byte}
    end
    rel[#rel + 1] = {file = item.file, message = item.message, range = item_range}
  end
  local owned_range = diag.range
  local range: any = nil
  if owned_range then
    range = {start_byte = owned_range.start_byte, end_byte = owned_range.end_byte}
  end
  return {rule = diag.rule, code = diag.code, severity = diag.severity, message = diag.message,
    file = diag.file, line = diag.line, column = diag.column, range = range,
    related = rel, fix_ids = diag.fix_ids,
      revision = diag.revision}
end

local function to_json(diags: {Diagnostic}): string | nil, string
  local values: {any} = {}
  for _, diag in ipairs(diags) do values[#values + 1] = json_value(diag) end
  return json.encode(values)
end

local function sort_diagnostics(diags: {Diagnostic})
  local severity_rank: {Severity: integer} = {error = 1, warning = 2, info = 3}
  table.sort(diags, function(a: Diagnostic, b: Diagnostic): boolean
    if a.file ~= b.file then return a.file < b.file end
    local ar = a.range and a.range.start_byte or math.huge
    local br = b.range and b.range.start_byte or math.huge
    if ar ~= br then return ar < br end
    local ae = a.range and a.range.end_byte or math.huge
    local be = b.range and b.range.end_byte or math.huge
    if ae ~= be then return ae < be end
    if a.code ~= b.code then return a.code < b.code end
    if a.rule ~= b.rule then return a.rule < b.rule end
    if a.severity ~= b.severity then
      return severity_rank[a.severity] < severity_rank[b.severity]
    end
    if a.message ~= b.message then return a.message < b.message end
    return a.revision < b.revision
  end)
end

local record DiagnosticsModule
  make: function(Snapshot, string, string, Severity, string, Node, string): Diagnostic
  issue: function(Snapshot, string, string, teal.Issue, string): Diagnostic
  related: function(Diagnostic, string, string, source.Range | nil): Diagnostic
  sort: function({Diagnostic})
  to_json: function({Diagnostic}): string | nil, string
end
local M: DiagnosticsModule = {make = make, issue = issue, related = related,
  sort = sort_diagnostics, to_json = to_json}
return M
