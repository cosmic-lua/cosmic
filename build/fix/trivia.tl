--- The comments and tokens of a lexed source as one stream in source order, with what lies between each two
--- neighbours: the first layer of the Teal formatter ([`lang.lexer`] keeps comments on the token after them, which a
--- printer cannot walk in order).
---
--- The stream is `comment`, `token`, ... and ends with the `eof` item, the `$EOF$` token, whose text is empty.
--- Whitespace is not an item. What it said is kept as the line structure alone: the line breaks before each item
--- (`newlines`, `blank`), and for a comment whether it trails code (`trailing`) or stands on a line of its own.
--- Columns and spaces within a line are the printer's to choose; a comment's `x` says where it began, for the
--- comments that keep their column.
---
--- A line break is `\n`, `\r`, `\r\n` or `\n\r`, each one, as the lexer counts them. The stream does not say which
--- a source used: a printer writes `\n`. The bytes of a token or a comment are untouched, a long string's breaks
--- among them.
local Lexer = require("lang.lexer")

local find, sub = string.find, string.sub

local record Trivia
  enum Kind
    "token"
    "comment"
    "eof"
  end

  --- One comment or token, with the gap before it.
  record Item
    kind: Kind
    --- The number of the token ([`Lexer.Tokens`]) that this is, or, for a comment, the token it is kept on: the
    --- first token after it, the `$EOF$` for a comment past the last.
    token: integer
    --- The bytes of the item: a comment's `--` to the end of its line (a long comment, which the grammar cuts and
    --- the lexer refuses, runs to its closing bracket), a token's text, or "" for `eof`.
    text: string
    --- The byte offset of the first byte, from 1.
    offset: integer
    --- The line and the column, from 1, of the first byte.
    y: integer
    x: integer
    --- The line the item ends on: that of its last byte, or, where the text ends in a line break, the line after,
    --- where the break leaves the cursor. Only a token that is an error ends so: an unterminated long string or
    --- comment, which runs to the end of the file, or a short string left open after a `\` and its break. It is `y`
    --- for a comment or token on one line.
    yend: integer
    --- The line breaks between the end of the item before and the start of this one: 0 on the line where that one
    --- ends. The first item has the breaks before it, so the `#!` line, when there is one, is line 1.
    newlines: integer
    --- Whether a line with nothing on it lies before the item: `newlines` is at least 2, or at least 1 where the
    --- item before ended with a line break of its own or there is none and no `#!` line.
    blank: boolean
    --- Whether a comment begins on the line where the token before it ends, or where a trailing comment before it
    --- ends. False for a token and for any other comment, which stands on a line of its own or follows a comment
    --- that does (its `newlines` is then 0).
    trailing: boolean
  end

  --- The items of a source, the last of kind `eof`.
  record Stream
    items: {Item}
    --- The `#!` line of the source without its line break, or nil. The lexer skips it, so it is no item;
    --- `newlines` of the first item counts from its line.
    shebang: string?
  end

  --- The stream of `source`, which `tokens` is the lexing of ([`Lexer.lex`]). It does not look at the lexer's
  --- errors: an unterminated long comment is one token to the end of the file, so a caller refuses a source that
  --- has errors before it uses the stream.
  of: function(source: string, tokens: Lexer.Tokens): Stream
end

local function byte(text: string, at: integer): integer?
  return string.byte(text, at)
end

--- Whether `text` ends in a line break.
local function ends_in_break(text: string): boolean
  local last = byte(text, #text)
  return last == 10 or last == 13
end

--- How many line breaks `text` holds.
local function breaks_in(text: string): integer
  local count, from = 0, 1
  while true do
    local at = find(text, "[\r\n]", from)
    if at == nil then
      return count
    end
    local c, d = byte(text, at), byte(text, at + 1)
    from = if (d == 10 or d == 13) and d ~= c then at + 2 else at + 1 end
    count = count + 1
  end
end

function Trivia.of(source: string, tokens: Lexer.Tokens): Trivia.Stream
  local items: mut {Trivia.Item} = {}
  local shebang: string? = nil
  if sub(source, 1, 2) == "#!" then
    shebang = sub(source, 1, (find(source, "[\r\n]", 3) or #source + 1) - 1)
  end

  local function add(kind: Trivia.Kind, token: integer, text: string, offset: integer, y: integer, x: integer,
                     yend: integer, trails: boolean)
    local before = items[#items]
    local newlines = y - (if before == nil then 1 else before.yend end)
    -- The cursor is at the start of a line at the start of the file (the `#!` line ends mid-line) and after a
    -- token that took its break.
    local at_line_start = if before == nil then shebang == nil else ends_in_break(before.text) end
    items[#items + 1] = {
      kind = kind, token = token, text = text, offset = offset, y = y, x = x, yend = yend, newlines = newlines,
      blank = newlines >= (if at_line_start then 1 else 2 end),
      trailing = trails and before ~= nil and (before.kind ~= "comment" or before.trailing) and y == before.yend,
    }
  end

  for i = 1, Lexer.count(tokens) do
    local comments = tokens.comments[i]
    if comments ~= nil then
      for _, comment in ipairs(comments) do
        add("comment", i, comment.text, comment.offset, comment.y, comment.x, comment.y + breaks_in(comment.text), true)
      end
    end
    local text = Lexer.text(tokens, i)
    local kind: Trivia.Kind = if Lexer.kind(tokens, i) == "$EOF$" then "eof" else "token" end
    local last = Lexer.yend(tokens, i) + (if ends_in_break(text) then 1 else 0 end)
    add(kind, i, text, Lexer.offset(tokens, i), Lexer.y(tokens, i), Lexer.x(tokens, i), last, false)
  end
  return { items = items, shebang = shebang }
end

return Trivia
