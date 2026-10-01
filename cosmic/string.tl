--- Small text operations a program otherwise writes by hand: splitting
--- on a separator, iterating over lines, trimming, testing a prefix or
--- suffix, and counting a noun. Every separator, prefix and suffix is plain
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
    error("string: split needs a separator that is not empty", 2)
  end
  local pieces: {string} = {}
  local from = 1
  while true do
    local at, stop = text:find(separator, from, true)
    if at == nil then break end
    pieces[#pieces + 1] = text:sub(from, at - 1)
    from = stop + 1
  end
  pieces[#pieces + 1] = text:sub(from)
  return pieces
end

--- An iterator over the lines of `text`: exactly the pieces
--- `split(text, "\n")` answers, so text ending in "\n" has an empty last
--- line, as "a\n" gives "a" and then "", and "" has one empty line. A "\r"
--- before the "\n" stays on its line.
--- @param text string The text to read
--- @return function(): string The next line, or nil after the last
function String.lines(text: string): function(): string
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

--- `n` and `singular` as a count of things, "1 entry" or "2 entries": the
--- noun is `several` unless `n` is 1, and `several` is `singular` with an
--- `s` when not given. Only 1 takes the singular, so "0 entries" and
--- "-1 entries" are plural.
--- @param n integer The count to write
--- @param singular string The noun for one
--- @param several string | nil The noun for any other count; `singular` and an "s" when nil
--- @return string The count, a space and the noun
function String.counted(n: integer, singular: string, several?: string): string
  return n .. " " .. (n == 1 and singular or several or singular .. "s")
end

return String
