--- Generate a serialized documentation index from source files.
--- Run directly as a script with source files as arguments.

local doc = require("_tool.doc")
local doc_exports = require("_tool.doc.exports")
local doc_types = require("cosmic.doc")
local type ModuleDoc = doc_types.ModuleDoc
local type FunctionDoc = doc_types.FunctionDoc
local type RecordDoc = doc_types.RecordDoc
local type ExampleDoc = doc_types.ExampleDoc
-- This script is compiled and run by the pinned BOOTSTRAP cosmic, whose
-- embedded types predate the current tree; use the signature-stable
-- cosmo.Slurp instead of cosmic.fs.read so it works under both, and
-- cosmo.EncodeLua directly so the index bytes stay identical across
-- generations.
local cosmo = require("cosmo")

local record DocIndexModule
  generate: function(files: {string}, names?: {string: string}): string | nil, string
end

--- Normalize directory-module init shards to the module name users
--- require: cosmic.fs.init -> cosmic.fs, cosmic.init -> cosmic.
--- `exports_by_name` is renamed in lockstep: a directory module's export
--- list is recorded (in `generate`) under its pre-rename name, and
--- `flatten_shards` below looks it up under the name shards merge into
--- — so the rename has to move both, or a directory module's own
--- export list would go missing as its filter.
local function normalize_init(modules: {string: ModuleDoc},
    exports_by_name: {string: {string: boolean}})
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
    exports_by_name[to] = exports_by_name[from]
    exports_by_name[from] = nil
  end
end

--- Append `from`'s entries onto `into`, skipping names `into` already
--- carries — the parent's own doc wins over a shard's on a collision.
--- `allowed`, when given, restricts the merge to entries whose name it
--- contains. Generic over the element type because functions, records
--- and examples are three different element types that a record cannot
--- share a single field-name-indexed helper over.
local function merge_list<T>(into: {T}, from: {T},
    name_of: function(T): (string), allowed?: {string: boolean})
  if not from or #from == 0 then
    return
  end
  local have: {string: boolean} = {}
  for _, entry in ipairs(into) do
    have[name_of(entry)] = true
  end
  for _, entry in ipairs(from) do
    local entry_name = name_of(entry)
    if (not allowed or allowed[entry_name]) and not have[entry_name] then
      table.insert(into, entry)
    end
  end
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
--- @param modules The index being built, keyed by module name
--- @param exports_by_name Each module's own export list, by name — the
---        parent's list filters which of a shard's functions merge
---        onto its page; never part of the shipped index itself.
local function flatten_shards(modules: {string: ModuleDoc},
    exports_by_name: {string: {string: boolean}})
  local shard_names: {string} = {}
  for name in pairs(modules) do
    shard_names[#shard_names + 1] = name
  end
  -- Deterministic merge order, so regenerating the index is stable.
  table.sort(shard_names)
  for _, name in ipairs(shard_names) do
    local parent_name = name:match("^(.+)%.[%w_]+$")
    if parent_name and modules[parent_name] then
      local parent = modules[parent_name]
      local shard = modules[name]
      -- Functions are filtered by the parent's own export list where it
      -- states one, so a shard's private helpers stay off the page;
      -- records and examples merge whole — signatures name the records,
      -- and an example is a demo either way.
      local filter = exports_by_name[parent_name]
      parent.functions = parent.functions or {}
      merge_list(parent.functions, shard.functions,
        function(f: FunctionDoc): (string) return f.name end, filter)
      parent.records = parent.records or {}
      merge_list(parent.records, shard.records,
        function(r: RecordDoc): (string) return r.name end)
      parent.examples = parent.examples or {}
      merge_list(parent.examples, shard.examples,
        function(e: ExampleDoc): (string) return e.name end)
    end
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
local function mark_visibility(modules: {string: ModuleDoc})
  for name, module_doc in pairs(modules) do
    local is_cosmo = name == "cosmo" or name:match("^cosmo%.") ~= nil
    local leaf = name:match("^cosmic%.([%w_]+)$")
    local public = leaf ~= nil and leaf:sub(1, 1) ~= "_"
    if not is_cosmo and not public then
      module_doc.internal = true
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
  local modules: {string: ModuleDoc} = {}
  local example_files: {string: ModuleDoc} = {} -- Store example docs separately
  -- Each module's own export list, by name — a scratch map, never part
  -- of the shipped index (see flatten_shards). Keyed by the name a
  -- module is FIRST registered under below, before normalize_init may
  -- rename it.
  local exports_by_name: {string: {string: boolean}} = {}

  for i = 1, #files do
    local file_path = files[i]

    local source, slurp_err = cosmo.Slurp(file_path)
    if not source then
      return nil, file_path .. ": " .. (slurp_err or "cannot read")
    end

    -- Parse based on file type
    local module_doc: ModuleDoc
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
        -- The export list rides in exports_by_name for flatten_shards
        -- below, keyed by this module's name — never stored on the
        -- ModuleDoc itself, so there is nothing to strip before the
        -- index is encoded.
        -- The same publishable view the markdown page is rendered
        -- from, so a page and a symbol lookup answer alike. The surface
        -- rides along for flatten_shards below, which filters a SHARD's
        -- exports against the parent that re-exports them — a different
        -- question from what one module publishes.
        local records = module_doc.records
        doc.publishable(module_doc, source)
        exports_by_name[name] = doc_exports.export_surface(source, records)
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
  normalize_init(modules, exports_by_name)

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
      mod.examples = mod.examples or {}
      for _, ex in ipairs(example_doc.examples) do
        table.insert(mod.examples, ex)
      end
    else
      -- No source module with this name (e.g. deploy_example.tl):
      -- register the example doc itself under the base name so its
      -- examples stay addressable instead of being silently dropped.
      modules[base_name] = example_doc
    end
  end

  flatten_shards(modules, exports_by_name)
  mark_visibility(modules)

  return cosmo.EncodeLua({modules = modules})
end

local M: DocIndexModule = {
  generate = generate,
}

return M
