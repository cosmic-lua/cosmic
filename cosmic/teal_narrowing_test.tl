#!/usr/bin/env cosmic
--- The truthiness-narrowing skip list's NEGATIVE side (the carried tl
--- patch): teal_test.tl's canary pins what must narrow; this file
--- pins what must not. Split from teal_test.tl by the 500-line file
--- limit.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- A typevar member is as truthiness-unsafe as boolean: `T | nil` may
-- instantiate T to boolean and put a runtime `false` in the negated
-- branch. The guard must NOT narrow the else branch to nil, so a file
-- relying on that narrowing must fail to check.
local function test_typevar_union_is_not_truthiness_narrowed()
  local path = fs.join(tmpdir, "narrow_typevar.tl")
  assert(fs.write(path, [[
local function f<T>(v: T | nil): string
  if v then
    return "t"
  else
    local n: nil = v
    return tostring(n)
  end
end
print(f(1))
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "T | nil must not narrow to nil in the negated branch (T may be boolean)")
end
test_typevar_union_is_not_truthiness_narrowed()

-- The direct boolean case the skip list has always covered, pinned so
-- the typevar fix above cannot regress it by loosening the scan.
local function test_boolean_union_is_not_truthiness_narrowed()
  local path = fs.join(tmpdir, "narrow_boolean.tl")
  assert(fs.write(path, [[
local function f(v: boolean | nil): string
  if v then
    return "t"
  else
    local n: nil = v
    return tostring(n)
  end
end
print(f(true))
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "boolean | nil must not narrow to nil in the negated branch")
end
test_boolean_union_is_not_truthiness_narrowed()

-- Control: with no guard at all, `any` must not satisfy a typed
-- parameter. Without this, test_early_exit_is_guard_narrows below would
-- still pass if `any` were freely assignable, and would pin nothing.
local function test_bare_any_does_not_satisfy_a_typed_parameter()
  local path = fs.join(tmpdir, "narrow_bare_any.tl")
  assert(fs.write(path, [[
local function take_string(s: string): string
  return s
end
local function f(v: any)
  take_string(v)
end
f("hi")
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "an unguarded `any` must not satisfy a typed parameter")
end
test_bare_any_does_not_satisfy_a_typed_parameter()

-- `is` narrowing of a plain variable DOES survive a return-terminated
-- early-exit guard, for a primitive, a record, and an array type. This
-- pins the correction to AGENTS.md and the guides: the false caveat
-- ("early-exit guards don't narrow") pushed writers toward needless
-- `as` casts at exactly the sites the epic's cast waves are removing.
local function test_early_exit_is_guard_narrows()
  local path = fs.join(tmpdir, "narrow_early_exit.tl")
  assert(fs.write(path, [[
local record Rec
  x: integer
end
local function take_string(s: string): string
  return s
end
local function take_rec(r: Rec): integer
  return r.x
end
local function take_array(a: {string}): integer
  return #a
end
local function f_string(v: any)
  if not (v is string) then return end
  take_string(v)
end
local function f_rec(v: any)
  if not (v is Rec) then return end
  take_rec(v)
end
local function f_array(v: any)
  if not (v is {string}) then return end
  take_array(v)
end
f_string("hi")
f_rec({x = 1})
f_array({"a"})
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "an `is` guard ending in return must narrow the variable below it: "
    .. table.concat(msgs, "; "))
end
test_early_exit_is_guard_narrows()

-- `is` narrows to a FUNCTION type as well, in all three spellings the
-- tree relies on: the anonymous `function(A): (B, C)` form, a named
-- function-type alias, and the `assert(x is F)` form. Sites that used
-- to guard with `type(x) == "function"` and then cast now guard with
-- `is` and hold no cast, so this is what keeps those deletions sound.
local function test_is_guard_narrows_a_function_type()
  local path = fs.join(tmpdir, "narrow_function_type.tl")
  assert(fs.write(path, [[
local type Thaw = function({string: any}): (any, any)
local function take_thaw(f: Thaw): any
  local a, _b = f({})
  return a
end
local function f_anon(v: any)
  if not (v is function({string: any}): (any, any)) then return end
  take_thaw(v)
end
local function f_alias(v: any)
  if not (v is Thaw) then return end
  take_thaw(v)
end
local function f_assert(v: any)
  assert(v is Thaw)
  take_thaw(v)
end
local thaw: Thaw = function(_h: {string: any}): (any, any)
  return 1, 2
end
f_anon(thaw)
f_alias(thaw)
f_assert(thaw)
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "an `is` guard must narrow a variable to a function type: "
    .. table.concat(msgs, "; "))
end
test_is_guard_narrows_a_function_type()

-- The negative twin: `type(v) ~= "function"` does NOT narrow, which is
-- why the guards above had to be rewritten rather than left alone.
-- Without this the positive test would still pass under a tl bump that
-- made the `type()` spelling narrow, and would pin nothing.
local function test_type_eq_function_does_not_narrow()
  local path = fs.join(tmpdir, "narrow_type_eq_function.tl")
  assert(fs.write(path, [[
local type Thaw = function({string: any}): (any, any)
local function take_thaw(f: Thaw): any
  local a, _b = f({})
  return a
end
local function f(v: any)
  if type(v) ~= "function" then return end
  take_thaw(v)
end
f(function(_h: {string: any}): (any, any)
  return 1, 2
end)
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "a `type(v) ~= \"function\"` guard must not narrow v to a function type")
end
test_type_eq_function_does_not_narrow()

-- A guard whose block ends in `error(...)` is terminal, so it narrows
-- below itself exactly as a `return`-terminated one does.
local function test_error_terminated_guard_narrows()
  local path = fs.join(tmpdir, "narrow_error_terminated.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local function f(): string
  local v = gs()
  if not v then error("no") end
  return v:upper()
end
print(f())
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a guard ending in error(...) must narrow below itself: "
    .. table.concat(msgs, "; "))
end
test_error_terminated_guard_narrows()

-- The other terminators that are not `return`: `break` leaves the loop,
-- `goto` jumps away, and `os.exit` ends the process. A branch ending in
-- any of them cannot fall through, so the negated guard narrows after it
-- — which is how every directory walk in this tree is written.
local function test_non_return_exits_narrow()
  local path = fs.join(tmpdir, "narrow_non_return_exits.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local function by_break(): integer
  local n = 0
  while true do
    local v = gs()
    if not v then break end
    n = n + #v:upper()
    break
  end
  return n
end
local function by_goto(): string
  local out = ""
  local v = gs()
  if not v then goto done end
  out = v:upper()
  ::done::
  return out
end
local function by_exit(): string
  local v = gs()
  if not v then os.exit(1) end
  return v:upper()
end
print(by_break(), by_goto(), by_exit())
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "break, goto and os.exit must terminate a guard's branch: "
    .. table.concat(msgs, "; "))
end
test_non_return_exits_narrow()

-- The pack-n patch: MIXED arguments fall to table.pack's any... overload,
-- which the carried patch types PackTable<any> instead of {any:any}, so
-- `.n` stays integer for every call shape. Without the patch both lines
-- fail with "got <any type>" (probed 2026-08-26); with it the file checks.
local function test_mixed_pack_keeps_n_integer()
  local path = fs.join(tmpdir, "narrow_pack_n.tl")
  assert(fs.write(path, [[
local t = coroutine.create(function(): boolean, string return true, "x" end)
local results = table.pack(coroutine.resume(t))
local n: integer = results.n
print(n)
print(table.unpack(results, 2, results.n))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "mixed table.pack must keep .n integer: " .. table.concat(msgs, "; "))
end
test_mixed_pack_keeps_n_integer()

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

-- ...and a NAMED target never reaches the rescue: the is-fact carries
-- the unresolved type, so a record nominal arrives as "nominal", not
-- "record", and the can-never-be refusal stands.
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
