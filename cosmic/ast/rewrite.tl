--- Structural rewrite over `cosmic.ast.match` patterns: find every match
--- in a whole tree, splice a replacement template over the ORIGINAL
--- source bytes, and reformat the result through `cosmic.format`.
---
--- Ported from the `spike/teal-search-replace` branch's
--- `docs/design/ast-rewrite/tlgrep.tl`, minus that spike's CLI/file
--- driver (a later item's job) and its own match/span logic, now
--- `cosmic.ast.match` and `cosmic.ast.walk` respectively.
---
--- Single-pass, single-file: no fixpoint (a rewrite creating a new
--- match of itself or another rule), no project-wide loop. A rewrite
--- that would silently delete a comment is refused instead of applied
--- -- see `dropped_comments` below.
local node_mod = require("cosmic.ast.node")
local ast_walk = require("cosmic.ast.walk")
local ast_match = require("cosmic.ast.match")
local format = require("cosmic.format")
local tl = require("tl")

local type Node = node_mod.Node

--- One search hit: a matched node plus its own capture bindings.
local record Hit
  node: Node
  caps: {string: Node}
end

--- One hit left unmodified because applying its replacement would
--- silently delete a comment -- reported, never applied.
local record Refusal
  node: Node
  --- The comment text(s) that would have been dropped.
  comments: {string}
end

--- The outcome of one `rewrite` call.
local record RewriteResult
  --- The final, formatted source -- unchanged at every refused hit's
  --- own byte range.
  code: string
  refused: {Refusal}
end

--- Every node in `ast`'s tree that `pattern` matches, sorted by source
--- position.
---
--- The sort is load-bearing, not cosmetic: `cosmic.ast.walk`'s own
--- traversal falls back to `pairs()` over a node's non-array fields
--- once its array part is exhausted (`if_blocks`, `body`), and Lua's
--- hash-part iteration order is not guaranteed stable across runs --
--- so search and splice order must not depend on it.
--- @param ast Node The tree to search
--- @param pattern Node A compiled pattern (`cosmic.ast.match.compile_pattern`)
--- @return {Hit} Every match, in source order
local function find_all(ast: Node, pattern: Node): {Hit}
  local hits: {Hit} = {}
  ast_walk.walk(ast, function(n: Node)
      local caps = ast_match.match(pattern, n)
      if caps then
        hits[#hits + 1] = {node = n, caps = caps}
      end
    end)
  table.sort(hits, function(p: Hit, q: Hit): boolean
      local py, px = ast_walk.span_start(p.node)
      local qy, qx = ast_walk.span_start(q.node)
      return py < qy or (py == qy and px < qx)
    end)
  return hits
end

--- Per-line starting byte offsets of `source`, 1-based: `starts[y]` is
--- the byte offset of line `y`'s first character.
--- @param source string
--- @return {integer}
local function line_starts(source: string): {integer}
  local starts: {integer} = {1}
  local pos = 1
  while true do
    local nl = source:find("\n", pos, true)
    if not nl then
      break
    end
    starts[#starts + 1] = nl + 1
    pos = nl + 1
  end
  return starts
end

--- The 1-based byte offset of 1-based line `y`, column `x` -- tl's own
--- columns are 1-based, confirmed empirically (a line's first
--- character is `x = 1`), not assumed from reading the grammar alone.
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @param y integer
--- @param x integer
--- @return integer
local function offset_of(starts: {integer}, y: integer, x: integer): integer
  return starts[y] + x - 1
end

--- `node`'s own span as an inclusive `[a, b]` byte range.
--- @param node Node
--- @param tokens {tl.Token} The token stream from the SAME parse as `node`
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @return integer a
--- @return integer b
local function byte_span(node: Node, tokens: {tl.Token}, starts: {integer}): integer, integer
  local sy, sx = ast_walk.span_start(node)
  local ey, ex = ast_walk.span_end(node, tokens)
  return offset_of(starts, sy, sx), offset_of(starts, ey, ex)
end

--- Byte ranges `[a, b]` (inclusive) whose capture's OWN span the
--- `replacement` template actually reuses, checked literally
--- (`replacement:find(name, 1, true)`) rather than by re-parsing the
--- template -- exactly the source text a rewrite carries forward
--- verbatim, as opposed to a captured span the template discards.
--- @param caps {string: Node} A hit's capture bindings
--- @param replacement string The (already desugared) replacement template
--- @param tokens {tl.Token} The token stream from the SAME parse as `caps`' nodes
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @return {{integer, integer}} Kept ranges, unordered
local function kept_ranges(caps: {string: Node}, replacement: string, tokens: {tl.Token},
    starts: {integer}): {{integer, integer}}
  local kept: {{integer, integer}} = {}
  for name, cap in pairs(caps) do
    if replacement:find(name, 1, true) then
      local a, b = byte_span(cap, tokens, starts)
      kept[#kept + 1] = {a, b}
    end
  end
  return kept
end

--- Comment texts inside `[a, b]` that no `kept` range covers -- exactly
--- the comments a rewrite over this range would silently delete: one
--- attached to a token in the match's own "connective tissue" (its
--- pattern's literal text, or the gaps between captures) rather than
--- inside a capture the replacement actually reuses. A comment attaches
--- to the token that FOLLOWS it, per `tl.lex`.
--- @param tokens {tl.Token} The full token stream, comments and all
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @param a integer Match's start byte offset
--- @param b integer Match's end byte offset
--- @param kept {{integer, integer}} Ranges the replacement carries forward verbatim
--- @return {string} The dropped comments' own text, in token order
local function dropped_comments(tokens: {tl.Token}, starts: {integer},
    a: integer, b: integer, kept: {{integer, integer}}): {string}
  local dropped: {string} = {}
  for _, t in ipairs(tokens) do
    if t.comments then
      for _, c in ipairs(t.comments) do
        local coff = offset_of(starts, c.y, c.x)
        if coff >= a and coff <= b then
          local covered = false
          for _, r in ipairs(kept) do
            if coff >= r[1] and coff <= r[2] then
              covered = true
              break
            end
          end
          if not covered then
            dropped[#dropped + 1] = c.text
          end
        end
      end
    end
  end
  return dropped
end

--- Find every match of `pattern` in `source` and splice `replacement`
--- over each one, then reformat the result through `cosmic.format`.
---
--- `replacement` uses the pattern's own `$NAME`/`$$$NAME` surface
--- syntax; each capture name is substituted with `source:sub(a, b)` of
--- its own span -- the ORIGINAL bytes of whatever it matched, verbatim,
--- comments and all. Splicing runs back-to-front so earlier offsets in
--- the same file stay valid across multiple hits. A hit that would
--- silently drop a comment (see `dropped_comments`) is refused: left
--- unmodified at its own byte range, and reported in the result rather
--- than applied.
---
--- The final splice is piped through `cosmic.format.format` rather than
--- hand-preserving inter-argument whitespace; that reparse also
--- validates the splice, so a syntax error the splice introduced is a
--- hard failure here, not a warning to swallow.
--- @param source string The file's source text
--- @param name string Filename, for parse diagnostics and format's language detection
--- @param pattern Node A compiled pattern (`cosmic.ast.match.compile_pattern`)
--- @param replacement string A replacement template, `$NAME`/`$$$NAME` surface syntax
--- @return RewriteResult|nil The formatted result plus any refused hits, or nil on failure
--- @return string Error message on failure, nil on success
local function rewrite(source: string, name: string, pattern: Node,
    replacement: string): RewriteResult | nil, string
  local parsed, perr = node_mod.parse(source, name)
  if not parsed then
    return nil, perr
  end
  local desugared = ast_match.desugar(replacement)
  local hits = find_all(parsed.node, pattern)
  local starts = line_starts(source)
  local out = source
  local refused: {Refusal} = {}
  for i = #hits, 1, -1 do
    local h = hits[i]
    local a, b = byte_span(h.node, parsed.tokens, starts)
    local kept = kept_ranges(h.caps, desugared, parsed.tokens, starts)
    local dropped = dropped_comments(parsed.tokens, starts, a, b, kept)
    if #dropped > 0 then
      refused[#refused + 1] = {node = h.node, comments = dropped}
    else
      local text = desugared
      for cname, cap in pairs(h.caps) do
        local ca, cb = byte_span(cap, parsed.tokens, starts)
        -- gsub: replacement %%-escaped on the line above
        text = text:gsub(cname, (source:sub(ca, cb):gsub("%%", "%%%%")))
      end
      out = out:sub(1, a - 1) .. text .. out:sub(b + 1)
    end
  end
  local result = format.format(out, name)
  if not result.ok then
    return nil, format.format_issues(result.errors)
  end
  return {code = result.code, refused = refused}, nil
end

local record RewriteModule
  type Hit = Hit
  type Refusal = Refusal
  type RewriteResult = RewriteResult
  find_all: function(ast: Node, pattern: Node): {Hit}
  line_starts: function(source: string): {integer}
  offset_of: function(starts: {integer}, y: integer, x: integer): integer
  rewrite: function(source: string, name: string, pattern: Node,
  replacement: string): RewriteResult | nil, string
end

local M: RewriteModule = {
  find_all = find_all,
  line_starts = line_starts,
  offset_of = offset_of,
  rewrite = rewrite,
}

return M
