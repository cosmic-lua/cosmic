--- `--diff OLD`: compare OLD's public API surface with this executable.
local proc = require("cosmic.proc")
local surface_archive = require("_tool.surface_archive")
local surface_diff = require("_tool.surface_diff")

local function refuse(detail: string): integer
  io.stderr:write("cosmic-lua: --diff: " .. detail .. "\n")
  return 2
end

--- Compare surfaces from two executable archives and print the complete report.
--- @param old_path string Earlier executable archive
--- @param new_path string Later executable archive
--- @return integer 1 for a breaking delta, 0 for additive or no deltas, 2 on failure
local function compare(old_path: string, new_path: string): integer
  if not old_path or old_path == "" then
    return refuse("usage: --diff <binary>")
  end
  local old, old_err = surface_archive.surface_of(old_path)
  if not old then
    return refuse(old_err or "cannot read old executable")
  end
  local new, new_err = surface_archive.surface_of(new_path)
  if not new then
    return refuse(new_err or "cannot read running executable")
  end
  local deltas = surface_diff.diff(old, new)
  io.write(surface_diff.render(deltas))
  return surface_diff.has_breaking(deltas) and 1 or 0
end

--- Run `--diff OLD`, resolving the running executable as the new surface.
--- @param old_path string Earlier executable archive
--- @return integer 1 for a breaking delta, 0 for additive or no deltas, 2 on failure
local function run(old_path: string): integer
  if not old_path or old_path == "" then
    return refuse("usage: --diff <binary>")
  end
  local self_path, self_err = proc.interpreter()
  if not self_path then
    return refuse(self_err or "cannot resolve running executable")
  end
  return compare(old_path, self_path)
end

local record DiffModule
  compare: function(old_path: string, new_path: string): integer
  run: function(old_path: string): integer
end

local M: DiffModule = {compare = compare, run = run}
return M
