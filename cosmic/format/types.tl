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
    elseif item.tk == ":" or item.tk == "as" or item.tk == "is" then
      -- All three put what follows in type position. `is` matters as
      -- much as `as`: `x is function` is a runtime type test, and
      -- reading its `function` as a definition indents everything
      -- after the line into a body no `end` ever closes.
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
  -- A bare `function` type -- `x is function`, `(loader as function)()`
  -- -- is the whole type by itself. Marking on past it would claim the
  -- line's own code tokens: the `)` closing the enclosing call gets
  -- marked away while its `(` was counted as an opener, banking the
  -- same phantom level a false block opener does. A parameter list
  -- (`function(`) or a generic prefix (`function<T>(`) is what says
  -- more of the line belongs to the type.
  local nxt = line_items[idx + 1]
  if not (nxt and (nxt.tk == "(" or nxt.tk == "<")) then
    return
  end
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

--- Mark a PARENTHESIZED type -- `as (T | nil)`, `: (T | nil)` -- from
--- its `(` through the matching `)`.
---
--- The group has to be marked whole, not just the `function` inside it.
--- Marked items are skipped for indent accounting on both sides, so
--- marking the keyword alone leaves the `(` counted as an opener while
--- its `)` is marked away, which banks the same phantom level a false
--- block opener does. `mark_function_type` cannot reach this shape from
--- the other end either: it marks from a `function` whose next token is
--- `(`, and here the `(` comes first.
---
--- A `(` in this position is always a type: after `as` there is nothing
--- else it can be, and a method call puts its `(` after the name
--- (`obj:m(x)`), never against the `:`.
--- @param line_items {Item} The line's items
--- @param type_ctx {integer: boolean} Marks, updated in place
local function mark_parenthesized_types(line_items: {Item},
    type_ctx: {integer: boolean})
  for idx, item in ipairs(line_items) do
    local next_item = line_items[idx + 1]
    if (item.tk == "as" or item.tk == ":")
    and next_item and next_item.tk == "(" and not type_ctx[idx + 1] then
      local depth = 0
      for k = idx + 1, #line_items do
        type_ctx[k] = true
        local tk = line_items[k].tk
        if tk == "(" then
          depth = depth + 1
        elseif tk == ")" then
          depth = depth - 1
          if depth == 0 then
            break
          end
        end
      end
    end
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
  mark_parenthesized_types(line_items, type_ctx)
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
---
--- **The open bracket is a DEPTH, not a bit, so it is carried as one.**
--- Counting only this line's brackets works for a two-line wrap and
--- fails for every longer one: the middle line of
---
---     f: function(a: A,
---       b: B,
---       c: C): D
---
--- neither opens nor closes anything, so a per-line count reads 0,
--- drops the carry, and the `)` line then dedents as if it closed a
--- code bracket -- taking the next field with it. That is the same
--- damage the carry exists to prevent, one line deeper, and it is
--- idempotent, so the gate blesses it. Adding this line's marked
--- brackets to what the previous lines left open is what makes the
--- carry survive an arbitrary wrap.
--- @param line_items {Item} The line's items
--- @param continues_type boolean What this line itself inherited
--- @param carry_depth integer Type brackets the previous lines left open
--- @return boolean Whether the next line opens in type position
--- @return integer The bracket depth to carry into it
local function opens_type_position(line_items: {Item},
    continues_type?: boolean, carry_depth?: integer): boolean, integer
  local depth = carry_depth or 0
  local last: Item = nil
  for i = #line_items, 1, -1 do
    if line_items[i].kind ~= "comment" then
      last = line_items[i]
      break
    end
  end
  if last == nil then
    return continues_type or false, depth
  end
  -- Still inside a type: count the brackets the marks call type, and
  -- see whether one is still open when the line runs out.
  local type_ctx = type_marks(line_items, continues_type)
  for idx, item in ipairs(line_items) do
    if type_ctx[idx] then
      if item.tk == "(" or item.tk == "[" or item.tk == "{" then
        depth = depth + 1
      elseif item.tk == ")" or item.tk == "]" or item.tk == "}" then
        -- Clamped per BRACKET, not once per line. A close with nothing
        -- open is not a type bracket at all, and letting it bank -1
        -- would make the next real open on the SAME line read as
        -- balanced -- so `) function(a: A,` would end the line at depth
        -- 0 and drop a carry it should have kept.
        if depth > 0 then
          depth = depth - 1
        end
      end
    end
  end
  if depth > 0 then
    return true, depth
  end
  if last.tk == "as" or last.tk == ":" then
    return true, depth
  end
  return false, depth
end

local record FormatTypesModule
  type Item = Item
  is_function_block_opener: function(line_items: {Item}, func_idx: integer, continues_type?: boolean): boolean
  type_marks: function(line_items: {Item}, continues_type?: boolean): {integer: boolean}
  opens_type_position: function(line_items: {Item}, continues_type?: boolean,
  carry_depth?: integer): boolean, integer
end

local M: FormatTypesModule = {}
M.is_function_block_opener = is_function_block_opener
M.type_marks = type_marks
M.opens_type_position = opens_type_position

return M
