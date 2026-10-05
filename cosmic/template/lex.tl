--- Cuts a template into runs of literal text and `{{ ... }}` actions,
--- applying the trim markers as it goes. Private to [`cosmic.template`].
---
--- Outside an action everything is literal text, byte for byte. Inside
--- one, words are separated by whitespace and `|`; a word that starts
--- with `.` is a field path and any other a bare word. The lexer does not
--- know which words are keywords: `parse` decides that from position.
---
--- `{{-` (followed by whitespace) drops the whitespace before the action
--- and `-}}` (preceded by whitespace) the whitespace after it, newlines
--- included. A text run left empty by that is dropped; the line and
--- column of the one that remains are those of its first byte, so a later
--- stage never counts a dropped newline wrong.

local types = require("cosmic.template.types")

--- Where the lexer is: the next byte to read, and the line it is on and
--- the offset that line started at. One cursor, advanced in place, so
--- each helper keeps to the two result slots a fallible function has.
local record Cursor
  pos: integer
  line: integer
  start: integer
end

--- Whether byte `b` is the whitespace trim markers and actions skip.
local function blank(b: integer): boolean
  return b == 32 or b == 9 or b == 10 or b == 13 or b == 12
end

--- Moves `cur` to `upto`, counting the newlines it passes.
local function advance(src: string, cur: Cursor, upto: integer)
  local at = cur.pos
  while true do
    local nl = src:find("\n", at, true)
    if nl == nil or nl >= upto then
      break
    end
    cur.line = cur.line + 1
    cur.start = nl + 1
    at = nl + 1
  end
  cur.pos = upto
end

--- Where the `skip` bytes at `cur` end, as a line and column.
local function after(src: string, cur: Cursor, skip: integer): integer, integer
  local moved: Cursor = { pos = cur.pos, line = cur.line, start = cur.start }
  advance(src, moved, cur.pos + skip)
  return moved.line, moved.pos - moved.start + 1
end

--- The length of the whitespace `text` starts with.
local function leading(text: string): integer
  local at = 1
  while at <= #text and blank(text:byte(at)) do
    at = at + 1
  end
  return at - 1
end

--- `text` less the whitespace it ends with.
local function trimmed_end(text: string): string
  local at = #text
  while at > 0 and blank(text:byte(at)) do
    at = at - 1
  end
  return text:sub(1, at)
end

--- Reads one action's words, from just after its `{{` (and `{{-`'s dash)
--- to just after its `}}`, appending them to `tokens`. True when the
--- action ended in `-}}`; nil and the reason when it never closes.
local function words(src: string, cur: Cursor, tokens: {types.Token}): boolean | nil, string
  local n = #src
  while cur.pos <= n do
    local b = src:byte(cur.pos)
    local line = cur.line
    local col = cur.pos - cur.start + 1
    if blank(b) then
      advance(src, cur, cur.pos + 1)
    elseif src:sub(cur.pos, cur.pos + 2) == "-}}" and (cur.pos == 1 or blank(src:byte(cur.pos - 1))) then
      cur.pos = cur.pos + 3
      return true, ""
    elseif src:sub(cur.pos, cur.pos + 1) == "}}" then
      cur.pos = cur.pos + 2
      return false, ""
    elseif b == 124 then
      tokens[#tokens + 1] = { kind = "pipe", value = "|", line = line, col = col }
      cur.pos = cur.pos + 1
    else
      local stop = cur.pos
      while stop <= n do
        local c = src:byte(stop)
        if blank(c) or c == 124 or (c == 125 and src:byte(stop + 1) == 125) then
          break
        end
        stop = stop + 1
      end
      local word = src:sub(cur.pos, stop - 1)
      tokens[#tokens + 1] = { kind = word:byte(1) == 46 and "field" or "word", value = word,
        line = line, col = col }
      cur.pos = stop
    end
  end
  return nil, "unterminated"
end

local record Lex
end

--- Cuts `src` into items. `name` heads each message.
--- @param src string The template source
--- @param name string The template's name, for messages
--- @return types.Lexed|nil The items and the line count
--- @return string The reason, as `name:line:col: ...`, on failure
function Lex.lex(src: string, name: string): types.Lexed | nil, string
  local items: {types.Item} = {}
  local cur: Cursor = { pos = 1, line = 1, start = 1 }
  local n = #src
  local trim_next = false
  while cur.pos <= n do
    local open = src:find("{{", cur.pos, true)
    local stop = open or n + 1
    local last: types.Item = nil
    if stop > cur.pos then
      local text = src:sub(cur.pos, stop - 1)
      local skip = trim_next and leading(text) or 0
      local line, col = after(src, cur, skip)
      text = text:sub(skip + 1)
      if text ~= "" then
        last = { action = false, text = text, tokens = {}, line = line, col = col, end_line = line }
        items[#items + 1] = last
      end
      advance(src, cur, stop)
    end
    trim_next = false
    if open == nil then
      break
    end
    local line = cur.line
    local col = cur.pos - cur.start + 1
    local first = src:byte(open + 2)
    local dash = first == 45 and open + 3 <= n and blank(src:byte(open + 3))
    if dash and last ~= nil then
      last.text = trimmed_end(last.text)
      if last.text == "" then
        items[#items] = nil
      end
    end
    advance(src, cur, open + (dash and 3 or 2))
    local tokens: {types.Token} = {}
    local trimmed, _ = words(src, cur, tokens)
    if trimmed == nil then
      return nil, name .. ":" .. line .. ":" .. col .. ": unterminated action: no closing }}"
    end
    trim_next = trimmed
    items[#items + 1] = { action = true, text = "", tokens = tokens, line = line, col = col,
      end_line = cur.line }
  end
  return { items = items, lines = cur.line }, ""
end

return Lex
