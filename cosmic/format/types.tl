--- Which tokens on a line are a TYPE rather than code.
---
--- Its own file because it answers a different question from its
--- neighbour. `rules.tl` asks how much a line indents and whether two
--- tokens need a space between them -- both decidable from the tokens
--- in front of it. This asks whether a token is part of a type
--- annotation, which is not: a type can wrap across lines, so the
--- answer depends on what the PREVIOUS line left open.
---
--- That one carried bit is the whole difficulty, and every bug this
--- file exists to prevent is a place it was dropped. A `function` in
--- type position read as a definition; a wrapped type's `)` counted as
--- an ordinary closer; a comment between `:` and its type resetting
--- the bit. Each indents the rest of the file into a body no `end`
--- ever closes, and each is invisible to the gate, because a
--- formatter's output is idempotent: run it twice and it re-blesses
--- its own damage.

--- An item in the output stream: either a token or a comment.
---
--- Declared HERE, and imported by `rules.tl` and the formatter, because
--- two declarations of one shape are two nominal types to Teal: a
--- line's items would not pass across the seam. This module is the one
--- underneath, so the shared contract lives at the bottom.
---
--- An interface, so the formatter's richer Item (which caches newline
--- counts) subtypes it and every rule function stays fully typed.
local interface Item
  y: integer
  x: integer
  tk: string
  kind: string
end

--- Determine if a `function` keyword is a block-opening function definition
--- vs a function TYPE annotation.
---
--- `continues_type` carries the one fact a per-line scan cannot see: the
--- PREVIOUS line ended in `as` or `:`, so this line opens in type
--- position and a leading `function` is the type it was waiting for.
--- Without it, `local f = g as\n  function(x: T): U` reads as a
--- definition and indents the rest of the file into a body no `end`
--- closes -- the same failure the return-list marking below exists to
--- prevent, one line-break further along.
local function is_function_block_opener(line_items: {Item}, func_idx: integer,
    continues_type?: boolean): boolean
  if continues_type then
    local first: Item = nil
    for _, item in ipairs(line_items) do
      if item.kind ~= "comment" then
        first = item
        break
      end
    end
    if first and first == line_items[func_idx] then
      return false
    end
  end
  -- `type X = function(...)` (optionally local/global-prefixed) declares a
  -- function TYPE alias: no body follows, so it never opens a block.
  -- Without this, everything after such an alias is indented into a
  -- phantom function body that no `end` ever closes.
  local first = line_items[1]
  local second = line_items[2]
  if first and (first.tk == "type"
    or ((first.tk == "local" or first.tk == "global")
      and second and second.tk == "type")) then
    return false
  end
  local paren_depth = 0
  for i = func_idx - 1, 1, -1 do
    local item = line_items[i]
    if item.kind == "comment" then
      -- skip
    elseif item.tk == ")" then
      paren_depth = paren_depth + 1
    elseif item.tk == "(" then
      if paren_depth > 0 then
        paren_depth = paren_depth - 1
      else
        return true
      end
    elseif paren_depth > 0 then
      -- Inside balanced parens; skip
    elseif item.tk == ":" or item.tk == "as" then
      return false
    elseif item.tk == "=" or item.tk == "," then
      return true
    elseif item.kind == "keyword" and (item.tk == "local" or item.tk == "return") then
      return true
    else
      -- Keep scanning
    end
  end
  return true
end

--- Mark every item belonging to the function TYPE starting at `idx`,
--- so the second pass counts none of them as opening a block.
---
--- The return type is the half that matters. It is a LIST, and its
--- members can be unions: `function(a: A): T | nil, U | nil`. Marking
--- only a parenthesized return leaves `function` inside such a list
--- unmarked, and a backward scan from there hits the `,` and reads it
--- as a definition — so the rest of the file indents into a body that
--- no `end` ever closes. `_types/cosmo/lsqlite3.d.tl` is a real file
--- that does this (`config`, returning `function | nil`).
--- @param line_items {Item} The line's items
--- @param idx integer Index of the `function` keyword
--- @param type_ctx {integer: boolean} Marks, updated in place
local function mark_return_list(line_items: {Item}, at: integer,
    type_ctx: {integer: boolean})
  -- The return list runs to the end of the line, stopping at `=` (a
  -- value follows, and it may legitimately open a block) or at a
  -- closer belonging to an enclosing bracket, as in `{function(): T}`.
  type_ctx[at] = true
  local depth = 0
  for k = at + 1, #line_items do
    local tk = line_items[k].tk
    if tk == "(" or tk == "[" or tk == "{" then
      depth = depth + 1
    elseif tk == ")" or tk == "]" or tk == "}" then
      if depth == 0 then
        return
      end
      depth = depth - 1
    elseif depth == 0 and (tk == "=" or tk == ";") then
      return
    end
    type_ctx[k] = true
  end
end

local function mark_function_type(line_items: {Item}, idx: integer,
    type_ctx: {integer: boolean})
  type_ctx[idx] = true
  local depth = 0
  local j = idx + 1
  while j <= #line_items do
    type_ctx[j] = true
    if line_items[j].tk == "(" then
      depth = depth + 1
    elseif line_items[j].tk == ")" then
      depth = depth - 1
      if depth == 0 then
        j = j + 1
        break
      end
    end
    j = j + 1
  end
  if j <= #line_items and line_items[j].tk == ":" then
    mark_return_list(line_items, j, type_ctx)
  end
end

--- Mark a type the PREVIOUS line left open.
---
--- A function type that wraps leaves its `(` unclosed, and the matching
--- `)` lands at the start of the next line, where no single-line scan
--- can claim it: the `(` is on the line before. Without this the second
--- pass reads it as an ordinary closer, the line DEDENTS with no
--- matching indent, and every line after it sits one level too shallow
--- to the end of the file.
---
--- Nothing catches that but a test. A formatter's output is
--- idempotent, so the damage is a fixpoint and the gate passes on it
--- every run.
---
--- A `)` at depth 0 here is the carried one; deeper brackets are this
--- line's own and balance normally.
--- @param line_items {Item} The line's items
--- @param type_ctx {integer: boolean} Marks, updated in place
local function mark_carried_type(line_items: {Item},
    type_ctx: {integer: boolean})
  local depth = 0
  local j = 1
  while j <= #line_items do
    type_ctx[j] = true
    if line_items[j].tk == "(" then
      depth = depth + 1
    elseif line_items[j].tk == ")" then
      if depth == 0 then
        j = j + 1
        break
      end
      depth = depth - 1
    end
    j = j + 1
  end
  if j <= #line_items and line_items[j].tk == ":" then
    mark_return_list(line_items, j, type_ctx)
  end
end

--- Every item on this line that belongs to a type rather than to code.
--- @param line_items {Item} The line's items
--- @param continues_type boolean Whether the previous line left a type open
--- @return {integer: boolean} The marks
local function type_marks(line_items: {Item},
    continues_type?: boolean): {integer: boolean}
  local type_ctx: {integer: boolean} = {}
  if continues_type then
    mark_carried_type(line_items, type_ctx)
  end
  for idx, item in ipairs(line_items) do
    if item.kind == "keyword" and item.tk == "function" and not type_ctx[idx]
    and not is_function_block_opener(line_items, idx, continues_type) then
      mark_function_type(line_items, idx, type_ctx)
    end
  end
  return type_ctx
end

--- Does this line leave the next one in TYPE position?
---
--- Three ways it can. Its last code token is `as` or `:`, both of which
--- are followed by a type. Or it opened a type bracket it never closed
--- -- a wrapped `function(a: A,` whose `)` lands on the next line. Or
--- it is a COMMENT, which decides nothing: the bit the previous line
--- set is what the next line inherits, and dropping it there put a
--- phantom body's worth of indent under any comment that happened to
--- fall between `as` and its type.
--- @param line_items {Item} The line's items
--- @param continues_type boolean What this line itself inherited
--- @return boolean Whether the next line opens in type position
local function opens_type_position(line_items: {Item},
    continues_type?: boolean): boolean
  local last: Item = nil
  for i = #line_items, 1, -1 do
    if line_items[i].kind ~= "comment" then
      last = line_items[i]
      break
    end
  end
  if last == nil then
    return continues_type or false
  end
  if last.tk == "as" or last.tk == ":" then
    return true
  end
  -- Still inside a type: count the brackets the marks call type, and
  -- see whether one is still open when the line runs out.
  local type_ctx = type_marks(line_items, continues_type)
  local depth = 0
  for idx, item in ipairs(line_items) do
    if type_ctx[idx] then
      if item.tk == "(" or item.tk == "[" or item.tk == "{" then
        depth = depth + 1
      elseif item.tk == ")" or item.tk == "]" or item.tk == "}" then
        depth = depth - 1
      end
    end
  end
  return depth > 0
end

local record FormatTypesModule
  type Item = Item
  is_function_block_opener: function(line_items: {Item}, func_idx: integer, continues_type?: boolean): boolean
  type_marks: function(line_items: {Item}, continues_type?: boolean): {integer: boolean}
  opens_type_position: function(line_items: {Item}, continues_type?: boolean): boolean
end

local M: FormatTypesModule = {}
M.is_function_block_opener = is_function_block_opener
M.type_marks = type_marks
M.opens_type_position = opens_type_position

return M
