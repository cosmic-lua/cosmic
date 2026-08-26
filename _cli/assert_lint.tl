--- The assert rules: `assert` is licensed in library code only in a
--- narrow shape, and both rules here guard one half of that licence —
--- `return-assert` the position it may be written in, `assert-justify`
--- the reason it must carry.
---
--- `return-assert` is the arity half. The carried `narrow-assert-decl`
--- patch declares Lua's `assert` as ONE return, which is what makes
--- `local db = assert(open(p))` yield a plain `Database` instead of a
--- union. In RETURN position that declaration is a lie: Lua's `assert`
--- returns ALL of its arguments, so a function written
--- `return assert(v, msg)` type-checks as one-valued and is two-valued
--- at runtime. The checker cannot catch it — the declaration is the
--- thing that is wrong — so it is caught here.
---
--- The damage is at the CALLER, which is why it survives a green gate:
--- the extra value only appears where the call sits in a
--- multiple-value position, and `table.insert(out, join(a, b))` is such
--- a position. That call becomes the three-argument `table.insert` and
--- fails at runtime with an error naming neither function.
---
--- `assert-justify` is the licence half. D23 lets a `cosmic.*` module
--- `assert` a `cosmo.*` return whose declared `| nil` is unreachable
--- for the arguments that call passes, PROVIDED the assert carries a
--- trailing `-- assert: <why the nil cannot occur>` — the way a cast
--- carries its `-- cast:`. Without the comment the assert is an
--- ordinary library throw, which the error doctrine forbids, and
--- nothing but a reader can tell the two apart.
---
--- Token-exact via the lexer, so an `assert` quoted inside a string or
--- a comment never counts. That is what makes `assert-justify` usable
--- at all: `cosmic/**` holds 23 `assert(` occurrences and every one is
--- inside a doc comment or a string constant — including
--- `cosmic/embed/init.tl`'s, which is a line of the entry wrapper this
--- tree WRITES rather than runs.

local returns = require("_cli.returns")
local style = require("_tool.lint")
local tl = require("tl")

local type Diagnostic = style.Diagnostic
local type Token = tl.Token

local skip_balanced = returns.skip_balanced

--- Tokens that open a `... end` block, so a `return` inside a function
--- expression is not cut short by that function's own `end`.
local BLOCK_OPEN < const >: {string: boolean} = {
  ["function"] = true,
  ["do"] = true,
  ["if"] = true,
  ["for"] = true,
  ["while"] = true,
}

--- Tokens that close a return statement's expression list at depth 0.
local STATEMENT_END < const >: {string: boolean} = {
  [";"] = true,
  ["until"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["$EOF$"] = true,
}

--- Index of the last token of the return statement starting at `i`.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `return` keyword
--- @return integer Index of the statement's last token; i when empty
local function statement_end(tokens: {Token}, i: integer): integer
  local brackets = 0
  local blocks = 0
  for j = i + 1, #tokens do
    local t = tokens[j]
    local tk = t.tk
    if tk == "(" or tk == "[" or tk == "{" then
      brackets = brackets + 1
    elseif tk == ")" or tk == "]" or tk == "}" then
      brackets = brackets - 1
    elseif brackets == 0 and t.kind == "keyword" and BLOCK_OPEN[tk] then
      blocks = blocks + 1
    elseif brackets == 0 and tk == "end" then
      if blocks == 0 then
        return j - 1
      end
      blocks = blocks - 1
    elseif brackets == 0 and blocks == 0 and STATEMENT_END[tk] then
      return j - 1
    end
  end
  return #tokens
end

--- Index where the last comma-separated expression of a return list
--- begins.
--- @param tokens {tl.Token} The file's tokens
--- @param first integer Index of the list's first token
--- @param last integer Index of the list's last token
--- @return integer Index of the last expression's first token
local function last_expression(tokens: {Token}, first: integer,
    last: integer): integer
  local start = first
  local depth = 0
  for j = first, last do
    local tk = tokens[j].tk
    if tk == "(" or tk == "[" or tk == "{" then
      depth = depth + 1
    elseif tk == ")" or tk == "]" or tk == "}" then
      depth = depth - 1
    elseif depth == 0 and tk == "," then
      start = j + 1
    end
  end
  return start
end

--- How many top-level arguments a call's parenthesized list holds.
--- @param tokens {tl.Token} The file's tokens
--- @param open integer Index of the call's `(`
--- @param close integer Index of the matching `)`
--- @return integer The argument count; 0 for an empty list
local function argument_count(tokens: {Token}, open: integer,
    close: integer): integer
  if close <= open + 1 then
    return 0
  end
  local n = 1
  local depth = 0
  for j = open + 1, close - 1 do
    local tk = tokens[j].tk
    if tk == "(" or tk == "[" or tk == "{" then
      depth = depth + 1
    elseif tk == ")" or tk == "]" or tk == "}" then
      depth = depth - 1
    elseif depth == 0 and tk == "," then
      n = n + 1
    end
  end
  return n
end

--- Whether the tokens from `start` to `last` are exactly a call to the
--- bare global `assert` with two or more top-level arguments.
--- @param tokens {tl.Token} The file's tokens
--- @param start integer Index of the expression's first token
--- @param last integer Index of the expression's last token
--- @return boolean
local function is_multi_assert(tokens: {Token}, start: integer,
    last: integer): boolean
  local t = tokens[start]
  if not t or t.tk ~= "assert" or t.kind ~= "identifier" then
    return false
  end
  if not tokens[start + 1] or tokens[start + 1].tk ~= "(" then
    return false
  end
  local after = skip_balanced(tokens, start + 1, "(", ")")
  -- The call must BE the expression: `assert(v, m) .. s` and
  -- `assert(v, m).field` truncate to one value, so they are safe.
  if after ~= last + 1 then
    return false
  end
  return argument_count(tokens, start + 1, after - 1) >= 2
end

--- Every `return` whose value is a multi-argument `assert` call.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @return {Diagnostic} One per two-valued return
local function check_return_assert(file: string, content: string): {Diagnostic}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, t in ipairs(tokens) do
    if t.tk == "return" and t.kind == "keyword" then
      local last = statement_end(tokens, i)
      if last > i then
        local start = last_expression(tokens, i + 1, last)
        if is_multi_assert(tokens, start, last) then
          local a = tokens[start]
          diagnostics[#diagnostics + 1] = {
            file = file,
            line = a.y,
            col = a.x,
            rule = "return-assert",
            message = string.format(
              "%s:%d: the carried tl patch declares one return for"
              .. " `assert`, so the checker reads this as one value —"
              .. " but Lua's assert returns ALL of its arguments, so"
              .. " this function is two-valued at runtime and a caller's"
              .. " last-argument position expands both. Write the assert"
              .. " as a statement and return the local (see `cosmic"
              .. " --docs guide.lint`)", file, a.y),
          }
        end
      end
    end
  end
  return diagnostics
end

--- Whether `file` is a `cosmic.*` library module — the only source D23
--- governs. The paths the gate walks are repo-relative, which is how
--- `_cli/visibility.tl` scopes the same tree; `/cosmic/` is deliberately
--- NOT matched as well, because the repository root directory is itself
--- named `cosmic` and that pattern would sweep the whole tree whenever
--- a caller passes an absolute path.
--- @param file string The path being linted
--- @return boolean True for library source, false for tests and examples
local function is_library_source(file: string): boolean
  if not file:match("^cosmic/") then
    return false
  end
  return not (file:match("_test%.tl$") or file:match("_example%.tl$"))
end

--- Every library `assert` that does not say why its nil cannot occur.
--- One diagnostic per LINE: a line with two asserts takes one comment,
--- the way one `-- cast:` covers however many casts share a line.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per unjustified assert line
local function check_assert_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not is_library_source(file) then
    return {}
  end
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  local seen: {integer: boolean} = {}
  for i, t in ipairs(tokens) do
    local before = i > 1 and tokens[i - 1].tk or ""
    if t.tk == "assert" and t.kind == "identifier" and not seen[t.y]
    and before ~= "." and before ~= ":"
    and tokens[i + 1] and tokens[i + 1].tk == "(" then
      seen[t.y] = true
      if not style.is_justified(lines, t.y, "assert") then
        diagnostics[#diagnostics + 1] = {
          file = file,
          line = t.y,
          col = t.x,
          rule = "assert-justify",
          message = string.format(
            "%s:%d: a library `assert` throws, and throwing from"
            .. " `cosmic/**` needs D23's licence: the `| nil` must be"
            .. " unreachable for the arguments THIS call passes. Say"
            .. " which, in a trailing `-- assert: <why the nil cannot"
            .. " occur>` (or on the line above); if the nil IS"
            .. " reachable, return it as `nil, err` instead (see"
            .. " `cosmic --docs guide.lint`)", file, t.y),
        }
      end
    end
  end
  return diagnostics
end

local record AssertLintModule
  check_return_assert: function(file: string, content: string): {Diagnostic}
  check_assert_justification: function(file: string, content: string,
  lines: {string}): {Diagnostic}
end

local M: AssertLintModule = {
  check_return_assert = check_return_assert,
  check_assert_justification = check_assert_justification,
}

return M
