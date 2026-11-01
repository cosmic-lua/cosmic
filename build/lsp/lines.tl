--- A text's lines as `cosmic lsp` ([`build.lsp`]) counts them, and the
--- protocol's positions in it ([`build.lsp.protocol`]): a line ends at
--- "\r\n", "\n" or a lone "\r", and a character is a UTF-16 unit, the
--- protocol's default, or a byte where the client offers UTF-8
--- (`general.positionEncodings`). The checker counts lines apart, as its
--- lexer does ([`lines.checker_starts`]).

local protocol = require("build.lsp.protocol")

local record lines
  --- A text's lines as the protocol counts them: where each starts (a
  --- byte, from 1) and what it holds, without its end, which is "\r\n",
  --- "\n" or a lone "\r".
  record Split
    starts: {integer}
    texts: {string}
  end

  --- How the lines of a text correspond to the lines of an earlier text: `same_as[n]` is the line of the earlier text that
  --- line `n` of the later one is the same as, 0 for a line that was added or edited. Lines are compared without their
  --- ends, so a change of line endings leaves every line the same.
  record Alignment
    old: Split
    new: Split
    --- The length of the earlier text, and of the later.
    old_length: integer
    new_length: integer
    same_as: {integer: integer}
    --- Whether every line that is not paired is one the texts do not share, and not one this could not tell: a part too large
    --- to pair and with no line that stands once in each text is left unpaired, and a place in it is unknown.
    complete: boolean
  end
end

local type Split = lines.Split
local type Position = protocol.Position

--- The lines of `text` ([`lines.Split`]).
function lines.lines_of(text: string): Split
  local starts: mut {integer} = {}
  local texts: mut {string} = {}
  local at = 1
  while true do
    local stop = text:find("[\r\n]", at)
    starts[#starts + 1] = at
    if stop == nil then
      table.insert(texts, text:sub(at))
      return { starts = starts, texts = texts }
    end
    table.insert(texts, text:sub(at, stop - 1))
    at = stop + 1
    if text:sub(stop, stop + 1) == "\r\n" then at = stop + 2 end
  end
end

--- The most cells of the table that pairs the lines of a region the two texts do not share at the starts and ends of;
--- a larger region is divided at the lines each text holds once ([`lines.align`]).
local MOST_CELLS <const> = 250000

--- How the lines of `new` correspond to those of `old`: those the two share at their starts and at their ends, then the
--- longest run of lines the rest share in order. Where the rest is too large for that, it is divided at the lines that
--- stand once in each text and are in the same order (anchors), and each part is aligned in turn; a part with no anchor
--- is left unpaired and the alignment is not `complete`.
function lines.align(old: string, new: string): lines.Alignment
  local before, after = lines.lines_of(old), lines.lines_of(new)
  local old_texts, new_texts = before.texts, after.texts
  local same_as: mut {integer: integer} = {}
  for n = 1, #new_texts do same_as[n] = 0 end
  local complete = true
  local function solve(o1: integer, o2: integer, n1: integer, n2: integer)
    while o1 <= o2 and n1 <= n2 and old_texts[o1] == new_texts[n1] do
      same_as[n1] = o1
      o1, n1 = o1 + 1, n1 + 1
    end
    while o1 <= o2 and n1 <= n2 and old_texts[o2] == new_texts[n2] do
      same_as[n2] = o2
      o2, n2 = o2 - 1, n2 - 1
    end
    local rows, columns = o2 - o1 + 1, n2 - n1 + 1
    if rows <= 0 or columns <= 0 then return end
    if rows * columns <= MOST_CELLS then
      -- shared[i][j]: how many lines the old lines from i and the new lines from j share, in order.
      local width = columns + 1
      local shared: mut {integer: integer} = {}
      for k = 1, (rows + 1) * width do shared[k] = 0 end
      for i = rows, 0, -1 do
        for j = columns, 0, -1 do
          if i < rows and j < columns then
            if old_texts[o1 + i] == new_texts[n1 + j] then
              shared[i * width + j + 1] = (shared[(i + 1) * width + j + 1 + 1] or 0) + 1
            else
              shared[i * width + j + 1] = math.max(shared[(i + 1) * width + j + 1] or 0,
                shared[i * width + j + 1 + 1] or 0)
            end
          end
        end
      end
      local i, j = 0, 0
      while i < rows and j < columns do
        if old_texts[o1 + i] == new_texts[n1 + j] then
          same_as[n1 + j] = o1 + i
          i, j = i + 1, j + 1
        elseif (shared[(i + 1) * width + j + 1] or 0) >= (shared[i * width + j + 1 + 1] or 0) then
          i = i + 1
        else
          j = j + 1
        end
      end
      return
    end
    -- The lines that stand once in each part, in the order of the new text.
    local old_count: mut {string: integer} = {}
    local old_at: mut {string: integer} = {}
    for o = o1, o2 do
      local text = assert(old_texts[o])
      old_count[text] = (old_count[text] or 0) + 1
      old_at[text] = o
    end
    local new_count: mut {string: integer} = {}
    for n = n1, n2 do
      local text = assert(new_texts[n])
      new_count[text] = (new_count[text] or 0) + 1
    end
    local anchor_new: mut {integer} = {}
    local anchor_old: mut {integer} = {}
    for n = n1, n2 do
      local text = assert(new_texts[n])
      if new_count[text] == 1 and old_count[text] == 1 then
        anchor_new[#anchor_new + 1] = n
        anchor_old[#anchor_old + 1] = assert(old_at[text])
      end
    end
    if #anchor_new == 0 then
      complete = false
      return
    end
    -- The longest run of anchors whose old lines rise too: tails[k] is the anchor that ends the best run of length k.
    local tails: mut {integer: integer} = {}
    local size = 0
    local back: mut {integer: integer} = {}
    for k = 1, #anchor_new do
      local low, high = 1, size
      while low <= high do
        local middle = (low + high) // 2
        if assert(anchor_old[assert(tails[middle])]) < assert(anchor_old[k]) then
          low = middle + 1
        else
          high = middle - 1
        end
      end
      local previous = 0
      if low > 1 then previous = assert(tails[low - 1]) end
      back[k] = previous
      tails[low] = k
      if low > size then size = low end
    end
    local chain: mut {integer} = {}
    local at = assert(tails[size])
    while at > 0 do
      table.insert(chain, 1, at)
      at = assert(back[at])
    end
    local from_old, from_new = o1, n1
    for _, k in ipairs(chain) do
      local o, n = assert(anchor_old[k]), assert(anchor_new[k])
      solve(from_old, o - 1, from_new, n - 1)
      same_as[n] = o
      from_old, from_new = o + 1, n + 1
    end
    solve(from_old, o2, from_new, n2)
  end
  solve(1, #old_texts, 1, #new_texts)
  return { old = before, new = after, old_length = #old, new_length = #new, same_as = same_as, complete = complete }
end

--- The line of `alignment`'s later text that holds byte `at` (from 1), the last whose start is not after it.
local function line_at(split: Split, at: integer): integer
  local low, high = 1, #split.starts
  local found = 1
  while low <= high do
    local middle = (low + high) // 2
    if assert(split.starts[middle]) <= at then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

--- Where the cursor, `count` bytes into the later text, is in the earlier text, counted in bytes the same way: in the same
--- place of the same line where the line is one the texts share; in an edited line, in the same place where the edit leaves
--- what is before the cursor or what is after it, else at the start of what the line and the line it replaced do not
--- share; and at the start of the next line the texts share where no line replaced it.
function lines.earlier(alignment: lines.Alignment, count: integer): integer?
  if count <= 0 then return 0 end
  local new, old = alignment.new, alignment.old
  local n = line_at(new, count)
  local column = count - assert(new.starts[n]) + 1
  local text = assert(new.texts[n])
  local matched = assert(alignment.same_as[n])
  --- The byte before the start of the earlier text's line `m`, which is the end of the text for a line past the last.
  local function before_line(m: integer): integer
    local start = old.starts[m]
    if start == nil then return alignment.old_length end
    return start - 1
  end
  if matched > 0 then
    -- Past the line's text is its end, which is the start of the next line.
    if column > #text then return before_line(matched + 1) end
    return before_line(matched) + column
  end
  -- A place in a part that could not be told apart is unknown.
  if not alignment.complete then return nil end
  -- The earlier lines that stand between the lines before this one and the lines after it that the texts share.
  local previous, following = 0, 0
  local skipped = 0
  for m = n - 1, 1, -1 do
    if assert(alignment.same_as[m]) > 0 then
      previous = assert(alignment.same_as[m])
      break
    end
    skipped = skipped + 1
  end
  for m = n + 1, #new.texts do
    if assert(alignment.same_as[m]) > 0 then
      following = assert(alignment.same_as[m])
      break
    end
  end
  if following == 0 then following = #old.texts + 1 end
  local first = previous + 1
  -- A line past the lines that were replaced is at the end of them, so that the places rise with the text.
  if first >= following or first + skipped >= following then return before_line(following) end
  local paired = first + skipped
  local other = assert(old.texts[paired])
  local limit = math.min(#text, #other)
  local same = 0
  while same < limit and text:byte(same + 1) == other:byte(same + 1) do same = same + 1 end
  local into = math.min(column, #text)
  if into <= same then return before_line(paired) + into end
  local rest = #text - into
  local end_same = 0
  while end_same < limit - same and text:byte(#text - end_same) == other:byte(#other - end_same) do
    end_same = end_same + 1
  end
  if rest <= end_same then return before_line(paired) + #other - rest end
  return before_line(paired) + same
end

--- How many units of `encoding` the bytes of `line` before byte `x` (from
--- 1) take: the protocol's character of that column, from 0.
local function character_of(line: string, x: integer, encoding: string): integer
  local before = line:sub(1, x - 1)
  if encoding == "utf-8" then return #before end
  local units = 0
  for _, code in utf8.codes(before, true) do
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return units
end

--- The byte (from 1) at the protocol's `character` of `line`, or one past
--- the line's end for a character past it.
function lines.byte_of(line: string, character: integer, encoding: string): integer
  if encoding == "utf-8" then return math.min(character, #line) + 1 end
  local units = 0
  for at, code in utf8.codes(line, true) do
    if units >= character then return at end
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return #line + 1
end

--- The protocol's position of byte `offset` (from 1) of the text `of`
--- holds; a byte of a line's end is past the line's last character.
function lines.position(of: Split, offset: integer, encoding: string): Position
  local low, high = 1, #of.starts
  while low < high do
    local middle = (low + high + 1) // 2
    if assert(of.starts[middle]) <= offset then low = middle else high = middle - 1 end
  end
  local line = assert(of.texts[low])
  local x = math.min(math.max(offset - assert(of.starts[low]) + 1, 1), #line + 1)
  return { line = low - 1, character = character_of(line, x, encoding) }
end

--- Where each line of `text` starts as the checker counts lines, which is as its lexer does: a line ends at "\n", "\r",
--- "\r\n" or "\n\r", each one break. Its columns are bytes.
function lines.checker_starts(text: string): {integer}
  local out: mut {integer} = { 1 }
  local pos = 1
  while true do
    local at = text:find("[\r\n]", pos)
    if at == nil then return out end
    local after = text:sub(at + 1, at + 1)
    if (after == "\r" or after == "\n") and after ~= text:sub(at, at) then at = at + 1 end
    out[#out + 1] = at + 1
    pos = at + 1
  end
end

return lines
