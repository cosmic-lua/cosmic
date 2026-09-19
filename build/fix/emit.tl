--- The output buffer `build.fix` renders into, and the one place
--- comments and blank lines are placed.
---
--- The renderer never adds or removes a line break: every construct is
--- emitted from its own node's kind, but WHERE the source put a
--- newline, the output puts one too. That makes the cursor's own source
--- line the coordinate everything else hangs off, and it is why this
--- buffer tracks a source line rather than an output line.
---
--- Comments are not attached to AST nodes at all -- tl's lexer hangs
--- each one on the token that follows it -- so they are placed by line
--- instead. When the cursor moves from source line A to a later line B:
--- every comment still unwritten that sat on A is a trailing comment
--- and goes one space after whatever the output line already holds;
--- every comment on a line between them gets a line of its own, at its
--- own column; and a line in that gap that is blank and carries no
--- comment becomes one blank line, a run of them collapsing to one. A
--- comment inside a range the renderer wrote out verbatim (type syntax,
--- a record body) came along with the bytes, and `consume` is how the
--- renderer says so.
---
--- An own-line comment keeps its own column rather than borrowing the
--- indentation of whatever follows it, for the same reason every other
--- line here keeps its column: a comment can sit where no statement
--- does -- alone inside an empty branch, halfway down a multi-line
--- expression -- and there is nothing after it whose indentation would
--- be the right one to borrow.
---
--- The one comment in that gap that does NOT get a line of its own is a
--- long one (`--[[ ... ]]`) closing on the very line being moved to,
--- because the source wrote code after its `]]`. Ending it with a
--- newline like the others would add a break the source never had, so
--- `gap` reports the line it finished on and `advance` carries on along
--- that line rather than opening a new one.

local type compiler = require("build.compiler")

local record Emitter
  parts: {string}
  --- The source line the cursor sits on. It starts at 0, not 1, so the
  --- very first `advance` still counts as a move and a comment on line
  --- 1 is placed before whatever follows it rather than after.
  line: integer
  --- Whether source line `y` holds nothing but whitespace.
  blank: {integer:boolean}
  --- Every comment the token stream carries, in source order.
  comments: {compiler.Comment}
  --- The first comment not yet written out.
  at: integer
  --- Columns to move a preserved column by, the same `shift` the
  --- renderer applies everywhere else. An own-line comment keeps its
  --- own column, so it moves with the statement a rewrite moved.
  shift: integer
  --- How far the output line in progress is indented: the width of the
  --- spaces it opens with, whatever wrote them. A construct that opens
  --- a BLOCK mid-expression -- a function literal is the only one --
  --- reads this to find the column it is actually being written at,
  --- which is not the column its enclosing statement was written at
  --- once the literal has started a line of its own.
  indent: integer
  --- Whether that line still holds nothing but those spaces, which is
  --- what says the width above is finished growing.
  bare: boolean
end

--- How many newlines `text` carries. A long comment (`--[[ ... ]]`) and
--- a long string are the two things a single token's text spans lines
--- with, and both have to move the cursor with them.
--- @param text string
--- @return integer
local function newlines(text: string): integer
  local n = 0
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  return n
end

--- A fresh buffer over one parse: `source` for which lines are blank,
--- `tokens` for the comments they carry.
--- @param source string The file's own source text
--- @param tokens {compiler.Token} The token stream from the same parse
--- @return Emitter
local function new(source: string, tokens: {compiler.Token}): Emitter
  local blank: {integer:boolean} = {}
  local y = 1
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    blank[y] = line:match("^%s*$") ~= nil
    y = y + 1
  end
  local comments: {compiler.Comment} = {}
  for _, t in ipairs(tokens) do
    local carried = t.comments
    if carried ~= nil then
      for _, c in ipairs(carried) do
        comments[#comments + 1] = c
      end
    end
  end
  return { parts = {}, line = 0, blank = blank, comments = comments, at = 1,
           shift = 0, indent = 0, bare = true }
end

--- Follow `s` through the output line in progress. Every newline it
--- carries starts that line over, and the spaces a line opens with are
--- its indentation -- so this holds whether the line was opened by
--- `advance`, by a comment written into a gap, or by the middle of a
--- range copied out verbatim.
local function track(e: Emitter, s: string)
  if s == "" then
    return
  end
  local tail = s
  if s:find("\n", 1, true) ~= nil then
    e.indent = 0
    e.bare = true
    tail = s:match("[^\n]*$") or ""
  end
  if e.bare then
    local opening = tail:match("^ *") or ""
    e.indent = e.indent + #opening
    e.bare = #opening == #tail
  end
end

--- Append `text` without touching the cursor's own line.
local function put(e: Emitter, text: string)
  e.parts[#e.parts + 1] = text
  track(e, text)
end

--- Append `s`, moving the cursor past any newlines it carries.
local function text(e: Emitter, s: string)
  put(e, s)
  e.line = e.line + newlines(s)
end

--- Every comment still unwritten that sat on the cursor's own line or
--- earlier: a trailing comment, one space after whatever the output
--- line already holds.
local function trailing(e: Emitter)
  while e.at <= #e.comments and e.comments[e.at].y <= e.line do
    local c = e.comments[e.at]
    put(e, " " .. c.text)
    e.line = e.line + newlines(c.text)
    e.at = e.at + 1
  end
end

--- The leading whitespace of a line that begins at source column `x`.
local function indent_of(e: Emitter, x: integer): string
  local width = x - 1 + e.shift
  if width < 0 then
    width = 0
  end
  return string.rep(" ", width)
end

--- Write the own-line comments and blank lines of the gap between the
--- cursor's line and `y`.
---
--- A long comment (`--[[ ... ]]`) opening in the gap can CLOSE on `y`
--- itself, which is the one case a comment here is not on a line of its
--- own: the source wrote code after it on the same line. It is written
--- without the newline the others end in, and the second return says
--- which line the gap actually finished on, so the caller knows it is
--- already where it was moving to and has no break to write.
--- @param e Emitter
--- @param y integer The line being moved to
--- @return boolean Whether a blank line is still owed, which the caller
---   emits last so a run of blanks before `y` collapses to one
--- @return integer The line the gap finished on
local function gap(e: Emitter, y: integer): boolean, integer
  local pending = false
  local cy = e.line + 1
  while cy < y do
    if e.at <= #e.comments and e.comments[e.at].y == cy then
      if pending then
        put(e, "\n")
        pending = false
      end
      while e.at <= #e.comments and e.comments[e.at].y == cy do
        local c = e.comments[e.at]
        local spans = newlines(c.text)
        if cy + spans >= y then
          put(e, indent_of(e, c.x) .. c.text)
          e.at = e.at + 1
          return pending, cy + spans
        end
        put(e, indent_of(e, c.x) .. c.text .. "\n")
        cy = cy + spans
        e.at = e.at + 1
      end
    elseif e.blank[cy] and #e.parts > 0 then
      pending = true
    end
    cy = cy + 1
  end
  return pending, e.line
end

--- Put the cursor on source line `y`, indented to `indent`. When `y` is
--- the line the cursor already sits on, `inline` is written instead:
--- the renderer preserves a line break exactly where the source had
--- one, and preserves its absence just as exactly.
--- @param e Emitter
--- @param y integer The source line to move to
--- @param pad string The leading whitespace of the line being moved to
--- @param inline string What to write instead when no move is needed
local function advance(e: Emitter, y: integer, pad: string, inline: string)
  if y <= e.line then
    put(e, inline)
    return
  end
  if #e.parts > 0 then
    trailing(e)
    put(e, "\n")
  end
  local pending, ended = gap(e, y)
  if ended >= y then
    -- A long comment in the gap ran into `y` itself, so the output is
    -- already on the line being moved to and the break the source had
    -- before it has been written. Whatever follows the comment on that
    -- line is separated from it, not put under it.
    put(e, " ")
    e.line = y
    return
  end
  if pending then
    put(e, "\n")
  end
  put(e, pad)
  e.line = y
end

--- Drop every comment at or before (`y`, `x`) as already written: the
--- renderer wrote a range of the original source out verbatim, and the
--- comments inside that range came along with the bytes.
local function consume(e: Emitter, y: integer, x: integer)
  while e.at <= #e.comments do
    local c = e.comments[e.at]
    if c.y > y or (c.y == y and c.x > x) then
      return
    end
    e.at = e.at + 1
  end
end

--- The rendered source: whatever is left of the comment stream after
--- the last statement, then exactly one closing newline. Trailing blank
--- lines are not carried over, which is the one place the buffer drops
--- something the source had.
--- @param e Emitter
--- @return string
local function done(e: Emitter): string
  trailing(e)
  if e.at <= #e.comments then
    local last = e.comments[#e.comments]
    advance(e, last.y + newlines(last.text) + 1, "", "")
  else
    put(e, "\n")
  end
  return (table.concat(e.parts))
end

local record EmitModule
  type Emitter = Emitter
  new: function(source: string, tokens: {compiler.Token}): Emitter
  put: function(e: Emitter, text: string)
  text: function(e: Emitter, s: string)
  advance: function(e: Emitter, y: integer, pad: string, inline: string)
  consume: function(e: Emitter, y: integer, x: integer)
  done: function(e: Emitter): string
  newlines: function(text: string): integer
end

local M: EmitModule = {
  new = new,
  put = put,
  text = text,
  advance = advance,
  consume = consume,
  done = done,
  newlines = newlines,
}

return M
