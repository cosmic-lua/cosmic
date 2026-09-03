--- The honest-nil invariant: a function whose declared slot 1 cannot be
--- nil must not return nil.
---
--- The checker does not refuse these. A bare non-nil return type
--- accepts `return nil` and then lets callers index the result, so the
--- annotation is a promise to the reader that nothing enforces — and
--- none of the nil tooling can see it, because the narrowing rules,
--- `check.must` and the `fallible-returns` rule all act on a type that
--- ADMITS nil. The union never forms, so nothing downstream is ever
--- asked to narrow it.
---
--- Its own file rather than a second rule inside `_cli.returns`: the
--- two share a type grammar, not an invariant, and the shared half is
--- what `_cli.returns` exports.

local returns = require("_cli.returns")
local tl = require("tl")

local type Token = tl.Token

local skip_balanced = returns.skip_balanced
local parse_type = returns.parse_type
local parse_list = returns.parse_list
local params_open = returns.params_open

--- One open block: what closes on the matching `end`.
local record Frame
  --- "fn" for a function or macroexp definition, "fields" for a
  --- record, interface or enum body, "block" for anything else.
  kind: string
  --- For a "fn" frame: its declared slot 1 cannot be nil.
  lies: boolean
end

--- What one walk of a file leaves behind: the sites it found, and
--- whether its frame stack balanced.
---
--- Balance is the type grammar's own consistency check. Every frame the
--- walk pushes is popped by exactly one `end`, so a type-position shape
--- the grammar mis-reads shows up here before it shows up as a wrong
--- count, and without anyone imagining the shape first: a type consumed
--- SHORT of its closer leaves an opener that the next `end` pops in
--- place of its own frame, and a body consumed AS a type pushes nothing
--- for its `end` to pop. Over well-formed source both numbers are zero;
--- a file where either is not is a grammar bug, whichever way the count
--- moved.
local record Walk
  --- Lines holding a `return nil` under a lying signature, ascending.
  lines: {integer}
  --- Frames still open at end of file.
  residual: integer
  --- `end`s that arrived on an empty stack.
  underflow: integer
end

--- Index just past a `local`/`global` declaration head, its type
--- annotation consumed with it.
---
--- Consuming the annotation is what keeps `local hs: {function(): T}`
--- from presenting its inner `function` as a definition. The walk stops
--- at `record`, `interface`, `enum`, `type` and `function` — each opens
--- a declaration of its own, and each is an IDENTIFIER to the lexer, so
--- a head that swallowed them as names would run on into the body — and
--- at `macroexp` when it sits directly after the `local` with a name
--- after it, the one spelling that declares one (`local macroexp = 1`
--- binds a value called `macroexp`; `local a, macroexp` names two).
--- Stopping here is what puts `type` directly after `local`/`global`
--- when the walk lands on it — the other position `opens_alias` accepts
--- is item start inside a record body — so a field access spelled
--- `t.type` can never reach this stop.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `local` or `global`
--- @return integer Index of the first token past the head
local function skip_declaration_head(tokens: {Token}, i: integer): integer
  local j = i + 1
  while tokens[j] ~= nil do
    local t = tokens[j]
    if t.tk == "record" or t.tk == "interface" or t.tk == "enum"
    or t.tk == "type" or t.tk == "function" then
      return j
    elseif t.tk == "macroexp" and j == i + 1 and tokens[j + 1] ~= nil
    and tokens[j + 1].kind == "identifier" then
      return j
    elseif t.kind == "identifier" or t.tk == "," then
      j = j + 1
    elseif t.tk == "<" then
      local k = skip_balanced(tokens, j, "<", ">")
      if k == 0 then
        return j
      end
      j = k
    else
      break
    end
  end
  if tokens[j] ~= nil and tokens[j].tk == ":" then
    local _, stop = parse_list(tokens, j + 1)
    if stop > j then
      return stop
    end
  end
  return j
end

--- Index just past a `type NAME = <type>` alias, and whether that
--- alias opens a BODY. Called only once `opens_alias` has confirmed the
--- `type` at `i` declares one, so the name at `i + 1` is already known
--- to be an identifier.
---
--- `record`, `interface` and `enum` are identifier atoms to the type
--- grammar, so handing one to `parse_type` consumes it — the walk never
--- lands on it, no frame opens, and the body's `end` pops the enclosing
--- function instead. So the alias reports the body itself: it is the
--- one path that knows a `record` here is a KEYWORD rather than a name,
--- and it lands exactly on that token.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `type`
--- @return integer Index of the alias body's opener, or of the first token past the alias
--- @return boolean True when that index is a body opener
local function skip_type_alias(tokens: {Token}, i: integer): integer, boolean
  local eq = tokens[i + 2]
  if eq == nil or eq.tk ~= "=" then
    return i + 1, false
  end
  local rhs = tokens[i + 3]
  if rhs ~= nil and rhs.kind == "identifier"
  and (rhs.tk == "record" or rhs.tk == "interface" or rhs.tk == "enum") then
    return i + 3, true
  end
  local after = parse_type(tokens, i + 3)
  if after == 0 then
    return i + 3, false
  end
  return after, false
end

--- Whether a token can END an item of a record body: what the grammar
--- leaves the walk standing after, just before a nested declaration.
---
--- An item is the body's header (`record R`, `R<T>`, `is {T}`,
--- `is A, B`, `userdata`, a `where` expression), a field with its type,
--- a `type` alias, a nested body or a macroexp closed by `end`. Each
--- ends on a name, a literal, a closer, `...`, `end`, or a bare
--- `function` — the type with no parameter list. A `where`
--- expression is the one item with the whole expression grammar in it,
--- and a name called `record` at its tail after an operator is not a
--- declaration — but after a `>` nothing tells a comparison from a
--- generic's closer, and the closer is the shape the tree writes.
--- @param t tl.Token The candidate
--- @return boolean True when an item can end on it
local function ends_item(t: Token): boolean
  if t.kind == "identifier" or t.kind == "string"
  or t.kind == "integer" or t.kind == "number" then
    return true
  end
  if t.kind == "keyword" then
    return t.tk == "end" or t.tk == "function"
    or t.tk == "nil" or t.tk == "true" or t.tk == "false"
  end
  return t.tk == ">" or t.tk == ">>" or t.tk == ")" or t.tk == "]"
  or t.tk == "}" or t.tk == "..."
end

--- Whether `record`/`interface`/`enum` at `i` opens a body rather than
--- naming a value. Each is an identifier to the lexer, so a name after
--- it is necessary but not enough: `t.record` followed by a line that
--- starts with a name has the same two tokens, and tl reads that as a
--- field access. The token BEFORE decides, exactly where tl accepts a
--- declaration: after `local`/`global` (`local record R`), or at item
--- start inside a `record`/`interface` body (the nested `record Inner`),
--- which is wherever the previous item ended.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the candidate
--- @param stack {Frame} The frames open at `i`
--- @return boolean True when a body follows
local function opens_body(tokens: {Token}, i: integer,
    stack: {Frame}): boolean
  local t = tokens[i]
  if t.kind ~= "identifier" then
    return false
  end
  if t.tk ~= "record" and t.tk ~= "interface" and t.tk ~= "enum" then
    return false
  end
  -- `local record R` and the nested `record Inner` are followed by a
  -- name. `local type R = record` is followed by the first FIELD, or by
  -- a string when it is an enum, and nothing after it says a body
  -- opens — `skip_type_alias` reports that one from the alias itself.
  local nxt = tokens[i + 1]
  if nxt == nil or not (nxt.kind == "identifier" or nxt.tk == "<") then
    return false
  end
  local prev = tokens[i - 1]
  if prev == nil then
    return false
  end
  if #stack > 0 and stack[#stack].kind == "fields" then
    return ends_item(prev)
  end
  return prev.tk == "local" or prev.tk == "global"
end

--- Whether `type` at `i` opens an alias declaration rather than naming a
--- value. `type` is an identifier to the lexer, so a name after it is
--- necessary but not enough: `t.type` followed by a line that starts
--- with a name (`k = ...`) has the same three tokens as `type NAME =
--- ...`, and tl reads the former as a field access ending a statement.
--- The token BEFORE decides, exactly where tl accepts a declaration:
--- after `local`/`global` (`local type R = ...`), or at item start
--- inside a `record`/`interface` body (a nested `type Inner = ...`),
--- which is wherever the previous item ended.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the candidate
--- @param stack {Frame} The frames open at `i`
--- @return boolean True when an alias follows
local function opens_alias(tokens: {Token}, i: integer,
    stack: {Frame}): boolean
  local nxt = tokens[i + 1]
  if nxt == nil or nxt.kind ~= "identifier" then
    return false
  end
  local prev = tokens[i - 1]
  if prev == nil then
    return false
  end
  if #stack > 0 and stack[#stack].kind == "fields" then
    return ends_item(prev)
  end
  return prev.tk == "local" or prev.tk == "global"
end

--- Whether `macroexp` at `i` opens a body rather than naming a value.
---
--- A macroexp is a function in every way the walk cares about: a
--- parameter list, a declared return list that can lie about nil, and
--- a body closed by `end`. It is an identifier to the lexer, and two
--- spellings declare one — `local macroexp NAME(...)`, where a name
--- follows, and a record field's `= macroexp(...)`, which only a field
--- body holds. A value that happens to be called `macroexp` is neither:
--- `local macroexp = 1` puts `=` after it, `t.macroexp` followed by a
--- line that starts with a name puts `.` before it, and a call of it
--- never sits after `=` inside a record body.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the candidate
--- @param stack {Frame} The frames open at `i`
--- @return boolean True when a body follows
local function opens_macroexp(tokens: {Token}, i: integer,
    stack: {Frame}): boolean
  local t = tokens[i]
  if t.kind ~= "identifier" or t.tk ~= "macroexp" then
    return false
  end
  local nxt = tokens[i + 1]
  if nxt == nil then
    return false
  end
  local prev = tokens[i - 1]
  if prev == nil then
    return false
  end
  if nxt.kind == "identifier" then
    return prev.tk == "local" or prev.tk == "global"
  end
  return (nxt.tk == "(" or nxt.tk == "<") and prev.tk == "="
  and #stack > 0 and stack[#stack].kind == "fields"
end

--- One walk of a file: the lines holding a `return nil` whose innermost
--- enclosing function DECLARES a slot 1 that cannot be nil, and whether
--- the frame stack that found them balanced.
---
--- The checker does not refuse these: a bare non-nil return type
--- accepts `return nil` and then lets callers index the result, so the
--- annotation is a promise to the reader that nothing enforces and
--- none of the nil tooling — the narrowing patch, `check.must`, the
--- `fallible-returns` rule — can see, because they all act on a type
--- that admits nil and this one does not.
---
--- The walk CONSUMES rather than scans, and that is what makes it
--- sound. Whether a `function` opens a body cannot be read off the
--- token before it: `{`, `<` and `,` each precede a definition in one
--- context and a type in another (`local t = {function() end}` against
--- `local t: {function(): T}`; `f(a, function() end)` against a return
--- list `(): T | nil, function(): U`). So every construct that opens a
--- type position — an annotation, a return list, `as`, `is`, an alias,
--- a record field — is consumed whole by the parser above, and a
--- `function` the walk still LANDS on is a definition by construction.
--- A `macroexp` is the same body under another name — a parameter
--- list, a return list that can lie, an `end` — and opens the same
--- frame, read the same way.
--- Reading it backwards instead charges an enclosing function's honest
--- `return nil` to a frame no `end` ever pops.
---
--- Innermost is the other half: a stack of open definitions means an
--- inner closure's nil is charged to the closure, never to the function
--- around it. A function with no declared return type is not in the
--- class at all, and neither is a bare `return` — the class is
--- `return nil`, written out.
---
--- Token-exact, so a `return nil` quoted in a string or shown in a doc
--- comment counts for nothing.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error reporting
--- @return Walk The lines, ascending, and the stack's residual and underflow
local function walk(content: string, file: string): Walk
  local tokens = tl.lex(content, file)
  if not tokens then
    return {lines = {}, residual = 0, underflow = 0}
  end
  local stack: {Frame} = {}
  local lines: {integer} = {}
  local underflow = 0
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    local tk = t.tk
    local word = t.kind == "keyword"
    if (word and tk == "function") or opens_macroexp(tokens, i, stack) then
      local open = params_open(tokens, i)
      local after = open > 0 and skip_balanced(tokens, open, "(", ")") or 0
      local lies = false
      local j = after > 0 and after or i + 1
      if after > 0 and tokens[after] ~= nil and tokens[after].tk == ":" then
        local slots, stop = parse_list(tokens, after + 1)
        lies = #slots > 0 and not slots[1]
        j = stop
      end
      stack[#stack + 1] = {kind = "fn", lies = lies}
      i = j
    elseif opens_body(tokens, i, stack) then
      stack[#stack + 1] = {kind = "fields", lies = false}
      i = i + 1
    elseif word and (tk == "do" or tk == "if") then
      stack[#stack + 1] = {kind = "block", lies = false}
      i = i + 1
    elseif word and tk == "end" then
      if #stack > 0 then
        stack[#stack] = nil
      else
        underflow = underflow + 1
      end
      i = i + 1
    elseif word and tk == "local" then
      i = skip_declaration_head(tokens, i)
    elseif t.kind == "identifier" and tk == "global"
    and tokens[i + 1] ~= nil and tokens[i + 1].kind == "identifier" then
      i = skip_declaration_head(tokens, i)
    elseif t.kind == "identifier" and tk == "type"
    and opens_alias(tokens, i, stack) then
      local after, body = skip_type_alias(tokens, i)
      if body then
        stack[#stack + 1] = {kind = "fields", lies = false}
        i = after + 1
      else
        i = after
      end
    elseif t.kind == "identifier" and (tk == "as" or tk == "is") then
      local after = parse_type(tokens, i + 1)
      i = after > i and after or i + 1
    elseif tk == ":" and #stack > 0 and stack[#stack].kind == "fields" then
      local _, stop = parse_list(tokens, i + 1)
      i = stop > i and stop or i + 1
    elseif word and tk == "return" and tokens[i + 1] ~= nil
    and tokens[i + 1].tk == "nil" then
      for d = #stack, 1, -1 do
        if stack[d].kind == "fn" then
          if stack[d].lies then
            lines[#lines + 1] = t.y
          end
          break
        end
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return {lines = lines, residual = #stack, underflow = underflow}
end

--- Lines holding a `return nil` whose innermost enclosing function
--- DECLARES a slot 1 that cannot be nil: the walk's sites, without its
--- balance.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error reporting
--- @return {integer} The lines, ascending
local function nil_return_lines(content: string, file: string): {integer}
  return walk(content, file).lines
end

local record NilReturnModule
  type Walk = Walk
  walk: function(content: string, file: string): Walk
  nil_return_lines: function(content: string, file: string): {integer}
end

local M: NilReturnModule = {
  walk = walk,
  nil_return_lines = nil_return_lines,
}

return M
