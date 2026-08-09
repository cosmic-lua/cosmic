--- The returns invariant: a fallible function returns at most two
--- values, and slot 2 is its error.
---
--- D20 rule 11 decided this in principle — "the error must be reachable
--- from `local v, err = ...` and from `check.must`, so a tuple never
--- carries it in slot 3 or beyond" — and left it to review. This is the
--- rule made mechanical, so the class is closed by construction. It
--- gates every project cosmic builds, not just this tree: a caller who
--- has learned `local v, err = f()` may write it at EVERY cosmic call
--- site, including the ones in your own code.
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
--- rule 11 has nothing to say about it. The fix for a flagged
--- signature is a RECORD — one value carrying the extras, one error
--- beside it.
---
--- There is no escape hatch, and none is needed. A `cosmo.*` binding's
--- tuple IS decided in C and cannot be folded — but it is already
--- declared, once, in the generated `.d.tl` files, which describe C
--- interfaces and which lint exempts by POSITION. Every marker this
--- rule once carried turned out to mark a cosmic-side RESTATEMENT of
--- one of those declarations: a hand-copy that could drift from the
--- binding, and in two cases already had. Name the generated type
--- instead of retyping its shape (`cosmic.re`'s Regex is now
--- `cosmo.re`'s), cast the argument rather than the whole binding, or
--- declare `any...` when the arity genuinely is not yours to know.
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

local record ReturnsModule
  check_fallible_returns: function(file: string, content: string): {Diagnostic}
end

local M: ReturnsModule = {
  check_fallible_returns = check_fallible_returns,
}

return M
