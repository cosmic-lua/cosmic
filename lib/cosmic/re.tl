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
--- Named test (not match) to avoid confusion with Lua's string.match,
--- which returns the matched text.
--- @param pattern string The regex pattern to match
--- @param text string The text to search in
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return boolean True if pattern matches, false otherwise
--- @return string? Error message if compilation or the engine failed
local function test(pattern: string, text: string, flags?: number): boolean, string
  local m, _, err = search(pattern, text, flags)
  if err then
    return false, err
  end
  return m ~= nil
end

--- A located match: absolute 1-based start/stop, the matched text,
--- and its capture groups.
local record Span
  s: integer
  e: integer
  m: string
  caps: {string}
end

--- Locate the absolute start of a match whose text is m, at or after
--- pos. The binding reports matched text without offsets, so candidate
--- positions (plain-text occurrences of m) are verified by re-running
--- the pattern anchored to exactly that window, with NOTBOL/NOTEOL
--- supplying the line-boundary context. The engine's leftmost-match
--- guarantee makes the first verified candidate the true position.
local function locate(regex: Regex, text: string, pos: integer, m: string): integer | nil
  local q = pos
  while true do
    local found = text:find(m, q, true)
    if not found then
      return nil
    end
    local vflags: number = 0
    if found > 1 then
      vflags = vflags | re.NOTBOL
    end
    if found + #m - 1 < #text then
      vflags = vflags | re.NOTEOL
    end
    local vm = regex:search(text:sub(found, found + #m - 1), vflags)
    if vm == m then
      return found
    end
    q = found + 1
  end
end

--- Compile a pattern for iteration and reject patterns that can match
--- the empty string: without offsets from the engine a zero-length
--- match cannot be positioned or advanced past.
local function compile_for_iter(pattern: string, flags?: number): Regex | nil, string
  local regex, cerr = compile(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local em = (regex as Regex):search("")
  if em then
    return nil, "pattern matches the empty string (unsupported): " .. pattern
  end
  return regex
end

--- Collect every non-overlapping match of regex in text, leftmost
--- first, as absolute spans. Returns nil + error on engine failure or
--- when a match cannot be located.
local function all_matches(regex: Regex, text: string): {Span} | nil, string
  local spans: {Span} = {}
  local pos = 1
  while pos <= #text do
    local sflags: number = 0
    if pos > 1 then
      sflags = re.NOTBOL
    end
    local m, caps = regex:search(text:sub(pos), sflags)
    if not m then
      if caps then
        return nil, tostring(caps)
      end
      break
    end
    local s = locate(regex, text, pos, m)
    if not s then
      return nil, "failed to locate match position for: " .. m
    end
    local si = s as integer
    spans[#spans + 1] = {s = si, e = si + #m - 1, m = m, caps = caps}
    pos = si + #m
  end
  return spans
end

--- Find every non-overlapping match of pattern in text, leftmost
--- first. Patterns that can match the empty string are rejected.
--- @param pattern string The regex pattern to match
--- @param text string The text to search in
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return {string} | nil The matched substrings (empty when none), or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function findall(pattern: string, text: string, flags?: number): {string} | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local spans, err = all_matches(regex as Regex, text)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  for i, sp in ipairs(spans as {Span}) do
    out[i] = sp.m
  end
  return out
end

--- Split text around every match of pattern. Fields between matches
--- are kept verbatim, including empty ones from adjacent or
--- leading/trailing matches; text with no match yields one field.
--- Patterns that can match the empty string are rejected.
--- @param pattern string The regex pattern to split on
--- @param text string The text to split
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return {string} | nil The fields, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function split(pattern: string, text: string, flags?: number): {string} | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local spans, err = all_matches(regex as Regex, text)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  local pos = 1
  for _, sp in ipairs(spans as {Span}) do
    out[#out + 1] = text:sub(pos, sp.s - 1)
    pos = sp.e + 1
  end
  out[#out + 1] = text:sub(pos)
  return out
end

--- Replacement for gsub: a literal string (no capture references —
--- "%1" is two plain characters), or a function receiving the matched
--- text and its capture groups; a nil return keeps the match unchanged.
local type Repl = string | function(string, {string}): string

--- Replace every non-overlapping match of pattern in text.
--- Patterns that can match the empty string are rejected.
--- @param pattern string The regex pattern to match
--- @param text string The text to operate on
--- @param repl Repl A literal replacement string, or function(match, caps)
--- @param flags number? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return string | nil The result, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function gsub(pattern: string, text: string, repl: Repl, flags?: number): string | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local spans, err = all_matches(regex as Regex, text)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  local pos = 1
  for _, sp in ipairs(spans as {Span}) do
    out[#out + 1] = text:sub(pos, sp.s - 1)
    if repl is string then
      out[#out + 1] = repl
    else
      local r = repl(sp.m, sp.caps)
      if r is string then
        out[#out + 1] = r
      else
        out[#out + 1] = sp.m
      end
    end
    pos = sp.e + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

local record ReModule
  -- Exported so callers can name/cast the fallible compile result.
  type Regex = Regex
  type Repl = Repl

  -- Functions
  compile: function(pattern: string, flags?: number): Regex | nil, string
  search: function(pattern: string, text: string, flags?: number): string | nil, {string} | nil, string | nil
  test: function(pattern: string, text: string, flags?: number): boolean, string
  findall: function(pattern: string, text: string, flags?: number): {string} | nil, string
  split: function(pattern: string, text: string, flags?: number): {string} | nil, string
  gsub: function(pattern: string, text: string, repl: Repl, flags?: number): string | nil, string

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
  test = test,
  findall = findall,
  split = split,
  gsub = gsub,

  -- Expose flags from cosmo.re
  BASIC = re.BASIC,
  ICASE = re.ICASE,
  NEWLINE = re.NEWLINE,
  NOSUB = re.NOSUB,
  NOTBOL = re.NOTBOL,
  NOTEOL = re.NOTEOL,
}

return M
