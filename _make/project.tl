--- The project model for `cosmic --make`: walk a project root and
--- classify what it finds.
---
--- There is no spec file. A project is a directory tree, and a file's
--- name and position declare what it is — so a directory with sources
--- in it is a package by existing, never by being listed somewhere. A
--- list is a thing that goes stale silently: the gates it feeds keep
--- passing over a directory nobody added to it (`#800`).
---
--- What the walk never sees: dot-prefixed entries (`.git`, `.github`,
--- `.cosmicignore` itself), the build directory `o/` at the root, and
--- anything a `.cosmicignore` pattern matches. What it sees but does
--- not follow: symlinks — only regular files become project files, so
--- a symlinked source is invisible rather than ambiguously staged.

local fs = require("cosmic.fs")
local fstypes = require("cosmic.fs.types")
local imports = require("_make.imports")
local types = require("_make.types")

local type WalkStat = fstypes.WalkStat
local type WalkAction = fs.WalkAction
local type File = types.File
local type Binary = types.Binary
local type Kind = types.Kind
local type Project = types.Project

--- Name of the per-project exclusion file, read from the root only.
local IGNORE_FILE < const > = ".cosmicignore"

--- The build directory. Everything generated lives here, and nothing
--- generated is ever an input, so the walk prunes it at the root.
local BUILD_DIR < const > = "o"

--- The reserved STEM of a unit's PAYLOAD generator: the one `*_gen`
--- that is scoped to a binary rather than to its own subtree, and that
--- runs at the END of a build rather than before it. Both spellings,
--- like every other marker.
--- Named here because the model, the artifact staging, and the
--- validator all have to agree about it.
local PAYLOAD_GEN < const > = "embed_gen"

--- The root unit: the project itself, rather than a `cmd/<name>/`
--- subtree. It is spelled as the empty string because a unit IS a
--- directory relative to the root, and the root's own relative path is
--- empty -- but the empty string is not self-describing at a call site,
--- and every place that read it re-derived the same consequences
--- inline. Named once, with `out_dir` for the derivation that recurred.
local ROOT < const > = ""

--- A unit's output directory, relative to the project root.
--- @param unit string The unit's directory, ROOT for the project itself
--- @return string The output directory, relative to the root
local function out_dir(unit: string): string
  if unit == ROOT then
    return BUILD_DIR
  end
  return BUILD_DIR .. "/" .. unit
end

--- How to name a unit in a message meant for a person.
--- @param unit string The unit's directory, ROOT for the project itself
--- @return string The unit's name, or "the build" for the root
local function unit_label(unit: string): string
  if unit == ROOT then
    return "the build"
  end
  return unit
end

--- The payload directory: its contents map to the artifact root, which
--- is how a project ships a file the one layout rule cannot place.
---
--- It is scoped to a unit, not to the project: `embed/` at the root is
--- every binary's payload the way a root package is every binary's
--- module, and `cmd/<name>/embed/` is that binary's alone. Nothing new
--- enforces that — it is the scope rule the artifact already applies to
--- `cmd/<name>/**`, which is why one binary can carry a toolchain while
--- its sibling stays lean.
local PAYLOAD_DIR < const > = "embed"

--- Is this path inside some unit's payload directory?
--- @param segs {string} The path's segments
--- @return integer|nil How many leading segments the payload root spans
local function payload_depth(segs: {string}): integer | nil
  if segs[1] == PAYLOAD_DIR and #segs > 1 then
    return 1
  end
  if #segs > 3 and segs[1] == "cmd" and segs[3] == PAYLOAD_DIR then
    return 3
  end
  return nil
end

--- Convert a glob (`*` any run, `?` one char) to an anchored Lua
--- pattern. Every other character, including Lua-pattern magic, is
--- literal — a `.cosmicignore` line is a glob, never a Lua pattern.
--- @param glob string The glob to convert
--- @return string An anchored Lua pattern
local function glob_to_pattern(glob: string): string
  local pattern = glob
  :gsub("([%.%^%$%(%)%[%]%+%-%%])", "%%%1")
  :gsub("%*", ".*")
  :gsub("%?", ".")
  return "^" .. pattern .. "$"
end

--- Read `.cosmicignore` from the root, returning one Lua pattern per
--- non-empty, non-comment line. A trailing `/` is accepted and dropped
--- so `build/` and `build` mean the same thing.
--- @param root string Absolute project root
--- @return {string} Anchored Lua patterns, possibly empty
local function read_ignore(root: string): {string}
  local patterns: {string} = {}
  local content = fs.read(fs.join(root, IGNORE_FILE))
  if not content then
    return patterns
  end
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local pat = trimmed:gsub("/+$", "")
      patterns[#patterns + 1] = glob_to_pattern(pat)
    end
  end
  return patterns
end

--- Does an ignore pattern cover this entry? A pattern matches either
--- the whole relative path or a bare name, so `vendor` and
--- `3p/vendor` and `*.log` all behave the way they read.
--- @param patterns {string} Lua patterns from read_ignore
--- @param rel string Path relative to the root
--- @param name string Basename of the entry
--- @return boolean True when the entry is excluded
local function is_ignored(patterns: {string}, rel: string, name: string): boolean
  for _, pat in ipairs(patterns) do
    if rel:match(pat) or name:match(pat) then
      return true
    end
  end
  return false
end

--- Split a relative path into its `/`-separated segments.
--- @param rel string A relative path
--- @return {string} The segments, in order
local function segments(rel: string): {string}
  local out: {string} = {}
  for seg in rel:gmatch("[^/]+") do
    out[#out + 1] = seg
  end
  return out
end

--- Strip the source extension a file's import path is derived from.
--- Returns the stem and true for a source, or the path and false for
--- anything else.
--- @param rel string Path relative to the root
--- @return string, boolean The stem, and whether it was a source
local function stem(rel: string): string, boolean
  if rel:sub(-5) == ".d.tl" then
    return rel:sub(1, -6), true
  elseif rel:sub(-3) == ".tl" then
    return rel:sub(1, -4), true
  elseif rel:sub(-4) == ".lua" then
    return rel:sub(1, -5), true
  end
  return rel, false
end

--- The import path a source is requireable as: path relative to the
--- root, extension dropped, `/` -> `.`, a trailing `init` removed. The
--- project root is the module root, so this is the only rule — inside
--- the artifact too, where the zip root is the module root.
--- @param rel string Path relative to the root
--- @return string|nil The import path, or nil when rel is not a source
local function import_path(rel: string): string | nil
  local base, ok = stem(rel)
  if not ok then
    return nil
  end
  local trimmed = base:gsub("/init$", "")
  if trimmed == "init" then
    return nil
  end
  return (trimmed:gsub("/", "."))
end

--- The marker suffixes apply to `.lua` as well as `.tl`, because
--- `.lua` sources are first-class here. They did not, and the silence
--- was the problem: in a Lua-only project `db_test.lua` classified as
--- a MODULE, so `--make test` reported the project had no tests and
--- `--make build` embedded the test file into the released binary.
--- Neither half announced itself.
---
--- Does this path carry `marker` as its suffix, in either spelling?
---
--- A marker is a NAME, not a name plus an extension. Recognising
--- `_test` in both and `_pin` in only one made the grammar split by
--- extension, and every unrecognised cell was a file that silently
--- classified as a module: a `dep_pin.lua` was never fetched and
--- shipped its url and sha inside the artifact instead. A `.lua`
--- project is a full commitment or it is a trap, and the cell that
--- does not exist -- `.d.lua`, a type declaration in a language with
--- no types -- is refused by the validator rather than left to fall
--- through here.
--- @param rel string Path relative to the root
--- @param marker string The marker, without extension
--- @return boolean Whether the path carries it
local function marked(rel: string, marker: string): boolean
  return rel:sub(-#marker - 3) == marker .. ".tl"
  or rel:sub(-#marker - 4) == marker .. ".lua"
end

--- Classify one file from its relative path. Order matters: payload
--- wins over everything, then testdata, then the suffix markers, then
--- position.
---
--- Payload first because `embed/**` ships VERBATIM — that is the whole
--- contract, and it is what makes `embed/.tl/x.tl` a file to ship
--- rather than a module to compile, `embed/x_gen.tl` a file to ship
--- rather than a generator to run, and `embed/testdata/x` a file to
--- ship rather than a fixture to drop. The two markers cannot fight
--- over a file: `payload_depth` anchors at the root or at
--- `cmd/<name>/`, so a fixture's own `embed/` (`pkg/testdata/app/embed/x`)
--- is not payload and still classifies as testdata.
--- @param rel string Path relative to the root
--- @return Kind The kind this file declares
local function classify(rel: string): Kind
  local segs = segments(rel)
  if payload_depth(segs) then
    return "payload"
  end
  for i = 1, #segs - 1 do
    if segs[i] == "testdata" then
      return "testdata"
    end
  end
  if rel:sub(-5) == ".d.tl" then
    return "types"
  elseif marked(rel, "_pin") then
    return "pin"
  elseif marked(rel, "_gen") then
    -- A unit's PAYLOAD generator is a different kind from a generation
    -- unit, and the difference is not cosmetic: this one is scoped to
    -- the BINARY (root packages plus its own `cmd/<name>/**`), runs
    -- AFTER the graph, and writes `o/<unit>/{embed,base}`, while a
    -- generation unit is scoped to its own subtree and runs BEFORE the
    -- graph, because what it writes is an input to it.
    -- They are separate KINDS so the distinction is not a
    -- basename match inside the generator runner: with one kind,
    -- `cmd/foo/data_gen.tl` is a file neither mechanism runs, and a
    -- generation unit that happens to be named `embed_gen.tl` silently
    -- acquires binary semantics.
    if segs[#segs] == PAYLOAD_GEN .. ".tl"
    or segs[#segs] == PAYLOAD_GEN .. ".lua" then
      return "payload-gen"
    end
    return "gen"
  elseif marked(rel, "_test") then
    return "test"
  elseif marked(rel, "_example") then
    return "example"
  elseif marked(rel, "_benchmark") then
    return "benchmark"
  end
  local _, is_source = stem(rel)
  if not is_source then
    return "asset"
  end
  if #segs == 1 and (rel == "main.tl" or rel == "main.lua") then
    return "entry"
  end
  if #segs == 3 and segs[1] == "cmd" and
  (segs[3] == "main.tl" or segs[3] == "main.lua") then
    return "entry"
  end
  return "module"
end

--- The artifact name an entry builds: the `cmd/` subdirectory's name.
--- A root `main.tl` has no subdirectory to name it, so it falls back to
--- the checkout directory here and is then refused by the validator
--- (`check_binaries`) -- the fallback exists only to name that refusal,
--- never to build under it.
--- @param root string Absolute project root
--- @param rel string Path to the entry, relative to the root
--- @return string The artifact name
local function binary_name(root: string, rel: string): string
  local segs = segments(rel)
  if #segs == 3 then
    return segs[2]
  end
  return fs.basename(root)
end

--- Kinds that carry an import path. Assets and testdata are copied,
--- never required; a pin is data read by `fetch`; a generator is run,
--- not imported.
local importable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
  types = true,
}

--- Walk context.
local record Scan
  root: string
  patterns: {string}
  files: {File}
end

--- Visit one entry: prune what the project never sees, classify the
--- rest.
local function visit(path: string, name: string, st: WalkStat, ctx: Scan): WalkAction
  local rel = path:sub(#ctx.root + 2)
  -- Dotfiles are invisible to the model — except under `embed/`, where
  -- the point is a verbatim mapping and the dot is doing work: a
  -- payload path is dot-prefixed precisely to stay OUT of the module
  -- root (`.tl/`, `.types/`, `.docs/`), so pruning it would prune the
  -- only files that need the directory to exist.
  if name:sub(1, 1) == "." and not payload_depth(segments(rel)) then
    return "skip"
  end
  if is_ignored(ctx.patterns, rel, name) then
    return "skip"
  end
  if st:is_dir() then
    if rel == BUILD_DIR then
      return "skip"
    end
  elseif st:is_file() then
    local kind = classify(rel)
    local f: File = {path = rel, kind = kind}
    if importable[kind] then
      local ip = import_path(rel)
      if ip then
        f.import = ip
      end
    end
    if kind == "entry" then
      f.binary = binary_name(ctx.root, rel)
    end
    ctx.files[#ctx.files + 1] = f
  end
end

--- Scan a project root into a Project.
---
--- The walk is complete or it fails: an unreadable subdirectory is an
--- error, not a quietly smaller project, because every downstream verb
--- treats the file list as the whole truth.
--- @param root string Path to the project root
--- @return Project|nil The scanned project, or nil on failure
--- @return string An error message when the scan failed
local function scan(root: string): Project | nil, string
  local abs = fs.abspath(root)
  if not fs.isdir(abs) then
    return nil, "make: not a directory: " .. root
  end
  -- A scan is the start of a model build, and the import memo's
  -- lifetime is exactly one of those: within a build the tree is a
  -- snapshot, so re-reading a source can only cost time; across builds
  -- it may have changed, so re-reading is the point.
  imports.forget()
  local ctx: Scan = {root = abs, patterns = read_ignore(abs), files = {}}
  local got, err = fs.walk(abs, visit, ctx)
  if not got then
    return nil, "make: cannot scan " .. root .. ": " .. (err or "unknown error")
  end
  if err then
    return nil, "make: incomplete scan of " .. root .. ": " .. err
  end
  table.sort(ctx.files, function(a: File, b: File): boolean
      return a.path < b.path
    end)

  local binaries: {Binary} = {}
  for _, f in ipairs(ctx.files) do
    if f.kind == "entry" then
      binaries[#binaries + 1] = {
        name = f.binary,
        dir = fs.dirname(f.path) == "." and "" or fs.dirname(f.path),
        entry = f.path,
      }
    end
  end
  table.sort(binaries, function(a: Binary, b: Binary): boolean
      return a.name < b.name
    end)

  return {root = abs, files = ctx.files, binaries = binaries}
end

--- Every file of the given kinds, in path order.
--- @param project Project The scanned project
--- @param kinds {Kind} Kinds to keep
--- @return {File} The matching files
local function of_kind(project: Project, kinds: {Kind}): {File}
  local want: {string: boolean} = {}
  for _, k in ipairs(kinds) do
    want[k] = true
  end
  local out: {File} = {}
  for _, f in ipairs(project.files) do
    if want[f.kind] then
      out[#out + 1] = f
    end
  end
  return out
end

local function paths_of(files: {File}): {string}
  local out: {string} = {}
  for _, f in ipairs(files) do
    out[#out + 1] = f.path
  end
  return out
end

local record ProjectModule
  IGNORE_FILE: string
  BUILD_DIR: string
  ROOT: string
  PAYLOAD_DIR: string
  PAYLOAD_GEN: string
  out_dir: function(unit: string): string
  unit_label: function(unit: string): string
  scan: function(root: string): Project | nil, string
  classify: function(rel: string): Kind
  payload_depth: function(segs: {string}): integer | nil
  import_path: function(rel: string): string | nil
  of_kind: function(project: Project, kinds: {Kind}): {File}
  segments: function(rel: string): {string}
  paths_of: function(files: {File}): {string}
end

local M: ProjectModule = {
  IGNORE_FILE = IGNORE_FILE,
  BUILD_DIR = BUILD_DIR,
  ROOT = ROOT,
  PAYLOAD_DIR = PAYLOAD_DIR,
  PAYLOAD_GEN = PAYLOAD_GEN,
  out_dir = out_dir,
  unit_label = unit_label,
  scan = scan,
  classify = classify,
  payload_depth = payload_depth,
  import_path = import_path,
  of_kind = of_kind,
  segments = segments,
  paths_of = paths_of,
}

return M
