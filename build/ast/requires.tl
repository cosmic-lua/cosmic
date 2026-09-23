--- Every module a file `require`s, found structurally rather than by a
--- regex over source text: a `require(...)` inside a string or a
--- comment is never parsed into a call, so it never matches.
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local ast_node = require("build.ast.node")
local type compiler = require("build.compiler")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

--- Any call to `require` with one argument. Compiled on first use and
--- memoized, failure included; it depends only on the pinned grammar,
--- so every caller's capsule shares it.
local PATTERN_SRC = "require($M)"
local pattern_cache: Node = nil
local pattern_err: string = nil
local pattern_compiled = false

local function get_pattern(built: compiler): Node | nil, string
  if not pattern_compiled then
    pattern_cache, pattern_err = ast_match.compile_pattern(built, PATTERN_SRC)
    pattern_compiled = true
  end
  return pattern_cache, pattern_err
end

--- Every module a `require(...)` call names anywhere in `parsed`'s
--- tree, in source order, each at most once. A call whose argument is
--- not a string literal contributes nothing: its target is not known
--- until the program runs.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param parsed Parsed A file's own parse (`build.ast.node.parse`)
--- @return {string} | nil Every required module name, in source order
--- @return string error When the pattern itself failed to compile
local function all_requires(built: compiler, parsed: Parsed): {string} | nil, string
  local pattern, err = get_pattern(built)
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
