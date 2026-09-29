--- Structural rewrite over `build.ast.match` patterns: find every match
--- in a tree and splice a replacement template over the original
--- source bytes.
---
--- The result is the raw spliced source: byte-exact wherever no hit
--- landed, the template's bytes where one did, nothing reflowed.
--- Rendering belongs to the caller. `build.fix` parses the spliced
--- source again and writes the file through `build.fix.render`, and
--- rendering here as well would render twice.
---
--- A `keep` predicate narrows the hits before anything is spliced;
--- `build.fix.spill` uses it to name its sites by position.
---
--- One pass over one file: no fixpoint (a rewrite that creates a new
--- match), no project-wide loop. A rewrite that would delete a comment
--- is refused instead of applied (`dropped_comments`).
---
--- A replacement of exactly `""` against a call-statement hit
--- (`is_call_statement`) removes the whole line range, not just the
--- node's byte span, so deleting `test_a()` leaves no blank line.
--- `dropped_comments` checks that wider range, so a trailing comment
--- on the same line still refuses the hit.
local type compiler = require("build.compiler")
local node_mod = require("build.ast.node")
local ast_walk = require("build.ast.walk")
local ast_match = require("build.ast.match")

local type Node = node_mod.Node

--- One search hit: a matched node plus its own capture bindings.
local record Hit
  node: Node
  caps: {string: Node}
end

--- One hit left unmodified because its replacement would delete a
--- comment. It is reported, never applied.
local record Refusal
  node: Node
  --- The comment text(s) that would have been dropped.
  comments: {string}
end

--- The outcome of one `rewrite` call.
local record RewriteResult
  --- The final source, spliced over the original bytes -- unchanged at
  --- every refused hit's own byte range.
  code: string
  refused: {Refusal}
  --- Accepted original hits, in ascending source order. A failed whole-file
  --- reparse has no result, so it has no tentative edit metadata either.
  edits: {Hit}
end

--- Every node in `ast`'s tree that `pattern` matches, sorted by source
--- position.
---
--- The sort makes the order deterministic: `build.ast.walk` visits a
--- node's non-array fields (`if_blocks`, `body`) with `pairs()`, whose
--- order Lua does not fix across runs.
--- @param ast Node The tree to search
--- @param pattern Node A compiled pattern (`build.ast.match.compile_pattern`)
--- @return {Hit} Every match, in source order
local function find_all(ast: Node, pattern: Node): {Hit}
  local hits: {Hit} = {}
  ast_walk.walk(ast, function(n: Node)
    local caps = ast_match.match(pattern, n)
    if caps then
      hits[#hits + 1] = { node = n, caps = caps }
    end
  end)
  table.sort(hits, function(p: Hit, q: Hit): boolean
    local ps, qs = ast_walk.span_start(p.node), ast_walk.span_start(q.node)
    local py, px, qy, qx = ps.y, ps.x, qs.y, qs.x
    return py < qy or (py == qy and px < qx)
  end)
  return hits
end

--- Per-line starting byte offsets of `source`, 1-based: `starts[y]` is
--- the byte offset of line `y`'s first character.
--- @param source string
--- @return {integer}
local function line_starts(source: string): {integer}
  local starts: {integer} = { 1 }
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

--- The 1-based byte offset of 1-based line `y`, column `x`. tl's
--- columns are 1-based: a line's first character is `x = 1`.
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @param y integer
--- @param x integer
--- @return integer
local function offset_of(starts: {integer}, y: integer, x: integer): integer
  return starts[y] + x - 1
end

--- Whether `node` is a rest capture that matched nothing: it stands for
--- no source at all, and substitutes as nothing.
local function empty_rest(node: Node): boolean
  return node.kind == "rest_capture" and #node == 0
end

--- `node`'s own span as an inclusive `[a, b]` byte range.
--- @param node Node
--- @param tokens {compiler.Token} The token stream from the SAME parse as `node`
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @return integer a
--- @return integer b
local function byte_span(node: Node, tokens: {compiler.Token},
    starts: {integer}): integer, integer
  local s, e = ast_walk.span_start(node), ast_walk.span_end(node, tokens)
  local sy, sx, ey, ex = s.y, s.x, e.y, e.x
  return offset_of(starts, sy, sx), offset_of(starts, ey, ex)
end

--- The byte range `[a, b]` of the next whole-identifier occurrence of
--- `name` in `text` at or after `init`, or nil if there is none. A
--- whole identifier has no identifier character (`[%w_]`) before or
--- after it. A plain substring search would match a capture name that
--- prefixes another (`_X` in `_XS`, `_N` in `_NAME`) inside the longer
--- name and corrupt it. `kept_ranges` and `substitute` share this so
--- they agree on what counts as an occurrence.
--- @param text string
--- @param name string A capture's own desugared name (`_X`, `___XS`, ...)
--- @param init integer 1-based byte offset to start searching from
--- @return integer|nil a
--- @return integer|nil b
local function find_name(text: string, name: string,
    init: integer): integer | nil, integer | nil
  local pos = init
  while pos <= #text + 1 do
    local a, b = text:find(name, pos, true)
    if not a then
      return nil, nil
    end
    local before = a > 1 and text:sub(a - 1, a - 1) or ""
    local after = b < #text and text:sub(b + 1, b + 1) or ""
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return a, b
    end
    pos = a + 1
  end
  return nil, nil
end

--- `text` with every whole-identifier occurrence of `name` replaced by
--- `value`, spliced as literal bytes (not as a `gsub` replacement).
--- @param text string
--- @param name string A capture's own desugared name
--- @param value string The literal bytes to splice in for each occurrence
--- @return string
local function substitute(text: string, name: string, value: string): string
  local out: {string} = {}
  local pos = 1
  while true do
    local a, b = find_name(text, name, pos)
    if not a then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, a - 1)
    out[#out + 1] = value
    pos = b + 1
  end
  return table.concat(out)
end

--- Byte ranges `[a, b]` (inclusive) of the captures the `replacement`
--- template reuses: the source text a rewrite carries forward, as
--- opposed to a captured span it discards. A capture counts as reused
--- when `find_name` finds its name in the template text.
--- @param caps {string: Node} A hit's capture bindings
--- @param replacement string The (already desugared) replacement template
--- @param tokens {compiler.Token} The token stream from the SAME parse as `caps`' nodes
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @return {{integer, integer}} Kept ranges, unordered
local function kept_ranges(caps: {string: Node}, replacement: string,
    tokens: {compiler.Token}, starts: {integer}): {{integer, integer}}
  local kept: {{integer, integer}} = {}
  for name, cap in pairs(caps) do
    if find_name(replacement, name, 1) and not empty_rest(cap) then
      local a, b = byte_span(cap, tokens, starts)
      kept[#kept + 1] = { a, b }
    end
  end
  return kept
end

--- Comment texts inside `[a, b]` that no `kept` range covers: the
--- comments a rewrite over this range would delete. They sit in the
--- match's connective text (the pattern's literals and the gaps
--- between captures), not inside a capture the replacement reuses.
--- `tl.lex` attaches a comment to the token that follows it.
--- @param tokens {compiler.Token} The full token stream, comments and all
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @param a integer Match's start byte offset
--- @param b integer Match's end byte offset
--- @param kept {{integer, integer}} Ranges the replacement carries forward verbatim
--- @return {string} The dropped comments' own text, in token order
local function dropped_comments(tokens: {compiler.Token}, starts: {integer},
    a: integer, b: integer, kept: {{integer, integer}}): {string}
  local dropped: {string} = {}
  for _, t in ipairs(tokens) do
    local comments = t.comments
    if comments then
      for _, c in ipairs(comments) do
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

--- Is `node` a call, `f(...)` or `t:m(...)`? Calls are "op" nodes with
--- operator "@funcall" or "@method". A statement has no node kind of
--- its own, and this does not check that `node` stands alone in a
--- "statements" list.
--- @param node Node
--- @return boolean
-- TODO: require that `node` is a statement. As it is, `rewrite` with a
-- replacement of `""` removes the whole line of a call nested in a
-- larger statement: `f($X)` over `local x = f(1)` deletes that line.
local function is_call_statement(node: Node): boolean
  local op = node.op
  return node.kind == "op" and op ~= nil and (op.op == "@funcall" or op.op == "@method")
end

--- The byte range `[a, b]` (inclusive) of every whole line `node`'s
--- span touches, from `span_start`'s line through `span_end`'s. It
--- includes each line's indentation and, except at end of file, its
--- trailing newline, so removing it leaves no blank line.
--- @param node Node
--- @param tokens {compiler.Token} The token stream from the SAME parse as `node`
--- @param starts {integer} `line_starts`'s own result, for the same source
--- @param source_len integer The source's own length in bytes
--- @return integer a
--- @return integer b
local function line_range(node: Node, tokens: {compiler.Token}, starts: {integer},
    source_len: integer): integer, integer
  local sy = ast_walk.span_start(node).y
  local ey = ast_walk.span_end(node, tokens).y
  local a = starts[sy]
  local b = ey + 1 <= #starts and starts[ey + 1] - 1 or source_len
  return a, b
end

--- Find every match of `pattern` in `source` and splice `replacement`
--- over each one.
---
--- `replacement` uses the pattern's `$NAME`/`$$$NAME` surface syntax;
--- each capture name becomes the original bytes of its span, comments
--- included. Splicing runs back to front so earlier offsets stay valid
--- across hits. A hit that would drop a comment (`dropped_comments`)
--- is refused: its bytes stay as they were and the result reports it.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string The file's source text
--- @param name string Filename, for parse diagnostics
--- @param pattern Node A compiled pattern (`build.ast.match.compile_pattern`)
--- @param replacement string A replacement template, `$NAME`/`$$$NAME` surface syntax
--- @param keep function(Node): boolean Optional: only hits whose node it accepts are applied
--- @return RewriteResult|nil The spliced result plus any refused hits, or nil on failure
--- @return string Error message on failure, "" on success
local function rewrite(built: compiler, source: string, name: string, pattern: Node,
    replacement: string, keep?: function(Node): boolean): RewriteResult | nil, string
  local parsed, perr = node_mod.parse(built, source, name)
  if not parsed then
    return nil, perr
  end
  local desugared = ast_match.desugar(replacement)
  local hits = find_all(parsed.node, pattern)
  if keep ~= nil then
    local kept: {Hit} = {}
    for _, h in ipairs(hits) do
      if keep(h.node) then kept[#kept + 1] = h end
    end
    hits = kept
  end
  local starts = line_starts(source)
  local out = source
  local refused: {Refusal} = {}
  local edits: {Hit} = {}
  for i = #hits, 1, -1 do
    local h = hits[i]
    local a, b: integer, integer
    if desugared == "" and is_call_statement(h.node) then
      a, b = line_range(h.node, parsed.tokens, starts, #source)
    else
      a, b = byte_span(h.node, parsed.tokens, starts)
    end
    local kept = kept_ranges(h.caps, desugared, parsed.tokens, starts)
    local dropped = dropped_comments(parsed.tokens, starts, a, b, kept)
    if #dropped > 0 then
      refused[#refused + 1] = { node = h.node, comments = dropped }
    else
      local text = desugared
      for cname, cap in pairs(h.caps) do
        local value = ""
        if not empty_rest(cap) then
          local ca, cb = byte_span(cap, parsed.tokens, starts)
          value = source:sub(ca, cb)
        end
        text = substitute(text, cname, value)
      end
      out = out:sub(1, a - 1) .. text .. out:sub(b + 1)
      -- Splicing walks backwards to preserve byte offsets. Insert at the
      -- front so public edit metadata retains the original source order.
      table.insert(edits, 1, h)
    end
  end
  return { code = out, refused = refused, edits = edits }, ""
end

local record RewriteModule
  type Hit = Hit
  type Refusal = Refusal
  type RewriteResult = RewriteResult
  find_all: function(ast: Node, pattern: Node): {Hit}
  line_starts: function(source: string): {integer}
  offset_of: function(starts: {integer}, y: integer, x: integer): integer
  rewrite: function(built: compiler, source: string, name: string, pattern: Node,
  replacement: string, keep?: function(Node): boolean): RewriteResult | nil, string
end

local M: RewriteModule = {
  find_all = find_all,
  line_starts = line_starts,
  offset_of = offset_of,
  rewrite = rewrite,
}

return M
