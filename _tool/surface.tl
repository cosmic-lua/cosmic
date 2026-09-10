--- Assemble public-module declarations from an in-memory source map.
local json = require("cosmic.json")
local scanner = require("_tool.surface_scan")

local record Surface
  entries: {string: string}
  modules: {string}
end

local function is_excluded(path: string): boolean
  if not path:match("%.tl$")
  or path:match("_test%.tl$") or path:match("_example%.tl$") then
    return true
  end
  for segment in path:gmatch("[^/]+") do
    if segment:sub(1, 1) == "_" then
      return true
    end
  end
  return false
end

--- Return the explicit public owner named by a root source, if any.
local function declared_owner(path: string): string | nil
  if is_excluded(path) then
    return nil
  end
  local name = path:match("^cosmic/([^/]+)%.tl$")
  if name == "init" then
    return nil
  end
  if not name then
    name = path:match("^cosmic/([^/]+)/init%.tl$")
  end
  if name and name:sub(1, 1) ~= "_" then
    return name
  end
  return nil
end

--- Return the first-level owner for any eligible source path.
local function source_owner(path: string): string | nil
  if is_excluded(path) then
    return nil
  end
  local name = path:match("^cosmic/([^/]+)/.+%.tl$")
  if not name then
    name = path:match("^cosmic/([^/]+)%.tl$")
  end
  if path == "cosmic/init.tl" or (name and name:sub(1, 1) == "_") then
    return nil
  end
  return name
end

--- Encode the distinct canonical types observed for one folded entry key.
--- A singleton stays byte-identical; multiple values are sorted JSON behind
--- a prefix Teal's lexer cannot produce at the start of a type.
local function encode_types(found: {string: boolean}): string | nil, string
  local types: {string} = {}
  for canonical_type in pairs(found) do
    types[#types + 1] = canonical_type
  end
  table.sort(types)
  if #types == 1 then
    return types[1]
  end
  local encoded, err = json.encode(types)
  if not encoded then
    return nil, err
  end
  return "@types " .. encoded
end

--- Assemble canonical declaration entries without reading the filesystem.
--- Every folded key records its distinct canonical type bytes. A singleton
--- remains the type itself; multiple values use deterministic `@types` JSON.
--- @param sources Source bytes keyed by repository-relative path
--- @return Surface|nil Sorted public modules and their declaration entries
--- @return string Diagnostic on scan or type-set encoding failure
local function extract(sources: {string: string}): Surface | nil, string
  local paths: {string} = {}
  local owners: {string: boolean} = {}
  for path in pairs(sources) do
    paths[#paths + 1] = path
    local owner = declared_owner(path)
    if owner then
      owners[owner] = true
    end
  end
  table.sort(paths)

  local surface: Surface = {entries = {}, modules = {}}
  local types_by_key: {string: {string: boolean}} = {}
  for owner in pairs(owners) do
    surface.modules[#surface.modules + 1] = "cosmic." .. owner
  end
  table.sort(surface.modules)

  for _, path in ipairs(paths) do
    local owner = source_owner(path)
    if owner and owners[owner] then
      local members, err = scanner.scan(sources[path], path)
      if not members then
        return nil, err
      end
      for _, member in ipairs(members) do
        local key = "cosmic." .. owner .. "." .. member.declaration ..
        "." .. member.name
        local found = types_by_key[key]
        if not found then
          found = {}
          types_by_key[key] = found
        end
        found[member.canonical_type] = true
      end
    end
  end
  for key, found in pairs(types_by_key) do
    local encoded, err = encode_types(found)
    if not encoded then
      return nil, err
    end
    surface.entries[key] = encoded
  end
  return surface
end

local record SurfaceModule
  type Surface = Surface
  extract: function(sources: {string: string}): Surface | nil, string
end

local M: SurfaceModule = {extract = extract}
return M
