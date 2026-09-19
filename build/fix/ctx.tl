--- What every part of the renderer shares: the buffer it writes into,
--- the source and tokens it reads positions out of, and the handful of
--- operations that turn an AST position into output.
---
--- Three of those operations carry the renderer's whole layout policy.
--- `lead` moves to a node's own starting line, or writes a separator
--- when the node begins on the line already in progress -- so a line
--- break survives exactly where the source had one, and so does its
--- absence. `lead_to` moves to a line the renderer indents itself,
--- which is every line that opens a statement. `verbatim` writes a
--- range of the original bytes out untouched, which is how type syntax
--- and record bodies are rendered at all.
---
--- `shift` is the difference between the column a statement is written
--- at and the column it was read from. A statement's own indentation is
--- the renderer's -- two columns per level of block -- so a file
--- indented some other way moves, and every line that CONTINUES that
--- statement has to move with it by the same amount. That is what
--- `shift` is for, and `indent` is where it is applied: a continuation
--- line keeps its column relative to the statement it belongs to
--- without the renderer having to decide where to wrap, which it never
--- does.

local ast = require("build.ast")
local emit = require("build.fix.emit")
local typescan = require("build.fix.typescan")
local type compiler = require("build.compiler")

local type Node = ast.Node

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
  memo: {Node:{integer}}
  --- Constructs this renderer will not write. A refusal is named rather
  --- than guessed at: writing something else and calling it the same
  --- program is the one outcome a source rewriter may never have.
  refused: {string}
  --- A block of statements, rendered. Assigned by `build.fix.render`,
  --- because an expression may hold a function literal whose body is
  --- statements again.
  block: function(Ctx, Node)
end

--- Where `node`'s own subtree starts, remembered across calls.
--- @param ctx Ctx
--- @param node Node
--- @return integer The 1-based line
--- @return integer The 1-based column
local function start_of(ctx: Ctx, node: Node): integer, integer
  local known = ctx.memo[node]
  if known ~= nil then
    return known[1], known[2]
  end
  local y, x = ast.span_start(node)
  ctx.memo[node] = { y, x }
  return y, x
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
  local y, x = start_of(ctx, node)
  emit.advance(ctx.em, y, indent(ctx, x), inline, x)
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

--- `text` with every line after the first moved by `ctx.shift` columns.
local function reindent(ctx: Ctx, text: string): string
  if ctx.shift == 0 or text:find("\n", 1, true) == nil then
    return text
  end
  local out: {string} = {}
  local first = true
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if first then
      out[#out + 1] = line
      first = false
    elseif ctx.shift > 0 then
      out[#out + 1] = string.rep(" ", ctx.shift) .. line
    else
      out[#out + 1] = (line:gsub("^" .. string.rep(" ", -ctx.shift), ""))
    end
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
  emit.text(ctx.em, reindent(ctx, text))
  emit.consume(ctx.em, y2, x2)
end

--- Write the original bytes of tokens `first` through `last`. Nothing
--- is written when the range is empty, which is a type the parser
--- synthesized rather than read off the source.
--- @param ctx Ctx
--- @param first integer The index of the region's first token
--- @param last integer The index of the region's last token
--- @return boolean Whether anything was written
local function region(ctx: Ctx, first: integer, last: integer): boolean
  local opening = ctx.scan.tokens[first]
  if opening == nil or last < first then
    return false
  end
  local ey, ex = typescan.ends_at(ctx.scan, last)
  verbatim(ctx, opening.y, opening.x, ey, ex)
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

local record CtxModule
  type Ctx = Ctx
  start_of: function(ctx: Ctx, node: Node): integer, integer
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
