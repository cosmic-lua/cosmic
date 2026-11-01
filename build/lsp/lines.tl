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

--- The most cells of the table that pairs the lines two texts do not share at their starts and ends; the lines between
--- two texts too different for that are all taken for edited.
local MOST_CELLS <const> = 250000

--- How the lines of `new` correspond to those of `old`: those the two share at their starts and at their ends, then the
--- longest run of lines the rest share in order ([`lines.Alignment`]).
function lines.align(old: string, new: string): lines.Alignment
  local before, after = lines.lines_of(old), lines.lines_of(new)
  local old_texts, new_texts = before.texts, after.texts
  local same_as: mut {integer: integer} = {}
  for n = 1, #new_texts do same_as[n] = 0 end
  local head = 0
  while head < #old_texts and head < #new_texts and old_texts[head + 1] == new_texts[head + 1] do
    head = head + 1
    same_as[head] = head
  end
  local tail = 0
  while tail < #old_texts - head and tail < #new_texts - head and
      old_texts[#old_texts - tail] == new_texts[#new_texts - tail] do
    same_as[#new_texts - tail] = #old_texts - tail
    tail = tail + 1
  end
  local rows, columns = #old_texts - head - tail, #new_texts - head - tail
  if rows > 0 and columns > 0 and rows * columns <= MOST_CELLS then
    -- shared[i][j]: how many lines the old lines from i and the new lines from j share, in order.
    local width = columns + 1
    local shared: mut {integer: integer} = {}
    for k = 1, (rows + 1) * width do shared[k] = 0 end
    for i = rows, 0, -1 do
      for j = columns, 0, -1 do
        if i < rows and j < columns then
          if old_texts[head + i + 1] == new_texts[head + j + 1] then
            shared[i * width + j + 1] = (shared[(i + 1) * width + j + 1 + 1] or 0) + 1
          else
            shared[i * width + j + 1] = math.max(shared[(i + 1) * width + j + 1] or 0, shared[i * width + j + 1 + 1] or 0)
          end
        end
      end
    end
    local i, j = 0, 0
    while i < rows and j < columns do
      if old_texts[head + i + 1] == new_texts[head + j + 1] then
        same_as[head + j + 1] = head + i + 1
        i, j = i + 1, j + 1
      elseif (shared[(i + 1) * width + j + 1] or 0) >= (shared[i * width + j + 1 + 1] or 0) then
        i = i + 1
      else
        j = j + 1
      end
    end
  end
  return { old = before, new = after, old_length = #old, new_length = #new, same_as = same_as }
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

--- The lines of the later text that were added or edited, by number.
function lines.edited(alignment: lines.Alignment): {integer}
  local out: mut {integer} = {}
  for n = 1, #alignment.new.texts do
    if alignment.same_as[n] == 0 then out[#out + 1] = n end
  end
  return out
end

--- Where the cursor, `count` bytes into the later text, is in the earlier text, counted in bytes the same way: in the same
--- place of the same line where the line is one the texts share; in an edited line, in the same place where the edit leaves
--- what is before the cursor or what is after it, else at the start of what the line and the line it replaced do not
--- share; and at the start of the next line the texts share where no line replaced it.
function lines.earlier(alignment: lines.Alignment, count: integer): integer
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
  -- The earlier lines that stand between the lines before this one and the lines after it that the texts share.
  local previous, following = 0, 0
  for m = n - 1, 1, -1 do
    if assert(alignment.same_as[m]) > 0 then
      previous = assert(alignment.same_as[m])
      break
    end
  end
  for m = n + 1, #new.texts do
    if assert(alignment.same_as[m]) > 0 then
      following = assert(alignment.same_as[m])
      break
    end
  end
  if following == 0 then following = #old.texts + 1 end
  local first = previous + 1
  if first >= following then return before_line(following) end
  local skipped = 0
  for m = n - 1, 1, -1 do
    if assert(alignment.same_as[m]) > 0 then break end
    skipped = skipped + 1
  end
  local paired = math.min(first + skipped, following - 1)
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
