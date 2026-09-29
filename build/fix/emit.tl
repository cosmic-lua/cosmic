--- The output buffer `build.fix` renders into, and the one place
--- comments and blank lines are placed.
---
--- The renderer never adds or removes a line break. Each construct is
--- emitted from its node's kind, but wherever the source had a newline
--- the output has one. So the coordinate everything hangs off is the
--- cursor's source line, and the buffer tracks that rather than an
--- output line.
---
--- tl's lexer hangs each comment on the token that follows it, so
--- comments are placed by line, not attached to AST nodes. When the
--- cursor moves from source line A to a later line B:
--- - every unwritten comment on A is a trailing comment and goes one
---   space after what the output line already holds;
--- - every comment on a line between them gets a line of its own, at
---   its own column;
--- - a blank line in the gap with no comment becomes one blank line,
---   and a run of them collapses to one.
--- A comment inside a range written verbatim (type syntax, a record
--- body) came along with the bytes, and `consume` says so.
---
--- An own-line comment keeps its own column rather than borrowing the
--- indentation of what follows it. It can sit where no statement does,
--- alone inside an empty branch or halfway down a multi-line
--- expression, and nothing after it has the right indentation to
--- borrow.
---
--- One line in the gap can hold several comments: a long one
--- (`--[[ ... ]]`) closing on it followed by another, or two long ones
--- in a row. They are written as a run: the first at its own column,
--- each later one a space along, and only the last ending in a line
--- break. When the run reaches the line being moved to because the
--- source wrote code after a `]]`, even that break is not written.
--- `gap` reports the line it finished on and `advance` continues along
--- that line.
---
--- A comment on that line with no code after it is the line's trailing
--- comment (`q ]] local x = 2 -- why`) and is not part of the run. It
--- goes after the statement, since a `--` comment written in front of
--- the code would comment it out. A comment has code after it when the
--- lexer hung it on a token of its own last line.
---
--- A run can also begin on the line being moved to. `--[[ q ]] print(1)`
--- opens its line with a comment and writes the code behind it, so the
--- run begins and ends on that line and `advance` continues along it.
--- Such a comment starts a run because the source wrote code after it
--- and only whitespace before it. A comment with code before it as
--- well (`f(--[[ x ]] 1)`) opens no line: `ahead` writes it where it
--- was, in front of the code it introduces, with no line break
--- involved. `ahead` writes it in front of the next node, which is one
--- token too far when an operator the renderer writes itself stands
--- between the two (see `ahead`).
---
--- Because a comment can open a statement's line, `opening_column`
--- gives where that line began, not where the statement's first keyword
--- sits. A statement the renderer indents elsewhere moves by the
--- distance its line moves, and every continuation line moves with it.

local String = require("cosmic.string")

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
  --- Whether the comment at the same index has CODE after it on the
  --- line it ends on, which is what separates a comment the code was
  --- written around from the trailing comment of a line.
  code_after: {integer:boolean}
  --- Whether the comment at the same index has nothing but whitespace
  --- in front of it on the line it STARTS on, which is what says a
  --- comment is what its line opens with rather than something written
  --- into the middle of one.
  opens_line: {integer:boolean}
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
  local wrote: {integer:string} = {}
  local y = 1
  for line in String.lines(source) do
    blank[y] = line:match("^%s*$") ~= nil
    wrote[y] = line
    y = y + 1
  end
  local comments: {compiler.Comment} = {}
  -- tl's lexer hangs a comment on the token that FOLLOWS it, so a
  -- comment whose token sits on the line the comment ends on is one the
  -- source wrote code after; any other is the last thing on its line.
  -- The one token that is not code is the end of the file, which a
  -- comment the source left unterminated by a newline lands on: nothing
  -- follows it there, whatever line it was stamped at.
  local code_after: {integer:boolean} = {}
  local opens_line: {integer:boolean} = {}
  for _, t in ipairs(tokens) do
    local carried = t.comments
    if carried ~= nil then
      local ends_file = t.tk == "$EOF$"
      for _, c in ipairs(carried) do
        comments[#comments + 1] = c
        code_after[#comments] = not ends_file and t.y == c.y + newlines(c.text)
        opens_line[#comments] =
          (wrote[c.y] or ""):sub(1, c.x - 1):match("^%s*$") ~= nil
      end
    end
  end
  return { parts = {}, line = 0, blank = blank, comments = comments,
           code_after = code_after, opens_line = opens_line, at = 1,
           shift = 0, indent = 0, bare = true }
end

--- Follow `s` through the output line in progress. A newline starts the
--- line over, and the spaces a line opens with are its indentation,
--- whether `advance`, a comment written into a gap, or the middle of a
--- verbatim range opened the line.
---
--- Only spaces count, one per column: a line opening with tabs reads as
--- no indentation. Nothing here writes a tab, so only a verbatim range
--- can open a line with one, and only a function literal opening a
--- block mid-line reads the number back. That literal would then be
--- indented from column zero. This is accepted: the output is stable
--- and says the same thing, at a column the literal was not written at.
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
--- The comments a line carries are written as a run: the next one
--- starts on the line the one before it ended on, so it goes a space
--- along rather than under it, and the line break comes after the last.
--- A long comment (`--[[ ... ]]`) opening in the gap can close on `y`,
--- and a run can open on `y`. Both are the source having written code
--- after it, and the run is then written without the newline the
--- others end in. The second return says which line the gap finished
--- on, so the caller knows it is already where it was moving to and has
--- no break to write.
---
--- Once the run has reached `y`, it takes only the comments the source
--- wrote code after, since those sit in front of the code being moved
--- to. A comment with nothing after it on that line is the line's
--- trailing comment and is left for `trailing` to write after the
--- statement, because a `--` comment in front of the code would
--- comment the line out.
---
--- A run starts on `y` only when the comment is what that line opens
--- with. `--[[ q ]] print(1)` is a run of one and the statement is
--- written behind it. `f(--[[ x ]] 1)` has code before the comment
--- too, so it opens nothing and `ahead` writes it where the source had
--- it.
--- @param e Emitter
--- @param y integer The line being moved to
--- @return boolean Whether a blank line is still owed, which the caller
---   emits last so a run of blanks before `y` collapses to one
--- @return integer The line the gap finished on
local function gap(e: Emitter, y: integer): boolean, integer
  local pending = false
  local cy = e.line + 1
  while cy <= y do
    local carried = e.at <= #e.comments and e.comments[e.at].y == cy
    if carried and (cy < y or (e.opens_line[e.at] and e.code_after[e.at])) then
      if pending then
        put(e, "\n")
        pending = false
      end
      local ended = cy
      local opened = false
      while e.at <= #e.comments and e.comments[e.at].y == ended
            and (ended < y or e.code_after[e.at]) do
        local c = e.comments[e.at]
        put(e, (opened and " " or indent_of(e, c.x)) .. c.text)
        ended = ended + newlines(c.text)
        opened = true
        e.at = e.at + 1
      end
      if ended >= y then
        return pending, ended
      end
      put(e, "\n")
      cy = ended
    elseif cy < y and e.blank[cy] and #e.parts > 0 then
      pending = true
    end
    cy = cy + 1
  end
  return pending, e.line
end

--- Every comment still unwritten that the source wrote on line `y` in
--- front of column `x`, with code after it. It stands between where the
--- output is and what is about to be written, so it is written in front
--- of that, with one space between.
---
--- This places a comment that no line break is involved with, one
--- written into the middle of a line like the `--[[ x ]]` of
--- `f(--[[ x ]] 1)`. Only a long comment can have code after it, since
--- a `--` comment runs to the end of its line, so nothing written here
--- can comment out what follows.
---
--- The column stops the renderer dragging a comment backwards past code
--- it was written behind. `local x = --[[ c ]] 1` leads to the name `x`
--- before the value, and the comment belongs to neither the name nor
--- anything else it merely sits after.
---
--- A comment written in front of an operator or keyword the renderer
--- writes itself moves one token along. `advance` runs only when a
--- node's lead is about to be written, and the tokens between two nodes
--- (`=`, `,`, `.`, `:`, `(`, `in`, `function`, an attribute's `<const>`)
--- are written by `put` and `text`, which ask nothing about comments.
--- So the comment waits for the next node's lead, by when the operator
--- is in the buffer: `local a --[[ c ]] = 1` becomes
--- `local a = --[[ c ]] 1`, and `for k --[[ q ]], v in t do` becomes
--- `for k, --[[ q ]] v in t do`. Only placement suffers. The comment is
--- kept, so `equiv.same_comments` holds, and the moved result is its
--- own fixed point. Nothing in this tree meets it, since it needs a
--- comment inside a line with code on both sides, and a `---` doc
--- comment runs to the end of its line.
--- @param e Emitter
--- @param y integer The source line being moved to
--- @param x integer The column on it the next thing written sits at
-- TODO: give every token the renderer writes itself a source position,
-- so comments standing before it are flushed by that write. The tree
-- has none (tl records no position for an assignment's `=`), so it
-- would come from the token stream `build.fix.typescan` already
-- indexes: a cursor over it, advanced by every write site in
-- `build.fix.stmt`, `.expr` and `.sig`. Comment placement would then
-- belong to every token write, not to node leads alone, which is the
-- model this module would be rebuilt on.
local function ahead(e: Emitter, y: integer, x: integer)
  while e.at <= #e.comments do
    local c = e.comments[e.at]
    if not e.code_after[e.at] or c.y ~= y or c.x >= x then
      return
    end
    put(e, c.text .. " ")
    e.line = e.line + newlines(c.text)
    e.at = e.at + 1
  end
end

--- The column source line `y` opens at, for a construct whose first
--- character sits at column `x`. That is `x`, unless the source opened
--- the line with a comment and wrote the construct behind it
--- (`--[[ q ]] print(1)`). A statement indented elsewhere moves by the
--- distance its line moves, so that distance is measured from the
--- line's column, not the keyword's, which the comment pushed along.
--- @param e Emitter
--- @param y integer The source line
--- @param x integer The column the construct's first character sits at
--- @return integer
local function opening_column(e: Emitter, y: integer, x: integer): integer
  for i = e.at, #e.comments do
    local c = e.comments[i]
    if c.y >= y then
      if c.y == y and c.x < x and e.opens_line[i] and e.code_after[i] then
        return c.x
      end
      return x
    end
  end
  return x
end

--- Put the cursor on source line `y`, indented to `indent`. When `y` is
--- the line the cursor already sits on, `inline` is written instead:
--- the renderer preserves a line break exactly where the source had
--- one, and preserves its absence just as exactly. Either way, a
--- comment the source wrote in front of what is being moved to is
--- written in front of it here.
--- @param e Emitter
--- @param y integer The source line to move to
--- @param pad string The leading whitespace of the line being moved to
--- @param inline string What to write instead when no move is needed
--- @param x integer The column on `y` the next thing written sits at
local function advance(e: Emitter, y: integer, pad: string, inline: string,
                       x: integer)
  if y <= e.line then
    put(e, inline)
    ahead(e, y, x)
    return
  end
  if #e.parts > 0 then
    trailing(e)
    if e.line >= y then
      -- The trailing comment of the cursor's own line spanned lines and
      -- closed on the one being moved to, so the break the source wrote
      -- in front of the code is inside that comment's own text and
      -- there is none left to write. What follows a `]]` is separated
      -- from it, the same as after a run that reaches `y`.
      put(e, " ")
      e.line = y
      return
    end
    put(e, "\n")
  end
  local pending, ended = gap(e, y)
  if ended >= y then
    -- A comment run in the gap ran into `y` itself, so the output is
    -- already on the line being moved to and the break the source had
    -- before it has been written. Whatever follows the run on that line
    -- is separated from it, not put under it.
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
    -- A line past the end of the last comment, which the file has no
    -- code on at all: column 1, since nothing there was written behind
    -- anything.
    local last = e.comments[#e.comments]
    advance(e, last.y + newlines(last.text) + 1, "", "", 1)
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
  advance: function(e: Emitter, y: integer, pad: string, inline: string,
                    x: integer)
  consume: function(e: Emitter, y: integer, x: integer)
  done: function(e: Emitter): string
  opening_column: function(e: Emitter, y: integer, x: integer): integer
end

local M: EmitModule = {
  new = new,
  put = put,
  text = text,
  advance = advance,
  consume = consume,
  done = done,
  opening_column = opening_column,
}

return M
