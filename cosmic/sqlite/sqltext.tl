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
---
--- One statement shape embeds semicolons of its own: a CREATE TRIGGER
--- body (`... BEGIN stmt; stmt; END`) is a single prepared statement,
--- and triggers are the only sqlite DDL that nests statements. The
--- scan reads words for exactly that shape: `CREATE` (`TEMP` or
--- `TEMPORARY` allowed between) `TRIGGER` arms it, `BEGIN` opens the
--- body, and inside it `CASE` and `END` pair off — END terminates
--- only CASE and TRIGGER in sqlite — until the body's own END closes
--- the statement. Semicolons inside the body are internal. A
--- semicolon between TRIGGER and BEGIN (illegal SQL) stays a
--- top-level refusal. A body that never closes is the one shape the
--- scan waves through: with no END the depth never returns to zero,
--- so every later semicolon reads as internal and the scan answers
--- false whatever follows. The backstop there is sqlite3_prepare
--- itself — an unclosed trigger is an incomplete statement it
--- refuses outright, so nothing runs, rather than a prefix running
--- silently.

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
  -- The trigger recognizer: `keyword` is the arming sequence's state
  -- ("create" seen, then "trigger" seen), `body_depth` is how many
  -- ENDs the body still owes (0 = not in a body; BEGIN sets 1, CASE
  -- adds one, END takes one away).
  local after_create = false
  local trigger_armed = false
  local body_depth = 0
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
      -- Any non-space, non-comment content after a top-level `;` is a
      -- second statement — including the opening quote of a string.
      return true
    elseif c == ";" then
      if body_depth == 0 then
        seen_semi = true
      end
      i = i + 1
    elseif c == "'" or c == "\"" or c == "`" then
      i = skip_quoted(sql, i, n)
    elseif c == "[" then
      local close = sql:find("]", i + 1, true)
      i = close and (close + 1) or (n + 1)
    elseif c:match("[%a_]") then
      -- Whole words, so an identifier like trigger_log can never match
      -- a keyword by prefix. A quoted or bracketed `end` was consumed
      -- above and never reaches here.
      local word = sql:match("^[%a_][%w_]*", i):upper()
      if body_depth > 0 then
        if word == "CASE" then
          body_depth = body_depth + 1
        elseif word == "END" then
          body_depth = body_depth - 1
        end
      elseif trigger_armed then
        if word == "BEGIN" then
          body_depth = 1
          trigger_armed = false
        end
      elseif after_create then
        if word == "TRIGGER" then
          trigger_armed = true
          after_create = false
        elseif word ~= "TEMP" and word ~= "TEMPORARY" then
          after_create = false
        end
      elseif word == "CREATE" then
        after_create = true
      end
      i = i + #word
    else
      i = i + 1
    end
  end
  return false
end

return {has_multiple_statements = has_multiple_statements}
