--- Two views of what a file `require`s, both structural rather than a
--- regex over source text.
---
--- `requires` is top-level require-ALIAS resolution: which local names
--- a file binds to `require("cosmic.<module>")` at its own top level.
--- Deliberately narrow, not general scope-aware resolution: only a
--- `local <alias> = require("cosmic.<m>")` statement sitting directly
--- among a file's own top-level statements counts. No shadowing, no
--- re-assignment tracking, no loop-bound aliases, and no resolution
--- through an intermediate local (`local h = hash; h.digest(...)` is
--- not resolved) -- a from-scratch scope-aware walk tracking every
--- kind of binding and block boundary is real work this narrow slice
--- does not need.
---
--- `all_requires` is the broader view a build's own dependency graph
--- needs: every module named by a `require(...)` call ANYWHERE in a
--- file's tree, of any prefix, regardless of whether it is bound to a
--- top-level local at all. `requires`'s narrow shape does not cover
--- this project's own source: `local type compiler =
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
--- Adapted from cosmic's own `cosmic.ast.requires`: `get_pattern`
--- compiles the one fixed pattern `requires` is built on, which now
--- needs the loaded compiler capsule to do so, so it -- and `requires`
--- itself -- take one as their own first argument. `all_requires` and
--- its own pattern are new here, v2's own answer to a caller
--- (`build.importer`) whose real requires do not fit `requires`'s
--- narrow shape.
local ast_node = require("build.ast.node")
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local type compiler = require("build.compiler")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

--- The one pattern this whole module is built on. `PATTERN_SRC` is a
--- fixed literal, so compiling it can only ever fail if the literal
--- itself stops parsing -- not a condition any caller's input can
--- trigger -- but that is still a real fallibility this module's own
--- contract must carry rather than assert past: compiled lazily, on
--- `requires`'s first call, and memoized in these two module-scope
--- locals so every later call reuses the same compiled `Node` (or the
--- same failure) instead of recompiling. The compiled pattern depends
--- only on the pinned grammar, not on which `built` capsule compiled
--- it, so the memo is shared across every caller's own `built`.
local PATTERN_SRC = "local $ALIAS = require($M)"
local pattern_cache: Node = nil
local pattern_err: string = nil
local pattern_compiled = false

--- Compile `PATTERN_SRC` on first use and memoize the result (success
--- or failure) for every call after. Isolated in its own function so
--- `requires` can propagate a real failure through its own `T | nil,
--- string` return instead of throwing one past its caller.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @return Node | nil, string
local function get_pattern(built: compiler): Node | nil, string
  if not pattern_compiled then
    pattern_cache, pattern_err = ast_match.compile_pattern(built, PATTERN_SRC)
    if pattern_cache then
      -- A `local_declaration`'s own `decltuple` (its optional `: T, T`
      -- type annotation) is present even on a plain, untyped `local` --
      -- tl's parser stamps a fresh, per-parse-unique `typeid` onto its
      -- implicit "tuple" type node every time it parses one, so the SAME
      -- source text parsed twice (once for this pattern, once for any
      -- real file) never carries equal `typeid`s. `build.ast.match`'s
      -- generic field comparison has no special case for a type node the
      -- way `build.ast.match_cast` compares a cast's own type by
      -- rendered text instead -- left in place, this pattern would never
      -- match a single real local declaration. Cleared here, once, on
      -- the compiled pattern's own node: `decltuple` carries no
      -- information this pattern needs to match on.
      -- cast: tl-parser field this Node kind doesn't name
      (pattern_cache as {any: any})["decltuple"] = nil
    end
    pattern_compiled = true
  end
  return pattern_cache, pattern_err
end

--- Every top-level `local <alias> = require("cosmic.<module>")` binding
--- in `parsed`, alias name -> the module it is bound to.
---
--- Matched with the compiled `PATTERN_SRC` via `build.ast.rewrite`'s
--- `find_all`, then narrowed to hits that are themselves direct
--- elements of the file's own top-level `statements` array --
--- `find_all`'s walk reaches every node in the whole tree, and a
--- `local` inside a nested block (a function body, an if-branch) binds
--- a local variable, not a module alias, so it is excluded here rather
--- than resolved.
---
--- A re-assigned alias (`local hash = require("cosmic.hash"); hash =
--- other_thing`) is still returned bound to `"cosmic.hash"` -- tracking
--- reassignment is out of this module's stated scope, not a bug.
---
--- Fails only if `PATTERN_SRC` itself has stopped compiling -- not a
--- condition any caller's `parsed` input can cause, but still surfaced
--- through the ordinary `T | nil, string` contract rather than thrown.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param parsed Parsed A file's own parse (`build.ast.node.parse`)
--- @return {string: string} | nil Alias name -> the `cosmic.*` module it is bound to
--- @return string error When the module's own pattern failed to compile
local function requires(built: compiler, parsed: Parsed): {string: string} | nil, string
  local pattern, err = get_pattern(built)
  if pattern == nil then
    return nil, err
  end
  local out: {string: string} = {}
  local top_level: {Node: boolean} = {}
  for _, stmt in ipairs(parsed.node) do
    top_level[stmt] = true
  end
  for _, hit in ipairs(ast_rewrite.find_all(parsed.node, pattern)) do
    if top_level[hit.node] then
      local alias_node = hit.caps["_ALIAS"]
      local mod_node = hit.caps["_M"]
      local alias_name = alias_node and alias_node.tk
      local mod_name = mod_node and mod_node.conststr
      if alias_name and mod_name then
        if mod_name:match("^cosmic%.") then
          out[alias_name] = mod_name
        end
      end
    end
  end
  return out
end

--- The one pattern `all_requires` is built on: any call to `require`
--- with exactly one argument, captured whole regardless of what that
--- argument is -- a string literal, a variable, a concatenation.
--- Compiled and memoized the same way `PATTERN_SRC` above is, in its
--- own pair of module-scope locals, since it is a different pattern
--- source and must not share `pattern_cache`'s memo.
local ALL_PATTERN_SRC = "require($M)"
local all_pattern_cache: Node = nil
local all_pattern_err: string = nil
local all_pattern_compiled = false

--- Compile `ALL_PATTERN_SRC` on first use and memoize the result
--- (success or failure) for every call after, mirroring `get_pattern`.
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
--- module's compiled or type-checked form depends on, not just the
--- narrow subset `requires` above resolves aliases for.
---
--- Fails only if `ALL_PATTERN_SRC` itself has stopped compiling -- see
--- `requires`'s own note on the same fallibility.
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
  requires: function(built: compiler, parsed: Parsed): {string: string} | nil, string
  all_requires: function(built: compiler, parsed: Parsed): {string} | nil, string
end

local M: RequiresModule = {
  requires = requires,
  all_requires = all_requires,
}

return M
