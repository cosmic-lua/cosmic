--- Existing Cosmic cast allowlist policy, separated from syntax traversal.
--- The established project data path stays opt-in by its conventional name.
--- Its exact bytes and resolved path key the cache across repeated lint runs.
local errno = require("cosmic.errno")
local fs = require("cosmic.fs")
local pattern = require("cosmic.ast.pattern")
local node = require("cosmic.ast.node")
local teal = require("cosmic.teal")

local record ExplicitSite
  path: string
  text: string
end

local record Kind
  name: string
  pattern: string
  where: {string}
  explicit: {ExplicitSite}
end

local record Compiled
  kind: Kind
  pattern: pattern.Pattern | nil
end

local record Policy
  kinds: {Compiled}
  reason: string | nil
end

local cached_path = ""
local cached_source = ""
local compiled: {Compiled} = {}
local cached_error: string | nil

local function invalid(path: string, field: string): {Compiled}, string
  compiled = {}
  cached_error = "malformed cast allowlist " .. path .. ": " .. field
  return compiled, cached_error
end

local function string_list(value: any): {string} | nil
  if not (value is {any}) then return nil end
  local out: {string} = {}
  for _, raw_item in ipairs(value) do
    local item = raw_item
    if not (item is string) then return nil end
    out[#out + 1] = item
  end
  return out
end

local function explicit_list(value: any): {ExplicitSite} | nil
  if not (value is {any}) then return nil end
  local out: {ExplicitSite} = {}
  for _, raw_item in ipairs(value) do
    local item = raw_item
    if not (item is {string: any}) then return nil end
    local path, text = item.path, item.text
    if not (path is string) or not (text is string) then return nil end
    out[#out + 1] = {path = path, text = text}
  end
  return out
end

local function load_kinds(): {Compiled}, string | nil
  local path = fs.absolute_path("_build/casts_kinds.tl")
  local content, read_err = fs.read(path)
  if not content then
    if errno.name_in(read_err) == "ENOENT" then return {}, nil end
    return {}, "cannot read cast allowlist: " .. path .. ": " .. read_err
  end
  if path == cached_path and content == cached_source then
    return compiled, cached_error
  end
  cached_path, cached_source = path, content
  compiled, cached_error = {}, nil
  local result = teal.compile(content, {chunk_name = path})
  if not result.ok or not result.code then
    cached_error = "cannot compile cast allowlist: " .. path
    return compiled, cached_error
  end
  local chunk, err = load(result.code)
  if not chunk then
    cached_error = err
    return compiled, cached_error
  end
  local ok, value = pcall(chunk)
  if not ok or not (value is {string: any}) then
    cached_error = "cannot load cast allowlist: " .. path
    return compiled, cached_error
  end
  local raw = value.KINDS
  if not (raw is {any}) then
    cached_error = "cast allowlist has no KINDS array: " .. path
    return compiled, cached_error
  end
  for i, raw_item in ipairs(raw) do
    local item = raw_item
    if not (item is {string: any}) then
      return invalid(path, "KINDS[" .. i .. "] is not a record")
    end
    local name = item.name
    if not (name is string) then
      return invalid(path, "KINDS[" .. i .. "].name is not a string")
    end
    local pattern_source = item.pattern
    if not (pattern_source is string) then
      return invalid(path, "KINDS[" .. i .. "].pattern is not a string")
    end
    local where = string_list(item.where)
    if not where then
      return invalid(path, "KINDS[" .. i .. "].where is not a string array")
    end
    local explicit = explicit_list(item.explicit)
    if not explicit then
      return invalid(path, "KINDS[" .. i .. "].explicit is malformed")
    end
    local kind: Kind = {
      name = name,
      pattern = pattern_source,
      where = where,
      explicit = explicit,
    }
    local p: pattern.Pattern | nil
    if kind.pattern ~= "" then
      local found, perr = pattern.compile(kind.pattern)
      if not found then
        cached_error = perr
        compiled = {}
        return compiled, cached_error
      end
      p = found
    end
    compiled[#compiled + 1] = {kind = kind, pattern = p}
  end
  return compiled, nil
end

local function load_policy(): Policy
  local kinds, err = load_kinds()
  return {kinds = kinds, reason = err}
end

local function allows(policy: Policy, path: string, text: string, target: node.Node): boolean
  for _, entry in ipairs(policy.kinds) do
    local p = entry.pattern
    if p then
      for _, prefix in ipairs(entry.kind.where) do
        if path:sub(1, #prefix) == prefix and pattern.match(p, target) then
          return true
        end
      end
    end
    for _, site in ipairs(entry.kind.explicit) do
      if site.path == path and site.text == text then return true end
    end
  end
  return false
end

local record PolicyModule
  type Policy = Policy
  load: function(): Policy
  allows: function(policy: Policy, path: string, text: string, target: node.Node): boolean
end
local M: PolicyModule = {load = load_policy, allows = allows}
return M
