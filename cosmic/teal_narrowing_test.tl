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
