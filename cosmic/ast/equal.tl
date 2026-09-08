--- Structural equality for parsed syntax and Teal type payloads.
---
--- The parser attaches source locations, filenames, and compiler
--- bookkeeping to both AST nodes and type nodes. Those fields are useful
--- for diagnostics, but two separately parsed copies of the same source
--- must still compare equal. This helper also handles the parser's real
--- back-references and other shared tables with an identity-pair guard.
local META_KEYS: {string: boolean} = {
  f = true, y = true, x = true, yend = true, xend = true,
  comments = true, typeid = true, if_parent = true,
}

local function map_view(value: any): {any: any} | nil
  if value is {any: any} then
    return value as {any: any} -- cast: generic map view
  end
  return nil
end

local function node_kind(value: {any: any}): string | nil
  local kind = value["kind"]
  if kind is string then
    return kind
  end
  return nil
end

local function meaningful_key(owner: {any: any}, key: any): boolean
  if key is string and META_KEYS[key] then
    return false
  end
  -- `tk` is the spelling of a leaf token. On compound nodes it is the
  -- incidental token which happened to start that node, so it is not a
  -- part of structural identity. Type payloads have no `kind` and keep
  -- every non-metadata field, including their named parts.
  if key == "tk" then
    local kind = node_kind(owner)
    return kind == "variable" or kind == "identifier" or kind == "string"
  end
  return true
end

--- Compare two parser values recursively, ignoring positions, parse-file
--- names, type IDs, comments, and the `if_parent` backlink. Shared and
--- cyclic values are guarded by the pair `(left,right)`, so a revisit is
--- accepted only after that exact pair has already been compared.
--- @param left any First parsed value
--- @param right any Second parsed value
--- @return boolean Whether the values have the same source structure
local function equal(left: any, right: any): boolean
  local seen: {any: {any: boolean}} = {}
  local function compare(a: any, b: any): boolean
    if a == nil then
      return b == nil
    end
    if b == nil then
      return false
    end
    local am = map_view(a)
    local bm = map_view(b)
    if not am or not bm then
      return a == b
    end

    local ak = node_kind(am)
    local bk = node_kind(bm)
    if ak ~= bk then
      return false
    end

    local prior = seen[am]
    if prior and prior[bm] then
      return true
    end
    if not prior then
      prior = {}
      seen[am] = prior
    end
    prior[bm] = true

    for key, av in pairs(am) do
      if meaningful_key(am, key) then
        local bv = bm[key]
        if bv == nil and av ~= nil then
          return false
        end
        if not compare(av, bv) then
          return false
        end
      end
    end
    for key, bv in pairs(bm) do
      if meaningful_key(bm, key) and bv ~= nil and am[key] == nil then
        return false
      end
    end
    return true
  end
  return compare(left, right)
end

local record EqualModule
  equal: function(left: any, right: any): boolean
end

local M: EqualModule = {
  equal = equal,
}

return M
