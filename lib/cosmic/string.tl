--- String utilities.
--- Common string manipulation functions for trimming, splitting, and case conversion.
---
--- Example usage:
---   local str = require("cosmic.string")
---   str.capitalize("hello")           -- "Hello"
---   str.trim("  hello  ")             -- "hello"
---   str.split("a,b,c", ",")           -- {"a", "b", "c"}
---   str.starts_with("hello", "he")    -- true

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

--- Convert a string to uppercase.
--- @param s string The string to convert
--- @return string The uppercase string
local function upper(s: string): string
  return s:upper()
end

--- Convert a string to lowercase.
--- @param s string The string to convert
--- @return string The lowercase string
local function lower(s: string): string
  return s:lower()
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

local record StringModule
  capitalize: function(s: string): string
  upper: function(s: string): string
  lower: function(s: string): string
  trim: function(s: string): string
  ltrim: function(s: string): string
  rtrim: function(s: string): string
  split: function(s: string, sep: string): {string}
  starts_with: function(s: string, prefix: string): boolean
  ends_with: function(s: string, suffix: string): boolean
end

local M: StringModule = {
  capitalize = capitalize,
  upper = upper,
  lower = lower,
  trim = trim,
  ltrim = ltrim,
  rtrim = rtrim,
  split = split,
  starts_with = starts_with,
  ends_with = ends_with,
}

return M
