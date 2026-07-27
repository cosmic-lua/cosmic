--- Generate a serialized documentation index from source files.
--- Run directly as a script with source files as arguments.

local doc = require("cosmic.doc")
local codec = require("cosmic.codec")
-- This script is compiled and run by the pinned BOOTSTRAP cosmic, whose
-- embedded types predate the current tree; use the signature-stable
-- cosmo.Slurp instead of cosmic.fs.read so it works under both.
local cosmo = require("cosmo")

local record DocIndexModule
  generate: function(files: {string}, names?: {string: string}): string | nil, string
  main: function(args: {string}): integer
end

--- Normalize directory-module init shards to the module name users
--- require: cosmic.fs.init -> cosmic.fs, cosmic.init -> cosmic.
local function normalize_init(modules: {string: any})
  local renames: {string: string} = {}
  for name in pairs(modules) do
    local parent = name:match("^(.+)%.init$")
    if parent and not modules[parent] then
      renames[name] = parent
    end
  end
  for from, to in pairs(renames) do
    modules[to] = modules[from]
    modules[from] = nil
  end
end

--- Mark each module's visibility by position: public is
--- exactly cosmic.<name> for a name that does not start with `_`;
--- every other cosmic.* entry and all repo tooling (_perf.*, ...) is
--- internal. cosmo.* C binding docs keep their own include_cosmo
--- handling and are never marked.
---
--- The rule is applied inline rather than through cosmic.doc.visibility
--- because this script also runs under the PINNED bootstrap binary,
--- whose embedded stdlib may not carry that module. The two copies must
--- agree; visibility_test.tl asserts they do.
local function mark_visibility(modules: {string: any})
  for name, module_doc in pairs(modules) do
    local is_cosmo = name == "cosmo" or name:match("^cosmo%.") ~= nil
    local leaf = name:match("^cosmic%.([%w_]+)$")
    local public = leaf ~= nil and leaf:sub(1, 1) ~= "_"
    if not is_cosmo and not public then
      (module_doc as {string: any}).internal = true -- cast: from any
    end
  end
end

--- Generate serialized documentation index from source files.
--- Merges examples from _example.tl files into their corresponding modules.
--- @param files List of .tl or .d.tl file paths to process
--- @param names Import path per file, for the files whose position is
---              not their import path — GENERATED declarations, which
---              live wherever the build wrote them and document the
---              binding they declare. The caller that generated them is
---              the only thing that knows both, so it says so here
---              rather than this deriving it from a path shape.
--- @return Encoded Lua source for the index, or nil on error
--- @return Error message if generation failed
local function generate(files: {string},
    names?: {string: string}): string | nil, string
  local modules: {string: any} = {}
  local example_files: {string: any} = {} -- Store example docs separately

  for i = 1, #files do
    local file_path = files[i]

    local source, slurp_err = cosmo.Slurp(file_path)
    if not source then
      return nil, file_path .. ": " .. (slurp_err or "cannot read")
    end

    -- Parse based on file type
    local module_doc: any
    if file_path:match("%.d%.tl$") then
      module_doc = doc.parse_dtl(source, file_path)
    else
      module_doc = doc.parse(source, file_path)
    end

    -- Derive module name from file path: relative position IS the
    -- import path, except where the caller says otherwise.
    local name = names and names[file_path]
    if not name then
      name = file_path:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("/", ".")
    end

    -- Check if this is an _example file
    if name:match("_example$") then
      -- Store example docs for later merging
      local base_name = name:gsub("_example$", "")
      example_files[base_name] = module_doc
    else
      modules[name] = module_doc
    end
  end

  -- Merge examples from _example files into corresponding modules
  for base_name, example_doc in pairs(example_files) do
    local mod = modules[base_name]
    if mod then
      -- Merge examples into the module's examples
      local mod_table = mod as {string: any} -- cast: from any
      local example_table = example_doc as {string: any} -- cast: from any
      if example_table.examples then
        mod_table.examples = mod_table.examples or {}
        for _, ex in ipairs(example_table.examples as {any}) do -- cast: from any
          table.insert(mod_table.examples as {any}, ex) -- cast: from any
        end
      end
    else
      -- No source module with this name (e.g. deploy_example.tl):
      -- register the example doc itself under the base name so its
      -- examples stay addressable instead of being silently dropped.
      modules[base_name] = example_doc
    end
  end

  normalize_init(modules)
  mark_visibility(modules)

  return codec.encode_lua({modules = modules})
end

local function main(args: {string}): integer
  local result, err = generate(args)
  if not result then
    io.stderr:write("error: " .. err .. "\n")
    return 1
  end
  io.write(result)
  return 0
end

local M: DocIndexModule = {
  generate = generate,
  main = main,
}

-- When run as a script, execute main
if arg and arg[0] and arg[0]:match("doc[/\\]index%.tl$") then
  os.exit(main(arg))
end

return M
