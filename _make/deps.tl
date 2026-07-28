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
---
--- A ratchet's subject is not an import, so `_make.reads` supplies the
--- second edge: `@reads <glob>` says "this file is an input of mine"
--- for the files a source opens rather than requires. It travels the
--- same closure and lands in the same facts file, one variable over.

local imports = require("_make.imports")
local project = require("_make.project")
local reads = require("_make.reads")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- One dependency variable for the facts file: `<name> := <values>`.
--- Rendered by `_make.graph`, which owns the file's shape; computed
--- here, because following an import edge is what this module is.
local record Assignment
  name: string
  values: {string}
end

--- Kinds a require can resolve to.
---
--- `types` is here because the type checker resolves `require("ffi")`
--- to `ffi.d.tl` when one exists -- the sanctioned `.d.tl`-beside-`.lua`
--- pattern the validator protects. Leaving it out lets a declaration's
--- contract change with no listed prerequisite's mtime moving, so
--- importers are never re-checked: incremental build PASS, clean build
--- FAIL, on the same tree.
---
--- A `.d.tl` is a SOURCE dependency only. It compiles to nothing, so
--- `built_paths` skips it -- listing `o/ffi.lua` for a declaration that
--- has no implementation would name a target nothing builds.
local resolvable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
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
  data_paths: function(proj: Project, file: File,
  by_import: {string: {File}}): {string}
  assignments: function(proj: Project): {Assignment}
end

--- The DATA a file reads, as paths — the second channel, unioned over
--- the same closure as the imports.
---
--- Transitive for the same reason the imports are: `_build/
--- docs_test.tl` reads no record itself, it requires `_docs/derive.tl`,
--- which does. Declaring at the READ and inheriting through the import
--- edge is what keeps the declaration next to the `fs.read` it is
--- about; the cost is the usual over-approximation, where a test that
--- imports a reader but never calls it re-runs anyway.
--- @param proj Project The scanned project
--- @param file File The file whose data dependencies are wanted
--- @param by_import {string: File} Index from index()
--- @return {string} Paths relative to the root, sorted
local function data_paths(proj: Project, file: File,
    by_import: {string: {File}}): {string}
  local sources: {File} = {file}
  for _, dep in ipairs(closure(proj, file, by_import)) do
    sources[#sources + 1] = dep
  end
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for _, f in ipairs(sources) do
    local path = proj.root ~= "" and (proj.root .. "/" .. f.path) or f.path
    for _, pattern in ipairs(reads.of_file(path)) do
      for _, rel in ipairs(reads.expand(proj.root, pattern)) do
        if not seen[rel] then
          seen[rel] = true
          out[#out + 1] = rel
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- Every dependency variable the facts file carries, in one pass.
---
--- Three flavours, and the distinctions are not cosmetic. A COMPILE
--- needs SOURCE paths, because a strict compile type-checks against
--- the modules it imports and the checker resolves those to `.tl`
--- through the include path: without them, changing a module's
--- contract left its importers un-recompiled and the incremental build
--- shipped code a clean build rejects. A TEST needs BUILT paths,
--- because it runs against compiled Lua. And whatever RUNS also needs
--- the data it declared, or a ratchet over a committed file re-runs
--- only in a fresh tree.
---
--- The make-variable stem is the path with its EXTENSION removed,
--- because that is the stem the pattern rules produce: a target
--- `o/x_test.lua.test.got` matching `$(O)/%.lua.test.got` has stem
--- `x_test`. Stripping only `.tl` named the `.lua` twin's variable
--- `deps_x_test.lua`, which no rule ever expands -- so a `.lua` test
--- got an EMPTY closure: never rebuilt when an import changed, and
--- fenced away from the modules it requires.
--- @param proj Project The scanned project
--- @return {Assignment} One entry per variable, in no particular order
local function assignments(proj: Project): {Assignment}
  local out: {Assignment} = {}
  local by_import = index(proj)
  for _, f in ipairs(proj.files) do
    local stem = (f.path:gsub("%.tl$", ""):gsub("%.lua$", ""))
    if types.compiled_kinds[f.kind] and f.path:sub(-3) == ".tl" then
      out[#out + 1] = {name = "srcdeps_" .. stem,
        values = source_paths(closure(proj, f, by_import))}
    end
    -- Examples and benchmarks get the same closure as tests, and for
    -- the same reason: each RUNS against the compiled tree, so what it
    -- imports must be built before it and is exactly what its fence may
    -- read. The model already says so — a rule cannot ask for a closure
    -- nobody emitted, and `cosmic.mk` asks for all three.
    if types.runs_against_the_stage[f.kind] then
      out[#out + 1] = {name = "deps_" .. stem,
        values = built_paths(closure(proj, f, by_import))}
      -- Only when there is one: a declaration is rare, and a line per
      -- test saying nothing would bury the ones that say something.
      -- An undefined make variable expands to empty, so the rule that
      -- names it needs no answer here.
      local data = data_paths(proj, f, by_import)
      if #data > 0 then
        out[#out + 1] = {name = "datadeps_" .. stem, values = data}
      end
    end
  end
  return out
end

local M: DepsModule = {
  built_path = built_path,
  index = index,
  direct = direct,
  closure = closure,
  built_paths = built_paths,
  source_paths = source_paths,
  data_paths = data_paths,
  assignments = assignments,
}

return M
