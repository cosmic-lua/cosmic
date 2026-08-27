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

--- Whether the `function` token at `i` opens a DEFINITION rather than
--- naming a function TYPE. A type opens no block and closes on no
--- `end`, so pushing one would swallow the next `end` and mis-attribute
--- every `return` after it.
---
--- Type position is what the token before decides: a `:` (an
--- annotation, a record field, a return list, a map's value type), a
--- `|` (a union member), an `as` (a cast's target), or the `=` of a
--- `type NAME =` alias. Everything else — `local`, `=`, `,`, `(`,
--- `return`, `then`, a statement boundary — is a definition.
--- @param tokens {tl.Token} The file's tokens
--- @param i integer Index of the `function` keyword
--- @return boolean True when a body follows
local function is_definition(tokens: {Token}, i: integer): boolean
  local prev = tokens[i - 1]
  if prev == nil then
    return true
  end
  if prev.tk == ":" or prev.tk == "|" or prev.tk == "as" then
    return false
  end
  -- `local type Revalidate = function(): string` — an alias binds a
  -- type to a name, so the `=` is not an assignment of a value.
  if prev.tk == "=" and tokens[i - 2] ~= nil
  and tokens[i - 2].kind == "identifier" and tokens[i - 3] ~= nil
  and tokens[i - 3].tk == "type" then
    return false
  end
  return true
end

--- The token texts that open a block closed by `end`. `while` and
--- `for` are absent on purpose: each carries its own `do`, which is
--- what closes them, so counting the keyword too would double-count.
--- `repeat` is absent because it closes on `until`.
local OPENS_BLOCK < const >: {string: boolean} = {
  ["do"] = true, ["if"] = true, ["record"] = true,
  ["enum"] = true, ["interface"] = true,
}

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
--- Innermost is what makes it sound: a stack of open definitions means
--- an inner closure's `nil` is charged to the closure, never to the
--- function around it. A function with no declared return type is not
--- in the class at all and is skipped.
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
  -- One entry per open block. `lies` is nil for a plain block and a
  -- boolean for a function definition, so the innermost function is
  -- the last entry that carries one.
  local stack: {boolean | nil} = {}
  local depth = 0
  local lines: {integer} = {}
  for i, t in ipairs(tokens) do
    if t.tk == "function" and t.kind == "keyword" and is_definition(tokens, i) then
      local open = params_open(tokens, i)
      local after = open > 0 and skip_balanced(tokens, open, "(", ")") or 0
      local lies = false
      if after > 0 and tokens[after] ~= nil and tokens[after].tk == ":" then
        local slots = parse_list(tokens, after + 1)
        lies = #slots > 0 and not slots[1]
      end
      depth = depth + 1
      stack[depth] = lies
    elseif t.kind == "keyword" and OPENS_BLOCK[t.tk] then
      depth = depth + 1
      stack[depth] = nil
    elseif t.tk == "end" and t.kind == "keyword" then
      if depth > 0 then
        stack[depth] = nil
        depth = depth - 1
      end
    elseif t.tk == "return" and t.kind == "keyword"
    and tokens[i + 1] ~= nil and tokens[i + 1].tk == "nil" then
      for d = depth, 1, -1 do
        if stack[d] ~= nil then
          if stack[d] then
            lines[#lines + 1] = t.y
          end
          break
        end
      end
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
