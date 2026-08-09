--- Regular expression matching using POSIX extended regex syntax.
--- Wraps cosmo.re for pattern compilation and matching. Module-level
--- functions are SUBJECT-FIRST D20: match(text, pattern), like
--- string.match. Compile behavior is a CompileOptions record — a search
--- flag in a compile slot cannot type-check, where the old shared
--- integer namespace silently ignored it. The compiled Regex speaks
--- :match/:find with integer search flags (NOTBOL/NOTEOL) — a userdata
--- metatable is the C layer's to name, so `match` arriving on the
--- charter verb took an upstream change (cosmopolitan#237). For exact
--- plain-text search see cosmic.string; for approximate (edit-distance)
--- matching see cosmic.fuzzy.
---
--- For best performance, compile patterns once and reuse them.
--- The convenience functions (match, is_match, find, find_all, gmatch,
--- split, gsub) take a pattern string per call; a bounded module cache
--- memoizes their compiled patterns, so repeated calls with the same
--- pattern skip recompilation. compile() itself is never cached: it is
--- the explicit-lifetime API, and each call returns a fresh handle.
local re = require("cosmo.re")

--- A compiled regular expression pattern.
--- Use compile() to create, then call :match() for O(n) matching.
local record Regex
  -- Runtime values are cosmo.re's compiled-regex userdata (compile()
  -- casts them in), so `x is Regex` must test for userdata.
  userdata
  --- Match the pattern against text (D20 rule 9's reserved verb; the
  --- binding's metatable carries `match` since cosmopolitan#237, so
  --- this is the method itself and not a wrapper).
  --- On a match, returns the matched substring plus a table of the
  --- parenthesized capture groups (an empty table when the pattern has
  --- no groups, "" for groups that did not participate). A no-match is
  --- not an error: it returns a single bare nil. A genuine engine
  --- failure (e.g. out of memory) returns nil, err — the error string
  --- arrives in the second position, mirroring the cosmo.re binding.
  --- @param text string The text to match against
  --- @param flags integer? Optional flags: NOTBOL, NOTEOL
  --- @return string | nil The matched substring, or nil if no match
  --- @return {string} | nil Capture groups on match (error string on engine failure)
  --- @return string | nil Error message on engine failure
  -- returns: the binding's own metatable method — this record DESCRIBES
  -- cosmo.re's C shape (cosmopolitan#237), it does not choose it
  match: function(self: Regex, text: string, flags?: integer): string | nil, {string} | nil, string | nil

  --- Like match, but reports WHERE: absolute 1-based inclusive start
  --- and end offsets into text, plus the capture table. init starts
  --- the search at that offset while keeping the returned offsets
  --- absolute, which is what lets iteration advance in O(n) instead of
  --- re-slicing the subject per match. A no-match is a single bare
  --- nil; an engine failure puts the error string in the second
  --- position.
  --- @param text string The text to search
  --- @param flags integer? Optional flags: NOTBOL, NOTEOL
  --- @param init integer? 1-based offset to start searching at
  --- @return integer | nil Absolute start offset, or nil
  --- @return integer | string | nil End offset (error string when start is nil)
  --- @return {string} Capture groups on match
  -- returns: same C metatable as match above; the shape is cosmo.re's
  find: function(self: Regex, text: string, flags?: integer, init?: integer): integer | nil, integer | string | nil, {string}
end

--- Compile behavior. Each field maps to one POSIX cflag; a record
--- keeps the compile and search namespaces unmixable (the old integer
--- flags shared one namespace, so a search flag passed at compile time
--- type-checked and was silently ignored).
local record CompileOptions
  --- Basic (obsolete) regex syntax instead of extended.
  basic: boolean
  --- Case-insensitive matching.
  ignore_case: boolean
  --- Treat newline as special (affects ^ and $).
  newline: boolean
  --- Report only success/failure, not match position.
  no_sub: boolean
end

--- The binding's integer cflags for a CompileOptions record.
local function flags_of(opts?: CompileOptions): integer
  local flags = 0
  if opts then
    if opts.basic then flags = flags | re.BASIC end
    if opts.ignore_case then flags = flags | re.ICASE end
    if opts.newline then flags = flags | re.NEWLINE end
    if opts.no_sub then flags = flags | re.NOSUB end
  end
  return flags
end

--- Compile a regular expression pattern.
--- Compiled patterns can be reused for efficient O(n) matching.
--- Uses POSIX extended syntax by default.
--- @param pattern string The regex pattern to compile
--- @param opts CompileOptions? Compile behavior
--- @return Regex? The compiled regex, or nil on error
--- @return string? Error message if compilation failed
local function compile(pattern: string, opts?: CompileOptions): Regex | nil, string
  local result, err = re.compile(pattern, flags_of(opts))
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

--- The memo key. Options are part of a pattern's identity: the same
--- source compiled with ignore_case is a different regex.
--- @param pattern string The regex pattern
--- @param flags integer The resolved compile flags
--- @return string The cache key
local function cache_key(pattern: string, flags: integer): string
  return tostring(flags) .. "\0" .. pattern
end

--- Get-or-create the memo entry for a pattern, compiling on miss.
--- Compile failures are cached too, so a bad pattern in a loop pays
--- one compile, not one per call.
--- @param pattern string The regex pattern
--- @param opts CompileOptions? Compile behavior
--- @return CacheEntry The entry (rx set on success, err on failure)
local function cache_entry(pattern: string, opts?: CompileOptions): CacheEntry
  local flags = flags_of(opts)
  local key = cache_key(pattern, flags)
  local entry = cache[key]
  if entry ~= nil then
    return entry
  end
  if cache_count >= CACHE_MAX then
    cache = {}
    cache_count = 0
  end
  local rx, cerr = re.compile(pattern, flags) as (Regex | nil, string) -- cast: userdata boundary

  if rx is Regex then
    entry = {rx = rx}
  else
    entry = {err = cerr or "regex compile failed"}
  end
  cache[key] = entry
  cache_count = cache_count + 1
  return entry
end

--- One match: the matched text and its parenthesized capture groups
--- (an empty table when the pattern has none, "" for groups that did
--- not participate).
local record Match
  text: string
  caps: {string}
end

--- Match pattern against text (convenience function; subject first).
--- Compiled patterns are cached - compile() gives explicit reuse.
--- Uses POSIX extended syntax by default. Two slots, three honest
--- outcomes: a Match on success, bare nil on no match (not an error),
--- nil + err on a bad pattern or engine failure — the old three-slot
--- tuple made every call site hand-decode which nil it was looking at.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param opts CompileOptions? Compile behavior
--- @return Match | nil The match, or nil when none (or on error)
--- @return string | nil Error message if compilation or the engine failed
local function match(text: string, pattern: string, opts?: CompileOptions): Match | nil, string
  local entry = cache_entry(pattern, opts)
  local regex, cerr = entry.rx, entry.err
  if regex is Regex then
    local m, caps = regex:match(text)
    if not m then
      if caps then
        -- Engine failure: the binding reports nil, err.
        return nil, tostring(caps)
      end
      -- No match is not an error.
      return nil
    end
    return {text = m, caps = caps}
  end
  return nil, cerr
end

--- Whether pattern matches anywhere in text (subject first).
--- Three honest outcomes: true, false on a clean no-match, and
--- nil + err on a bad pattern — the old boolean shape returned false
--- for both, so "no match" and "your pattern is invalid" were the
--- same value. Narrow with `~= nil`, which is exact for boolean unions.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param opts CompileOptions? Compile behavior
--- @return boolean | nil The verdict, or nil on error
--- @return string? Error message if compilation or the engine failed
local function is_match(text: string, pattern: string, opts?: CompileOptions): boolean | nil, string
  local m, err = match(text, pattern, opts)
  if err then
    return nil, err
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

--- Compile a pattern for iteration and reject patterns that can match
--- the empty string: a zero-length match cannot be advanced past
--- (its end offset sits before its start, so iteration would not
--- move).
local function compile_for_iter(pattern: string, opts?: CompileOptions): Regex | nil, string
  local entry = cache_entry(pattern, opts)
  if entry.rx == nil then
    return nil, entry.err
  end
  if entry.iter_err ~= nil then
    return nil, entry.iter_err
  end
  if not entry.iter_ok then
    local em = entry.rx:match("")
    if em then
      entry.iter_err = "pattern matches the empty string unsupported: " .. pattern
      return nil, entry.iter_err
    end
    entry.iter_ok = true
  end
  return entry.rx
end

--- Collect every non-overlapping match of regex in text, leftmost
--- first, as absolute spans. The engine reports offsets directly
--- (Regex:find with init), so each step is one search from the
--- previous match's end -- no subject re-slicing, no relocation pass.
--- Returns nil + error on engine failure.
local function all_matches(regex: Regex, text: string): {Span} | nil, string
  local spans: {Span} = {}
  local pos = 1
  while pos <= #text do
    local sflags: integer = 0
    if pos > 1 then
      sflags = re.NOTBOL
    end
    local s, e, caps = regex:find(text, sflags, pos)
    if s == nil then
      if e is string then
        return nil, e
      end
      break
    end
    local ei = e as integer -- cast: tuple element (integer whenever start is non-nil)
    spans[#spans + 1] = {s = s, e = ei, m = text:sub(s, ei), caps = caps}
    pos = ei + 1
  end
  return spans
end

--- Find the first match of pattern in text, with its position: a Span
--- {s, e, m, caps} (absolute 1-based, inclusive). A no-match returns
--- bare nil; a bad pattern or engine failure returns nil, err.
--- Patterns that can match the empty string are rejected.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param opts CompileOptions? Compile behavior
--- @return Span | nil The first match, or nil when none
--- @return string? Error message on a bad pattern or engine failure
local function find(text: string, pattern: string, opts?: CompileOptions): Span | nil, string
  local regex, cerr = compile_for_iter(pattern, opts)
  if not regex then
    return nil, cerr
  end
  -- Explicit flags and init: also keeps the lexer-based find-needle
  -- lint (which cannot know the receiver is a Regex, not a string)
  -- from reading this as a two-argument string find.
  local s, e, caps = regex:find(text, 0, 1)
  if s == nil then
    if e is string then
      return nil, e
    end
    return nil
  end
  local ei = e as integer -- cast: tuple element (integer whenever start is non-nil)
  return {s = s, e = ei, m = text:sub(s, ei), caps = caps}
end

--- Every non-overlapping match of pattern in text, leftmost first, as
--- Spans. Patterns that can match the empty string are rejected.
---
--- Under the NEWLINE compile flag, `^`/`$` anchors match at embedded
--- newlines as POSIX specifies: find_all("foo\nfoo", "^foo",
--- re.NEWLINE) returns both spans. (The engine reports offsets
--- directly, which removed the relocation pass whose verification
--- window historically could not see those anchors past the first
--- line.)
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param opts CompileOptions? Compile behavior
--- @return {Span} | nil The matches (empty when none), or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function find_all(text: string, pattern: string, opts?: CompileOptions): {Span} | nil, string
  local regex, cerr = compile_for_iter(pattern, opts)
  if not regex then
    return nil, cerr
  end
  return all_matches(regex, text)
end

--- Iterate every non-overlapping match, like string.gmatch: each step
--- yields the matched text and its capture table. Matching is done up
--- front over find_all's spans; a bad pattern or engine failure
--- returns nil, err instead of an iterator — and the signature now
--- admits that nil, so `for m in re.gmatch(t, p) do` on a bad pattern
--- is a check error instead of a runtime crash.
--- @param text string The text to search in
--- @param pattern string The regex pattern to match
--- @param opts CompileOptions? Compile behavior
--- @return function | nil Iterator yielding (match, caps), or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function gmatch(text: string, pattern: string, opts?: CompileOptions): MatchIterator | nil, string
  local spans, err = find_all(text, pattern, opts)
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
--- @param text string The text to split
--- @param pattern string The regex pattern to split on
--- @param opts CompileOptions? Compile behavior
--- @return {string} | nil The fields, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function split(text: string, pattern: string, opts?: CompileOptions): {string} | nil, string
  local regex, cerr = compile_for_iter(pattern, opts)
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
--- @param text string The text to operate on
--- @param pattern string The regex pattern to match
--- @param repl Repl A literal replacement string, or function(match, caps)
--- @param opts CompileOptions? Compile behavior
--- @return string | nil The result, or nil on error
--- @return string? Error message on a bad pattern or engine failure
local function gsub(text: string, pattern: string, repl: Repl, opts?: CompileOptions): string | nil, string
  local regex, cerr = compile_for_iter(pattern, opts)
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
  type Match = Match
  type CompileOptions = CompileOptions

  -- Functions (subject first, D20)
  compile: function(pattern: string, opts?: CompileOptions): Regex | nil, string
  match: function(text: string, pattern: string, opts?: CompileOptions): Match | nil, string
  is_match: function(text: string, pattern: string, opts?: CompileOptions): boolean | nil, string
  find: function(text: string, pattern: string, opts?: CompileOptions): Span | nil, string
  find_all: function(text: string, pattern: string, opts?: CompileOptions): {Span} | nil, string
  type MatchIterator = MatchIterator
  gmatch: function(text: string, pattern: string, opts?: CompileOptions): MatchIterator | nil, string
  split: function(text: string, pattern: string, opts?: CompileOptions): {string} | nil, string
  gsub: function(text: string, pattern: string, repl: Repl, opts?: CompileOptions): string | nil, string

  -- Search flags for the raw Regex layer (:search/:find), whose method
  -- names and integer flags belong to the binding's userdata metatable.
  NOTBOL: integer -- First character is not at beginning of line
  NOTEOL: integer -- Last character is not at end of line
end

local M: ReModule = {
  compile = compile,
  match = match,
  is_match = is_match,
  find = find,
  find_all = find_all,
  gmatch = gmatch,
  split = split,
  gsub = gsub,

  NOTBOL = re.NOTBOL,
  NOTEOL = re.NOTEOL,
}

return M
