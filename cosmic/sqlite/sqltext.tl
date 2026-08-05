--- Internal helper for cosmic.sqlite: lexical facts about SQL text.
---
--- has_multiple_statements answers one question: does this SQL contain
--- a second statement after a `;`? sqlite3_prepare compiles only the
--- FIRST statement and the binding does not expose the tail, so a
--- parameterized exec/query of multi-statement SQL would silently run
--- a prefix and report success — the exact silent bug the wrappers
--- exist to prevent. They reject it instead, using this scan.
---
--- The scan is a small lexer, not a parser: it skips string literals
--- ('...', "...", `...`, with doubled-quote escapes), bracketed
--- identifiers ([...]), line comments (-- ...\n) and block comments
--- (/* ... */), so a `;` inside any of those never counts, and
--- content after a real `;` that is only whitespace or comments never
--- counts either (a trailing semicolon is one statement, not two).

local function is_space(c: string): boolean
  return c == " " or c == "\t" or c == "\n" or c == "\r"
  or c == "\v" or c == "\f"
end

--- Skip a quoted region starting at i (sql[i] is the quote char).
--- Doubled quote chars are escapes. Returns the index after the
--- closing quote (or past the end when unterminated).
local function skip_quoted(sql: string, i: integer, n: integer): integer
  local q = sql:sub(i, i)
  i = i + 1
  while i <= n do
    if sql:sub(i, i) == q then
      if sql:sub(i + 1, i + 1) == q then
        i = i + 2
      else
        return i + 1
      end
    else
      i = i + 1
    end
  end
  return n + 1
end

--- True when sql contains a second statement after a top-level `;`.
--- @param sql string The SQL text to scan
--- @return boolean True when more than one statement is present
local function has_multiple_statements(sql: string): boolean
  local i = 1
  local n = #sql
  local seen_semi = false
  while i <= n do
    local c = sql:sub(i, i)
    if c == "-" and sql:sub(i + 1, i + 1) == "-" then
      local nl = sql:find("\n", i + 2, true)
      i = nl and (nl + 1) or (n + 1)
    elseif c == "/" and sql:sub(i + 1, i + 1) == "*" then
      local close = sql:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    elseif is_space(c) then
      i = i + 1
    elseif seen_semi then
      -- Any non-space, non-comment content after a `;` is a second
      -- statement — including the opening quote of a string.
      return true
    elseif c == ";" then
      seen_semi = true
      i = i + 1
    elseif c == "'" or c == "\"" or c == "`" then
      i = skip_quoted(sql, i, n)
    elseif c == "[" then
      local close = sql:find("]", i + 1, true)
      i = close and (close + 1) or (n + 1)
    else
      i = i + 1
    end
  end
  return false
end

return {has_multiple_statements = has_multiple_statements}
