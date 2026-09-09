--- Dynamically scoped make-source compilation context. The searcher restores
--- the previous root even when compilation throws; ordinary compilation has
--- no root and retains the normal shared environment cache.
local current: string | nil

local function get_root(): string | nil
  return current
end

local function set_root(root: string | nil)
  current = root
end

--- Search the engine's complete ordered path without tl's unconditional
--- OS TL_PATH override. Only make compilation installs this scoped lookup.
local function search_module(path: string, name: string, all: boolean): string | nil, FILE
  local suffixes: {string} = {".tl"}
  if all then
    suffixes = {".d.tl", ".tl", ".lua"}
  end
  local slash_name = name:gsub("%.", "/")
  for entry in path:gmatch("[^;]+") do
    local candidate = entry:gsub("%?", function(): string return slash_name end)
    for _, suffix in ipairs(suffixes) do
      local filename = candidate
      if candidate:sub(-4) == ".lua" then filename = candidate:sub(1, -5) .. suffix end
      local f = io.open(filename, "rb")
      if f then return filename, f end
    end
  end
  return nil
end

return {get_root = get_root, set_root = set_root, search_module = search_module}
