--- Regular expression matching using POSIX extended regex syntax.
--- Wraps cosmo.re for pattern compilation and matching. Module-level
--- functions are SUBJECT-FIRST D20: match(text, pattern), like
--- string.match. The compiled Regex keeps the binding's own :search
--- method name — a userdata metatable is the C layer's to name.
---
--- For best performance, compile patterns once and reuse them.
--- The convenience functions (match, test, find, find_all, gmatch,
--- split, gsub) take a pattern string per call; a bounded module cache
--- memoizes their compiled patterns, so repeated calls with the same
--- pattern skip recompilation. compile() itself is never cached: it is
--- the explicit-lifetime API, and each call returns a fresh handle.
local re = require("cosmo.re")

--- A compiled regular expression pattern.
--- Use compile() to create, then call :search() for O(n) matching.
local record Regex
  -- Runtime values are cosmo.re's compiled-regex userdata (compile()
  -- casts them in), so `x is Regex` must test for userdata.
  userdata
  --- Search for pattern match in text.
  --- On a match, returns the matched substring plus a table of the
  --- parenthesized capture groups (an empty table when the pattern has
  --- no groups, "" for groups that did not participate). A no-match is
  --- not an error: it returns a single bare nil. A genuine engine
  --- failure (e.g. out of memory) returns nil, err — the error string
  --- arrives in the second position, mirroring the cosmo.re binding.
  --- @param text string The text to search
  --- @param flags integer? Optional flags: NOTBOL, NOTEOL
  --- @return string | nil The matched substring, or nil if no match
  --- @return {string} | nil Capture groups on match (error string on engine failure)
  --- @return string | nil Error message on engine failure
  search: function(self: Regex, text: string, flags?: integer): string | nil, {string} | nil, string | nil
end

--- Compile a regular expression pattern.
--- Compiled patterns can be reused for efficient O(n) matching.
--- Uses POSIX extended syntax by default.
--- @param pattern string The regex pattern to compile
--- @param flags integer? Optional flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return Regex? The compiled regex, or nil on error
--- @return string? Error message if compilation failed
local function compile(pattern: string, flags?: integer): Regex | nil, string
  local result, err = re.compile(pattern, flags)
  if not result then
    return nil, err
  end
  return result as Regex -- cast: userdata boundary
end

--- One memoized compilation of a convenience-surface pattern. rx/err
--- record the compile outcome; iter_ok/iter_err record the (lazy)
--- empty-match probe compile_for_iter runs on top of it.
local record CacheEntry
  rx: Regex
  err: string
  iter_ok: boolean
  iter_err: string
end

--- Bounded pattern-string -> CacheEntry memo for the convenience
--- functions. Wiped wholesale when full: eviction bookkeeping isn't
--- worth it for a cache whose hit case is "the same handful of
--- patterns in a loop", and a wipe only costs the recompiles the cache
--- was already paying before it filled.
local CACHE_MAX = 64
local cache: {string: CacheEntry} = {}
local cache_count = 0

--- The memo key. Flags are part of a pattern's identity: the same
--- source compiled with ICASE is a different regex.
--- @param pattern string The regex pattern
--- @param flags integer? Optional compile flags
--- @return string The cache key
local function cache_key(pattern: string, flags?: integer): string
  return tostring(flags or 0) .. "\0" .. pattern
end

--- Get-or-create the memo entry for a pattern, compiling on miss.
--- Compile failures are cached too, so a bad pattern in a loop pays
--- one compile, not one per call.
--- @param pattern string The regex pattern
--- @param flags integer? Optional compile flags
--- @return CacheEntry The entry (rx set on success, err on failure)
local function cache_entry(pattern: string, flags?: integer): CacheEntry
  local key = cache_key(pattern, flags)
  local entry = cache[key]
  if entry ~= nil then
    return entry
  end
  if cache_count >= CACHE_MAX then
    cache = {}
    cache_count = 0
  end
  local rx, cerr = compile(pattern, flags)
  if rx is Regex then
    entry = {rx = rx}
  else
    entry = {err = cerr or "regex compile failed"}
  end
  cache[key] = entry
  cache_count = cache_count + 1
  return entry
end

--- Match pattern against text (convenience function; subject first).
--- Compiled patterns are cached - compile() gives explicit reuse.
--- Uses POSIX extended syntax by default.
--- On a match, returns the matched substring plus a table of the
--- parenthesized capture groups (an empty table when the pattern has no
--- groups, "" for groups that did not participate). A no-match returns
--- nil with no error; a bad pattern or an engine failure returns
--- nil, nil, err.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return string | nil The matched substring, or nil on no match or error
--- @return {string} | nil Capture groups on match
--- @return string | nil Error message if compilation or the engine failed
local function match(text: string, pattern: string, flags?: integer): string | nil, {string} | nil, string | nil
  local entry = cache_entry(pattern, flags)
  local regex, cerr = entry.rx, entry.err
  if regex is Regex then
    -- Search flags (NOTBOL/NOTEOL) are not passed here; use compile() + :search() for those
    local m, caps = regex:search(text)
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
  return nil, nil, cerr
end

--- Check if pattern matches anywhere in text (subject first).
--- Convenience predicate returning boolean instead of matched text.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB
--- @return boolean True if pattern matches, false otherwise
--- @return string? Error message if compilation or the engine failed
local function test(text: string, pattern: string, flags?: integer): boolean, string
  local m, _, err = match(text, pattern, flags)
  if err then
    return false, err
  end
  return m ~= nil
end

--- Iterator yielded by gmatch: each call returns the next match and
--- its capture table, then nil when exhausted.
local type MatchIterator = function(): string, {string}

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
---
--- KNOWN LIMITATION: the verification window is exactly #m characters
--- (found .. found + #m - 1), so it never includes the character before
--- or after a candidate. Under the NEWLINE compile flag, `^` and `$`
--- can be satisfied by an EMBEDDED newline rather than true text
--- start/end ("regardless of NOTBOL/NOTEOL" per POSIX) -- but that
--- newline byte falls outside this window, so the re-verification
--- search can never see it and always fails to confirm. The result
--- is not a silent undercount: all_matches gives up entirely (its
--- caller sees nil, "failed to locate ..."/a short match count)
--- as soon as a NEWLINE-anchored match past the first line is hit.
--- See find_all's doc for the concrete case. A fix needs the
--- verification window widened to include that neighboring byte,
--- which reintroduces its own edge case (an off-by-one window can
--- itself contain another literal occurrence of m); not attempted here.
local function locate(regex: Regex, text: string, pos: integer, m: string): integer | nil
  local q = pos
  while true do
    local found = text:find(m, q, true)
    if not found then
      return nil
    end
    local vflags: integer = 0
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
local function compile_for_iter(pattern: string, flags?: integer): Regex | nil, string
  local entry = cache_entry(pattern, flags)
  if entry.rx == nil then
    return nil, entry.err
  end
  if entry.iter_err ~= nil then
    return nil, entry.iter_err
  end
  if not entry.iter_ok then
    local em = entry.rx:search("")
    if em then
      entry.iter_err = "pattern matches the empty string unsupported: " .. pattern
      return nil, entry.iter_err
    end
    entry.iter_ok = true
  end
  return entry.rx
end

--- Collect every non-overlapping match of regex in text, leftmost
--- first, as absolute spans. Returns nil + error on engine failure or
--- when a match cannot be located.
local function all_matches(regex: Regex, text: string): {Span} | nil, string
  local spans: {Span} = {}
  local pos = 1
  while pos <= #text do
    local sflags: integer = 0
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
    local si = s
    spans[#spans + 1] = {s = si, e = si + #m - 1, m = m, caps = caps}
    pos = si + #m
  end
  return spans
end

--- Find the first match of pattern in text, with its position: a Span
--- {s, e, m, caps} (absolute 1-based, inclusive). A no-match returns
--- bare nil; a bad pattern or engine failure returns nil, err.
--- Patterns that can match the empty string are rejected.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return Span | nil The first match, or nil when none
--- @return string? Error message on a bad pattern or engine failure
local function find(text: string, pattern: string, flags?: integer): Span | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local m, caps = regex:search(text)
  if not m then
    if caps then
      return nil, tostring(caps)
    end
    return nil
  end
  local start = locate(regex, text, 1, m)
  if not start then
    return nil, "failed to locate match position for: " .. m
  end
  return {s = start, e = start + #m - 1, m = m, caps = caps}
end

--- Every non-overlapping match of pattern in text, leftmost first, as
--- Spans. Patterns that can match the empty string are rejected.
---
--- KNOWN LIMITATION with the NEWLINE flag: `^`/`$` anchors that only
--- match via an embedded newline (not the true start/end of text) fail
--- to be re-confirmed past the first line (see locate's doc), so
--- find_all("foo\nfoo", "^foo", re.NEWLINE) returns nil, "failed to
--- locate match position for: foo" instead of two spans -- use
--- split plus a per-line match instead when this matters.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return {Span} | nil The matches (empty when none), or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function find_all(text: string, pattern: string, flags?: integer): {Span} | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  return all_matches(regex, text)
end

--- Iterate every non-overlapping match, like string.gmatch: each step
--- yields the matched text and its capture table. Matching is done up
--- front (the engine reports no offsets, so lazy stepping buys
--- nothing); a bad pattern or engine failure returns nil, err instead
--- of an iterator. Shares find_all's NEWLINE limitation.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return function | nil Iterator yielding (match, caps), or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function gmatch(text: string, pattern: string, flags?: integer): MatchIterator, string
  local spans, err = find_all(text, pattern, flags)
  if not spans then
    return nil, err
  end
  local i = 0
  local iter: MatchIterator = function(): string, {string}
    i = i + 1
    local sp = (spans)[i]
    if not sp then
      return nil
    end
    return sp.m, sp.caps
  end
  return iter
end

--- Split text around every match of pattern. Fields between matches
--- are kept verbatim, including empty ones from adjacent or
--- leading/trailing matches; text with no match yields one field.
--- Patterns that can match the empty string are rejected.
--- Shares find_all's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
--- past the first line (see find_all's doc).
--- @param text string The text to split
--- @param pattern string The regex pattern to split on
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return {string} | nil The fields, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function split(text: string, pattern: string, flags?: integer): {string} | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local spans, err = all_matches(regex, text)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  local pos = 1
  for _, sp in ipairs(spans) do
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
--- Shares find_all's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
--- past the first line (see find_all's doc).
--- @param text string The text to operate on
--- @param pattern string The regex pattern to match
--- @param repl Repl A literal replacement string, or function(match, caps)
--- @param flags integer? Optional compile flags: BASIC, ICASE, NEWLINE
--- @return string | nil The result, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function gsub(text: string, pattern: string, repl: Repl, flags?: integer): string | nil, string
  local regex, cerr = compile_for_iter(pattern, flags)
  if not regex then
    return nil, cerr
  end
  local spans, err = all_matches(regex, text)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  local pos = 1
  for _, sp in ipairs(spans) do
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
  -- Exported so callers can name/cast the fallible results.
  type Regex = Regex
  type Repl = Repl
  type Span = Span

  -- Functions (subject first, D20)
  compile: function(pattern: string, flags?: integer): Regex | nil, string
  match: function(text: string, pattern: string, flags?: integer): string | nil, {string} | nil, string | nil
  test: function(text: string, pattern: string, flags?: integer): boolean, string
  find: function(text: string, pattern: string, flags?: integer): Span | nil, string
  find_all: function(text: string, pattern: string, flags?: integer): {Span} | nil, string
  type MatchIterator = MatchIterator
  gmatch: function(text: string, pattern: string, flags?: integer): MatchIterator, string
  split: function(text: string, pattern: string, flags?: integer): {string} | nil, string
  gsub: function(text: string, pattern: string, repl: Repl, flags?: integer): string | nil, string

  -- Compile flags
  BASIC: integer -- Use basic (obsolete) regex syntax instead of extended
  ICASE: integer -- Case-insensitive matching
  NEWLINE: integer -- Treat newline as special (affects ^ and $)
  NOSUB: integer -- Report only success/failure, not match position

  -- Search flags
  NOTBOL: integer -- First character is not at beginning of line
  NOTEOL: integer -- Last character is not at end of line
end

local M: ReModule = {
  compile = compile,
  match = match,
  test = test,
  find = find,
  find_all = find_all,
  gmatch = gmatch,
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
