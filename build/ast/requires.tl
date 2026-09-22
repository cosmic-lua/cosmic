--- The modules a file `require`s, matched structurally rather than with
--- a regex over source text.
---
--- `all_requires` is the view a build's own dependency graph
--- needs: every module named by a `require(...)` call ANYWHERE in a
--- file's tree, of any prefix, regardless of whether it is bound to a
--- top-level local at all. This project's own source includes
--- `local type compiler =
--- require("build.compiler")` is a type-only import (a "local_type"
--- node, not "local_declaration" -- erased from the compiled output,
--- but still a real dependency for import order and the
--- recompilation-key hash) that appears throughout `build/*.tl`, and
--- `cosmic/store.tl` / `cosmic/sqlite.tl` each require their own raw
--- module through a plain re-assignment inside an `if`/`else`
--- (`store = require("cosmic.internal.store")`), never a `local` at
--- all. `all_requires` matches `require(...)` structurally wherever it
--- sits, which handles both without special-casing either -- the same
--- structural approach also naturally excludes a `require(...)` that is
--- only text inside a string literal or a comment, since neither is
--- ever parsed into a call node for it to match against.
---
local ast_node = require("build.ast.node")
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local type compiler = require("build.compiler")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

--- The one pattern `all_requires` is built on: any call to `require`
--- with exactly one argument, captured whole regardless of what that
--- argument is -- a string literal, a variable, a concatenation.
--- Compiled lazily and memoized in module-scope locals.
local ALL_PATTERN_SRC = "require($M)"
local all_pattern_cache: Node = nil
local all_pattern_err: string = nil
local all_pattern_compiled = false

--- Compile `ALL_PATTERN_SRC` on first use and memoize the result
--- (success or failure) for every call after.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @return Node | nil, string
local function get_all_pattern(built: compiler): Node | nil, string
  if not all_pattern_compiled then
    all_pattern_cache, all_pattern_err = ast_match.compile_pattern(built, ALL_PATTERN_SRC)
    all_pattern_compiled = true
  end
  return all_pattern_cache, all_pattern_err
end

--- Every module a `require(...)` call names anywhere in `parsed`'s
--- tree, in source order, each name at most once -- no prefix
--- restriction, no top-level-only restriction, no requirement that the
--- call feed a `local`. A call whose argument is not a string literal
--- (`require(name)`, computed at runtime) contributes nothing, exactly
--- as no earlier text-based or structural approach here could resolve
--- one either: its target is not known until the program runs.
---
--- This is what `build.importer` needs for its own dependency graph
--- (import order, the recompilation-key hash): every real `require` a
--- module's compiled or type-checked form depends on.
---
--- Fails only if `ALL_PATTERN_SRC` itself has stopped compiling.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param parsed Parsed A file's own parse (`build.ast.node.parse`)
--- @return {string} | nil Every required module name, in source order
--- @return string error When the module's own pattern failed to compile
local function all_requires(built: compiler, parsed: Parsed): {string} | nil, string
  local pattern, err = get_all_pattern(built)
  if pattern == nil then
    return nil, err
  end
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for _, hit in ipairs(ast_rewrite.find_all(parsed.node, pattern)) do
    local mod_node = hit.caps["_M"]
    local mod_name = mod_node and mod_node.conststr
    if mod_name and not seen[mod_name] then
      seen[mod_name] = true
      out[#out + 1] = mod_name
    end
  end
  return out
end

local record RequiresModule
  all_requires: function(built: compiler, parsed: Parsed): {string} | nil, string
end

local M: RequiresModule = {
  all_requires = all_requires,
}

return M
