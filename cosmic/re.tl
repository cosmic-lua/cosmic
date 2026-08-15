--- Regular expression matching using POSIX extended regex syntax.
--- Wraps cosmo.re for pattern compilation and matching. Module-level
--- functions are subject-first: match(text, pattern), like
--- string.match. Behavior comes in two records: CompileOptions fixes
--- what a pattern means and belongs to the compiled Regex;
--- SearchOptions describes one subject and applies per call. They are
--- separate types because neither set is usable in the other's slot.
---
--- Regex is cosmo.re's own userdata, so its :match/:find take an
--- integer flag word rather than a record; search_flags() builds that
--- word from a SearchOptions.
---
--- gmatch and gsub mirror string.gmatch/string.gsub, whose behavior a
--- Lua reader already knows.
---
--- For exact plain-text search see cosmic.string; for approximate
--- (edit-distance) matching see cosmic.fuzzy.
---
--- For best performance, compile patterns once and reuse them.
--- The convenience functions (match, is_match, find, find_all, gmatch,
--- split, gsub) take a pattern string per call; a bounded module cache
--- memoizes their compiled patterns, so repeated calls with the same
--- pattern skip recompilation. compile() itself is never cached: it is
--- the explicit-lifetime API, and each call returns a fresh handle.
local re = require("cosmo.re")

--- A compiled regular expression pattern, as returned by compile().
--- Use compile() to create, then call :match() for O(n) matching.
---
--- This IS `cosmo.re`'s type, not a mirror of it. The methods live on
--- the binding's own metatable, so their shapes are declared once, in
--- the generated `cosmo/re.d.tl`, where a C tuple belongs — restating
--- them here meant a hand-copy that could drift from the binding (and
--- a `:match` slot the binding never returns), plus a userdata cast on
--- every value crossing between the two nominally-different records.
local type Regex = re.Regex

--- Compile behavior. Each field maps to one POSIX cflag; a record
--- keeps the compile and search namespaces unmixable, so a search
--- flag passed at compile time fails to type-check instead of being
--- silently accepted and ignored.
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

--- What the subject's edges mean for one search. A pattern is
--- compiled once but searched against many subjects, some of which
--- are slices of a larger text whose edges are not line boundaries —
--- so these belong to the call, not to CompileOptions.
local record SearchOptions
  --- The subject does not begin a line, so `^` must not match at its
  --- start (POSIX REG_NOTBOL). Set it when searching a tail of a
  --- larger subject.
  not_bol: boolean
  --- The subject does not end a line, so `$` must not match at its
  --- end (POSIX REG_NOTEOL).
  not_eol: boolean
end

--- Convert a SearchOptions to the integer flag word cosmo.re's
--- :match/:find take. Infallible: no options is 0, which searches the
--- subject as a whole line.
--- @param opts SearchOptions? Search behavior
--- @return integer The flag word to pass to Regex:match / Regex:find
local function search_flags(opts?: SearchOptions): integer
  local flags = 0
  if opts then
    if opts.not_bol then flags = flags | re.NOTBOL end
    if opts.not_eol then flags = flags | re.NOTEOL end
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
  return result
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
  local rx, cerr = re.compile(pattern, flags)

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
--- nil + err on a bad pattern or engine failure — a single nil would
--- force every call site to hand-decode which case it was looking at.
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
    -- the guard above took the failure path, where the union's string
    -- arm lives; a match always carries the capture table
    -- cast: captures, past the no-match/failure guard
    return {text = m, caps = caps as {string}}
  end
  return nil, cerr
end

--- Whether pattern matches anywhere in text (subject first).
--- Three honest outcomes: true, false on a clean no-match, and
--- nil + err on a bad pattern — collapsing to a boolean would make
--- "no match" and "your pattern is invalid" the same value.
--- Narrow with `~= nil`, which is exact for boolean unions.
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

--- Hoisted: the iteration helpers need this word on every step past
--- the first, and it never varies.
local NOT_BOL = search_flags({not_bol = true})

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
      -- Past the first step the engine sees a tail as the whole
      -- subject, so `^` must not match at the resume offset.
      sflags = NOT_BOL
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
--- Under the `newline` compile option, `^`/`$` anchors match at
--- embedded newlines as POSIX specifies: find_all("foo\nfoo", "^foo",
--- {newline = true}) returns both spans.
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
  type SearchOptions = SearchOptions

  -- Functions (subject first)
  compile: function(pattern: string, opts?: CompileOptions): Regex | nil, string
  match: function(text: string, pattern: string, opts?: CompileOptions): Match | nil, string
  is_match: function(text: string, pattern: string, opts?: CompileOptions): boolean | nil, string
  find: function(text: string, pattern: string, opts?: CompileOptions): Span | nil, string
  find_all: function(text: string, pattern: string, opts?: CompileOptions): {Span} | nil, string
  type MatchIterator = MatchIterator
  gmatch: function(text: string, pattern: string, opts?: CompileOptions): MatchIterator | nil, string
  split: function(text: string, pattern: string, opts?: CompileOptions): {string} | nil, string
  gsub: function(text: string, pattern: string, repl: Repl, opts?: CompileOptions): string | nil, string

  -- Builds the integer flag word Regex:match / Regex:find take.
  search_flags: function(opts?: SearchOptions): integer
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
  search_flags = search_flags,
}

return M
