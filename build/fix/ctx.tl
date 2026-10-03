--- What every part of the renderer shares: the buffer it writes into,
--- the source and tokens it reads positions out of, and the handful of
--- operations that turn an AST position into output.
---
--- Three of those operations carry the renderer's whole layout policy.
--- `lead` moves to a node's own starting line, or writes a separator
--- when the node begins on the line already in progress -- so a line
--- break survives exactly where the source had one, and so does its
--- absence. [`lead_to`] moves to a line the renderer indents itself,
--- which is every line that opens a statement. `verbatim` writes a
--- range of the original bytes out untouched, which is how type syntax
--- and record bodies are rendered at all.
---
--- `shift` is the difference between the column a statement is written
--- at and the column it was read from. The renderer sets a statement's
--- indentation (two columns per level of block), so a file indented
--- another way moves, and every line that continues the statement moves
--- by the same amount. `indent` applies it: a continuation line keeps
--- its column relative to its statement, and the renderer never decides
--- where to wrap.

local ast = require("build.ast")
local emit = require("build.fix.emit")
local typescan = require("build.fix.typescan")
local String = require("cosmic.string")
local type compiler = require("build.compiler")

local type Node = ast.Node

--- Where a construct's last token was written: the output column it
--- ends at and the source line it was read from.
local record Ending
  column: integer
  line: integer
  --- Whether its closing keyword was written on the line already open.
  inline: boolean
end

local record Ctx
  em: emit.Emitter
  source: string
  tokens: {compiler.Token}
  --- Per-line starting byte offsets, for turning a position into a cut.
  starts: {integer}
  scan: typescan.Scan
  --- Columns to move a continuation line by: the statement's rendered
  --- indentation minus the one it was read at.
  shift: integer
  --- The indentation, in COLUMNS, of the statement being rendered: two
  --- for each block it sits inside, and the same number again for the
  --- closing keyword of a block it opens, so the two line up. A column
  --- rather than a count of blocks because a block does not always open
  --- on the grid -- a function literal on a continuation line opens
  --- wherever that line sits, and its body is indented from there.
  margin: integer
  --- `span_start`, remembered: the renderer asks for the same node's
  --- start once per join it sits beside, and the answer is a walk of
  --- the whole subtree.
  memo: {Node: ast.Position}
  --- Constructs this renderer will not write. A refusal is named rather
  --- than guessed at: writing something else and calling it the same
  --- program is the one outcome a source rewriter may never have.
  refused: {string}
  --- A block of statements, rendered. Assigned by [`build.fix.render`],
  --- because an expression may hold a function literal whose body is
  --- statements again.
  block: function(Ctx, Node)
  --- What [`build.fix.breaks`] judges, gathered as the file is
  --- rendered so it walks nothing again. `parted` holds each statement
  --- written on a line another statement or a comment had opened, after
  --- the first of its block; `continues`, each block whose first
  --- statement was, and each `elseif` or `else` branch that was;
  --- `constructs` and `ends`, every construct that opens a block and
  --- where its last token was written.
  parted: {Node}
  continues: {Node:boolean}
  constructs: {Node}
  ends: {Node:Ending}
  --- The `;` tokens, by index, that a node opens on (a block's, an
  --- empty `return` list's): one is the node's own and stays.
  owned: {integer:boolean}
  --- The tokens, by index, of each binary operator written at the
  --- start of a line, which [`build.fix.breaks`] moves to the end of
  --- the line before.
  leading: {integer}
end

--- Where `node`'s own subtree starts, remembered across calls.
--- @param ctx Ctx
--- @param node Node
--- @return ast.Position Where it starts
local function start_of(ctx: Ctx, node: Node): ast.Position
  local known = ctx.memo[node]
  if known == nil then
    known = ast.span_start(node)
    ctx.memo[node] = known
  end
  return known
end

--- The leading whitespace of a line that begins at source column `x`.
--- @param ctx Ctx
--- @param x integer
--- @return string
local function indent(ctx: Ctx, x: integer): string
  local width = x - 1 + ctx.shift
  if width < 0 then
    width = 0
  end
  return string.rep(" ", width)
end

--- Move to where `node` starts: onto its own line when the source put
--- it there, or `inline` when it continues the line already open.
--- @param ctx Ctx
--- @param node Node
--- @param inline string The separator to write when no line break is due
local function lead(ctx: Ctx, node: Node, inline: string)
  local at = start_of(ctx, node)
  emit.advance(ctx.em, at.y, indent(ctx, at.x), inline, at.x)
end

--- Move to a bare position rather than a node's -- a continuation the
--- parser recorded as `yend`/`xend` rather than as a node of its own.
--- @param ctx Ctx
--- @param y integer
--- @param x integer The column the terminator's first character sits at
--- @param inline string The separator to write when no line break is due
local function lead_at(ctx: Ctx, y: integer, x: integer, inline: string)
  emit.advance(ctx.em, y, indent(ctx, x), inline, x)
end

--- Move to source line `y` at the indentation the renderer chose, not
--- one carried over from the source: `margin` columns in. Every line
--- that opens a statement, and every block's closing keyword, goes
--- through here.
---
--- `x` is carried even though the indentation does not come from it:
--- what was written in front of the destination on its own line is
--- placed in front of it here, and the column is how the buffer knows
--- which comments those are.
--- @param ctx Ctx
--- @param y integer
--- @param x integer The column the line's own first character sits at
--- @param margin integer The column the line is indented to
--- @param inline string The separator to write when no line break is due
local function lead_to(ctx: Ctx, y: integer, x: integer, margin: integer,
                       inline: string)
  emit.advance(ctx.em, y, string.rep(" ", margin), inline, x)
end

--- The byte offset of 1-based (`y`, `x`) in the source being rendered.
local function offset(ctx: Ctx, y: integer, x: integer): integer
  return ast.offset_of(ctx.starts, y, x)
end

--- Set the indentation of the statement about to be written: `margin`
--- columns in, read from source column `x`. Everything the statement
--- carries onto a later line moves by the same amount, comments in
--- front of it included.
--- @param ctx Ctx
--- @param margin integer The column to write the statement at
--- @param x integer The column the statement was read at
local function place(ctx: Ctx, margin: integer, x: integer)
  ctx.margin = margin
  ctx.shift = margin - (x - 1)
  ctx.em.shift = ctx.shift
end

--- How many newlines `text` carries.
local function newlines(text: string): integer
  local _, n = text:gsub("\n", "")
  return n
end

--- The source lines after `y1`, through `y2`, that open inside a long
--- comment or a long string starting at or after (`y1`, `x1`): the
--- bytes there are the comment's or the string's own, not indentation.
local function held_lines(ctx: Ctx, y1: integer, x1: integer, y2: integer): {integer:boolean}
  local held: {integer:boolean} = {}
  local function hold(y: integer, x: integer, text: string)
    if y < y1 or (y == y1 and x < x1) or y > y2 then
      return
    end
    for line = y + 1, y + newlines(text) do
      held[line] = true
    end
  end
  -- A comment hangs on the token after it, so the first token past the
  -- range still carries the comments that end it.
  local tokens = ctx.scan.tokens
  local i = typescan.index_before(ctx.scan, y1, x1) + 1
  while tokens[i] ~= nil do
    local t = tokens[i]
    local carried = t.comments
    if carried ~= nil then
      for _, c in ipairs(carried) do
        hold(c.y, c.x, c.text)
      end
    end
    if t.y > y2 then
      break
    end
    hold(t.y, t.x, t.tk)
    i = i + 1
  end
  return held
end

--- `text`, read from source line `y1` on, with every line after the
--- first moved by `ctx.shift` columns, but those `held` keeps as they
--- are.
local function reindent(ctx: Ctx, text: string, y1: integer, held: {integer:boolean}): string
  local out: {string} = {}
  local y = y1
  for line in String.lines(text) do
    if y == y1 or held[y] then
      out[#out + 1] = line
    elseif ctx.shift > 0 then
      out[#out + 1] = string.rep(" ", ctx.shift) .. line
    else
      out[#out + 1] = (line:gsub("^" .. string.rep(" ", -ctx.shift), ""))
    end
    y = y + 1
  end
  return table.concat(out, "\n")
end

--- Write the original bytes from (`y1`, `x1`) through (`y2`, `x2`)
--- inclusive, and count every comment inside them as written: they came
--- along with the bytes.
--- @param ctx Ctx
--- @param y1 integer
--- @param x1 integer
--- @param y2 integer
--- @param x2 integer
local function verbatim(ctx: Ctx, y1: integer, x1: integer, y2: integer, x2: integer)
  local text = ctx.source:sub(offset(ctx, y1, x1), offset(ctx, y2, x2))
  if ctx.shift ~= 0 and y2 > y1 then
    text = reindent(ctx, text, y1, held_lines(ctx, y1, x1, y2))
  end
  emit.text(ctx.em, text)
  emit.consume(ctx.em, y2, x2)
end

--- Write the original bytes of tokens `first` through `last`. Nothing
--- is written when the range is empty, which is a type the parser
--- synthesized rather than read off the source.
---
--- It leads to the first token first, so a comment the source wrote in
--- front of it is written there, and a line break before it kept,
--- rather than taken as written with the bytes after it.
--- @param ctx Ctx
--- @param first integer The index of the region's first token
--- @param last integer The index of the region's last token
--- @return boolean Whether anything was written
local function region(ctx: Ctx, first: integer, last: integer): boolean
  local opening = ctx.scan.tokens[first]
  if opening == nil or last < first then
    return false
  end
  lead_at(ctx, opening.y, opening.x, "")
  verbatim(ctx, opening.y, opening.x, ctx.scan.tokens[last].y,
    typescan.last_column(ctx.scan, last))
  return true
end

--- Write a `:` and the type syntax that follows it, tokens `first`
--- through `last`. The `:` sits against whatever came before it and the
--- type gets one space -- unless the source started the type on a line
--- of its own, which is carried over like every other line break.
--- @param ctx Ctx
--- @param first integer The index of the type's first token
--- @param last integer The index of the type's last token
--- @return boolean Whether anything was written
local function annotation(ctx: Ctx, first: integer, last: integer): boolean
  local opening = ctx.scan.tokens[first]
  if opening == nil or last < first then
    return false
  end
  emit.put(ctx.em, ":")
  lead_at(ctx, opening.y, opening.x, " ")
  return region(ctx, first, last)
end

--- Note that construct `n` was just written in full, for
--- [`build.fix.breaks`] to judge, its closing keyword `inline` or not.
local function ended(ctx: Ctx, n: Node, inline: boolean)
  ctx.constructs[#ctx.constructs + 1] = n
  -- Only a construct closing on an open line can be one on one line,
  -- and only then does the column it reached matter.
  ctx.ends[n] = { column = inline and emit.column(ctx.em) or 0, line = ctx.em.line,
                  inline = inline }
end

--- Note that the `;` at (`y`, `x`) is the token a node opens on.
local function owns(ctx: Ctx, y: integer, x: integer)
  local i = typescan.index_at(ctx.scan, y, x)
  if i ~= nil then
    ctx.owned[i] = true
  end
end

--- Note a construct this renderer will not write, rather than writing
--- something else and calling it the same program.
local function refuse(ctx: Ctx, what: string)
  ctx.refused[#ctx.refused + 1] = what
end

local record CtxModule
  type Ctx = Ctx
  type Ending = Ending
  ended: function(ctx: Ctx, n: Node, inline: boolean)
  owns: function(ctx: Ctx, y: integer, x: integer)
  refuse: function(ctx: Ctx, what: string)
  start_of: function(ctx: Ctx, node: Node): ast.Position
  indent: function(ctx: Ctx, x: integer): string
  lead: function(ctx: Ctx, node: Node, inline: string)
  lead_at: function(ctx: Ctx, y: integer, x: integer, inline: string)
  lead_to: function(ctx: Ctx, y: integer, x: integer, margin: integer,
                    inline: string)
  place: function(ctx: Ctx, margin: integer, x: integer)
  verbatim: function(ctx: Ctx, y1: integer, x1: integer, y2: integer, x2: integer)
  region: function(ctx: Ctx, first: integer, last: integer): boolean
  annotation: function(ctx: Ctx, first: integer, last: integer): boolean
end

local M: CtxModule = {
  ended = ended,
  owns = owns,
  refuse = refuse,
  start_of = start_of,
  indent = indent,
  lead = lead,
  lead_at = lead_at,
  lead_to = lead_to,
  place = place,
  verbatim = verbatim,
  region = region,
  annotation = annotation,
}

return M
