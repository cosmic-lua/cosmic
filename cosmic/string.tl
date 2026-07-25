--- String utilities.
--- Common string manipulation functions for trimming, splitting, searching,
--- padding, and quoting. All functions are infallible and treat their
--- arguments as plain text (no Lua patterns).
---
--- Example usage:
---   local str = require("cosmic.string")
---   str.capitalize("hello")           -- "Hello"
---   str.trim("  hello  ")             -- "hello"
---   str.split("a,b,c", ",")           -- {"a", "b", "c"}
---   str.starts_with("hello", "he")    -- true
---   str.contains("hello", "ell")      -- true
---   str.replace("a-b-c", "-", "+")    -- "a+b+c"
---   str.fields("  a  b  ")            -- {"a", "b"}

--- Capitalize the first character of a string.
--- Converts the first character to uppercase, leaving the rest unchanged.
--- @param s string The string to capitalize
--- @return string The string with first character capitalized
local function capitalize(s: string): string
  if s == "" then
    return s
  end
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Trim whitespace from both ends of a string.
--- @param s string The string to trim
--- @return string The trimmed string
local function trim(s: string): string
  return s:match("^%s*(.-)%s*$") or s
end

--- Trim whitespace from the left side of a string.
--- @param s string The string to trim
--- @return string The left-trimmed string
local function ltrim(s: string): string
  return s:match("^%s*(.*)$") or s
end

--- Trim whitespace from the right side of a string.
--- @param s string The string to trim
--- @return string The right-trimmed string
local function rtrim(s: string): string
  return s:match("^(.-)%s*$") or s
end

--- Split a string by a separator.
--- If separator is empty string, splits into individual characters.
--- Trailing empty fields (from a trailing separator) are preserved.
--- @param s string The string to split
--- @param sep string The separator to split on
--- @return {string} Array of substrings
local function split(s: string, sep: string): {string}
  local result: {string} = {}
  local n = 0
  if sep == "" then
    for i = 1, #s do
      n = n + 1
      result[n] = s:sub(i, i)
    end
    return result
  end
  if s == "" then
    return result
  end
  local pos = 1
  local sep_len = #sep
  while true do
    local found = s:find(sep, pos, true)
    if not found then
      n = n + 1
      result[n] = s:sub(pos)
      break
    end
    n = n + 1
    result[n] = s:sub(pos, found - 1)
    pos = found + sep_len
  end
  return result
end

--- Check if a string starts with a prefix.
--- @param s string The string to check
--- @param prefix string The prefix to look for
--- @return boolean True if s starts with prefix
local function starts_with(s: string, prefix: string): boolean
  return s:sub(1, #prefix) == prefix
end

--- Check if a string ends with a suffix.
--- @param s string The string to check
--- @param suffix string The suffix to look for
--- @return boolean True if s ends with suffix
local function ends_with(s: string, suffix: string): boolean
  return suffix == "" or s:sub(-#suffix) == suffix
end

--- Check if a string contains a substring.
--- Plain-text search; the substring is not a Lua pattern.
--- The empty substring is contained in every string.
--- @param s string The string to search
--- @param sub string The substring to look for
--- @return boolean True if s contains sub
local function contains(s: string, sub: string): boolean
  if sub == "" then
    return true
  end
  return s:find(sub, 1, true) ~= nil
end

--- Count non-overlapping occurrences of a substring.
--- Plain-text search; the substring is not a Lua pattern.
--- The empty substring counts as zero occurrences.
--- @param s string The string to search
--- @param sub string The substring to count
--- @return integer Number of non-overlapping occurrences
local function count(s: string, sub: string): integer
  if sub == "" then
    return 0
  end
  local n = 0
  local pos = 1
  while true do
    local found = s:find(sub, pos, true)
    if not found then
      return n
    end
    n = n + 1
    pos = found + #sub
  end
end

--- Replace occurrences of a substring with plain text.
--- Both old and new are treated literally (no Lua patterns, unlike
--- string.gsub). Replaces all occurrences unless max is given.
--- An empty old string returns s unchanged.
--- @param s string The string to operate on
--- @param old string The substring to replace
--- @param new string The replacement text
--- @param max integer? Maximum number of replacements (default unlimited)
--- @return string The string with replacements applied
local function replace(s: string, old: string, new: string, max?: integer): string
  if old == "" or max == 0 then
    return s
  end
  local parts: {string} = {}
  local n = 0
  local done = 0
  local pos = 1
  while true do
    local found = s:find(old, pos, true)
    if not found or (max and done >= max) then
      n = n + 1
      parts[n] = s:sub(pos)
      break
    end
    n = n + 1
    parts[n] = s:sub(pos, found - 1)
    n = n + 1
    parts[n] = new
    done = done + 1
    pos = found + #old
  end
  return table.concat(parts)
end

--- Split a string into lines.
--- Lines are separated by "\n"; a trailing "\r" on each line (from
--- "\r\n" endings) is removed. A final trailing newline does not
--- produce an extra empty line. The empty string yields no lines.
--- @param s string The string to split
--- @return {string} Array of lines without their line endings
local function lines(s: string): {string}
  local result: {string} = {}
  if s == "" then
    return result
  end
  if s:sub(-1) == "\n" then
    s = s:sub(1, -2)
  end
  local n = 0
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    n = n + 1
    result[n] = line
  end
  return result
end

--- Split the string at the first occurrence of a separator.
--- Plain-text search. If the separator is not found (or is empty),
--- returns the whole string followed by two empty strings.
--- @param s string The string to partition
--- @param sep string The separator to split at
--- @return string The part before the separator (or all of s)
--- @return string The separator if found, otherwise ""
--- @return string The part after the separator, otherwise ""
local function partition(s: string, sep: string): string, string, string
  if sep == "" then
    return s, "", ""
  end
  local found = s:find(sep, 1, true)
  if not found then
    return s, "", ""
  end
  return s:sub(1, found - 1), sep, s:sub(found + #sep)
end

--- Split a string around runs of whitespace.
--- Leading and trailing whitespace is ignored; the result contains
--- no empty strings. A blank or empty string yields no fields.
--- @param s string The string to split
--- @return {string} Array of whitespace-separated fields
local function fields(s: string): {string}
  local result: {string} = {}
  local n = 0
  for field in s:gmatch("%S+") do
    n = n + 1
    result[n] = field
  end
  return result
end

--- Pad a string on the left to a minimum width.
--- The pad string (default " ") is repeated as needed and truncated
--- so the result is exactly width characters. Strings already at
--- least width long are returned unchanged, as is any input when
--- the pad string is empty.
--- @param s string The string to pad
--- @param width integer Minimum width of the result
--- @param pad string? Padding text (default " ")
--- @return string The padded string
local function pad_left(s: string, width: integer, pad?: string): string
  pad = pad or " "
  local need = width - #s
  if need <= 0 or pad == "" then
    return s
  end
  local fill = pad:rep(math.ceil(need / #pad)):sub(1, need)
  return fill .. s
end

--- Pad a string on the right to a minimum width.
--- The pad string (default " ") is repeated as needed and truncated
--- so the result is exactly width characters. Strings already at
--- least width long are returned unchanged, as is any input when
--- the pad string is empty.
--- @param s string The string to pad
--- @param width integer Minimum width of the result
--- @param pad string? Padding text (default " ")
--- @return string The padded string
local function pad_right(s: string, width: integer, pad?: string): string
  pad = pad or " "
  local need = width - #s
  if need <= 0 or pad == "" then
    return s
  end
  local fill = pad:rep(math.ceil(need / #pad)):sub(1, need)
  return s .. fill
end

--- Remove common leading whitespace from all lines.
--- The margin is the longest whitespace prefix shared by every
--- non-blank line; blank (empty or whitespace-only) lines are ignored
--- when computing it and have the margin stripped where present.
--- Line endings are preserved.
--- @param s string The string to dedent
--- @return string The dedented string
local function dedent(s: string): string
  local margin: string | nil = nil
  for _, line in ipairs(split(s, "\n")) do
    if line:find("%S") then
      local prefix: string = line:match("^[ \t]*")
      if margin == nil then
        margin = prefix
      else
        local m = margin
        local i = 0
        local limit = math.min(#m, #prefix)
        while i < limit and prefix:sub(i + 1, i + 1) == string.sub(m, i + 1, i + 1) do
          i = i + 1
        end
        margin = string.sub(m, 1, i)
      end
    end
  end
  if margin == nil or margin == "" then
    return s
  end
  local m = margin
  local out: {string} = {}
  for i, line in ipairs(split(s, "\n")) do
    if line:sub(1, #m) == m then
      out[i] = line:sub(#m + 1)
    else
      out[i] = line
    end
  end
  return table.concat(out, "\n")
end

--- Prefix each non-blank line of a string.
--- Blank (empty or whitespace-only) lines are left unchanged.
--- Line endings are preserved.
--- @param s string The string to indent
--- @param prefix string The prefix to add to each non-blank line
--- @return string The indented string
local function indent(s: string, prefix: string): string
  local out: {string} = {}
  for i, line in ipairs(split(s, "\n")) do
    if line:find("%S") then
      out[i] = prefix .. line
    else
      out[i] = line
    end
  end
  return table.concat(out, "\n")
end

--- Truncate a string to a maximum width, appending a suffix when cut.
--- Widths count bytes, not display characters. Strings at most width
--- long are returned unchanged. Otherwise the result is exactly width
--- bytes ending in the suffix (default "..."); if width is too small
--- to fit the suffix, the string is hard-cut to width without it.
--- @param s string The string to truncate
--- @param width integer Maximum width of the result
--- @param suffix string? Marker appended when truncated (default "...")
--- @return string The truncated string
local function truncate(s: string, width: integer, suffix?: string): string
  if #s <= width then
    return s
  end
  if width <= 0 then
    return ""
  end
  suffix = suffix or "..."
  local keep = width - #suffix
  if keep < 1 then
    return s:sub(1, width)
  end
  return s:sub(1, keep) .. suffix
end

--- Quote a string for use as a single word in a POSIX shell.
--- Safe strings (alphanumerics and ._-/=:,+@%) are returned unchanged;
--- everything else is wrapped in single quotes with embedded single
--- quotes escaped. The empty string quotes to ''.
--- @param s string The string to quote
--- @return string The shell-quoted string
local function shell_quote(s: string): string
  if s == "" then
    return "''"
  end
  if s:match("^[%w%._%-/=:,+@%%]+$") then
    return s
  end
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local record StringModule
  capitalize: function(s: string): string
  trim: function(s: string): string
  ltrim: function(s: string): string
  rtrim: function(s: string): string
  split: function(s: string, sep: string): {string}
  starts_with: function(s: string, prefix: string): boolean
  ends_with: function(s: string, suffix: string): boolean
  contains: function(s: string, sub: string): boolean
  count: function(s: string, sub: string): integer
  replace: function(s: string, old: string, new: string, max?: integer): string
  lines: function(s: string): {string}
  partition: function(s: string, sep: string): string, string, string
  fields: function(s: string): {string}
  pad_left: function(s: string, width: integer, pad?: string): string
  pad_right: function(s: string, width: integer, pad?: string): string
  dedent: function(s: string): string
  indent: function(s: string, prefix: string): string
  truncate: function(s: string, width: integer, suffix?: string): string
  shell_quote: function(s: string): string
end

local M: StringModule = {
  capitalize = capitalize,
  trim = trim,
  ltrim = ltrim,
  rtrim = rtrim,
  split = split,
  starts_with = starts_with,
  ends_with = ends_with,
  contains = contains,
  count = count,
  replace = replace,
  lines = lines,
  partition = partition,
  fields = fields,
  pad_left = pad_left,
  pad_right = pad_right,
  dedent = dedent,
  indent = indent,
  truncate = truncate,
  shell_quote = shell_quote,
}

return M
