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
--- Edges come from the same literal `require("…")` scan the validator
--- uses. A computed require is invisible here, exactly as it is there —
--- a project that computes its module names has left the shape, and the
--- consequence is now a denied read rather than only a missing rule.

local project = require("cosmic.make.project")
local validate = require("cosmic.make.validate")
local types = require("cosmic.make.types")

local type File = types.File
local type Project = types.Project

--- Kinds that carry code a require can resolve to.
local resolvable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
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
--- @param proj Project The scanned project
--- @return {string: File} Import path to the file defining it
local function index(proj: Project): {string: File}
  local by_import: {string: File} = {}
  for _, f in ipairs(proj.files) do
    if resolvable[f.kind] and f.import then
      by_import[f.import] = f
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
local function direct(root: string, file: File, by_import: {string: File}): {File}
  local out: {File} = {}
  local seen: {string: boolean} = {}
  local path = root ~= "" and (root .. "/" .. file.path) or file.path
  for _, name in ipairs(validate.imports_of(path)) do
    local dep = by_import[name]
    if dep and dep.path ~= file.path and not seen[dep.path] then
      seen[dep.path] = true
      out[#out + 1] = dep
    end
  end
  return out
end

--- Every file `file` transitively imports, as BUILT paths, sorted.
---
--- The file itself is excluded: a rule already names its own compiled
--- output, and repeating it would only make the recipe line longer.
--- Cycles terminate — the walk is over a visited set, and a cyclic
--- import is the project's problem rather than this function's.
--- @param proj Project The scanned project
--- @param file File The file whose closure is wanted
--- @param by_import {string: File} Index from index()
--- @return {string} Built paths, sorted
local function closure(proj: Project, file: File, by_import: {string: File}): {string}
  local seen: {string: boolean} = {[file.path] = true}
  local queue: {File} = {file}
  local out: {string} = {}
  while #queue > 0 do
    local cur = table.remove(queue)
    for _, dep in ipairs(direct(proj.root, cur, by_import)) do
      if not seen[dep.path] then
        seen[dep.path] = true
        queue[#queue + 1] = dep
        out[#out + 1] = built_path(dep.path, project.BUILD_DIR)
      end
    end
  end
  table.sort(out)
  return out
end

local record DepsModule
  built_path: function(rel: string, build_dir: string): string
  index: function(proj: Project): {string: File}
  direct: function(root: string, file: File, by_import: {string: File}): {File}
  closure: function(proj: Project, file: File, by_import: {string: File}): {string}
end

local M: DepsModule = {
  built_path = built_path,
  index = index,
  direct = direct,
  closure = closure,
}

return M
