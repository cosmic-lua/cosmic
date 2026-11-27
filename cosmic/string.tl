--- Small text operations a program otherwise writes by hand: splitting
--- on a separator, iterating over lines, trimming, testing a prefix, a
--- suffix or a part, reading a byte that must be there, cutting UTF-8
--- text to a length in bytes, making any bytes UTF-8, counting a noun, and filling `{name}` slots from values. Every separator, prefix and suffix is plain
--- text, never a Lua pattern, so a `.` or `%` in one means itself.
---
---     for line in String.lines("a\n\nb") do print(line) end -- a, "", b

local record String
end

--- Every piece of `text` between occurrences of `separator`, in order,
--- empty pieces included: n separators make n + 1 pieces, so
--- `split("a,", ",")` is `{ "a", "" }` and `split("", ",")` is `{ "" }`.
--- An empty separator raises.
--- @param text string The text to split
--- @param separator string The plain text between pieces
--- @return {string} The pieces
function String.split(text: string, separator: string): {string}
  if separator == "" then
    error("string: split's separator is empty", 2)
  end
  local pieces: mut {string} = {}
  local from = 1
  while true do
    local at, stop = text:find(separator, from, true)
    if at == nil or stop == nil then break end
    pieces[#pieces + 1] = text:sub(from, at - 1)
    from = stop + 1
  end
  pieces[#pieces + 1] = text:sub(from)
  return pieces
end

--- An iterator over the lines of `text`: exactly the pieces
--- `split(text, "\n")` returns, so text ending in "\n" has an empty last
--- line, as "a\n" gives "a" and then "", and "" has one empty line. A "\r"
--- before the "\n" stays on its line.
--- @param text string The text to read
--- @return function(): string? The next line, or nil after the last
function String.lines(text: string): function(): string?
  return (text .. "\n"):gmatch("([^\n]*)\n")
end

--- `text` without the whitespace at either end: the ASCII bytes `%s`
--- matches (space, "\t", "\n", "\v", "\f", "\r"), never a multibyte
--- space such as U+00A0.
--- @param text string The text to trim
--- @return string The trimmed text
function String.trim(text: string): string
  local from = text:find("%S")
  if from == nil then return "" end
  -- Scanned back from the end: a pattern anchored at `$` would retry at
  -- every position of an inner run of whitespace.
  local to = #text
  while text:find("^%s", to) do to = to - 1 end
  return text:sub(from, to)
end

--- Whether `text` begins with `prefix`; every text begins with "".
--- @param text string The text to test
--- @param prefix string The plain text it may begin with
--- @return boolean True when it does
function String.starts_with(text: string, prefix: string): boolean
  return text:sub(1, #prefix) == prefix
end

--- Whether `text` ends with `suffix`; every text ends with "".
--- @param text string The text to test
--- @param suffix string The plain text it may end with
--- @return boolean True when it does
function String.ends_with(text: string, suffix: string): boolean
  return suffix == "" or text:sub(-#suffix) == suffix
end

--- Whether `part` occurs in `text`; every text contains "". `part` is
--- plain text, as `text:find(part, 1, true) ~= nil` reads it, and this
--- returns a boolean that a condition and `assert` take as it is.
--- @param text string The text to search
--- @param part string The plain text it may contain
--- @return boolean True when it does
function String.contains(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

--- The byte of `text` at `index`, counted from 1, for code that has
--- already checked the index against `#text` (a wire parser that read a
--- length first, a loop over `1, #text`). `text:byte(index)` returns nil
--- past either end, which a caller then adds or shifts; this raises,
--- blaming its caller, so a length check that was missed fails where the
--- read is. A negative index is refused rather than counted from the end,
--- and so is 0.
--- @param text string The bytes to read
--- @param index integer The position, 1 to `#text`
--- @return integer The byte, 0 to 255
function String.byte_at(text: string, index: integer): integer
  local byte = if index >= 1 then text:byte(index) else nil end
  if byte == nil then
    if #text == 0 then
      error(("string: byte_at(%d) reads an empty text"):format(index), 2)
    end
    error(("string: byte_at(%d) is outside the text of %s (1 to %d)"):format(
      index, String.counted(#text, "byte"), #text), 2)
  end
  return byte
end

--- At most `most` bytes of `text`, UTF-8, cut where no character is
--- split: a label, a subject or a preview kept to a store's limit stays
--- valid UTF-8. The cut backs up past the continuation bytes (0x80 to
--- 0xBF) after it, so it may keep fewer than `most`, and in text that
--- is not UTF-8 it may drop the byte before a stray one. A negative
--- `most` raises.
--- @param text string The UTF-8 text to cut
--- @param most integer The most bytes to keep, 0 or more
--- @return string The text, or its start up to a character's end
function String.cut(text: string, most: integer): string
  if most < 0 then error(("string: cut(%d) keeps a negative count of bytes"):format(most), 2) end
  if #text <= most then return text end
  local at = most
  while at > 0 and String.byte_at(text, at + 1) & 0xC0 == 0x80 do at = at - 1 end
  return text:sub(1, at)
end

--- `text` as UTF-8: `text` itself where it is UTF-8, else each byte
--- that begins no whole character (a stray continuation byte, a cut
--- sequence, an overlong form, a surrogate or past U+10FFFF) is one
--- U+FFFD. What a program ran and wrote, or a database
--- cell, so goes where only UTF-8 may: JSON, a terminal, an API.
--- @param text string Any bytes
--- @return string The bytes as UTF-8
function String.as_utf8(text: string): string
  if utf8.len(text) ~= nil then return text end
  local out: mut {string} = {}
  local at = 1
  while at <= #text do
    local b = text:byte(at) or 0
    local n = if b < 0x80 then 1 elseif b >= 0xC2 and b <= 0xDF then 2 elseif b >= 0xE0 and b <= 0xEF then 3
      elseif b >= 0xF0 and b <= 0xF4 then 4 else 0 end
    local piece = if n > 0 then text:sub(at, at + n - 1) else "" end
    if n > 0 and #piece == n and utf8.len(piece) == 1 then
      out[#out + 1] = piece
      at = at + n
    else
      out[#out + 1] = "\u{FFFD}"
      at = at + 1
    end
  end
  return table.concat(out)
end

--- `n` and `singular` as a count of things, "1 entry" or "2 entries": the
--- noun is `several` unless `n` is 1, and `several` is `singular` with an
--- `s` when not given. Only 1 takes the singular, so "0 entries" and
--- "-1 entries" are plural.
--- @param n integer The count to write
--- @param singular string The noun for one
--- @param several string | nil The noun for any other count; `singular` and an "s" when nil
--- @return string The count, a space and the noun
function String.counted(n: integer, singular: string, several?: string): string
  return tostring(n) .. " " .. (if n == 1 then singular else several or singular .. "s" end)
end

--- `template` with each `{name}` slot filled by `tostring(values[name])`: `fill("{n} files in {dir}", { n = 3,
--- dir = "src" })` is `"3 files in src"`. A name is a letter or `_`, then letters, digits and `_`; `{{` and `}}` write
--- `{` and `}`. A slot whose name `values` does not hold raises, naming it, so a typo is not written as text.
--- @param template string The text, with `{name}` slots
--- @param values {string: string | number | boolean} The value of each slot
--- @return string The text, filled
function String.fill(template: string, values: {string: string | number | boolean}): string
  local out: mut {string} = {}
  local at = 1
  while at <= #template do
    local two = template:sub(at, at + 1)
    if two == "{{" or two == "}}" then
      out[#out + 1] = two:sub(1, 1)
      at = at + 2
    else
      local name, stop = template:match("^{([%a_][%w_]*)}()", at)
      if name ~= nil and stop is integer then
        local value = values[name]
        if value == nil then error("string: fill: no value for {" .. name .. "}", 2) end
        out[#out + 1] = tostring(value)
        at = stop
      else
        out[#out + 1] = template:sub(at, at)
        at = at + 1
      end
    end
  end
  return table.concat(out)
end

return String
