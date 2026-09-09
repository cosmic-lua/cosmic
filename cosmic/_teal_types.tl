--- Position-to-type lookups over the checked Teal environment's report.
--- Internal shared plumbing: missing report data yields nil or false.

--- tl's AST and report values are opaque in the narrowed compiler API.
local type Node = {any: any}

--- Read the report when type reporting was enabled for a checked environment.
--- @param env Node The opaque tl environment
--- @return Node | nil The report, or nil when unavailable
local function get_report(env: Node): Node | nil
  if not (env is Node) then return nil end
  local reporter = env["reporter"]
  if not (reporter is Node) then return nil end
  local method = reporter["get_report"]
  if type(method) ~= "function" then return nil end
  -- cast: TypeReporter method, outside the narrowed API
  local get = method as function(any): any
  local report = get(reporter)
  if report is Node then return report end
  return nil
end

--- Look up the type information recorded at one exact source position.
--- @param report Node The checked environment's type report
--- @param path string The filename used when checking the source
--- @param y integer One-based source line
--- @param x integer One-based source column
--- @return Node | nil Type information, or nil when the position is absent
local function type_info_at(report: Node, path: string, y: integer,
    x: integer): Node | nil
  if not (report is Node) then return nil end
  local by_pos, types = report["by_pos"], report["types"]
  if not (by_pos is Node) or not (types is Node) then return nil end
  local by = by_pos[path]
  if not (by is Node) then return nil end
  local row = by[y]
  if not (row is Node) then return nil end
  local id = row[x]
  if id == nil then return nil end
  local info = types[id]
  if info is Node then return info end
  return nil
end

--- Read the type string without imposing a caller-specific type filter.
--- @param report Node The checked environment's type report
--- @param path string The filename used when checking the source
--- @param y integer One-based source line
--- @param x integer One-based source column
--- @return string | nil The type string, or nil when unavailable
local function type_str_at(report: Node, path: string, y: integer,
    x: integer): string | nil
  local info = type_info_at(report, path, y, x)
  if info ~= nil then
    local str = info["str"]
    if str is string then return str end
  end
  return nil
end

--- Whether the reported type is nil itself or a union containing nil.
--- @param report Node The checked environment's type report
--- @param path string The filename used when checking the source
--- @param y integer One-based source line
--- @param x integer One-based source column
--- @return boolean True for nil or a union with a nil member
local function is_nilable_at(report: Node, path: string, y: integer,
    x: integer): boolean
  local info = type_info_at(report, path, y, x)
  if info == nil then return false end
  if info["str"] == "nil" then return true end
  local members, types = info["types"], report["types"]
  if members is {integer} and types is Node then
    for _, id in ipairs(members) do
      local member = types[id]
      if member is Node and member["str"] == "nil" then return true end
    end
  end
  return false
end

local record TealTypesModule
  type Node = Node
  get_report: function(env: Node): Node | nil
  type_info_at: function(report: Node, path: string, y: integer, x: integer): Node | nil
  type_str_at: function(report: Node, path: string, y: integer, x: integer): string | nil
  is_nilable_at: function(report: Node, path: string, y: integer, x: integer): boolean
end

local M: TealTypesModule = {
  get_report = get_report,
  type_info_at = type_info_at,
  type_str_at = type_str_at,
  is_nilable_at = is_nilable_at,
}

return M
