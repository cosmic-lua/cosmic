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
  --- "fn" for a function definition, "fields" for a record, interface
  --- or enum body, "block" for anything else.
  kind: string
  --- For a "fn" frame: its declared slot 1 cannot be nil.
  lies: boolean
end

--- Index just past a `local`/`global` declaration head, its type
--- annotation consumed with it.
---
--- Consuming the annotation is what keeps `local hs: {function(): T}`
--- from presenting its inner `function` as a definition. The walk stops
--- at `record`, `interface`, `enum`, `type` and `function` — each opens
--- a declaration of its own, and each is an IDENTIFIER to the lexer, so
--- a head that swallowed them as names would run on into the body.
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
--- alias opens a BODY.
---
--- `record`, `interface` and `enum` are identifier atoms to the type
--- grammar, so handing one to `parse_type` consumes it — the walk never
--- lands on it, no frame opens, and the body's `end` pops the enclosing
--- function instead. So the alias reports the body itself: it is the
--- one path that knows a `record` here is a KEYWORD rather than a name,
--- and it lands exactly on that token. Reading it backwards instead —
--- any `record` whose previous token is `=` — cannot tell the alias
--- from an ordinary binding of a value that happens to be called
--- `record` (`record = record` in an export table), and the frame that
--- pushes is one no `end` ever pops.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `type`
--- @return integer Index of the alias body's opener, or of the first token past the alias
--- @return boolean True when that index is a body opener
local function skip_type_alias(tokens: {Token}, i: integer): integer, boolean
  local name = tokens[i + 1]
  local eq = tokens[i + 2]
  if name == nil or name.kind ~= "identifier" or eq == nil or eq.tk ~= "=" then
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

--- Whether `record`/`interface`/`enum` at `i` opens a body rather than
--- naming a value. Each is an identifier to the lexer, so only what
--- follows separates `local record R` and the nested `record Inner`
--- from a field or variable that happens to be called `record` — which
--- is followed by `:`, `=`, `.` or a closer, never by a name.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the candidate
--- @return boolean True when a body follows
local function opens_body(tokens: {Token}, i: integer): boolean
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
  return nxt ~= nil and (nxt.kind == "identifier" or nxt.tk == "<")
end

--- Lines holding a `return nil` whose innermost enclosing function
--- DECLARES a slot 1 that cannot be nil.
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
--- @return {integer} The lines, ascending
local function nil_return_lines(content: string, file: string): {integer}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local stack: {Frame} = {}
  local lines: {integer} = {}
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    local tk = t.tk
    local word = t.kind == "keyword"
    if word and tk == "function" then
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
    elseif opens_body(tokens, i) then
      stack[#stack + 1] = {kind = "fields", lies = false}
      i = i + 1
    elseif word and (tk == "do" or tk == "if") then
      stack[#stack + 1] = {kind = "block", lies = false}
      i = i + 1
    elseif word and tk == "end" then
      if #stack > 0 then
        stack[#stack] = nil
      end
      i = i + 1
    elseif word and tk == "local" then
      i = skip_declaration_head(tokens, i)
    elseif t.kind == "identifier" and tk == "global"
    and tokens[i + 1] ~= nil and tokens[i + 1].kind == "identifier" then
      i = skip_declaration_head(tokens, i)
    elseif t.kind == "identifier" and tk == "type" then
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
  return lines
end

local record NilReturnModule
  nil_return_lines: function(content: string, file: string): {integer}
end

local M: NilReturnModule = {
  nil_return_lines = nil_return_lines,
}

return M
