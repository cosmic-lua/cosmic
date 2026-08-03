--- Shared block-body scanner used by the benchmark, example, and doc
--- extractors. Internal by position (`cosmic.doc.scan` is two segments
--- under `cosmic/`, so `cosmic/doc/visibility.tl`'s `is_public` rule
--- says no) — this is plumbing for those three parsers, not published
--- API.
---
--- Finds the end of a Lua/Teal block by tracking nesting depth, the way
--- a bracket matcher would, while skipping over string and comment
--- literals so keywords inside them are never mistaken for real
--- block-openers or -closers. Two defects that every hand-rolled copy
--- of this scanner used to repeat, fixed once here:
--- - keyword matching must consume a FULL identifier: a bare `%a+`
---   pattern stops at the first `_` or digit, so `end_time` lexed as
---   `end` and closed the block early.
--- - a bare `do ... end` block must open its own nesting level. Only
---   `for`/`while`'s OWN trailing `do` is already accounted for (by the
---   `for`/`while` keyword itself), so a `do` opens a new level exactly
---   when it is not one of those.

--- Block-opening keywords that need one matching `end` each. `repeat`
--- is closed by `until` instead, tracked separately below; `do` is
--- handled separately too since whether it opens a NEW level depends on
--- whether a `for`/`while` already opened one for it.
local BLOCK_STARTS: {string: boolean} = {
  ["function"] = true,
  ["if"] = true,
  ["for"] = true,
  ["while"] = true,
  ["repeat"] = true,
}

--- Count newlines in source over an inclusive position range.
--- @param source string The text to scan
--- @param start_pos integer First position to examine
--- @param end_pos integer Last position to examine
--- @return integer Number of `\n` bytes in [start_pos, end_pos]
local function count_lines(source: string, start_pos: integer, end_pos: integer): integer
  local count = 0
  for i = start_pos, end_pos do
    if source:sub(i, i) == "\n" then
      count = count + 1
    end
  end
  return count
end

--- Find the end of a block that is already open at depth 1 (typically a
--- function body) by scanning forward and tracking nesting depth.
--- @param source string The full source text
--- @param start_pos integer Position to begin scanning from — just after
--- whatever already put the scanner at depth 1 (e.g. right after a
--- function's closing `)`)
--- @return integer Position of the last body character, just before the
--- closing `end`
--- @return integer Position just past that closing `end`
local function find_block_end(source: string, start_pos: integer): integer, integer
  local depth = 1
  local i = start_pos
  -- Number of `do` tokens still owed to an already-counted `for`/`while`.
  local pending_do = 0

  while i <= #source and depth > 0 do
    local c = source:sub(i, i)
    if c == '"' or c == "'" then
      -- Skip strings
      local quote = c
      i = i + 1
      while i <= #source do
        if source:sub(i, i) == "\\" then
          i = i + 2
        elseif source:sub(i, i) == quote then
          i = i + 1
          break
        else
          i = i + 1
        end
      end
    elseif source:sub(i, i + 1) == "[[" then
      -- Skip long strings
      local close = source:find("]]", i + 2, true)
      i = close and close + 2 or #source + 1
    elseif source:sub(i, i + 1) == "--" then
      -- Skip comments (including long comments)
      if source:sub(i + 2, i + 3) == "[[" then
        local close = source:find("]]", i + 4, true)
        i = close and close + 2 or #source + 1
      else
        local newline = source:find("\n", i)
        i = newline and newline + 1 or #source + 1
      end
    else
      -- Check for keywords. A full identifier, not just a run of
      -- letters: `%a+` alone stops at the first `_` or digit.
      local word_start, word_end, word = source:find("([%a_][%w_]*)", i)
      if word_start == i then
        if word == "do" then
          if pending_do > 0 then
            -- Already accounted for by an earlier for/while.
            pending_do = pending_do - 1
          else
            -- A bare `do ... end` block: its own nesting level.
            depth = depth + 1
          end
        elseif BLOCK_STARTS[word] then
          if word == "function" then
            -- Make sure it's not just a type annotation.
            local before = source:sub(math.max(1, i - 1), i - 1)
            if before ~= ":" and before ~= ">" then
              depth = depth + 1
            end
          else
            depth = depth + 1
            if word == "for" or word == "while" then
              pending_do = pending_do + 1
            end
          end
        elseif word == "until" then
          depth = depth - 1
        elseif word == "end" then
          depth = depth - 1
        end
        i = word_end + 1
      else
        i = i + 1
      end
    end
  end

  return i - 4, i -- Before "end"
end

local record ScanModule
  count_lines: function(source: string, start_pos: integer, end_pos: integer): integer
  find_block_end: function(source: string, start_pos: integer): integer, integer
end

local M: ScanModule = {
  count_lines = count_lines,
  find_block_end = find_block_end,
}

return M
