--- Script loading without a command-registry dependency. Explicit-manifest
--- generator children need this loader, not every CLI handler's type imports.

--- Load a script file (.tl or .lua): .tl through Teal (cached), .lua directly.
--- @param script_path string Script to load
--- @return function|nil The chunk, or nil on a load failure
--- @return string The load error
local function load_script_file(script_path: string): function(...: any): any ... | nil, string
  if script_path:match("%.tl$") then
    package.path = package.path .. ";/zip/.tl/?.tl" -- so teal can find cosmic modules
    local teal = require("cosmic.teal")
    local code, cerr = teal.compile_cached(script_path)
    if not code then
      return nil, cerr
    end
    local src = code
    if src:sub(1, 2) == "#!" then
      src = src:sub((src:find("\n") or 0) + 1)
    end
    return load(src, "@" .. script_path)
  else
    return loadfile(script_path)
  end
end

local record ScriptModule
  load_script_file: function(script_path: string): function(...: any): any ... | nil, string
end

local M: ScriptModule = {load_script_file = load_script_file}
return M
