#!/usr/bin/env cosmic
--- How nil FLOWS, in value position and at admission (the carried tl
--- patch's value-position rules, and the checker's one demanded
--- guard): `x or fallback`, disjunctive guards, `a and a.field`, and
--- the boundary where an unnarrowed `T | nil` is admitted everywhere
--- but an index. The guard and dispatch rules live in
--- teal_narrowing_test.tl; this file is the home for nil-flow tests
--- (the strict-mode queue lands its cases here). Split from that file
--- by the 500-line limit.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- `x or fallback` cannot be nil when the fallback cannot be, so the
-- expression drops the nil member rather than taking the left union
-- whole. Two unions stay a union: neither operand disposes of the nil.
local function test_or_fallback_drops_nil()
  local path = fs.join(tmpdir, "narrow_or_fallback.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local text = gs() or ""
print(text:upper())
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "`x or fallback` with a non-nil fallback must not be nil: "
    .. table.concat(msgs, "; "))

  local both = fs.join(tmpdir, "narrow_or_both_unions.tl")
  assert(fs.write(both, [[
local function gs(): string | nil
  return "s"
end
local a = gs() or gs()
print(a:upper())
]]))
  assert(not teal.check_file(both).ok,
    "`x or y` with both operands nil-carrying must stay a union")
end

-- A disjunctive guard distributes: every arm of an `or` is false in the
-- fall-through branch, so a `== nil` arm narrows there even when the
-- other arms say nothing about the variable's type.
local function test_disjunctive_guard_narrows()
  local path = fs.join(tmpdir, "narrow_disjunctive_guard.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local function by_eq(): string
  local v = gs()
  if v == nil or v == "" then return "" end
  return v:upper()
end
local function by_truthy(): string
  local v = gs()
  if not v or v == "" then return "" end
  return v:upper()
end
print(by_eq(), by_truthy())
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "each arm of an `or` guard is false below it, so the nil arm narrows: "
    .. table.concat(msgs, "; "))
end

-- The left operand of `and` is read for its truthiness wherever the
-- expression sits, not only inside an `if`: when it is falsy the right
-- operand never runs, so the variable is non-nil throughout it.
local function test_and_operand_narrows_in_value_position()
  local path = fs.join(tmpdir, "narrow_and_value_position.tl")
  assert(fs.write(path, [[
local function gs(): string | nil
  return "s"
end
local function assigned(): string | nil
  local v = gs()
  local up = v and v:upper()
  return up
end
local function returned(): string | nil
  local v = gs()
  return v and v:upper()
end
print(assigned(), returned())
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "`x and x:m()` must narrow x outside a boolean context too: "
    .. table.concat(msgs, "; "))
end

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
