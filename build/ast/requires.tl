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
local ast_walk = require("build.ast.walk")
local type compiler = require("build.compiler")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

--- The pattern [`all_requires`] is built on: a call to `require` with
--- exactly one argument, captured whole whatever it is (a string
--- literal, a variable, a concatenation). Compiled on first use and
--- memoized in `all_pattern`.
local ALL_PATTERN_SRC = "require($M)"

local record PatternMemo
  mut compiled: boolean
  mut pattern: Node?
  mut err: string?
end

local all_pattern: PatternMemo = { compiled = false }

--- Compile `ALL_PATTERN_SRC` on first use and memoize the result,
--- success or failure.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @return Node | nil, string
local function get_all_pattern(built: compiler): Node?, string
  if not all_pattern.compiled then
    all_pattern.pattern, all_pattern.err = ast_match.compile_pattern(built, ALL_PATTERN_SRC)
    all_pattern.compiled = true
  end
  local pattern = all_pattern.pattern
  if pattern == nil then return nil, all_pattern.err end
  return pattern, ""
end

--- A `require` of a module: the module it names, and where the name is
--- in the source.
local record Site
  name: string
  y: integer
  x: integer
end

--- Every module a `require(...)` call names anywhere in `parsed`'s
--- tree, in source order, each name once, at its first call. A call
--- whose argument is not a string literal (`require(name)`) contributes
--- nothing, since its target is unknown until the program runs.
---
--- Fails only if `ALL_PATTERN_SRC` does not compile.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param parsed Parsed A file's own parse ([`build.ast.node.parse`])
--- @return {Site} | nil Every required module, in source order
--- @return string error When the module's own pattern failed to compile
local function require_sites(built: compiler, parsed: Parsed): {Site}?, string
  local pattern, err = get_all_pattern(built)
  if pattern == nil then
    return nil, err
  end
  -- Only a node of the pattern's own kind can match it: the rest are
  -- passed over without the generic match, most of a walk's cost.
  local hits: mut {Node} = {}
  local caps_of: {Node: {string: Node}} = {}
  ast_walk.walk(parsed.node, function(n: Node)
    if n.kind == pattern.kind then
      local caps = ast_match.match(pattern, n)
      if caps then
        hits[#hits + 1] = n
        caps_of[n] = caps
      end
    end
  end)
  local memo: {Node: {integer}} = {}
  table.sort(hits, function(p: Node, q: Node): boolean
    local ps, qs = ast_walk.span_start(p, memo), ast_walk.span_start(q, memo)
    return ps.y < qs.y or (ps.y == qs.y and ps.x < qs.x)
  end)
  local seen: mut {string: boolean} = {}
  local out: mut {Site} = {}
  for _, hit in ipairs(hits) do
    local mod_node = assert(caps_of[hit])["_M"]
    if mod_node ~= nil then
      local mod_name = mod_node.conststr
      if mod_name ~= nil and seen[mod_name] == nil then
        seen[mod_name] = true
        out[#out + 1] = { name = mod_name, y = mod_node.y, x = mod_node.x }
      end
    end
  end
  return out, ""
end

--- Every module a `require(...)` call names anywhere in `parsed`'s
--- tree, in source order, each name once ([`require_sites`]).
---
--- [`build.importer`] builds its dependency graph (import order, the
--- recompilation key) from this.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param parsed Parsed A file's own parse ([`build.ast.node.parse`])
--- @return {string} | nil Every required module name, in source order
--- @return string error When the module's own pattern failed to compile
local function all_requires(built: compiler, parsed: Parsed): {string}?, string
  local sites, err = require_sites(built, parsed)
  if sites == nil then
    return nil, err
  end
  local out: mut {string} = {}
  for _, site in ipairs(sites) do out[#out + 1] = site.name end
  return out
end

local record RequiresModule
  type Site = Site
  require_sites: function(built: compiler, parsed: Parsed): {Site}?, string
  all_requires: function(built: compiler, parsed: Parsed): {string}?, string
end

local M: RequiresModule = {
  require_sites = require_sites,
  all_requires = all_requires,
}

return M
