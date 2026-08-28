#!/usr/bin/env cosmic
--- The metatable half of the carried tl patch: what `mt is <target>`
--- narrows a getmetatable() result to, and what it must not. Split
--- from teal_narrowing_test.tl by the 500-line file limit.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- The metatable-is patch: a getmetatable() result is a table at
-- runtime, so `is` against a table-kinded target narrows it instead of
-- refusing. Unpatched this file reports "cannot resolve a type for mt
-- here" plus the can-never-be branch warning (probed 2026-08-27); with
-- the patch the guarded index checks clean.
local function test_metatable_is_table_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_table.tl")
  assert(fs.write(path, [[
local function f(x: any): boolean
  local mt = getmetatable(x)
  if not (mt is {string: any}) then
    return false
  end
  return mt.__index ~= nil
end
print(f({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is {string: any}` must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_table_narrows()

-- ...and only table-kinded targets qualify: a metatable can never be a
-- scalar, so that `is` keeps refusing.
local function test_metatable_is_scalar_is_refused()
  local path = fs.join(tmpdir, "narrow_metatable_scalar.tl")
  assert(fs.write(path, [[
local function g(x: any): boolean
  local mt = getmetatable(x)
  if mt is integer then
    return true
  end
  return false
end
print(g({}))
]]))
  local result = teal.check_file(path)
  assert(not result.ok, "`mt is integer` must keep failing to check")
end
test_metatable_is_scalar_is_refused()

-- ...and a record target is refused even though the rescue now resolves
-- a nominal one: a record's resolved typename is not in the rescue's
-- table_kinded set, so the can-never-be refusal stands.
local function test_metatable_is_record_is_refused()
  local path = fs.join(tmpdir, "narrow_metatable_record.tl")
  assert(fs.write(path, [[
local record Handler
  name: string
end
local function h(x: any): string
  local mt = getmetatable(x)
  if mt is Handler then
    return mt.name
  end
  return ""
end
print(h({}))
]]))
  local result = teal.check_file(path)
  assert(not result.ok, "`mt is Handler` (a record nominal) must keep failing to check")
end
test_metatable_is_record_is_refused()

-- An interface nominal is refused for the same reason.
local function test_metatable_is_interface_is_refused()
  local path = fs.join(tmpdir, "narrow_metatable_interface.tl")
  assert(fs.write(path, [[
local interface Shape
  kind: string
end
local function s(x: any): string
  local mt = getmetatable(x)
  if mt is Shape then
    return mt.kind
  end
  return ""
end
print(s({}))
]]))
  local result = teal.check_file(path)
  assert(not result.ok, "`mt is Shape` (an interface nominal) must keep failing to check")
end
test_metatable_is_interface_is_refused()

-- The array half of the live rescue: an inline `{T}` target narrows a
-- metatable exactly as an inline map target does.
local function test_metatable_is_array_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_array.tl")
  assert(fs.write(path, [[
local function a(x: any): integer
  local mt = getmetatable(x)
  if not (mt is {string}) then
    return 0
  end
  return #mt
end
print(a({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is {string}` must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_array_narrows()

-- A named alias of a map narrows exactly as the inline literal does:
-- the rescue resolves a nominal target and judges its structural kind.
local function test_metatable_is_map_alias_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_map_alias.tl")
  assert(fs.write(path, [[
local type Meta = {string: any}
local function m(x: any): boolean
  local mt = getmetatable(x)
  if not (mt is Meta) then
    return false
  end
  return mt.__index ~= nil
end
print(m({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is Meta` (an alias of a map) must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_map_alias_narrows()

-- ...and the array half of the same rule.
local function test_metatable_is_array_alias_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_array_alias.tl")
  assert(fs.write(path, [[
local type Names = {string}
local function n(x: any): integer
  local mt = getmetatable(x)
  if not (mt is Names) then
    return 0
  end
  return #mt
end
print(n({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is Names` (an alias of an array) must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_array_alias_narrows()

-- The rescue admits the target by its KIND alone, so only the kind may
-- reach the narrowed variable: a metatable<T>'s values are metamethods,
-- never the target's value type. `mt is {string: integer}` narrows mt
-- to {string: any}, so `mt.__index` stays `any` and arithmetic on it is
-- refused. Typed as integer it would check clean and throw at runtime.
local function test_metatable_is_concrete_map_does_not_type_the_value()
  local path = fs.join(tmpdir, "metatable_concrete_map.tl")
  assert(fs.write(path, [[
local function f(x: any): integer
  local mt = getmetatable(x)
  if not (mt is {string: integer}) then
    return 0
  end
  return mt.__index + 1
end
print(f(setmetatable({}, {__index = function() end})))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  local joined = table.concat(msgs, "; ")
  assert(not result.ok,
    "`mt is {string: integer}` must not type mt.__index as integer")
  assert(joined:find("cannot use operator '+'", 1, true),
    "expected an arithmetic refusal on an `any` metamethod: " .. joined)
end
test_metatable_is_concrete_map_does_not_type_the_value()

-- The same through a named target: the rescue resolves the nominal to
-- judge its kind, so an alias of a concrete map opens exactly like the
-- inline spelling. The two must not disagree.
local function test_metatable_is_concrete_map_alias_does_not_type_the_value()
  local path = fs.join(tmpdir, "metatable_concrete_alias.tl")
  assert(fs.write(path, [[
local type Ints = {string: integer}
local function f(x: any): integer
  local mt = getmetatable(x)
  if not (mt is Ints) then
    return 0
  end
  return mt.__index + 1
end
print(f(setmetatable({}, {__index = function() end})))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  local joined = table.concat(msgs, "; ")
  assert(not result.ok,
    "`mt is Ints` must not type mt.__index as integer")
  assert(joined:find("cannot use operator '+'", 1, true),
    "expected an arithmetic refusal on an `any` metamethod: " .. joined)
end
test_metatable_is_concrete_map_alias_does_not_type_the_value()

-- The array half opens the same way: `mt is {integer}` narrows mt to
-- {any}, so `#mt` still checks while `mt[1]` is `any`.
local function test_metatable_is_array_does_not_type_the_element()
  local path = fs.join(tmpdir, "metatable_concrete_array.tl")
  assert(fs.write(path, [[
local function f(x: any): integer
  local mt = getmetatable(x)
  if not (mt is {integer}) then
    return 0
  end
  return mt[1] + 1
end
print(f(setmetatable({}, {})))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  local joined = table.concat(msgs, "; ")
  assert(not result.ok,
    "`mt is {integer}` must not type mt[1] as integer")
  assert(joined:find("cannot use operator '+'", 1, true),
    "expected an arithmetic refusal on an `any` element: " .. joined)
end
test_metatable_is_array_does_not_type_the_element()

-- The narrowed type does not stay inside the guard: it assigns out into
-- ordinary variables and arguments, which is what makes an invented
-- value type worth refusing rather than tolerating.
local function test_metatable_narrow_does_not_escape_into_a_concrete_map()
  local path = fs.join(tmpdir, "metatable_escape.tl")
  assert(fs.write(path, [[
local function f(x: any): {string: integer}
  local mt = getmetatable(x)
  if not (mt is {string: integer}) then
    return {}
  end
  local m: {string: integer} = mt
  return m
end
print(f(setmetatable({}, {})))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  local joined = table.concat(msgs, "; ")
  assert(not result.ok,
    "a narrowed metatable must not assign out as {string: integer}")
  assert(joined:find("in map value", 1, true),
    "expected a map-value mismatch on the escaping assignment: " .. joined)
end
test_metatable_narrow_does_not_escape_into_a_concrete_map()
