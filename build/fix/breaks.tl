--- The line breaks `cosmic fix` adds: one statement to a line, and a
--- block on one line only where it reads as one.
---
--- The renderer carries over every line break the source has and adds
--- none ([`build.fix.render`]), so this pass is the one place a break is
--- decided. It judges from what the renderer gathered while writing the
--- file -- every block, and the column each construct ended at in the
--- output -- so it walks nothing again, and a file that needs no break
--- costs a few lookups per statement. It writes a line break into the
--- source in front of each statement or closing keyword that must start
--- a line, and the renderer then indents those lines as it indents any
--- other. Each break keeps what follows it at the column it had, so a
--- continuation line of the statement moved keeps its place relative to
--- that statement.
---
--- A statement shares no line with the statement before it. A block --
--- the body of an `if`, a loop, a `do`, a `repeat` or a function --
--- stays on one line only when all of these hold:
--- - each of its bodies holds at most one statement, and that statement
---   is no `if`, loop, `do`, `repeat` or function statement (a function
---   literal inside it is a block of its own, judged alone);
--- - an `if` has at most two branches;
--- - the construct ends by column 100 (`width`) in the output, counted
---   in bytes as every column here is.
--- Any other block gets each of its statements and its closing keywords
--- (`elseif`, `else`, `end`, `until`) on a line of its own. A `local
--- macroexp` is left as written: its body is one `return` by its
--- grammar.
---
--- Statements are parted first and blocks judged on a later pass, once
--- each statement sits at the column it keeps, and a block inside one
--- being opened is judged on the pass after that; [`fix.source`]
--- renders and judges again until no break is due.
---
--- A break parts code from code. A statement behind the `]]` of a long
--- comment, or behind a `;` that opens its line, stays there: what
--- opens that line is no statement, and the renderer keeps a comment
--- and a `;` where the source put them.
---
--- A `;` a break replaces is dropped with it. One a comment hangs on is
--- left, since the parser would attach the comment to the statement
--- after it, and so is one a node opens on (a block's, an empty
--- `return` list's). The parser keeps a `;` as a flag on the statement,
--- a flag [`build.fix.equiv`] ignores.

local ast = require("build.ast")
local stmt = require("build.fix.stmt")
local typescan = require("build.fix.typescan")
local type compiler = require("build.compiler")
local ctx_mod = require("build.fix.ctx")

local type Node = ast.Node
local type Ctx = ctx_mod.Ctx

--- The column a one-line block must end by.
local width <const> = 100

--- Statement kinds that open a block of their own.
local opens_block: {string:boolean} = {
  ["if"] = true,
  ["while"] = true,
  ["fornum"] = true,
  ["forin"] = true,
  ["do"] = true,
  ["repeat"] = true,
  ["local_function"] = true,
  ["global_function"] = true,
  ["record_function"] = true,
  ["local_macroexp"] = true,
}

--- One place a line must start: the byte it starts at, and whether a
--- `;` run in front of it may be dropped.
local record Break
  at: integer
  drop: boolean
  y: integer
  x: integer
  --- Whether it is for a closing keyword, which the break goes right in
  --- front of: a comment before it stays behind the code it followed.
  closer: boolean
end

--- A construct to open up: the breaks it wants, and where it starts
--- and ends, to tell which constructs hold which.
local record Opening
  wants: {Break}
  first: ast.Position
  last: ast.Position
end

local record Pass
  c: Ctx
  breaks: {integer:Break}
end

local function offset(p: Pass, y: integer, x: integer): integer
  return ast.offset_of(p.c.starts, y, x)
end

--- Whether token `i` is a `;` a break may drop: not one a comment
--- hangs on, which the parser attaches to the statement after it once
--- the `;` is gone, nor one a node opens on.
local function droppable(p: Pass, i: integer): boolean
  local t = p.c.scan.tokens[i]
  return t ~= nil and t.tk == ";" and t.comments == nil and not p.c.owned[i]
end

--- The last code token before (`y`, `x`), passing over `;`s when
--- `drop` is set, if it ends on line `y`: nil when nothing but comments
--- and `;`s stands in front of (`y`, `x`) on its line.
local function sharing(p: Pass, y: integer, x: integer, drop: boolean): compiler.Token | nil
  local scan = p.c.scan
  local j = typescan.index_before(scan, y, x)
  while drop and droppable(p, j) do
    j = j - 1
  end
  local t = scan.tokens[j]
  if t == nil then
    return nil
  end
  local _, lines = t.tk:gsub("\n", "")
  if t.y + lines ~= y then
    return nil
  end
  return t
end

local function want(p: Pass, b: Break)
  local known = p.breaks[b.at]
  if known == nil then
    p.breaks[b.at] = b
  elseif b.drop then
    known.drop = true
  end
end

local function wanted(p: Pass, y: integer, x: integer, drop: boolean, closer: boolean): Break
  return { at = offset(p, y, x), drop = drop, y = y, x = x, closer = closer }
end

--- Whether (`ay`, `ax`) comes before (`by`, `bx`).
local function before(ay: integer, ax: integer, by: integer, bx: integer): boolean
  return ay < by or (ay == by and ax < bx)
end

--- The bodies of block construct `n` and the places its closing
--- keywords sit, or nil when `n` opens no block this pass lays out.
local function shape(n: Node): {Node}, {ast.Position}
  local kind = n.kind
  local bodies: {Node} = {}
  local closers: {ast.Position} = {}
  if kind == "if" then
    for i, b in ipairs(n.if_blocks or {}) do
      if i > 1 then
        closers[#closers + 1] = { y = b.y, x = b.x }
      end
      local body = b.body
      if body ~= nil then
        bodies[#bodies + 1] = body
      end
    end
  elseif kind == "repeat" then
    local body = n.body
    if body == nil or body.yend == nil or body.xend == nil then
      return nil, nil
    end
    bodies[1] = body
    -- The body's recorded end is its `until`'s last column.
    closers[1] = { y = body.yend, x = body.xend - #"until" + 1 }
    return bodies, closers
  elseif (opens_block[kind] and kind ~= "local_macroexp") or kind == "function" then
    local body = n.body
    if body ~= nil then
      bodies[1] = body
    end
  else
    return nil, nil
  end
  if n.yend == nil or n.xend == nil then
    return nil, nil
  end
  -- A construct's recorded end is its `end`'s last column.
  closers[#closers + 1] = { y = n.yend, x = n.xend - #"end" + 1 }
  return bodies, closers
end

--- Whether a block on one line reads as one ([`build.fix.breaks`]).
local function fits_one_line(n: Node, bodies: {Node}, ending: ctx_mod.Ending): boolean
  if n.kind == "if" and #bodies > 2 then
    return false
  end
  for _, body in ipairs(bodies) do
    if #body > 1 or (#body == 1 and opens_block[body[1].kind]) then
      return false
    end
  end
  return ending.column <= width
end

--- Whether any body of construct `n` opens on a line already open, or
--- any of its `elseif`s or `else`s does.
local function continues(c: Ctx, n: Node): boolean
  local blocks = n.if_blocks
  if blocks == nil then
    local body = n.body
    return body ~= nil and c.continues[body] == true
  end
  for _, b in ipairs(blocks) do
    local body = b.body
    if c.continues[b] or (body ~= nil and c.continues[body]) then
      return true
    end
  end
  return false
end

--- How block construct `n` is to be opened up, or nil when it is to be
--- left as it is.
local function construct(p: Pass, n: Node): Opening | nil
  local ending = p.c.ends[n]
  if ending == nil or (not ending.inline and not continues(p.c, n)) then
    -- Each statement and closing keyword already opens its line.
    return nil
  end
  local bodies, closers = shape(n)
  if bodies == nil then
    return nil
  end
  local firsts: {ast.Position} = {}
  for _, body in ipairs(bodies) do
    local first = body[1]
    if first ~= nil then
      firsts[#firsts + 1] = stmt.start(p.c, first)
    end
  end
  -- On one line: every statement and closing keyword continues the
  -- line before it, and all of them are on the line the construct's
  -- last token is.
  local inline = true
  local last = ending.line
  for _, at in ipairs(firsts) do
    inline = inline and at.y == last and sharing(p, at.y, at.x, true) ~= nil
  end
  for _, at in ipairs(closers) do
    inline = inline and at.y == last and sharing(p, at.y, at.x, true) ~= nil
  end
  if inline and fits_one_line(n, bodies, ending) then
    return nil
  end
  local wants: {Break} = {}
  for _, at in ipairs(firsts) do
    wants[#wants + 1] = wanted(p, at.y, at.x, false, false)
  end
  for _, at in ipairs(closers) do
    wants[#wants + 1] = wanted(p, at.y, at.x, true, true)
  end
  -- A `repeat` ends with its condition, which may hold constructs of
  -- its own, so it reaches to the end of the line it ends on.
  local reach = n.kind == "repeat" and { y = ending.line, x = math.maxinteger }
    or closers[#closers]
  return { wants = wants, first = stmt.start(p.c, n), last = reach }
end

--- Whether opening `outer` holds opening `inner`.
local function holds(outer: Opening, inner: Opening): boolean
  return outer ~= inner
    and before(outer.first.y, outer.first.x, inner.first.y, inner.first.x)
    and not before(outer.last.y, outer.last.x, inner.last.y, inner.last.x)
end

--- `out` with a line opened in front of `b`: right after `t`, the code
--- token before it, so a comment between the two opens the new line
--- and the statement follows it there. Whatever follows the break
--- keeps the column it had, and `out` is unchanged in front of `b`'s
--- run, which is how breaks are written last first.
local function open_line(p: Pass, out: string, b: Break, t: compiler.Token): string
  local from = offset(p, t.y, t.x) + #t.tk
  local source = p.c.source
  local between = source:sub(from, b.at - 1)
  if b.drop then
    -- The run holds code only as `;`s; a `--` comment cannot stand in
    -- front of code on its line, and a long one holds no `;` the scan
    -- would stop at, since it is no token.
    local kept: {string} = {}
    local i = typescan.index_before(p.c.scan, b.y, b.x)
    local cut = b.at
    while droppable(p, i) do
      local semi = p.c.scan.tokens[i]
      local o = offset(p, semi.y, semi.x)
      table.insert(kept, 1, source:sub(o + 1, cut - 1))
      cut = o
      i = i - 1
    end
    table.insert(kept, 1, source:sub(from, cut - 1))
    between = table.concat(kept)
  end
  if b.closer then
    -- The break goes right in front of the keyword, so a comment
    -- before it trails the code it followed: an own-line comment keeps
    -- its column, and the keyword's line is indented apart from it.
    local trailing = between:gsub("%s+$", "")
    return out:sub(1, from - 1) .. trailing .. "\n" .. string.rep(" ", b.x - 1) .. out:sub(b.at)
  end
  local rest = between:sub(#(between:match("^%s*") or "") + 1)
  -- What opens the new line is placed so the statement or keyword the
  -- break is for keeps its column, and its continuation lines with it.
  local column = b.x - 1 - #rest
  if column < 0 then
    column = 0
  end
  return out:sub(1, from - 1) .. "\n" .. string.rep(" ", column) .. rest .. out:sub(b.at)
end

--- The source with every break `p` holds written in.
local function written(p: Pass): string
  local edits: {Break} = {}
  local after: {Break:compiler.Token} = {}
  for _, b in pairs(p.breaks) do
    local t = sharing(p, b.y, b.x, b.drop)
    if t ~= nil then
      edits[#edits + 1] = b
      after[b] = t
    end
  end
  table.sort(edits, function(a: Break, b: Break): boolean return a.at > b.at end)
  local out = p.c.source
  for _, b in ipairs(edits) do
    out = open_line(p, out, b, after[b])
  end
  return out
end

--- The source `c` rendered, with a line break in front of every
--- statement and closing keyword that must start a line, judged from
--- what the render gathered (the context's `parted`, `continues`,
--- `constructs` and `ends`).
--- @param c Ctx The context a whole file was just rendered with
--- @return string The source, broken where it must be, statements before
--- blocks; `c.source` itself when no break is due
local function broken(c: Ctx): string
  local p: Pass = { c = c, breaks = {} }
  -- Statements are parted first, and blocks judged on the next pass,
  -- once each statement sits at the column it will keep: a block
  -- behind another statement on its line is judged too wide otherwise.
  for _, s in ipairs(c.parted) do
    local at = stmt.start(c, s)
    want(p, wanted(p, at.y, at.x, true, false))
  end
  local out = written(p)
  if out ~= c.source then
    return out
  end
  -- A construct held by another that opens up this pass waits for the
  -- next: it is judged too wide otherwise, at the column it had behind
  -- the one around it.
  local openings: {Opening} = {}
  for _, n in ipairs(c.constructs) do
    local opening = construct(p, n)
    if opening ~= nil then
      openings[#openings + 1] = opening
    end
  end
  for _, inner in ipairs(openings) do
    local held = false
    for _, outer in ipairs(openings) do
      held = held or holds(outer, inner)
    end
    if not held then
      for _, b in ipairs(inner.wants) do
        want(p, b)
      end
    end
  end
  return written(p)
end

local record BreaksModule
  broken: function(c: Ctx): string
end

local M: BreaksModule = {
  broken = broken,
}

return M
