--- One parsed file, written back out as source.
---
--- This is the second half of `cosmic fix`: parse, apply the structural
--- rules, render. Rendering is what makes the result canonical text
--- rather than a splice, and it is deliberately the ONLY way a rewrite
--- reaches the file -- a rule changes nodes, never bytes.
---
--- The line between what the renderer decides and what it carries over
--- is worth stating plainly, because it is the whole design:
---
--- The renderer decides everything a line HOLDS. Every keyword,
--- operator, separator and bracket, and the spacing around each. A
--- variable attribute (`x <const>`) as one unit attached to the name. A
--- type annotation as `: ` and then the type's own bytes. A statement's
--- indentation: two columns per level of block, and a block's closing
--- keyword lined up with the statement that opened it. One space before
--- a trailing comment. A comma after the last entry of a table that
--- closes on a line of its own, and none on one that does not. A run of
--- blank lines collapsed to one. No trailing whitespace anywhere, and
--- exactly one newline at the end. None of these is a question about
--- which two tokens ended up adjacent, which is why none of them can go
--- the way `<const>` went in a token re-emitter.
---
--- The renderer carries over where the lines BREAK, and where they do
--- not. It never adds a break and never removes one: `if x then return
--- end` written on one line stays on one line, a call spread over five
--- stays spread over five, and an operator written at the end of a line
--- rather than the start of the next stays there. Wrapping is a
--- judgement about a whole line that no rule here is in a position to
--- make, so it is left to the author, and a line that continues a
--- statement keeps its column relative to that statement.
---
--- One thing is added rather than decided or carried: where tl's own
--- parser inserted a `;` to settle which of two readings a `f()`
--- followed by a `(` had, that `;` is written out, so the source says
--- what the compiler had already decided.
---
--- Type syntax is written as original bytes throughout. tl's parser
--- keeps a type's MEANING, not its text: a type object has a start
--- position, no end, and, for a record body, no trace of the comments
--- between its fields. Copying the bytes is the only rendering of a
--- type that cannot lose something.

local ast = require("build.ast")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local stmt = require("build.fix.stmt")
local typescan = require("build.fix.typescan")
local type compiler = require("build.compiler")

local type Ctx = ctx_mod.Ctx

--- Write an already-parsed file back out.
--- @param parsed ast.Parsed The AST and the token stream it came from
--- @param source string The source that parse read
--- @return string|nil The rendered source, or nil when a construct is refused
--- @return string What was refused, on failure
local function rendered(parsed: ast.Parsed, source: string): string | nil, string
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
  }
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
  return emit.done(c.em)
end

--- Parse `source` and write it back out.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
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
  render: function(built: compiler, source: string, name: string): string | nil, string
  rendered: function(parsed: ast.Parsed, source: string): string | nil, string
end

local M: RenderModule = {
  render = render,
  rendered = rendered,
}

return M
