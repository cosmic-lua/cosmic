--- Generate a serialized documentation index from source files.
--- Run directly as a script with source files as arguments.

local doc = require("_tool.doc")
local codec = require("cosmic.codec")
-- This script is compiled and run by the pinned BOOTSTRAP cosmic, whose
-- embedded types predate the current tree; use the signature-stable
-- cosmo.Slurp instead of cosmic.fs.read so it works under both.
local cosmo = require("cosmo")

local record DocIndexModule
  generate: function(files: {string}, names?: {string: string}): string | nil, string
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

--- Append `src`'s entries of `key` (functions/records/examples) onto
--- `dst`, skipping names `dst` already carries — the parent's own doc
--- wins over a shard's on a collision. `allowed`, when given, restricts
--- the merge to entries whose name it contains.
local function merge_entries(dst: {string: any}, src: {string: any},
    key: string, allowed?: {string: boolean})
  local from = src[key] as {any} -- cast: from any
  if not from or #from == 0 then
    return
  end
  dst[key] = dst[key] or {}
  local into = dst[key] as {any} -- cast: from any
  local have: {string: boolean} = {}
  for _, entry in ipairs(into) do
    local entry_name = (entry as {string: any}).name -- cast: from any
    if entry_name is string then
      have[entry_name] = true
    end
  end
  for _, entry in ipairs(from) do
    local entry_name = (entry as {string: any}).name -- cast: from any
    local named = entry_name is string
    local permitted = not allowed or (named and allowed[entry_name as string]) -- cast: narrowed by named
    if permitted and (not named or not have[entry_name as string]) then -- cast: narrowed by named
      table.insert(into, entry)
    end
  end
end

--- The export list a module states in its top-level typed table
--- literal (`local M: FsModule = { read = fs_file.read, ... }`): the
--- keys. That literal is the convention every module follows (the
--- module's API is its returned interface record), so its keys are the
--- authoritative "what this module exports" — the interface record's
--- own fields would serve too, but the parser does not extract
--- function-typed record fields today. nil when the file builds its
--- module table some other way; callers treat that as "unknown", not
--- "empty".
local function scan_exports(source: string): {string: boolean} | nil
  local names: {string: boolean} = nil
  local in_table = false
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if in_table then
      if line:match("^}") then
        in_table = false
      else
        local key = line:match("^%s*([%w_]+)%s*=")
        if key then
          names = names or {}
          names[key] = true
        end
      end
    elseif line:match("^local%s+[%w_]+%s*:%s*[%w_%.]+%s*=%s*{") then
      local inline = line:match("{(.*)}%s*$")
      local rest = inline or line:match("{(.*)$")
      if rest then
        for key in rest:gmatch("([%w_]+)%s*=") do
          names = names or {}
          names[key] = true
        end
      end
      in_table = inline == nil
    end
  end
  return names
end

--- Fold directory-module shards into the parent users require.
--- `cosmic.fs`'s API is implemented and documented across its shards
--- (`cosmic.fs.ops`, `.file`, `.walk`, `.path`, `.types`), but
--- `require("cosmic.fs")` is the one name a user sees, and the shards
--- are internal by the visibility rule — so with only per-file parsing,
--- `--docs fs` showed a header and `--docs fs.read` found nothing. The
--- shard docs are copied onto the parent's page (parent wins on name
--- collisions); the shard entries stay in the index, addressable by
--- their own names as before. Runs after normalize_init so the parent
--- is already at the name users require.
local function flatten_shards(modules: {string: any})
  local shard_names: {string} = {}
  for name in pairs(modules) do
    shard_names[#shard_names + 1] = name
  end
  -- Deterministic merge order, so regenerating the index is stable.
  table.sort(shard_names)
  for _, name in ipairs(shard_names) do
    local parent_name = name:match("^(.+)%.[%w_]+$")
    if parent_name and modules[parent_name] then
      local parent = modules[parent_name] as {string: any} -- cast: from any
      local shard = modules[name] as {string: any} -- cast: from any
      -- Functions are filtered by the parent's own export list where it
      -- states one, so a shard's private helpers stay off the page;
      -- records and examples merge whole — signatures name the records,
      -- and an example is a demo either way.
      local filter = parent.exports as {string: boolean} -- cast: stored by generate
      merge_entries(parent, shard, "functions", filter)
      merge_entries(parent, shard, "records")
      merge_entries(parent, shard, "examples")
    end
  end
  -- The export lists were carried for this pass only; the index the
  -- binary ships stays exactly what it documents.
  for _, name in ipairs(shard_names) do
    (modules[name] as {string: any}).exports = nil -- cast: from any
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
--- agree; `cosmic/doc/public_test.tl` asserts they do, against
--- `cosmic.doc.visibility` rather than against a second hand-kept list.
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
      if not file_path:match("%.d%.tl$") then
        -- The export list rides along for flatten_shards below, and is
        -- stripped again before the index is encoded.
        (module_doc as {string: any}).exports = scan_exports(source) -- cast: from any
      end
      modules[name] = module_doc
    end
  end

  -- Init shards normalize to the name users require BEFORE examples
  -- merge: a directory module with a sibling example file
  -- (cosmic/flags/init.tl + cosmic/flags_example.tl) otherwise loses
  -- the race — the example doc registers itself as `cosmic.flags`, the
  -- init rename then finds the name taken and skips, and the module's
  -- real doc is stranded under `cosmic.flags.init` while the page
  -- users see is the bare example.
  normalize_init(modules)

  -- Merge examples from _example files into corresponding modules
  for base_name, example_doc in pairs(example_files) do
    -- An example beside an init shard (cosmic/fs/init_example.tl)
    -- documents the DIRECTORY module, whose entry normalize_init just
    -- renamed to the name users require. Without this retarget the
    -- orphan branch below re-registers the stranded `.init` name — and
    -- the example never reaches the module's page.
    local init_parent = base_name:match("^(.+)%.init$")
    if init_parent and not modules[base_name] and modules[init_parent] then
      base_name = init_parent
    end
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

  flatten_shards(modules)
  mark_visibility(modules)

  return codec.encode_lua({modules = modules})
end

local M: DocIndexModule = {
  generate = generate,
}

return M
