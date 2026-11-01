--- Proves the contextual typing of a function literal that the checker
--- ([`lang.check`]) gives. A literal checked where a function type is
--- expected -- a call's argument, a declared local, an assignment, a
--- table field, a return -- gives each parameter it leaves untyped the
--- expected parameter type, and an omitted return list the expected
--- returns, which its `return` statements are then checked against;
--- one that can reach its end where a value is expected is refused,
--- and one ending in a `do` block that ends, or in a `while true` or
--- `repeat ... until false` no `break` leaves, cannot. A
--- generic call's arguments before the literal bind the type variables
--- it reads (`table.sort(xs, function(a, b) ... end)`), and an
--- overloaded callee gives a literal the parameter type all its
--- functions agree on.
---
--- What stays as before has a case each: a declared parameter or return
--- list keeps its declaration, a type variable no earlier argument
--- binds leaves its parameter `any` (a nested generic call's result
--- binds none early), overloads that disagree give no context, and a
--- `...` away from the expected vararg stays `any`.
---
--- Each fixture is a module of its own, read by the new checker alone ([`build.snippet_fixture`]).

local Programs = require("lang.check_programs")
local Snippet = require("build.snippet_fixture")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Checks `source` as the one module of a fresh fixture: true, or false and what the new checker refused. `tmp` and `case`
--- are kept for the callers' sake: a snippet needs no directory.
local function compiles(_: string, _: string, source: string): boolean, string
  return Snippet.compiles(source)
end

--- Whether the compile was refused with the error `code` among its errors, and nothing else of the program wrong.
local function refused_by(ok: boolean, trouble: string, code: string): boolean
  return not ok and trouble:find("(" .. code .. ")", 1, true) ~= nil
end

local each_prelude = [[
local enum Kind
   "file"
   "dir"
end
local function each(f: function(Kind): boolean): boolean
   return f("file")
end
]]

local function test_an_untyped_parameter_takes_the_callee_s_type(tmp: string)
  local ok, trouble = compiles(tmp, "parameter", each_prelude .. [[
print(each(function(k) return k == "file" end))
print(each(function(k) return k == "dir" end))
]])
  assert(ok, "an untyped parameter should be the Kind each calls it with, " ..
      "and the omitted returns each's boolean, but: " .. tostring(trouble))
end

local function test_a_kind_typo_in_an_untyped_parameter_is_refused(tmp: string)
  local ok, trouble = compiles(tmp, "typo", each_prelude .. [[
print(each(function(k) return k == "directory" end))
]])
  assert(refused_by(ok, trouble, "enum_member"),
    "k is a Kind, so comparing it with \"directory\" is a typo, but: " .. tostring(trouble))
end

local function test_returns_are_checked_against_the_context(tmp: string)
  local ok, trouble = compiles(tmp, "returns", each_prelude .. [[
print(each(function(k) return #k end))
]])
  assert(refused_by(ok, trouble, "not_assignable"),
    "each's callback returns a boolean, so returning an integer is refused, but: " ..
      tostring(trouble))
end

local function test_a_missing_return_is_refused(tmp: string)
  local ok, trouble = compiles(tmp, "missing", each_prelude .. [[
print(each(function(k) print(k) end))
]])
  assert(refused_by(ok, trouble, "missing_return"),
    "a callback that returns nothing where a boolean is expected is refused, but: " ..
      tostring(trouble))
  ok, trouble = compiles(tmp, "missing-branch", each_prelude .. [[
print(each(function(k) if k == "dir" then return true end end))
]])
  assert(refused_by(ok, trouble, "missing_return"),
    "an if with no else falls through to the end, but: " .. tostring(trouble))
end

local function test_an_ending_that_never_falls_through_needs_no_return(tmp: string)
  local ok, trouble = compiles(tmp, "ends", each_prelude .. [[
print(each(function(k)
   if k == "dir" then return true else return false end
end))
print(each(function(k)
   if k == "dir" then return true end
   error("not a directory")
end))
local ok, trouble = pcall(function() print(1) end)
print(ok, trouble)
]])
  assert(ok, "an if with an else, an error at the end and pcall's optional returns need no return at the end, but: " ..
      tostring(trouble))
  -- The fork let a declared `: boolean` return list stand with no return at the end; the new checker does not.
  ok, trouble = compiles(tmp, "ends-declared", each_prelude .. [[
print(each(function(k): boolean print(k) end))
]])
  assert(refused_by(ok, trouble, "missing_return"),
    "a declared return list needs a return as an omitted one does, but: " .. tostring(trouble))
end

--- Each body that ends a block in a way 39a through 39d add, as its
--- own fixture, so each fails alone without them.
local endless_bodies: {{string}} = {
  { "do-return", "do return k == \"dir\" end" },
  { "do-nested", "do do if k == \"dir\" then return true else return false end end end" },
  { "while-true", "while true do if k == \"dir\" then return true end end" },
  { "repeat-false", "repeat if k == \"dir\" then return true end until false" },
  { "inner-break", [[
while true do
   for _ = 1, 2 do break end
   while true do break end
   repeat break until false
   if k == "dir" then return true end
end]] },
  { "do-while", "do while true do if k == \"dir\" then return true end end end" },
}

local function test_an_ending_block_or_endless_loop_needs_no_return(tmp: string)
  for _, case in ipairs(endless_bodies) do
    local name, body = case[1], case[2]
    assert(name and body, "a case is a name and a body")
    local ok, trouble = compiles(tmp, "ends-" .. name, each_prelude ..
        "print(each(function(k)\n" .. body .. "\nend))\n")
    assert(ok, name .. ": a body ending in a do block that ends, or a loop no " ..
        "break leaves, cannot reach its end, but: " .. tostring(trouble))
  end
end

--- Each body that can still reach its end: a loop whose condition is
--- not the literal that never ends it, one a `break` leaves (in its
--- body, an `if` or a `do` there), one a `break` leaves after a
--- `goto` continues, a `for`, and a `do` whose body falls through.
local falling_bodies: {{string}} = {
  { "while-cond", "while k == \"dir\" do return true end" },
  { "while-break", "while true do if k == \"dir\" then break end return true end" },
  { "while-do-break", "while true do do break end end" },
  { "while-else-break", "while true do if k == \"dir\" then return true else break end end" },
  { "repeat-true", "repeat if k == \"dir\" then return true end until true" },
  { "repeat-break", "repeat if k == \"dir\" then break end until false" },
  { "for", "for _ = 1, 2 do return true end" },
  { "forin", "for _ in pairs({}) do return true end" },
  { "do-falls", "do if k == \"dir\" then return true end end" },
  { "do-loop-break", "do while true do break end end" },
}

local function test_a_loop_or_block_that_can_end_still_needs_a_return(tmp: string)
  for _, case in ipairs(falling_bodies) do
    local name, body = case[1], case[2]
    assert(name and body, "a case is a name and a body")
    local ok, trouble = compiles(tmp, "falls-" .. name, each_prelude ..
        "print(each(function(k)\n" .. body .. "\nend))\n")
    assert(refused_by(ok, trouble, "missing_return"),
      name .. ": this body can reach its end, so it needs a return, but: " ..
        tostring(trouble))
  end
end

local function test_a_generic_call_binds_before_the_literal(tmp: string)
  local ok, trouble = compiles(tmp, "sort", [[
local xs = {3, 1, 2}
table.sort(xs, function(a, b)
   local half: integer = a // 2
   return half < b // 2 or a < b
end)
local function apply<T>(v: T, f: function(T): T): T
   return f(v)
end
local shout = apply("x", function(s) return s:upper() end)
print(shout)
]])
  assert(ok, "a and b are the integers xs holds, and s the string, but: " ..
      tostring(trouble))
end

local function test_an_unbound_type_variable_stays_any(tmp: string)
  local ok, trouble = compiles(tmp, "unbound", [[
local function map<A, B>(f: function(A): B, xs: {A}): {B}
   local out: mut {B} = {}
   for _, x in ipairs(xs) do out[#out + 1] = f(x) end
   return out
end
print(#map(function(x: string): string return x:upper() end, {"a"}))
print(#map(function(x) return x:upper() end, {"a"}))
]])
  -- The new checker binds A from the later argument `{"a"}` as well, so x is a string and `x:upper()` is fine; what no
  -- argument fixes is B, the literal's result, which a literal does not answer.
  assert(refused_by(ok, trouble, "cannot_infer"),
    "nothing fixes B, the result of a literal whose parameter is untyped, but: " .. tostring(trouble))
end

local function test_a_nested_generic_call_binds_nothing_early(tmp: string)
  local ok, trouble = compiles(tmp, "nested", [[
local function twice<A>(xs: mut {A}, f: function(A): A): mut {A}
   local out: mut {A} = {}
   for _, v in ipairs(xs) do out[#out + 1] = f(f(v)) end
   return out
end
local inner = twice({1}, function(i) return i // 1 end)
local outer = twice(twice({1}, function(i) return i // 1 end), function(i): integer
   if i == 1 then return 1 end
   return 2
end)
print(inner, outer)
]])
  assert(ok, "the inner call's result binds the outer call's A to no type early, " ..
      "so the outer literal is checked as before, but: " .. tostring(trouble))
end

local function test_an_optional_callback_takes_its_function_type(tmp: string)
  local ok, trouble = compiles(tmp, "optional", [[
local type Measure = function(string): integer
local function run(f: Measure?, g?: Measure): integer
   return (f and f("ab") or 0) + (g and g("c") or 0)
end
print(run(function(s) return #s:upper() end, function(s) return #s:lower() end))
]])
  assert(ok, "the one function type of a union with nil, and an optional " ..
      "parameter's, give the literal its context, but: " .. tostring(trouble))
end

local function test_declarations_fields_and_returns_give_context(tmp: string)
  local ok, trouble = compiles(tmp, "forms", [[
local record Handlers
   mut on: function(integer): string
end
local h: Handlers = { on = function(n) return tostring(n // 2) end }
h.on = function(n) return tostring(n // 3) end
local double: function(integer): integer = function(n) return n // 1 * 2 end
local function make(): function(string): integer
   return function(s) return #s:upper() end
end
print(h.on(4), double(2), make()("x"))
]])
  assert(ok, "a table field, an assignment, a declared local and a return " ..
      "each give a literal its context, but: " .. tostring(trouble))
end

local function test_a_declared_parameter_keeps_its_type(tmp: string)
  local ok, trouble = compiles(tmp, "declared", each_prelude .. [[
print(each(function(k: string): boolean return k == "directory" end))
]])
  assert(ok, "a parameter declared string compares with any string, as before, but: " ..
      tostring(trouble))
end

--- The fork gave an untyped `...` the type of the expected vararg; the grammar has no untyped rest parameter, so there is
--- no literal left to give a context to.
local function test_a_rest_parameter_is_always_typed(tmp: string)
  local ok, trouble = compiles(tmp, "varargs", [[
local function call(f: function(string, ...: integer): integer): integer
   return f("a", 1, 2)
end
print(call(function(s, ...: integer)
   local first = ... or 0
   return #s + first
end))
]])
  assert(ok, "a `...` written with the expected vararg's type is taken, but: " .. tostring(trouble))
  ok, trouble = compiles(tmp, "varargs-untyped", [[
local function call(f: function(string, integer): integer): integer
   return f("a", 1)
end
print(call(function(...)
   local first = ...
   return first:upper()
end))
]])
  assert(refused_by(ok, trouble, "expected_token"),
    "a `...` with no type is no part of the grammar, but: " .. tostring(trouble))
end

--- Overloads are declared in a declaration file only: a record that repeats a function field is refused. A literal passed to
--- a declared overloaded callee takes the parameter type its overloads agree on, and none where they disagree.
local function test_overloads_give_the_context_they_agree_on(tmp: string)
  local ok, trouble = compiles(tmp, "poly-record", [[
local record Each
   run: function(f: function(string): integer, n: integer): integer
   run: function(f: function(string): integer, s: string): integer
end
print(Each)
]])
  assert(refused_by(ok, trouble, "duplicate_field"), "a record cannot hold overloads, but: " .. tostring(trouble))
  local agree: {string: string} = {
    ["eachdecl"] = "local record Each\n  run: function(f: function(string): integer, n: integer): integer\n" ..
      "  run: function(f: function(string): integer, s: string): integer\nend\nreturn Each\n",
  }
  local r = Programs.run("local e = require(\"eachdecl\")\nprint(e.run(function(s) return #s:upper() end, 1))\n", nil, agree)
  assert(#r.before == 0 and Programs.codes(r) == "", "every overload calls the literal with a string, but: " ..
      table.concat(r.before, " ") .. Programs.codes(r))
  local disagree: {string: string} = {
    ["eachdecl"] = "local record Each\n  run: function(f: function(string): integer, n: integer): integer\n" ..
      "  run: function(f: function(integer): integer, s: string): integer\nend\nreturn Each\n",
  }
  local r2 = Programs.run("local e = require(\"eachdecl\")\nprint(e.run(function(s: string): integer return #s end, 1))\n" ..
      "print(e.run(function(s) return s:upper() end, 1))\n", nil, disagree)
  assert(#r2.before == 0 and Programs.codes(r2) ~= "",
    "overloads that disagree give the literal no context, but nothing was refused")
end
