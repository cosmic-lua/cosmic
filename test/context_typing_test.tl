--- Proves the contextual typing of a function literal that patch/tl's
--- 37a through 37i add. A literal checked where a function type is
--- expected -- a call's argument, a declared local, an assignment, a
--- table field, a return -- gives each parameter it leaves untyped the
--- expected parameter type, and an omitted return list the expected
--- returns, which its `return` statements are then checked against;
--- one that can reach its end where a value is expected is refused. A
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
--- Each fixture is a single file in its own fresh subdirectory, since
--- [`build.importer`] compiles every `.tl` file under a root together.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Compiles `source` as the one module of a fresh fixture project:
--- true, or false and what the compile refused.
local function compiles(tmp: string, case: string, source: string): boolean, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/probe.tl", source))
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "context-typing-test")
  work.close(handle)
  if result == nil then
    return false, trouble
  end
  return true, ""
end

--- Whether the compile was refused with `text` among its errors.
local function refused(ok: boolean, trouble: string, text: string): boolean
  return not ok and trouble:find(text, 1, true) ~= nil
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
print(each(function(k) return k:upper() == "FILE" end))
print(each(function(k) return k == "dir" end))
]])
  assert(ok, "an untyped parameter should be the Kind each calls it with, " ..
      "and the omitted returns each's boolean, but: " .. tostring(trouble))
end

local function test_a_kind_typo_in_an_untyped_parameter_is_refused(tmp: string)
  local ok, trouble = compiles(tmp, "typo", each_prelude .. [[
print(each(function(k) return k == "directory" end))
]])
  assert(refused(ok, trouble, "\"directory\" is not a member of Kind"),
    "k is a Kind, so comparing it with \"directory\" is a typo, but: " .. tostring(trouble))
end

local function test_returns_are_checked_against_the_context(tmp: string)
  local ok, trouble = compiles(tmp, "returns", each_prelude .. [[
print(each(function(k) return #k end))
]])
  assert(refused(ok, trouble, "got integer, expected boolean"),
    "each's callback returns a boolean, so returning an integer is refused, but: " ..
      tostring(trouble))
end

local function test_a_missing_return_is_refused(tmp: string)
  local ok, trouble = compiles(tmp, "missing", each_prelude .. [[
print(each(function(k) print(k) end))
]])
  assert(refused(ok, trouble, "missing return"),
    "a callback that returns nothing where a boolean is expected is refused, but: " ..
      tostring(trouble))
  ok, trouble = compiles(tmp, "missing-branch", each_prelude .. [[
print(each(function(k) if k == "dir" then return true end end))
]])
  assert(refused(ok, trouble, "missing return"),
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
print(each(function(k): boolean print(k) end))
local ok, trouble = pcall(function() print(1) end)
print(ok, trouble)
]])
  assert(ok, "an if with an else, an error at the end, declared returns and " ..
      "pcall's optional returns need no return at the end, but: " .. tostring(trouble))
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
   local out: {B} = {}
   for i, x in ipairs(xs) do out[i] = f(x) end
   return out
end
print(#map(function(x: string): string return x:upper() end, {"a"}))
print(#map(function(x) return x:upper() end, {"a"}))
]])
  assert(refused(ok, trouble, "of type <any type>"),
    "no argument before the literal binds A, so x is any, but: " .. tostring(trouble))
end

local function test_a_nested_generic_call_binds_nothing_early(tmp: string)
  local ok, trouble = compiles(tmp, "nested", [[
local function twice<A>(xs: {A}, f: function(A): A): {A}
   for i, v in ipairs(xs) do xs[i] = f(f(v)) end
   return xs
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
local function run(f: Measure | nil, g?: Measure): integer
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
   on: function(integer): string
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

local function test_varargs_take_the_expected_vararg(tmp: string)
  local ok, trouble = compiles(tmp, "varargs", [[
local function call(f: function(string, ...: integer): integer): integer
   return f("a", 1, 2)
end
print(call(function(s, ...)
   local first: integer = ...
   return #s + first
end))
]])
  assert(ok, "a `...` at the expected vararg takes its type, but: " .. tostring(trouble))
  ok, trouble = compiles(tmp, "varargs-misplaced", [[
local function call(f: function(string, integer): integer): integer
   return f("a", 1)
end
print(call(function(...)
   local first = ...
   return first:upper()
end))
]])
  assert(refused(ok, trouble, "of type <any type>"),
    "a `...` covering several expected parameters stays any, but: " .. tostring(trouble))
end

local function test_overloads_give_the_context_they_agree_on(tmp: string)
  local ok, trouble = compiles(tmp, "poly", [[
local record Each
   run: function(f: function(string): integer, n: integer): integer
   run: function(f: function(string): integer, s: string): integer
end
local e: Each = {}
print(e.run(function(s) return #s:upper() end, 1))
]])
  assert(ok, "every overload calls the literal with a string, but: " .. tostring(trouble))
  ok, trouble = compiles(tmp, "poly-disagree", [[
local record Each
   run: function(f: function(string): integer, n: integer): integer
   run: function(f: function(integer): integer, s: string): integer
end
local e: Each = {}
print(e.run(function(s: string): integer return #s end, 1))
print(e.run(function(s) return s:upper() end, 1))
]])
  assert(refused(ok, trouble, "of type <any type>"),
    "overloads that disagree give the literal no context, but: " .. tostring(trouble))
end
