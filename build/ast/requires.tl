--- The modules a file `require`s, matched structurally rather than with
--- a regex over source text.
---
--- [`all_requires`] is the view a build's dependency graph needs: every
--- module named by a `require(...)` call anywhere in a file's tree, of
--- any prefix, whether or not the call feeds a top-level local. Two
--- shapes in this tree are not top-level locals:
--- - `local type compiler = require("build.compiler")`, a type-only
---   import (a "local_type" node) that is erased from the compiled
---   output but still a dependency for import order and the
---   recompilation key;
--- - `store = require("cosmic.internal.store")` in [`cosmic/store.tl`]
---   and [`cosmic/sqlite.tl`], a plain assignment inside an `if`/`else`.
---
--- Matching `require(...)` structurally covers both, and skips text in
--- a string literal or comment, which never parses into a call node.
local ast_node = require("build.ast.node")
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local type compiler = require("build.compiler")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

--- The pattern [`all_requires`] is built on: a call to `require` with
--- exactly one argument, captured whole whatever it is (a string
--- literal, a variable, a concatenation). Compiled on first use and
--- memoized in `all_pattern`.
local ALL_PATTERN_SRC = "require($M)"

local record PatternMemo
  compiled: boolean
  pattern: Node | nil
  err: string | nil
end

local all_pattern: PatternMemo = { compiled = false }

--- Compile `ALL_PATTERN_SRC` on first use and memoize the result,
--- success or failure.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @return Node | nil, string
local function get_all_pattern(built: compiler): Node | nil, string
  if not all_pattern.compiled then
    all_pattern.pattern, all_pattern.err = ast_match.compile_pattern(built, ALL_PATTERN_SRC)
    all_pattern.compiled = true
  end
  local pattern = all_pattern.pattern
  if pattern == nil then return nil, all_pattern.err end
  return pattern, ""
end

--- Every module a `require(...)` call names anywhere in `parsed`'s
--- tree, in source order, each name once. A call whose argument is not
--- a string literal (`require(name)`) contributes nothing, since its
--- target is unknown until the program runs.
---
--- [`build.importer`] builds its dependency graph (import order, the
--- recompilation key) from this.
---
--- Fails only if `ALL_PATTERN_SRC` does not compile.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param parsed Parsed A file's own parse ([`build.ast.node.parse`])
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
