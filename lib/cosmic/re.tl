--- Regular expression matching using POSIX extended regex syntax.
--- Wraps cosmo.re for pattern compilation and searching.
---
--- For best performance, compile patterns once and reuse them.
--- The search() convenience function compiles on each call (O(2^n) complexity).
local re = require("cosmo.re")

--- A compiled regular expression pattern.
--- Use compile() to create, then call :search() for O(n) matching.
local record Regex
  --- Search for pattern match in text.
  --- On a match, returns the matched substring plus a table of the
  --- parenthesized capture groups (an empty table when the pattern has
  --- no groups, "" for groups that did not participate). A no-match is
  --- not an error: it returns a single bare nil. A genuine engine
  --- failure (e.g. out of memory) returns nil, err — the error string
  --- arrives in the second position, mirroring the cosmo.re binding.
  --- @param text string The text to search
  --- @param flags number? Optional flags: NOTBOL, NOTEOL
  --- @return string The matched substring, or nil if no match
  --- @return {string} Capture groups on match (error string on engine failure)
  search: function(self: Regex, text: string, flags?: number): string, {string}, string | nil
end

--- Compile a regular expression pattern.
--- Compiled patterns can be reused for efficient O(n) matching.
--- Uses POSIX extended syntax by default.
--- @param pattern string The regex pattern to compile
--- @param flags number? Optional flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return Regex? The compiled regex, or nil on error
--- @return string? Error message if compilation failed
local function compile(pattern: string, flags?: number): Regex | nil, string
  local result, err = re.compile(pattern, flags)
  if not result then
    return nil, err as string
  end
  return result as Regex
end

--- Search for pattern match in text (convenience function).
--- Compiles pattern on each call - use compile() for repeated searches.
--- Uses POSIX extended syntax by default.
--- On a match, returns the matched substring plus a table of the
--- parenthesized capture groups (an empty table when the pattern has no
--- groups, "" for groups that did not participate). A no-match returns
--- nil with no error; a bad pattern or an engine failure returns
--- nil, nil, err.
--- @param pattern string The regex pattern to search for
--- @param text string The text to search in
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return string | nil The matched substring, or nil on no match or error
--- @return {string} | nil Capture groups on match
--- @return string | nil Error message if compilation or the engine failed
local function search(pattern: string, text: string, flags?: number): string | nil, {string} | nil, string | nil
  local regex, cerr = compile(pattern, flags)
  if not regex then
    return nil, nil, cerr
  end
  -- Search flags (NOTBOL/NOTEOL) are not passed here; use compile() + :search() for those
  local m, caps = (regex as Regex):search(text)
  if not m then
    if caps then
      -- Engine failure: the binding reports nil, err.
      return nil, nil, tostring(caps)
    end
    -- No match is not an error.
    return nil
  end
  return m, caps
end

--- Check if pattern matches anywhere in text.
--- Convenience function that returns boolean instead of matched text.
--- @param pattern string The regex pattern to match
--- @param text string The text to search in
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return boolean True if pattern matches, false otherwise
--- @return string? Error message if compilation or the engine failed
local function match(pattern: string, text: string, flags?: number): boolean, string
  local m, _, err = search(pattern, text, flags)
  if err then
    return false, err
  end
  return m ~= nil
end

local record ReModule
  -- Exported so callers can name/cast the fallible compile result.
  type Regex = Regex

  -- Functions
  compile: function(pattern: string, flags?: number): Regex | nil, string
  search: function(pattern: string, text: string, flags?: number): string | nil, {string} | nil, string | nil
  match: function(pattern: string, text: string, flags?: number): boolean, string

  -- Compile flags
  BASIC: number -- Use basic (obsolete) regex syntax instead of extended
  ICASE: number -- Case-insensitive matching
  NEWLINE: number -- Treat newline as special (affects ^ and $)
  NOSUB: number -- Report only success/failure, not match position

  -- Search flags
  NOTBOL: number -- First character is not at beginning of line
  NOTEOL: number -- Last character is not at end of line
end

local M: ReModule = {
  compile = compile,
  search = search,
  match = match,

  -- Expose flags from cosmo.re
  BASIC = re.BASIC,
  ICASE = re.ICASE,
  NEWLINE = re.NEWLINE,
  NOSUB = re.NOSUB,
  NOTBOL = re.NOTBOL,
  NOTEOL = re.NOTEOL,
}

return M
