--- A call to a generic function binds each type variable from its arguments, and an argument the variable cannot take is
--- refused: a nilable one for a variable another argument fixes, and an array of a record for an array of its interface.
---
--- The fork's tests of `setmetatable(t, mt)`, `function<T>(T, metatable<T>): T`, bound through the arguments-first retry
--- of its checker are gone: the grammar has no `setmetatable` (a program that calls it is refused with `setmetatable_call`,
--- lang/check_class_test.tl), and a class makes its value with a table literal typed as the class.

local Snippet = require("build.snippet_fixture")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Checks `source` as the one module of a fresh fixture: true, or false and what the new checker refused. `tmp` and `case`
--- are kept for the callers' sake: a snippet needs no directory.
local function compiles(_: string, _: string, source: string): boolean, string
  return Snippet.compiles(source)
end

local prelude = [[
local interface Named
  name: string
end
local record Thing is Named
  name: string
end
]]

-- `id({ name = "a" }, u)` with u: Thing? is refused in a function returning Named: the argument may be nil, though the
-- result of the call is taken for a Named, so a nil that reached a type variable some other way would leak through.
local function test_a_nilable_argument_is_refused_for_a_shared_type_variable(tmp: string)
  local ok, trouble = compiles(tmp, "hole-nil", prelude .. [[
local function id<T>(a: T, b: T): T
  print(a)
  return b
end
local function named(): Named
  local u: Thing?
  return id({ name = "a" }, u)
end
print(named)
]])
  assert(not ok, "the nil of u is refused, but the compile passed")
  assert(tostring(trouble):find("(nil_not_allowed)", 1, true) ~= nil,
    "the nil of u is refused as a value that is no Named: " .. tostring(trouble))
end

-- A view `{T}` is read-only, so an array of Thing stands for an array of Named through a type variable; a `mut {T}` is
-- invariant, as the caller may store any Named in the array it gets back. The fork took every array covariantly and its
-- test pinned that hole.
local function test_a_view_is_covariant_and_a_mut_array_invariant_through_a_type_variable(tmp: string)
  local ok, trouble = compiles(tmp, "view-array", prelude .. [[
local function wrap<T>(a: {T}, b: {T}): {T}
  print(a)
  return b
end
local function named(ts: {Thing}): {Named}
  return wrap({ { name = "a" } }, ts)
end
print(named)
]])
  assert(ok, "a view of Thing is a view of Named, but: " .. tostring(trouble))
  ok, trouble = compiles(tmp, "mut-array", prelude .. [[
local function wrap<T>(a: mut {T}, b: mut {T}): mut {T}
  print(a)
  return b
end
local function named(ts: mut {Thing}): mut {Named}
  return wrap({ { name = "a" } }, ts)
end
print(named)
]])
  assert(not ok, "a mut array of Thing is no mut array of Named, but the compile passed")
  assert(tostring(trouble):find("(invariant_mut)", 1, true) ~= nil, tostring(trouble))
end
