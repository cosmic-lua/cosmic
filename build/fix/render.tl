--- One parsed file, written back out as source.
---
--- This is the second half of `cosmic fix`: parse, apply the structural
--- rules, render. Rendering makes the result canonical text rather than
--- a splice, and it is the only way a rewrite reaches the file: a rule
--- changes nodes, never bytes.
---
--- The renderer decides everything a line holds:
--- - every keyword, operator, separator and bracket, and the spacing
---   around each;
--- - a variable attribute (`x <const>`) as one unit attached to the
---   name;
--- - a type annotation as `: ` and then the type's own bytes;
--- - a statement's indentation, two columns per level of block, with a
---   block's closing keyword lined up with the statement that opened it;
--- - one space before a trailing comment;
--- - a comma after the last entry of a table that closes on a line of
---   its own, and none on one that does not;
--- - a run of blank lines collapsed to one, no trailing whitespace, and
---   exactly one newline at the end.
--- None of these depends on which two tokens ended up adjacent, so none
--- can go wrong the way `<const>` did in a token re-emitter.
---
--- It carries over where the lines break, and where they do not. It
--- never adds or removes a break: `if x then return end` written on one
--- line stays on one line, a call spread over five stays spread over
--- five, and an operator at the end of a line stays there. Wrapping is
--- a judgement about a whole line that no rule here can make, so it is
--- left to the author. A line that continues a statement is indented
--- from the brackets open where it starts ([`build.fix.ctx`]). The
--- breaks [`build.fix`] does add -- a statement to a line, a block
--- opened up -- are noted as the file is rendered, written into its
--- source by [`build.fix.breaks`], and rendered again.
---
--- One thing is added rather than decided or carried: where tl's parser
--- inserted a `;` to settle which of two readings a `f()` followed by
--- `(` had, the `;` is written out, so the source says what the
--- compiler had already decided.
---
--- Type syntax is written as original bytes throughout. tl's parser
--- keeps a type's meaning, not its text: a type object has a start
--- position, an end only where its syntax closes with a bracket, and,
--- for a record body, no trace of the comments between its fields.
--- Copying the bytes is the only rendering of a type that cannot lose
--- something.

local ast = require("build.ast")
local breaks = require("build.fix.breaks")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local stmt = require("build.fix.stmt")
local typescan = require("build.fix.typescan")
local type compiler = require("build.compiler")

local type Ctx = ctx_mod.Ctx

--- A rendered file, and the source with the line breaks it lacks
--- written in ([`build.fix.breaks`]).
local record Layout
  text: string
  --- `source` with a line break in front of each statement or closing
  --- keyword that must start a line, or nil when none is due.
  opened: string | nil
end

--- Write an already-parsed file back out, and say which line breaks
--- it is still due.
--- @param parsed ast.Parsed The AST and the token stream it came from
--- @param source string The source that parse read
--- @return Layout|nil The rendered source and the breaks it lacks, or nil when a construct is refused
--- @return string What was refused, on failure
local function laid_out(parsed: ast.Parsed, source: string): Layout | nil, string
  local c: Ctx = {
    em = emit.new(source, parsed.tokens),
    source = source,
    tokens = parsed.tokens,
    starts = ast.line_starts(source),
    scan = typescan.new(parsed.tokens),
    shift = 0,
    margin = -2,
    memo = {},
    refused = {},
    block = stmt.block,
    parted = {},
    leading = {},
    opens = {},
    header = 2,
    starting = false,
    closing = false,
    continues = {},
    constructs = {},
    ends = {},
    owned = {},
  }
  local hashbang = parsed.node.hashbang
  if hashbang ~= nil then
    -- The `#!` line is no statement and carries no comment, so nothing
    -- else writes it; the cursor moves past it as past any line written.
    emit.put(c.em, hashbang)
    c.em.line = 1
  end
  stmt.block(c, parsed.node)
  if #c.refused > 0 then
    local seen: {string:boolean} = {}
    local named: {string} = {}
    for _, what in ipairs(c.refused) do
      if not seen[what] then
        seen[what] = true
        named[#named + 1] = what
      end
    end
    return nil, "this renderer has no spelling for " .. table.concat(named, ", ")
  end
  local opened = breaks.broken(c)
  return { text = emit.done(c.em), opened = opened ~= source and opened or nil }
end

--- Write an already-parsed file back out.
--- @param parsed ast.Parsed The AST and the token stream it came from
--- @param source string The source that parse read
--- @return string|nil The rendered source, or nil when a construct is refused
--- @return string What was refused, on failure
local function rendered(parsed: ast.Parsed, source: string): string | nil, string
  local layout, trouble = laid_out(parsed, source)
  if layout == nil then
    return nil, trouble
  end
  return layout.text
end

--- Parse `source` and write it back out.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param source string
--- @param name string Filename used in diagnostics
--- @return string|nil The rendered source, or nil on a parse or refusal
--- @return string Error message on failure
local function render(built: compiler, source: string,
                      name: string): string | nil, string
  local parsed, trouble = ast.parse(built, source, name)
  if parsed == nil then
    return nil, trouble
  end
  return rendered(parsed, source)
end

local record RenderModule
  type Layout = Layout
  laid_out: function(parsed: ast.Parsed, source: string): Layout | nil, string
  render: function(built: compiler, source: string, name: string): string | nil, string
  rendered: function(parsed: ast.Parsed, source: string): string | nil, string
end

local M: RenderModule = {
  laid_out = laid_out,
  render = render,
  rendered = rendered,
}

return M
