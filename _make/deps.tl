--- The import graph: what each file transitively needs from the
--- project.
---
--- Two things want this answer and it is the same answer, which is why
--- it is one function. The GRAPH wants it so a test re-runs when
--- something it imports changes and not when anything else does; the
--- FENCE wants it so a test may read what it imports and nothing else.
--- Computing it once and putting it in the recipe line serves both:
--- the argument positions are the declaration.
---
--- Edges come from `_make.imports`, the one scanner the validator, the
--- facts writer and the fence also use — so what refuses a project and
--- what schedules it can never disagree. A computed require is
--- invisible there, and the consequence is a denied read rather than
--- only a missing rule.

local imports = require("_make.imports")
local project = require("_make.project")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- Kinds a require can resolve to.
---
--- `types` is here because the type checker resolves `require("ffi")`
--- to `ffi.d.tl` when one exists -- the sanctioned `.d.tl`-beside-`.lua`
--- pattern the validator protects. Leaving it out meant a declaration's
--- contract could change with no listed prerequisite's mtime moving, so
--- importers were never re-checked: incremental build PASS, clean build
--- FAIL, on the same tree. Reproduced before the fix.
---
--- A `.d.tl` is a SOURCE dependency only. It compiles to nothing, so
--- `built_paths` skips it -- listing `o/ffi.lua` for a declaration that
--- has no implementation would name a target nothing builds.
local resolvable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  types = true,
}

--- Where a source lands once built: `.tl` compiles to `.lua` under the
--- build directory, `.lua` is copied there unchanged.
--- @param rel string Source path, relative to the root
--- @param build_dir string The build directory
--- @return string The built path, relative to the root
local function built_path(rel: string, build_dir: string): string
  if rel:sub(-3) == ".tl" then
    return build_dir .. "/" .. rel:sub(1, -4) .. ".lua"
  end
  return build_dir .. "/" .. rel
end

--- Index the project by import path, so an edge can be resolved.
---
--- A LIST per name, not one file: `ffi.lua` and `ffi.d.tl` both claim
--- `ffi`, and both are inputs -- the implementation is what runs, the
--- declaration is what the checker reads. Keeping one would drop
--- whichever the walk happened to see last.
--- @param proj Project The scanned project
--- @return {string: {File}} Import path to the files defining it
local function index(proj: Project): {string: {File}}
  local by_import: {string: {File}} = {}
  for _, f in ipairs(proj.files) do
    if resolvable[f.kind] and f.import then
      local at = by_import[f.import]
      if not at then
        at = {}
        by_import[f.import] = at
      end
      at[#at + 1] = f
    end
  end
  return by_import
end

--- The files `file` imports directly, resolved within the project.
--- Imports that leave the project — the standard library, anything not
--- defined here — are not edges: they are not inputs the graph can
--- schedule on or the fence can grant.
--- @param root string Absolute project root
--- @param file File The importer
--- @param by_import {string: File} Index from index()
--- @return {File} Direct project dependencies
local function direct(root: string, file: File,
    by_import: {string: {File}}): {File}
  local out: {File} = {}
  local seen: {string: boolean} = {}
  local path = root ~= "" and (root .. "/" .. file.path) or file.path
  for _, name in ipairs(imports.of_file(path)) do
    for _, dep in ipairs(by_import[name] or {}) do
      if dep.path ~= file.path and not seen[dep.path] then
        seen[dep.path] = true
        out[#out + 1] = dep
      end
    end
  end
  return out
end

--- Every file `file` transitively imports.
---
--- The file itself is excluded: a rule already names its own source and
--- its own output, and repeating them would only make the recipe line
--- longer. Cycles terminate — the walk is over a visited set, and a
--- cyclic import is the project's problem rather than this function's.
--- @param proj Project The scanned project
--- @param file File The file whose closure is wanted
--- @param by_import {string: File} Index from index()
--- @return {File} Dependencies, transitively
local function closure(proj: Project, file: File,
    by_import: {string: {File}}): {File}
  local seen: {string: boolean} = {[file.path] = true}
  local queue: {File} = {file}
  local out: {File} = {}
  while #queue > 0 do
    local cur = table.remove(queue)
    for _, dep in ipairs(direct(proj.root, cur, by_import)) do
      if not seen[dep.path] then
        seen[dep.path] = true
        queue[#queue + 1] = dep
        out[#out + 1] = dep
      end
    end
  end
  return out
end

--- A closure as BUILT paths — what a test needs, because a test runs
--- against compiled Lua.
--- @param files {File} A closure
--- @return {string} Built paths, sorted
local function built_paths(files: {File}): {string}
  local out: {string} = {}
  for _, f in ipairs(files) do
    -- A `.d.tl` builds to nothing: it is on the include path, never
    -- compiled. It stays in the SOURCE closure, where it belongs.
    if f.kind ~= "types" then
      out[#out + 1] = built_path(f.path, project.BUILD_DIR)
    end
  end
  table.sort(out)
  return out
end

--- A closure as SOURCE paths — what a compile needs, because the type
--- checker resolves `require("util")` to `util.tl` through the include
--- path, not to its compiled output. Getting this backwards is the
--- difference between an incremental build that catches a broken
--- contract and one that ships past it.
--- @param files {File} A closure
--- @return {string} Source paths, sorted
local function source_paths(files: {File}): {string}
  local out: {string} = {}
  for _, f in ipairs(files) do
    out[#out + 1] = f.path
  end
  table.sort(out)
  return out
end

local record DepsModule
  built_path: function(rel: string, build_dir: string): string
  index: function(proj: Project): {string: {File}}
  direct: function(root: string, file: File,
  by_import: {string: {File}}): {File}
closure: function(proj: Project, file: File,
by_import: {string: {File}}): {File}
built_paths: function(files: {File}): {string}
source_paths: function(files: {File}): {string}
end

local M: DepsModule = {
  built_path = built_path,
  index = index,
  direct = direct,
  closure = closure,
  built_paths = built_paths,
  source_paths = source_paths,
}

return M
