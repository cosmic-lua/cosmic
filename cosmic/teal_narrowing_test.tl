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

-- The caveat that IS true: a guard whose block ends in `error(...)`
-- rather than `return` does not narrow below itself — the checker
-- cannot see that the block is terminal. Pinned so a future patch
-- cannot quietly flip this back.
local function test_error_terminated_guard_does_not_narrow()
  local path = fs.join(tmpdir, "narrow_error_terminated.tl")
  assert(fs.write(path, [[
local function take_string(s: string): string
  return s
end
local function f(v: any)
  if not (v is string) then error("no") end
  take_string(v)
end
f("hi")
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "an `is` guard ending in error(...) must not narrow below itself")
end
test_error_terminated_guard_does_not_narrow()

-- The other half of the honest-nil doctrine, and the one the prose used
-- to get wrong: the checker DEMANDS a guard in exactly one position, an
-- index. Assignment to a declared non-nil type, a non-nil parameter,
-- arithmetic and concatenation all admit an unnarrowed `T | nil`, so an
-- unguarded union becomes a runtime nil downstream. AGENTS.md,
-- docs/stdlib.md and docs/guides/checking.md describe this boundary; if
-- this test fails, the boundary moved and those three say the wrong
-- thing.
local function test_nil_union_is_admitted_outside_an_index()
  local path = fs.join(tmpdir, "narrow_nil_admitted.tl")
  assert(fs.write(path, [[
local function gi(): integer | nil
  return 1
end
local function gs(): string | nil
  return "s"
end
local function take_int(n: integer): integer
  return n
end
local n = gi()
local m: integer = gi()
local t: string = gs()
print(n + 1, take_int(gi()), ("abc"):sub(1, gi()))
print(gs() .. "x", m, t)
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "arithmetic, concatenation, a declared non-nil local and a non-nil "
    .. "parameter must all admit an unnarrowed T | nil: "
    .. table.concat(msgs, "; "))
end
test_nil_union_is_admitted_outside_an_index()

-- The negative twin: an index is the position that does refuse. Without
-- it the test above would still pass under a checker that grew strict
-- everywhere, and would pin nothing.
local function test_nil_union_is_refused_at_an_index()
  local path = fs.join(tmpdir, "narrow_nil_indexed.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local s = gs()
print(s:upper())
]]))
  local result = teal.check_file(path)
  assert(not result.ok,
    "indexing an unnarrowed string | nil must be refused")
end
test_nil_union_is_refused_at_an_index()
