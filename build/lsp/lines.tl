--- A text's lines as `cosmic lsp` ([`build.lsp`]) counts them, and the
--- protocol's positions in it ([`build.lsp.protocol`]): a line ends at
--- "\r\n", "\n" or a lone "\r", and a character is a UTF-16 unit, the
--- protocol's default, or a byte where the client offers UTF-8
--- (`general.positionEncodings`). The checker counts lines apart, at "\n"
--- alone ([`lines.checker_starts`]).

local protocol = require("build.lsp.protocol")

local record lines
  --- A text's lines as the protocol counts them: where each starts (a
  --- byte, from 1) and what it holds, without its end, which is "\r\n",
  --- "\n" or a lone "\r".
  record Split
    starts: {integer}
    texts: {string}
  end
end

local type Split = lines.Split
local type Position = protocol.Position

--- The lines of `text` ([`lines.Split`]).
function lines.lines_of(text: string): Split
  local starts: {integer} = {}
  local texts: {string} = {}
  local at = 1
  while true do
    local stop = text:find("[\r\n]", at)
    starts[#starts + 1] = at
    if stop == nil then
      texts[#texts + 1] = text:sub(at)
      return { starts = starts, texts = texts }
    end
    texts[#texts + 1] = text:sub(at, stop - 1)
    at = stop + 1
    if text:sub(stop, stop + 1) == "\r\n" then at = stop + 2 end
  end
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

--- Where each line of `text` starts as the checker counts lines, which is
--- at "\n" alone: its columns are bytes.
function lines.checker_starts(text: string): {integer}
  local out: {integer} = { 1 }
  local at = text:find("\n", 1, true)
  while at ~= nil do
    out[#out + 1] = at + 1
    at = text:find("\n", at + 1, true)
  end
  return out
end

return lines
