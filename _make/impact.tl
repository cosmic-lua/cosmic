--- Changed-source impact over the existing project import graph.
--- Missing paths and non-module inputs conservatively select the project:
--- without the old graph, a deleted or renamed import cannot be excluded.
local deps = require("_make.deps")
local selection = require("_make.select")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

local record Impact
  roots: {File}
  selected: {File}
  dependencies: {File}
  excluded: {File}
  conservative: boolean
  reason: string
end

--- Compute reverse impact once, then the forward inputs of affected roots.
--- Each source's import list is read once; cycles terminate through path sets.
local function affected(proj: Project, paths: {string}): Impact
  local picked, err = selection.files(proj.files, paths, proj.root)
  local conservative = picked == nil or #paths == 0
  local reason = err or (#paths == 0 and "no changed paths supplied" or "")
  local roots: {File} = picked or {}
  local index = deps.index(proj)
  local resolvable: {string: boolean} = {}
  for _, files in pairs(index) do
    for _, f in ipairs(files) do resolvable[f.path] = true end
  end
  for _, f in ipairs(roots) do
    if not resolvable[f.path] then
      conservative = true
      reason = "changed input has no module identity: " .. f.path
    end
  end
  local direct: {string: {File}} = {}
  local reverse: {string: {File}} = {}
  for _, f in ipairs(proj.files) do
    local inputs: {File} = {}
    if f.path:sub(-3) == ".tl" or f.path:sub(-4) == ".lua" then
      inputs = deps.direct(proj.root, f, index)
    end
    direct[f.path] = inputs
    for _, dep in ipairs(inputs) do
      local users = reverse[dep.path] or {}
      users[#users + 1] = f
      reverse[dep.path] = users
    end
  end
  local selected: {File} = {}
  local seen: {string: boolean} = {}
  for _, f in ipairs(conservative and proj.files or roots) do
    if not seen[f.path] then
      seen[f.path] = true
      selected[#selected + 1] = f
    end
  end
  local i = 1
  while i <= #selected do
    for _, f in ipairs(reverse[selected[i].path] or {}) do
      if not seen[f.path] then
        seen[f.path] = true
        selected[#selected + 1] = f
      end
    end
    i = i + 1
  end
  local inputs: {File} = {}
  local inspected: {string: boolean} = {}
  local queue: {File} = {}
  for _, f in ipairs(selected) do
    queue[#queue + 1] = f
    inspected[f.path] = true
  end
  i = 1
  while i <= #queue do
    for _, f in ipairs(direct[queue[i].path] or {}) do
      if not inspected[f.path] then
        inspected[f.path] = true
        queue[#queue + 1] = f
        inputs[#inputs + 1] = f
      end
    end
    i = i + 1
  end
  local excluded: {File} = {}
  for _, f in ipairs(proj.files) do
    if not inspected[f.path] then excluded[#excluded + 1] = f end
  end
  local function before(a: File, b: File): boolean return a.path < b.path end
  table.sort(selected, before)
  table.sort(inputs, before)
  table.sort(excluded, before)
  return {roots = roots, selected = selected, dependencies = inputs,
    excluded = excluded, conservative = conservative, reason = reason}
end

local record ImpactModule
  type Impact = Impact
  affected: function(proj: Project, paths: {string}): Impact
end
local M: ImpactModule = {affected = affected}
return M
