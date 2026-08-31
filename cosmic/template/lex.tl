--- Splits template source into a token stream. Internal to
--- `cosmic.template` — see `cosmic/template/types.tl` for the token
--- grammar and why this directory is not the published API.
---
--- Outside `{{ }}`, everything is a run of literal text, kept
--- verbatim (no trim markers, no escaping — a template's literal text
--- becomes literal Teal string content byte for byte). Inside `{{ }}`,
--- the grammar is a handful of words, dotted paths, and `|`; this
--- lexer does not know which words are keywords — `parse.tl` decides
--- that from position, the same way it decides what a bareword's
--- dotted shape means (an import path versus a plain identifier).

local types = require("cosmic.template.types")

--- Where the lexer is: the byte offset to read next, and the line and
--- column that offset falls on. A single mutable cursor, threaded
--- through the helpers below and updated in place, is what keeps every
--- helper's return to the two slots `fallible-returns` requires — line
--- and column would otherwise be two more return values on top of
--- "did this succeed".
local record Cursor
  pos: integer
  line: integer
  line_start: integer
end

--- True for the ASCII whitespace this lexer treats as a separator
--- inside an action: space, tab, newline, and carriage return.
--- @param c string A single character
--- @return boolean True when c is whitespace
local function is_space(c: string): boolean
  return c == " " or c == "\t" or c == "\n" or c == "\r"
end

--- The column `at` falls on, given where its line started.
--- @param cur Cursor The cursor, for its line_start
--- @param at integer A byte offset on the cursor's current line
--- @return integer The 1-based column
local function col_at(cur: Cursor, at: integer): integer
  return at - cur.line_start + 1
end

--- Advance `cur.line`/`cur.line_start` past every newline in
--- `src[from, upto)`, so the next token's line and column stay
--- accurate across a multi-line text run or action. `cur.pos` is left
--- untouched — callers advance it themselves once they know the
--- token's extent.
--- @param src string The template source
--- @param cur Cursor The cursor to advance in place
--- @param from integer Start of the range, inclusive
--- @param upto integer End of the range, exclusive
local function advance_lines(src: string, cur: Cursor, from: integer, upto: integer)
  local at = from
  while true do
    local nl = src:find("\n", at, true)
    if not nl or nl >= upto then
      break
    end
    cur.line = cur.line + 1
    cur.line_start = nl + 1
    at = nl + 1
  end
end

--- Lex one action's content, from just after `{{` to just after the
--- matching `}}`, appending tokens to `toks` and advancing `cur` in
--- place. Splits on whitespace and `|`; a run of non-space, non-`|`
--- characters is a "field" token when it starts with `.`, otherwise a
--- "word" token.
--- @param src string The template source
--- @param cur Cursor The cursor, positioned just after the opening `{{`
--- @param name string The template's name, for error messages
--- @param toks {types.Token} The token list to append to
--- @return boolean True on success; false when the action never closes
--- @return string The error on failure
local function lex_action(src: string, cur: Cursor, name: string,
    toks: {types.Token}): boolean, string
  local n = #src
  while cur.pos <= n do
    local c = src:sub(cur.pos, cur.pos)
    if is_space(c) then
      advance_lines(src, cur, cur.pos, cur.pos + 1)
      cur.pos = cur.pos + 1
    elseif src:sub(cur.pos, cur.pos + 1) == "}}" then
      toks[#toks + 1] = {kind = "close", value = "}}", line = cur.line,
        col = col_at(cur, cur.pos)}
      cur.pos = cur.pos + 2
      return true, ""
    elseif c == "|" then
      toks[#toks + 1] = {kind = "pipe", value = "|", line = cur.line,
        col = col_at(cur, cur.pos)}
      cur.pos = cur.pos + 1
    else
      local j = cur.pos
      while j <= n and not is_space(src:sub(j, j))
      and src:sub(j, j) ~= "|" and src:sub(j, j + 1) ~= "}}" do
        j = j + 1
      end
      local word = src:sub(cur.pos, j - 1)
      local kind = word:sub(1, 1) == "." and "field" or "word"
      toks[#toks + 1] = {kind = kind, value = word, line = cur.line,
        col = col_at(cur, cur.pos)}
      cur.pos = j
    end
  end
  return false, name .. ":" .. cur.line .. ": unterminated action, missing '}}'"
end

--- Lex a template into a token stream.
--- @param src string The template source
--- @param name string The template's name, for error messages
--- @return {types.Token}|nil The tokens
--- @return string The error, with line, when the source cannot be lexed
local function lex(src: string, name: string): {types.Token} | nil, string
  local toks: {types.Token} = {}
  local n = #src
  local cur: Cursor = {pos = 1, line = 1, line_start = 1}
  while cur.pos <= n do
    local open_at = src:find("{{", cur.pos, true)
    if not open_at then
      toks[#toks + 1] = {kind = "text", value = src:sub(cur.pos), line = cur.line,
        col = col_at(cur, cur.pos)}
      cur.pos = n + 1
    else
      if open_at > cur.pos then
        toks[#toks + 1] = {kind = "text", value = src:sub(cur.pos, open_at - 1),
          line = cur.line, col = col_at(cur, cur.pos)}
      end
      advance_lines(src, cur, cur.pos, open_at)
      toks[#toks + 1] = {kind = "open", value = "{{", line = cur.line,
        col = col_at(cur, open_at)}
      cur.pos = open_at + 2
      local ok, err = lex_action(src, cur, name, toks)
      if not ok then
        return nil, err
      end
    end
  end
  return toks, ""
end

local record LexModule
  lex: function(src: string, name: string): {types.Token} | nil, string
end

local M: LexModule = {lex = lex}
return M
