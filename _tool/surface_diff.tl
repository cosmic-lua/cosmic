--- Deterministic name-level comparison of two in-memory public surfaces.
local surface = require("_tool.surface")

--- Every structural change the name-level comparison can report.
local enum DeltaKind
  "removed"
  "added"
  "retyped"
  "module-removed"
  "module-added"
end

--- One module or declaration-entry change.
--- Module changes carry an empty key and no type strings.
local record Delta
  kind: DeltaKind
  module: string
  key: string
  old_type: string
  new_type: string
end

local function module_for(key: string): string
  return key:match("^(cosmic%.[^.]+)%.") or key
end

local function module_set(modules: {string}): {string: boolean}
  local found: {string: boolean} = {}
  for _, name in ipairs(modules) do
    found[name] = true
  end
  return found
end

local function append_modules(deltas: {Delta}, old: surface.Surface,
    new: surface.Surface)
  local old_modules = module_set(old.modules)
  local new_modules = module_set(new.modules)
  for name in pairs(old_modules) do
    if not new_modules[name] then
      deltas[#deltas + 1] = {
        kind = "module-removed",
        module = name,
        key = "",
      }
    end
  end
  for name in pairs(new_modules) do
    if not old_modules[name] then
      deltas[#deltas + 1] = {
        kind = "module-added",
        module = name,
        key = "",
      }
    end
  end
end

local function append_entries(deltas: {Delta}, old: surface.Surface,
    new: surface.Surface)
  for key, old_type in pairs(old.entries) do
    local new_type = new.entries[key]
    if new_type == nil then
      deltas[#deltas + 1] = {
        kind = "removed",
        module = module_for(key),
        key = key,
        old_type = old_type,
      }
    elseif new_type ~= old_type then
      deltas[#deltas + 1] = {
        kind = "retyped",
        module = module_for(key),
        key = key,
        old_type = old_type,
        new_type = new_type,
      }
    end
  end
  for key, new_type in pairs(new.entries) do
    if old.entries[key] == nil then
      deltas[#deltas + 1] = {
        kind = "added",
        module = module_for(key),
        key = key,
        new_type = new_type,
      }
    end
  end
end

--- Compare two surfaces by module name, entry name, and canonical type bytes.
--- Module events and their entry events are deliberately independent.
--- @param old Surface Earlier public surface
--- @param new Surface Later public surface
--- @return {Delta} Changes sorted by module, key, then kind
local function diff(old: surface.Surface, new: surface.Surface): {Delta}
  local deltas: {Delta} = {}
  append_modules(deltas, old, new)
  append_entries(deltas, old, new)
  table.sort(deltas, function(a: Delta, b: Delta): boolean
      if a.module ~= b.module then
        return a.module < b.module
      elseif a.key ~= b.key then
        return a.key < b.key
      end
      return tostring(a.kind) < tostring(b.kind)
    end)
  return deltas
end

--- Report whether any delta removes a name or changes its type.
--- @param deltas {Delta} Name-level changes
--- @return boolean True for removed, retyped, or module-removed changes
local function has_breaking(deltas: {Delta}): boolean
  for _, delta in ipairs(deltas) do
    if delta.kind == "removed" or delta.kind == "retyped"
    or delta.kind == "module-removed" then
      return true
    end
  end
  return false
end

local function relative_key(delta: Delta): string
  return delta.key:sub(#delta.module + 2)
end

--- Render module-grouped changes and their additive/breaking verdict counts.
--- @param deltas {Delta} Deterministically ordered name-level changes
--- @return string Human-readable, newline-terminated diff
local function render(deltas: {Delta}): string
  local out: {string} = {}
  local current = ""
  local breaking, added = 0, 0
  for _, delta in ipairs(deltas) do
    if delta.module ~= current then
      if current ~= "" then
        out[#out + 1] = ""
      end
      current = delta.module
      out[#out + 1] = current .. ":"
    end
    if delta.kind == "module-removed" or delta.kind == "module-added" then
      out[#out + 1] = "  " .. delta.kind
    elseif delta.kind == "removed" then
      out[#out + 1] = "  removed " .. relative_key(delta) .. ": " .. delta.old_type
    elseif delta.kind == "added" then
      out[#out + 1] = "  added " .. relative_key(delta) .. ": " .. delta.new_type
    else
      out[#out + 1] = "  retyped " .. relative_key(delta) .. ": " ..
      delta.old_type .. " -> " .. delta.new_type
    end
    if delta.kind == "removed" or delta.kind == "retyped"
    or delta.kind == "module-removed" then
      breaking = breaking + 1
    else
      added = added + 1
    end
  end
  if #out > 0 then
    out[#out + 1] = ""
  end
  out[#out + 1] = string.format("diff: %d removed or retyped, %d added",
    breaking, added)
  return table.concat(out, "\n") .. "\n"
end

local record SurfaceDiffModule
  type DeltaKind = DeltaKind
  type Delta = Delta
  diff: function(old: surface.Surface, new: surface.Surface): {Delta}
  has_breaking: function(deltas: {Delta}): boolean
  render: function(deltas: {Delta}): string
end

local M: SurfaceDiffModule = {
  diff = diff,
  has_breaking = has_breaking,
  render = render,
}

return M
