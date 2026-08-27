--- The returns invariant: a fallible function returns at most two
--- values, and slot 2 is its error.
---
--- The error must be reachable from `local v, err = ...` and from
--- `check.must`, so a tuple never carries it in slot 3 or beyond. This
--- is that rule made mechanical, so the class is closed by
--- construction. It gates every project cosmic builds, not just this
--- tree: a caller who has learned `local v, err = f()` may write it at
--- EVERY cosmic call site, including the ones in your own code.
---
--- What counts as fallible is the declaration itself, never a guess
--- about the body: slot 1 admits nil (`T | nil`, or `any`, which admits
--- everything). That is what makes `local v, err = f()` the calling
--- convention, and what makes a third slot unreachable from it — the
--- caller who writes the two-name form silently drops slot 3, and the
--- caller who writes `check.must(f())` feeds slot 2 to `must`'s `err`
--- parameter whatever it holds.
---
--- An infallible tuple is untouched: `string.partition` returns
--- `string, string, string` and no slot of it could be an error, so
--- this rule has nothing to say about it. The fix for a flagged
--- signature is a RECORD — one value carrying the extras, one error
--- beside it.
---
--- There is no escape hatch, and none is needed. A `cosmo.*` binding's
--- tuple IS decided in C and cannot be folded — but it is already
--- declared, once, in the generated `.d.tl` files, which describe C
--- interfaces and which lint exempts by POSITION. A signature that
--- looks like it needs an exemption is usually a cosmic-side
--- RESTATEMENT of one of those declarations instead: a hand-copy that
--- can drift from the binding. Name the generated type instead of
--- retyping its shape (`cosmic.re`'s Regex names `cosmo.re`'s
--- generated type rather than declaring its own), cast the argument
--- rather than the whole binding, or declare `any...` when the arity
--- genuinely is not yours to know.
---
--- Token-exact, via the lexer, so a signature quoted inside a string
--- or a doc comment never counts. The type grammar parsed here is the
--- return-list subset: unions, table types, generics, dotted names,
--- parenthesized lists, varargs, and nested function types.

local style = require("_tool.lint")
local tl = require("tl")

local type Diagnostic = style.Diagnostic
local type Token = tl.Token

--- Index just past the token that closes a balanced group.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the opening token
--- @param open string The opening token's text
--- @param close string The closing token's text
--- @return integer Index after the close, or 0 when unbalanced
local function skip_balanced(tokens: {Token}, i: integer,
    open: string, close: string): integer
  local depth = 0
  for j = i, #tokens do
    local tk = tokens[j].tk
    if tk == open then
      depth = depth + 1
    elseif tk == close then
      depth = depth - 1
      if depth == 0 then
        return j + 1
      end
    end
  end
  return 0
end

--- The return list of a function type, parsed. Forward-declared: a
--- return slot may itself be a function type with its own return list.
local parse_list: function(tokens: {Token}, i: integer): {boolean}, integer

--- One type with no union bar: a name, a table type, a parenthesized
--- type, `nil`, or a nested function type.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the type's first token
--- @return integer Index after the atom, or 0 when this is not a type
--- @return boolean Whether the atom admits nil
local function parse_atom(tokens: {Token}, i: integer): integer, boolean
  local t = tokens[i]
  if not t then
    return 0, false
  end
  if t.tk == "nil" then
    return i + 1, true
  elseif t.tk == "{" then
    return skip_balanced(tokens, i, "{", "}"), false
  elseif t.tk == "(" then
    return skip_balanced(tokens, i, "(", ")"), false
  elseif t.tk == "function" then
    local j = i + 1
    if tokens[j] and tokens[j].tk == "<" then
      j = skip_balanced(tokens, j, "<", ">")
      if j == 0 then
        return 0, false
      end
    end
    if tokens[j] and tokens[j].tk == "(" then
      j = skip_balanced(tokens, j, "(", ")")
      if j == 0 then
        return 0, false
      end
      -- A nested function type's own return list binds greedily, as it
      -- does in Teal itself.
      if tokens[j] and tokens[j].tk == ":" then
        local _, after = parse_list(tokens, j + 1)
        j = after
      end
    end
    return j, false
  elseif t.kind == "identifier" then
    local j = i + 1
    while tokens[j] and tokens[j].tk == "."
    and tokens[j + 1] and tokens[j + 1].kind == "identifier" do
      j = j + 2
    end
    if tokens[j] and tokens[j].tk == "<" then
      j = skip_balanced(tokens, j, "<", ">")
      if j == 0 then
        return 0, false
      end
    end
    -- `any` is the type that admits everything, nil included, which is
    -- why sqlite's `any, boolean, string` hid an error in slot 3.
    return j, t.tk == "any" and i + 1 == j
  end
  return 0, false
end

--- One slot's type: a union of atoms, plus a trailing `?` or `...`.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the slot's first token
--- @return integer Index after the type, or 0 when this is not a type
--- @return boolean Whether any union member admits nil
local function parse_type(tokens: {Token}, i: integer): integer, boolean
  local j, admits_nil = parse_atom(tokens, i)
  if j == 0 then
    return 0, false
  end
  while tokens[j] and tokens[j].tk == "|" do
    local k, member_nil = parse_atom(tokens, j + 1)
    if k == 0 then
      break
    end
    j = k
    admits_nil = admits_nil or member_nil
  end
  if tokens[j] and tokens[j].tk == "?" then
    j = j + 1
    admits_nil = true
  end
  if tokens[j] and tokens[j].tk == "..." then
    j = j + 1
  end
  return j, admits_nil
end

parse_list = function(tokens: {Token}, i: integer): {boolean}, integer
  local slots: {boolean} = {}
  local j = i
  -- `): (WalkAction ...)` — parentheses around the whole list, which
  -- Teal accepts and which say where the list ends.
  local parenthesized = tokens[j] ~= nil and tokens[j].tk == "("
  and tokens[j + 1] ~= nil and tokens[j + 1].tk ~= ")"
  if parenthesized then
    j = j + 1
  end
  while true do
    local after, admits_nil = parse_type(tokens, j)
    if after == 0 then
      break
    end
    slots[#slots + 1] = admits_nil
    j = after
    -- Only a comma continues the list. Anything else is the function's
    -- BODY (or the next record field), and stopping here is what keeps
    -- `local function f(): T\n  g(x)` from reading `g` as slot 2.
    if not (tokens[j] and tokens[j].tk == ",") then
      break
    end
    -- A comma may also separate the enclosing PARAMETER list when this
    -- return list belongs to a nested function type:
    -- `function(fn: function(e: E): boolean | nil, string, acc: {A})`
    -- ends fn's returns before `acc`. Teal disambiguates on `name:`
    -- (optionally `name?:`) — no type starts that way — and so must
    -- this parse, or the parameter after a fallible callback counts as
    -- a phantom third slot.
    local n1 = tokens[j + 1]
    local n2 = tokens[j + 2]
    local n3 = tokens[j + 3]
    if n1 and n1.kind == "identifier" and n2
    and (n2.tk == ":" or (n2.tk == "?" and n3 and n3.tk == ":")) then
      break
    end
    j = j + 1
  end
  if parenthesized and tokens[j] and tokens[j].tk == ")" then
    j = j + 1
  end
  return slots, j
end

--- Index of the `(` opening a function's parameter list.
---
--- Only a name and a generic list may sit between `function` and `(`,
--- and only on the same line — otherwise a BARE `function` type
--- (`handler: function`) would scan forward and adopt the parameter
--- list of some later declaration.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `function` keyword
--- @return integer Index of the `(`, or 0 when there is none
local function params_open(tokens: {Token}, i: integer): integer
  local line = tokens[i].y
  local j = i + 1
  while tokens[j] and tokens[j].y == line do
    local t = tokens[j]
    if t.tk == "(" then
      return j
    elseif t.kind == "identifier" or t.tk == "." or t.tk == ":" then
      j = j + 1
    elseif t.tk == "<" then
      j = skip_balanced(tokens, j, "<", ">")
      if j == 0 then
        return 0
      end
    else
      return 0
    end
  end
  return 0
end

--- Every declared return list that puts a slot past the error.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @return {Diagnostic} One per over-wide fallible signature
local function check_fallible_returns(file: string, content: string): {Diagnostic}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, t in ipairs(tokens) do
    if t.tk == "function" and t.kind == "keyword" then
      local open = params_open(tokens, i)
      local after = open > 0 and skip_balanced(tokens, open, "(", ")") or 0
      if after > 0 and tokens[after] and tokens[after].tk == ":" then
        local slots = parse_list(tokens, after + 1)
        if #slots > 2 and slots[1] then
          diagnostics[#diagnostics + 1] = {
            file = file,
            line = t.y,
            col = t.x,
            rule = "fallible-returns",
            message = string.format(
              "%s:%d: a fallible return (slot 1 admits nil) declares %d"
              .. " slots; a caller writing `local v, err = f()` cannot"
              .. " reach past slot 2, and check.must feeds slot 2 to its"
              .. " `err` parameter — carry the extras in the value's"
              .. " record. A cosmo binding's own tuple is already"
              .. " declared in the generated .d.tl: name that type"
              .. " rather than retyping its shape (see `cosmic --docs"
              .. " guide.lint`)",
              file, t.y, #slots),
          }
        end
      end
    end
  end
  return diagnostics
end

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

--- Index just past a `type NAME = <type>` alias.
---
--- Returns the index of what follows `=` when the right-hand side is
--- not a type expression — `record`/`enum` open a body instead, and the
--- walk handles those where it finds them.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `type`
--- @return integer Index of the first token past the alias
local function skip_type_alias(tokens: {Token}, i: integer): integer
  local name = tokens[i + 1]
  local eq = tokens[i + 2]
  if name == nil or name.kind ~= "identifier" or eq == nil or eq.tk ~= "=" then
    return i + 1
  end
  local after = parse_type(tokens, i + 3)
  if after == 0 then
    return i + 3
  end
  return after
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
      i = skip_type_alias(tokens, i)
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

local record ReturnsModule
  check_fallible_returns: function(file: string, content: string): {Diagnostic}
  nil_return_lines: function(content: string, file: string): {integer}
  skip_balanced: function(tokens: {Token}, i: integer,
  open: string, close: string): integer
end

local M: ReturnsModule = {
  check_fallible_returns = check_fallible_returns,
  nil_return_lines = nil_return_lines,
  skip_balanced = skip_balanced,
}

return M
