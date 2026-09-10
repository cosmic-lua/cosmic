--- Assemble public-module declarations from an in-memory source map.
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

--- Assemble canonical declaration entries without reading the filesystem.
--- @param sources Source bytes keyed by repository-relative path
--- @return Surface|nil Sorted public modules and their declaration entries
--- @return string Diagnostic on scan failure or a conflicting duplicate
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
  local locations: {string: string} = {}
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
        local location = string.format("%s:%d:%d", path, member.line, member.column)
        local previous = surface.entries[key]
        if previous and previous ~= member.canonical_type then
          return nil, string.format("conflicting surface entry %s: %s and %s",
            key, locations[key], location)
        end
        if not previous then
          surface.entries[key] = member.canonical_type
          locations[key] = location
        end
      end
    end
  end
  return surface
end

local record SurfaceModule
  type Surface = Surface
  extract: function(sources: {string: string}): Surface | nil, string
end

local M: SurfaceModule = {extract = extract}
return M
