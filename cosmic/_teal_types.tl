--- Typed access to Teal's position type report.
---
--- The compiler owns the raw report. Public callers receive revision-scoped
--- TypeRefs and query records, so absence or an unsupported report shape is
--- `unknown`, never a false semantic fact. Structural queries use TypeInfo's
--- ids (union members, function returns, fields and containers); `str` is
--- retained only for display and primitive-name equality.

local record TypeInfo
  t: integer
  str: string
  file: string
  x: integer
  y: integer
  ref: integer
  typeargs: {{string, integer}}
  fields: {string: integer}
  meta_fields: {string: integer}
  enums: {string}
  args: {{integer, string}}
  rets: {{integer, string}}
  vararg: boolean
  varret: boolean
  types: {integer}
  keys: integer
  values: integer
  elements: integer
end

local record TypeReport
  by_pos: {string: {integer: {integer: integer}}}
  types: {integer: TypeInfo}
end

--- An inferred type, valid only for the Analysis revision that returned it.
local record TypeRef
  _owner: any
  _id: integer
  revision: integer
end


local enum QueryState
  "known"
  "unknown"
end

--- Result of asking for one type.
local record TypeQuery
  state: QueryState
  value: TypeRef | nil
  reason: string | nil
end

--- Result of asking for an ordered list of types.
local record TypesQuery
  state: QueryState
  values: {TypeRef} | nil
  reason: string | nil
  variadic: boolean | nil
end

--- Result of asking for a boolean semantic fact.
local record BoolQuery
  state: QueryState
  value: boolean | nil
  reason: string | nil
end

local record FieldQuery
  state: QueryState
  values: {string: TypeRef} | nil
  reason: string | nil
end

local record Report
  _raw: TypeReport
  revision: integer
end

local type Map = {any: any}
local TYPECODES < const > = require("tl").typecodes

local function unknown_type(reason: string): TypeQuery
  return {state = "unknown", reason = reason}
end

local function unknown_types(reason: string): TypesQuery
  return {state = "unknown", reason = reason}
end

local function unknown_bool(reason: string): BoolQuery
  return {state = "unknown", reason = reason}
end

local function ref(report: Report, id: integer): TypeRef | nil
  if not report._raw.types[id] then
    return nil
  end
  return {_owner = report, _id = id, revision = report.revision}
end

local function info(report: Report, tref: TypeRef): TypeInfo | nil, string
  if tref._owner ~= report or tref.revision ~= report.revision then
    return nil, "type belongs to another analysis revision"
  end
  local ti = report._raw.types[tref._id]
  if not ti then
    return nil, "type is absent from the compiler report"
  end
  return ti
end

--- Construct a typed report view from a checked Teal environment.
local function from_env(env: any, revision?: integer): Report | nil, string
  if not (env is Map) then
    return nil, "checker environment has no type report"
  end
  local reporter = env["reporter"]
  if not (reporter is Map) then
    return nil, "checker did not provide a type reporter"
  end
  local get_report = reporter["get_report"]
  if not (get_report is function(any): any) then
    return nil, "checker type reporter cannot be read"
  end
  local raw = get_report(reporter)
  if not (raw is Map) then
    return nil, "checker returned no type report"
  end
  local by_pos = raw["by_pos"]
  local types = raw["types"]
  if not (by_pos is Map) or not (types is Map) then
    return nil, "checker returned an incomplete type report"
  end
  return {
    _raw = raw as TypeReport, -- cast: validated raw TypeReport map fields above
    revision = revision or 0,
  }
end

--- Type recorded at one exact compiler source position.
--- No nearest-position fallback is used: absence is unknown.
local function type_at(report: Report, file: string, y: any, x: any): TypeQuery
  if not (y is number) or not (x is number) then
    return unknown_type("node has no source position")
  end
  local iy = math.tointeger(y)
  local ix = math.tointeger(x)
  if not iy or not ix then
    return unknown_type("node has a non-integral source position")
  end
  local by_file = report._raw.by_pos[file]
  if not by_file then
    return unknown_type("file is absent from the compiler type report")
  end
  local row = by_file[iy]
  if not row then
    return unknown_type("position is absent from the compiler type report")
  end
  local id = row[ix]
  if not id then
    return unknown_type("position is absent from the compiler type report")
  end
  local value = ref(report, id)
  if not value then
    return unknown_type("position refers to a missing compiler type")
  end
  return {state = "known", value = value}
end

--- Human-readable Teal rendering. It is display only.
local function describe(report: Report, tref: TypeRef): string
  local ti = info(report, tref)
  return ti and ti.str or "<unknown>"
end

local function refs_for(report: Report, ids: {integer}): TypesQuery
  local values: {TypeRef} = {}
  for _, id in ipairs(ids) do
    local value = ref(report, id)
    if not value then
      return unknown_types("compiler report refers to a missing type")
    end
    values[#values + 1] = value
  end
  return {state = "known", values = values}
end

--- Direct members of a union/poly/tuple type.
local function members(report: Report, tref: TypeRef): TypesQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_types(err)
  end
  if ti.t ~= TYPECODES["UNION"] then
    return unknown_types("type is not a union")
  end
  if not ti.types then
    return unknown_types("union has no reported members")
  end
  return refs_for(report, ti.types)
end

--- Declared return slots of a function type.
local function returns(report: Report, tref: TypeRef): TypesQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_types(err)
  end
  if not ti.rets then
    return unknown_types("type is not a function")
  end
  local ids: {integer} = {}
  for _, ret in ipairs(ti.rets) do
    if not ret[1] then
      return unknown_types("function return is missing its type")
    end
    ids[#ids + 1] = ret[1]
  end
  local out = refs_for(report, ids)
  out.variadic = ti.varret or false
  return out
end

--- Declared argument slots of a function type.
local function arguments(report: Report, tref: TypeRef): TypesQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_types(err)
  end
  if not ti.args then
    return unknown_types("type is not a function")
  end
  local ids: {integer} = {}
  for _, param in ipairs(ti.args) do
    if not param[1] then
      return unknown_types("function argument is missing its type")
    end
    ids[#ids + 1] = param[1]
  end
  local out = refs_for(report, ids)
  out.variadic = ti.vararg or false
  return out
end

--- Named record fields, resolved structurally from report ids.
local function fields(report: Report, tref: TypeRef): FieldQuery
  local ti, err = info(report, tref)
  if not ti then
    return {state = "unknown", reason = err}
  end
  if not ti.fields then
    return {state = "unknown", reason = "type has no reported record fields"}
  end
  local values: {string: TypeRef} = {}
  for name, id in pairs(ti.fields) do
    local value = ref(report, id)
    if not value then
      return {state = "unknown", reason = "record field refers to a missing type"}
    end
    values[name] = value
  end
  return {state = "known", values = values}
end

--- Array element type.
local function elements(report: Report, tref: TypeRef): TypeQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_type(err)
  end
  if not ti.elements then
    return unknown_type("type has no reported array element")
  end
  local value = ref(report, ti.elements)
  return value and {state = "known", value = value}
  or unknown_type("array element refers to a missing type")
end

local function is_named(report: Report, tref: TypeRef, name: string): BoolQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_bool(err)
  end
  if ti.t == TYPECODES["ANY"] or ti.t == TYPECODES["UNKNOWN"]
  or ti.t == TYPECODES["INVALID"] or ti.t == TYPECODES["TYPE_VARIABLE"] then
    return unknown_bool("type name is not concrete")
  end
  return {state = "known", value = ti.str == name}
end

local function contains_named_inner(report: Report, tref: TypeRef, name: string,
    seen: {integer: boolean}): BoolQuery
  local ti, err = info(report, tref)
  if not ti then
    return unknown_bool(err)
  end
  if name == "nil" and ti.t == TYPECODES["NIL"] then
    return {state = "known", value = true}
  end
  if seen[tref._id] then
    return unknown_bool("nominal type cycle has no conclusive nil fact")
  end
  seen[tref._id] = true
  if ti.t == TYPECODES["ANY"] or ti.t == TYPECODES["UNKNOWN"]
  or ti.t == TYPECODES["INVALID"] or ti.t == TYPECODES["TYPE_VARIABLE"]
  or ti.t == TYPECODES["SELF"] then
    return unknown_bool("type is not concrete enough to prove nilability")
  end
  if ti.ref then
    local target = ref(report, ti.ref)
    if not target then
      return unknown_bool("nominal reference points to a missing type")
    end
    return contains_named_inner(report, target, name, seen)
  end
  if ti.t == TYPECODES["UNION"] and ti.types then
    local unresolved: string = nil
    for _, id in ipairs(ti.types) do
      local member = ref(report, id)
      if not member then
        return unknown_bool("aggregate member points to a missing type")
      end
      local has = contains_named_inner(report, member, name, seen)
      if has.value then
        return has
      end
      if has.state == "unknown" then
        unresolved = has.reason
      end
    end
    if unresolved then
      return unknown_bool(unresolved)
    end
  elseif ti.t == TYPECODES["UNION"] then
    return unknown_bool("union has no reported members")
  elseif ti.t == TYPECODES["TUPLE"] or ti.t == TYPECODES["POLY"] then
    return unknown_bool("aggregate is not a single value type")
  end
  return {state = "known", value = false}
end

local function contains_nil(report: Report, tref: TypeRef): BoolQuery
  return contains_named_inner(report, tref, "nil", {})
end

--- Whether a function has at least two returns and its last is string.
local function is_fallible(report: Report, tref: TypeRef): BoolQuery
  local rets = returns(report, tref)
  if rets.state == "unknown" then
    return unknown_bool(rets.reason)
  end
  local values = rets.values
  if not values then
    return unknown_bool("function returns are unavailable")
  end
  if #values < 2 then
    return {state = "known", value = false}
  end
  local last = values[#values]
  local ti, err = info(report, last)
  if not ti then
    return unknown_bool(err)
  end
  if ti.t == TYPECODES["STRING"] then
    return {state = "known", value = true}
  end
  if ti.t == TYPECODES["ANY"] or ti.t == TYPECODES["UNKNOWN"]
  or ti.t == TYPECODES["INVALID"] or ti.t == TYPECODES["TYPE_VARIABLE"] then
    return unknown_bool("function error return is not concrete")
  end
  -- D24 structured failures implement Failure's message field and
  -- __tostring metafield. Resolve a nominal's concrete definition first.
  if ti.ref then
    local target = ref(report, ti.ref)
    if not target then
      return unknown_bool("nominal error return points to a missing type")
    end
    ti, err = info(report, target)
    if not ti then
      return unknown_bool(err)
    end
  end
  if ti.fields and ti.meta_fields then
    local message_id = ti.fields["message"]
    local tostring_id = ti.meta_fields["__tostring"]
    if message_id and tostring_id then
      local message = ref(report, message_id)
      local tostring_ref = ref(report, tostring_id)
      if not message or not tostring_ref then
        return unknown_bool("structured failure fields point to missing types")
      end
      local is_string = is_named(report, message, "string")
      local signature = arguments(report, tostring_ref)
      if is_string.state == "unknown" or signature.state == "unknown" then
        return unknown_bool("structured failure fields are unresolved")
      end
      return {state = "known", value = is_string.value == true}
    end
  end
  return {state = "known", value = false}
end

local record TealTypesModule
  type TypeRef = TypeRef
  type QueryState = QueryState
  type TypeQuery = TypeQuery
  type TypesQuery = TypesQuery
  type BoolQuery = BoolQuery
  type FieldQuery = FieldQuery
  type Report = Report
  from_env: function(env: any, revision?: integer): Report | nil, string
  type_at: function(report: Report, file: string, y: any, x: any): TypeQuery
  describe: function(report: Report, tref: TypeRef): string
  members: function(report: Report, tref: TypeRef): TypesQuery
  arguments: function(report: Report, tref: TypeRef): TypesQuery
  returns: function(report: Report, tref: TypeRef): TypesQuery
  fields: function(report: Report, tref: TypeRef): FieldQuery
  elements: function(report: Report, tref: TypeRef): TypeQuery
  contains_nil: function(report: Report, tref: TypeRef): BoolQuery
  is_fallible: function(report: Report, tref: TypeRef): BoolQuery
end

local M: TealTypesModule = {
  from_env = from_env,
  type_at = type_at,
  describe = describe,
  members = members,
  arguments = arguments,
  returns = returns,
  fields = fields,
  elements = elements,
  contains_nil = contains_nil,
  is_fallible = is_fallible,
}

return M
