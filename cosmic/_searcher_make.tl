--- Source-only make searcher. Load its compiler capsule before installation:
--- compiler requires must not recursively compile the compiler from the tree.
local teal = require("cosmic.teal")
local context = require("cosmic._teal_project")
local _ast = require("cosmic._teal_ast")
local _discard = require("cosmic._teal_discard")
local tl = require("tl")
local fs = require("cosmic.fs")

local installed_root: string | nil
local compiling = false

local function source(root: string, name: string): string | nil
  local stem = root .. "/" .. name:gsub("%.", "/")
  for _, suffix in ipairs({".tl", "/init.tl", ".lua", "/init.lua"}) do
    local path = stem .. suffix
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end
  return nil
end

local function compile(path: string, root: string): string
  local previous = context.get_root()
  local previous_guard = compiling
  local previous_path = tl.path
  local previous_search = tl.search_module
  context.set_root(root)
  compiling = true
  local ok, result = pcall(teal.compile_file, path, {strict = true, werror = false})
  compiling = previous_guard
  context.set_root(previous)
  -- Also restore if env construction or code generation throws before the
  -- engine reaches its ordinary process-call cleanup.
  tl.path = previous_path
  tl.search_module = previous_search
  if not ok then
    -- throws: a present broken source is a require failure, never a fallback.
    error(tostring(result), 0)
  end
  if not result.ok then
    local messages: {string} = {}
    for _, issue in ipairs(result.errors) do
      messages[#messages + 1] = issue.file .. ":" .. issue.line .. ":" ..
      issue.column .. ": " .. issue.message
    end
    -- throws: searcher protocol; deliberately no optional hint imports.
    error(table.concat(messages, "\n"), 0)
  end
  return result.code or ""
end

--- Install once for one absolute root; conflicting roots are refused.
--- Missing source falls through, but neither built o/ nor cached Lua is read.
local function install(root: string): boolean, string
  if not fs.is_absolute(root) then
    return false, "make searcher requires an absolute root"
  end
  if installed_root then
    if installed_root == root then return true end
    return false, "make searcher already installed for " .. installed_root
  end
  installed_root = root
  table.insert(package.searchers, 2, function(name: string): any, any
      if compiling then return nil end
      local path = source(root, name)
      if not path then return nil end
      local loader: function
      local err: string
      if path:sub(-3) == ".tl" then
        local code = compile(path, root):gsub("^#![^\n]*\n", "")
        loader, err = load(code, "@" .. path)
      else
        loader, err = loadfile(path)
      end
      if not loader then
        -- throws: present-source errors must not select the embedded copy.
        error(err or "cannot load " .. path, 0)
      end
      return loader, path
    end)
  return true
end

return {install = install}
