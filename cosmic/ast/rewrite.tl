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
---
--- A replacement of exactly `""` against a hit whose own node is a
--- call-statement (see `is_call_statement`) removes the STATEMENT --
--- its whole line range, not just its own byte span -- so deleting
--- `test_a()` leaves no blank line behind. `dropped_comments` is
--- reused unchanged over that WIDER range, so a trailing comment on
--- the same line still refuses the hit rather than vanishing with it.
local node_mod = require("cosmic.ast.node")
local ast_walk = require("cosmic.ast.walk")
local ast_match = require("cosmic.ast.match")
local template = require("cosmic.edit")
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
--- replacement template reuses, based on the lexical template
--- instantiator's code-only use counts.
--- @param caps {string: Node} A hit's capture bindings
--- @param uses {string: integer} Template code use count by capture name
--- @param tokens {tl.Token} The token stream from the SAME parse as `caps`' nodes
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @return {{integer, integer}} Kept ranges, unordered
local function kept_ranges(caps: {string: Node}, uses: {string: integer}, tokens: {tl.Token},
    starts: {integer}): {{integer, integer}}
  local kept: {{integer, integer}} = {}
  for name, cap in pairs(caps) do
    if (uses[name] or 0) > 0 then
      if cap.kind == "rest_capture" then
        local elems = cap as {Node} -- cast: synthetic rest_capture array view
        if #elems > 0 then
          local a = byte_span(elems[1], tokens, starts)
          local _, b = byte_span(elems[#elems], tokens, starts)
          kept[#kept + 1] = {a, b}
        end
      else
        local a, b = byte_span(cap, tokens, starts)
        kept[#kept + 1] = {a, b}
      end
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

--- Is `node` a call-statement -- `f(...)` or `t:m(...)` used bare, as
--- its own statement, rather than nested inside a larger expression?
--- The only tl AST shape a call takes at all: an "op" node whose own
--- operator is "@funcall"/"@method" (confirmed against a real
--- `test_a()` line with `cosmic --find`: kind "op", `op.op ==
--- "@funcall"`, no distinct "this is a statement" marker of its own --
--- position in a "statements" list is what makes one a statement, not
--- a different node shape).
--- @param node Node
--- @return boolean
local function is_call(node: Node): boolean
  local op = node.op
  return node.kind == "op" and op ~= nil and (op.op == "@funcall" or op.op == "@method")
end

--- Calls that are direct array elements of a `statements` node. A call
--- nested in `local x = f()` has the same AST shape, so shape alone is
--- never enough to authorize statement deletion.
local function statement_calls(root: Node): {Node: boolean}
  local found: {Node: boolean} = {}
  local seen: {any: boolean} = {}
  local function visit(value: any)
    if not (value is {any: any}) or seen[value] then
      return
    end
    seen[value] = true
    local map = value as {any: any} -- cast: generic AST reflection view
    if map["kind"] == "statements" then
      for _, child in ipairs(value as {any}) do -- cast: statements array view
        if child is {any: any} then
          local child_kind = child["kind"]
          if child_kind is string then
            local n = child as Node -- cast: kind field identifies a parsed Node
            if is_call(n) then
              found[n] = true
            end
          end
        end
      end
    end
    for k, child in pairs(map) do
      if k ~= "if_parent" then
        if child is {any: any} then
          local child_kind = child["kind"]
          if child_kind is string then
            visit(child)
          else
            for _, element in ipairs(child as {any}) do -- cast: child-list view
              visit(element)
            end
          end
        end
      end
    end
  end
  visit(root)
  return found
end

--- Delete one direct statement without consuming its same-line peers.
--- A statement alone on its line owns the line. Otherwise consume one
--- adjacent semicolon; absence of one is an unsupported parser shape.
local function statement_range(node: Node, tokens: {tl.Token}, starts: {integer},
    source: string): integer | nil, integer | nil
  local a, b = byte_span(node, tokens, starts)
  local y = ast_walk.span_start(node)
  local line_a = starts[y]
  local line_end = y + 1 <= #starts and starts[y + 1] - 1 or #source
  local content_end = y + 1 <= #starts and line_end - 1 or line_end
  local before = source:sub(line_a, a - 1)
  local after = source:sub(b + 1, content_end)
  if before:match("^%s*$") and not after:find(";", 1, true) then
    return line_a, line_end
  end
  local _, right = after:find("^%s*;%s*")
  if right then
    return a, b + right
  end
  local left = before:find(";%s*$")
  if left then
    return line_a + left - 1, b
  end
  return nil, nil
end

local record Proposed
  a: integer
  b: integer
  text: string
  hit: Hit
end

local function capture_text(source: string, cap: Node, tokens: {tl.Token},
    starts: {integer}): string
  if cap.kind == "rest_capture" then
    local elems = cap as {Node} -- cast: synthetic rest_capture array view
    if #elems == 0 then
      return ""
    end
    local a = byte_span(elems[1], tokens, starts)
    local _, b = byte_span(elems[#elems], tokens, starts)
    return source:sub(a, b)
  end
  local a, b = byte_span(cap, tokens, starts)
  local text = source:sub(a, b)
  if cap.kind == "op" then
    local op = cap.op
    if op and op.op ~= "@funcall" and op.op ~= "@method" and op.op ~= "@index" then
      return "(" .. text .. ")"
    end
  end
  return text
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
  local hits = find_all(parsed.node, pattern)
  local starts = line_starts(source)
  local direct_calls = statement_calls(parsed.node)
  local refused: {Refusal} = {}
  local proposed: {Proposed} = {}
  for _, h in ipairs(hits) do
    local a, b = byte_span(h.node, parsed.tokens, starts)
    if replacement == "" and is_call(h.node) then
      if not direct_calls[h.node] then
        refused[#refused + 1] = {
          node = h.node, comments = {},
        }
        goto continue
      end
      local sa, sb = statement_range(h.node, parsed.tokens, starts, source)
      if not sa or not sb then
        refused[#refused + 1] = {
          node = h.node, comments = {},
        }
        goto continue
      end
      a, b = sa, sb
    end
    local values: {string: string} = {}
    for cname, cap in pairs(h.caps) do
      values[cname] = capture_text(source, cap, parsed.tokens, starts)
    end
    local text, uses = template.instantiate(replacement, values)
    local kept = kept_ranges(h.caps, uses, parsed.tokens, starts)
    local dropped = dropped_comments(parsed.tokens, starts, a, b, kept)
    if #dropped > 0 then
      refused[#refused + 1] = {
        node = h.node, comments = dropped,
      }
    else
      proposed[#proposed + 1] = {a = a, b = b, text = text, hit = h}
    end
    ::continue::
  end

  table.sort(proposed, function(p: Proposed, q: Proposed): boolean
      return p.a < q.a or (p.a == q.a and p.b < q.b)
    end)
  local conflicted: {Proposed: boolean} = {}
  local covering = proposed[1]
  for i = 2, #proposed do
    local current = proposed[i]
    if covering and current.a <= covering.b then
      conflicted[covering], conflicted[current] = true, true
      if current.b > covering.b then covering = current end
    else
      covering = current
    end
  end
  if next(conflicted) ~= nil then
    for _, edit in ipairs(proposed) do
      if conflicted[edit] then
        refused[#refused + 1] = {
          node = edit.hit.node, comments = {},
        }
      end
    end
    proposed = {}
  end

  local pieces: {string} = {}
  local pos = 1
  for _, edit in ipairs(proposed) do
    pieces[#pieces + 1] = source:sub(pos, edit.a - 1)
    pieces[#pieces + 1] = edit.text
    pos = edit.b + 1
  end
  pieces[#pieces + 1] = source:sub(pos)
  local out = table.concat(pieces)
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
