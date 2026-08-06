--- The Lua-pattern-magic argument rules: find-needle and
--- gsub-replacement.
---
--- Split from `_cli/lint.tl` for the 500-line cap. The two rules are
--- one trap family: `string.find` treats its needle as a pattern, and
--- `string.gsub` interpolates `%` in its replacement — in both, a
--- value the reader cannot see silently changes what the call does.
--- Both rules are token-exact (the lexer, never source matching), both
--- exempt literals, and both ask the author to say what they mean
--- rather than forbid the call.

local style = require("cosmic.style")
local tl = require("tl")

local type Diagnostic = style.Diagnostic

--- Whether line `y` carries a `-- <tag>: <reason>` marker, trailing or
--- on the line directly above — the same two positions cast-justify
--- reads.
--- @param lines {string} The file's lines
--- @param y integer The line the flagged call is on
--- @param tag string The marker name (e.g. "gsub")
--- @return boolean True when marked here or on the line above
local function is_marked(lines: {string}, y: integer, tag: string): boolean
  local marker = "%-%- " .. tag .. ": %S"
  local here = lines[y]
  if here and here:match(marker) then
    return true
  end
  local above = lines[y - 1]
  return above ~= nil and above:match("^%s*" .. marker) ~= nil
end

--- Calls of `find` whose needle is a VARIABLE and which never say
--- whether they meant a pattern.
---
--- `s:find(x)` treats x as a Lua pattern, so a `-`, `.`, `(` or `%` in
--- it silently changes what matches. When x is a path, a name, or a
--- filter the author almost always meant a substring, and the failure is
--- invisible: the assertion still runs, it just compares the wrong
--- thing. A test that plants a file under `/tmp/a-b/` and greps for it
--- passes everywhere except where the path has a dash.
---
--- Literal needles are exempt — `s:find("%d+")` is a pattern on purpose
--- and reads as one. The rule is only for needles the reader cannot see.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error messages
--- @return {integer} 1-based line numbers, each at most once
local function unguarded_find_lines(content: string, file: string): {integer}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local seen: {integer: boolean} = {}
  local out: {integer} = {}
  for i, t in ipairs(tokens) do
    local prev = i > 1 and tokens[i - 1] or nil
    local open = tokens[i + 1]
    -- Method form takes the subject as the receiver, so its needle is
    -- first and plain is third; `string.find(s, needle, init, plain)`
    -- passes the subject too, shifting both by one. A `.` on anything
    -- but `string` is some other function that happens to be named
    -- find, and is none of this rule's business.
    local needle_at = 0
    local plain_at = 0
    if t.tk == "find" and open and open.tk == "(" and prev then
      if prev.tk == ":" then
        needle_at = 1
        plain_at = 3
      elseif prev.tk == "." and i > 2 and tokens[i - 2].tk == "string" then
        needle_at = 2
        plain_at = 4
      end
    end
    if plain_at > 0 and not seen[t.y] then
      local depth = 1
      local argno = 1
      local literal_needle = true
      local empty = true
      local j = i + 2
      while j <= #tokens and depth > 0 do
        local tk = tokens[j].tk
        local separator = tk == "," and depth == 1
        if tk == "(" or tk == "[" or tk == "{" then
          depth = depth + 1
        elseif tk == ")" or tk == "]" or tk == "}" then
          depth = depth - 1
        elseif separator then
          argno = argno + 1
        end
        -- The separator belongs to no argument: counting it as one made
        -- every `string.find(s, "literal")` look non-literal, because
        -- the comma before the needle is not a string token.
        if depth > 0 and not separator then
          empty = false
          if argno == needle_at and tokens[j].kind ~= "string" and tk ~= ".." then
            literal_needle = false
          end
        end
        j = j + 1
      end
      if not empty and not literal_needle and argno < plain_at then
        seen[t.y] = true
        out[#out + 1] = t.y
      end
    end
  end
  return out
end

--- Report each `find` that leaves pattern-vs-substring unsaid.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @return {Diagnostic} One per unguarded call
local function check_find_needle(file: string, content: string): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for _, y in ipairs(unguarded_find_lines(content, file)) do
    diagnostics[#diagnostics + 1] = {
      file = file,
      line = y,
      col = 1,
      rule = "find-needle",
      message = string.format(
        "%s:%d: `find` with a non-literal needle is a PATTERN, so a `-`,"
        .. " `.` or `%%` in it silently changes the match: pass `, 1, true`"
        .. " for a substring, or `, 1, false` to mean the pattern",
        file, y),
    }
  end
  return diagnostics
end

--- Calls of `gsub` whose REPLACEMENT is a variable, a field, or a call
--- — anything the reader cannot see is `%`-safe.
---
--- `gsub`'s replacement argument interpolates `%`: `%1`–`%9` splice in
--- captures, `%0` the whole match, and a lone `%` before anything else
--- is a runtime error. Templating an untrusted value in corrupts the
--- output — or crashes — the first time the value contains a `%`.
--- find-needle covers the needle side of this trap family; this is the
--- replacement side, and unlike the needle it has a clean library
--- answer: `str.replace` (cosmic.string) is literal on both sides.
---
--- Exempt: literal replacements (a literal `"%1"` reads as deliberate
--- capture splicing), function and table replacements (those forms do
--- not interpolate), and a call that says what it means with a trailing
--- `-- gsub: <reason>` (or one on the line above) — the deliberate
--- pattern-template case, where the author vouches the value is
--- escaped or meant to splice.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error messages
--- @param lines {string} The file's lines, for the justification comment
--- @return {integer} 1-based line numbers, each at most once
local function unguarded_gsub_lines(content: string, file: string,
    lines: {string}): {integer}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local seen: {integer: boolean} = {}
  local out: {integer} = {}
  for i, t in ipairs(tokens) do
    local prev = i > 1 and tokens[i - 1] or nil
    local open = tokens[i + 1]
    -- Method form takes the subject as the receiver, so its replacement
    -- is second; `string.gsub(s, pattern, repl)` passes the subject
    -- too, shifting it to third. A `.gsub` on anything but `string` is
    -- some other function and none of this rule's business.
    local repl_at = 0
    if t.tk == "gsub" and open and open.tk == "(" and prev then
      if prev.tk == ":" then
        repl_at = 2
      elseif prev.tk == "." and i > 2 and tokens[i - 2].tk == "string" then
        repl_at = 3
      end
    end
    if repl_at > 0 and not seen[t.y] then
      local depth = 1
      local argno = 1
      local literal_repl = true
      local repl_seen = false
      local exempt = false
      local j = i + 2
      while j <= #tokens and depth > 0 do
        local tk = tokens[j].tk
        local separator = tk == "," and depth == 1
        if tk == "(" or tk == "[" or tk == "{" then
          depth = depth + 1
        elseif tk == ")" or tk == "]" or tk == "}" then
          depth = depth - 1
        elseif separator then
          argno = argno + 1
        end
        if depth > 0 and not separator and argno == repl_at then
          -- The argument's FIRST token decides the exempt forms: an
          -- anonymous function or a table constructor does not
          -- interpolate anything.
          if not repl_seen and (tk == "function" or tk == "{") then
            exempt = true
          end
          repl_seen = true
          local kind = tokens[j].kind
          if kind ~= "string" and kind ~= "number" and kind ~= "integer"
          and tk ~= ".." then
            literal_repl = false
          end
        end
        j = j + 1
      end
      if repl_seen and not exempt and not literal_repl
      and not is_marked(lines, t.y, "gsub") then
        seen[t.y] = true
        out[#out + 1] = t.y
      end
    end
  end
  return out
end

--- Report each `gsub` whose replacement's `%`-safety is unstated.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per unguarded call
local function check_gsub_replacement(file: string, content: string,
    lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for _, y in ipairs(unguarded_gsub_lines(content, file, lines)) do
    diagnostics[#diagnostics + 1] = {
      file = file,
      line = y,
      col = 1,
      rule = "gsub-replacement",
      message = string.format(
        "%s:%d: a non-literal gsub replacement interpolates %% — for"
        .. " literal text use str.replace (cosmic.string); a deliberate"
        .. " template takes an escape (value:gsub(\"%%%%\", \"%%%%%%%%\"))"
        .. " and a trailing `-- gsub: <reason>` (or on the line above)",
        file, y),
    }
  end
  return diagnostics
end

local record PatternArgsModule
  check_find_needle: function(file: string, content: string): {Diagnostic}
  check_gsub_replacement: function(file: string, content: string, lines: {string}): {Diagnostic}
end

local M: PatternArgsModule = {
  check_find_needle = check_find_needle,
  check_gsub_replacement = check_gsub_replacement,
}

return M
