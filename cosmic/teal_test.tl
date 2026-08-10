#!/usr/bin/env cosmic
-- Canary tests for teal.hint_for_message: each hint pattern is provoked
-- through the real check path with the pinned tl, so a tl version bump
-- that rewords an error message fails here instead of silently killing
-- the hint. Same philosophy as the 5.4 codegen canary in 3p/tl/tl_test.tl.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- Check a snippet and return the first error message that has a hint,
-- plus that hint, asserting the check failed at all.
local function first_hinted_error(name: string, source: string): string, string
  local path = fs.join(tmpdir, name)
  local ok, werr = fs.write(path, source)
  assert(ok, "write " .. name .. ": " .. tostring(werr))
  local result = teal.check_file(path)
  assert(not result.ok, name .. ": snippet should fail the strict check")
  assert(#result.errors > 0, name .. ": snippet should produce errors")
  for _, issue in ipairs(result.errors) do
    local hint = teal.hint_for_message(issue.message)
    if hint then
      return issue.message, hint
    end
  end
  local msgs: {string} = {}
  for _, issue in ipairs(result.errors) do
    msgs[#msgs + 1] = issue.message
  end
  error(name .. ": no error message matched a hint; got:\n  "
    .. table.concat(msgs, "\n  "))
end

local function test_hint_number_expected_integer()
  local msg, hint = first_hinted_error("h_integer.tl", [[
local s = "abc"
local n: number = 2.5
print(s:sub(1, n))
]])
  assert(msg:find("got number, expected integer", 1, true), "wrong error: " .. msg)
  assert(hint:find("math.tointeger", 1, true), "wrong hint: " .. hint)
end
test_hint_number_expected_integer()

local function test_hint_nil_union_not_narrowed()
  -- tl 0.24.8 accepts a plain `T | nil` where `T` is expected (nil is a
  -- member of every type), so the two-member case never errors; a union
  -- with a second non-nil member is what actually produces
  -- "got ... | nil, expected ...".
  local msg, hint = first_hinted_error("h_union.tl", [[
local function f(): string | integer | nil
  return nil
end
local function g(s: string): string
  return s
end
print(g(f()))
]])
  assert(msg:find("| nil", 1, true) and msg:find("expected", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("narrow first", 1, true), "wrong hint: " .. hint)
end
test_hint_nil_union_not_narrowed()

-- The carried tl patch's canary (3p/tl/tl_patch.tl): a plain variable's
-- nil union narrows through truthiness (positive branch and negated
-- early-return alike), through `assert(x)`, through the left operand
-- of `and` (`if x and x.field`), and through `== nil` / `~= nil` —
-- which is exact, so it narrows boolean unions truthiness cannot
-- touch. `assert` narrows in EXPRESSION position too, since it
-- declares that it strips nil. A tl pin bump that lands without the
-- patch — or a patch whose anchor drifted — fails HERE, not as a
-- hundred downstream type errors.
local function test_narrowing_canary()
  local path = fs.join(tmpdir, "narrow_ok.tl")
  assert(fs.write(path, [[
local record R
  x: integer
end
local function make(): R | nil
  return {x = 1}
end
local function early(): integer
  local r = make()
  if not r then
    return 1
  end
  return r.x
end
local function positive(): integer
  local r = make()
  if r then
    return r.x
  end
  return 0
end
local function arr(): integer
  local xs: {integer} | nil = {2}
  if not xs then
    return 0
  end
  local sum = 0
  for _, v in ipairs(xs) do
    sum = sum + v
  end
  return sum
end
local function via_assert(): integer
  local r = make()
  assert(r, "make failed")
  return r.x
end
local function via_assert_expression(): integer
  -- the shape a Lua programmer writes first (whilp/cosmic#1065):
  -- assert DECLARES that it strips nil, so it narrows composed with a
  -- fallible call, not only as a statement above the use
  local r = assert(make())
  local r2 = assert(make())
  return r.x + r2.x
end
local function via_and_operand(): integer
  -- `if x and x.field` is the guard a Lua programmer writes; the left
  -- operand of `and` decides the branch, so it is read in boolean
  -- context and carries the same fact (whilp/cosmic#942)
  local r = make()
  if r and r.x > 0 then
    return r.x
  end
  local s = make()
  while s and s.x > 3 do
    return s.x
  end
  return 0
end
local function via_eq_nil(): integer
  local r = make()
  if r == nil then
    return 0
  end
  return r.x
end
local function via_ne_nil_boolean(): integer
  local b: boolean | nil = false
  if b ~= nil then
    return b and 1 or 2
  end
  return 0
end
print(early() + positive() + arr() + via_assert() + via_assert_expression()
  + via_and_operand() + via_eq_nil() + via_ne_nil_boolean())
]]))
  local result = teal.check_file(path)
  assert(result.ok, "guards must narrow a nil union (carried tl patch): "
    .. (result.ok and "" or teal.format_issues(result.errors)))
end
test_narrowing_canary()

-- Record FIELDS still do not narrow — a guard on `o.sub` leaves `o.sub`
-- un-narrowed at the use; the error names the type but not the cause,
-- so the shape carries a hint at the fix (copy the field to a local).
local function test_hint_index_through_nil_union()
  local msg, hint = first_hinted_error("h_idx_union.tl", [[
local record Inner
  x: integer
end
local record Outer
  sub: Inner | nil
end
local function use(o: Outer): integer
  if o.sub then
    return o.sub.x
  end
  return 0
end
print(use({}))
]])
  assert(msg:find("cannot index", 1, true) and msg:find("| nil", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("do not narrow", 1, true), "wrong hint: " .. hint)
  assert(hint:find("guide.checking", 1, true), "wrong hint: " .. hint)
end
test_hint_index_through_nil_union()

local function test_hint_for_loop_nil_union_iterator()
  local msg, hint = first_hinted_error("h_for_union.tl", [[
local type Iter = function(): string
local function rows(): Iter | nil
  return nil
end
local function use()
  local it = rows()
  for x in it do
    print(x)
  end
end
use()
]])
  assert(msg:find("for loop does not return an iterator", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("fallible call", 1, true), "wrong hint: " .. hint)
end
test_hint_for_loop_nil_union_iterator()

local function test_hint_ipairs_on_nil_union()
  local msg, hint = first_hinted_error("h_ipairs_union.tl", [[
local function list(): {string} | nil
  return nil
end
local function use()
  local xs = list()
  for _, x in ipairs(xs) do
    print(x)
  end
end
use()
]])
  assert(msg:find("attempting ipairs", 1, true) and msg:find("| nil", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("does not narrow", 1, true), "wrong hint: " .. hint)
end
test_hint_ipairs_on_nil_union()

local function test_hint_unexported_type()
  -- The dep module declares its record standalone (file-local), so the
  -- user file's `depmod.Widget` cannot resolve; both land in tmpdir so
  -- the require resolves relative to the checked file.
  local ok, werr = fs.write(fs.join(tmpdir, "depmod.tl"), [[
local record Widget
  id: integer
end
local record DepModule
  make: function(): Widget
end
local function make(): Widget
  return {id = 1}
end
local M: DepModule = {make = make}
return M
]])
  assert(ok, "write depmod.tl: " .. tostring(werr))
  local msg, hint = first_hinted_error("h_unexported.tl", [[
local depmod = require("depmod")
local function label(w: depmod.Widget): string
  return tostring(w.id)
end
print(label(depmod.make()))
]])
  assert(msg:find("unknown type", 1, true), "wrong error: " .. msg)
  assert(hint:find("interface record", 1, true), "wrong hint: " .. hint)
end
test_hint_unexported_type()

local function test_hint_scalar_method_call_unguarded()
  -- Any guard on the variable narrows it and the method call works;
  -- with no guard at all the method call is the use that fails first —
  -- the same "cannot index ... | nil" error shape as records, so it
  -- carries the same hint.
  local msg, hint = first_hinted_error("h_scalar_method.tl", [[
local function readish(): string | nil, string
  return nil, "nope"
end
local function use(): integer
  local data = readish()
  for word in data:gmatch("%a+") do
    print(word)
  end
  return 0
end
print(use())
]])
  assert(msg:find("cannot index", 1, true) and msg:find("| nil", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("do not narrow", 1, true), "wrong hint: " .. hint)
end
test_hint_scalar_method_call_unguarded()

local function test_hint_colon_call_on_module_function()
  local msg, hint = first_hinted_error("h_colon.tl", [[
local record Store
  id: integer
end
local function add(store: Store, name: string): string
  return tostring(store.id) .. name
end
local function use(store: Store): string
  return store:add("alice")
end
local store: Store = {id = 1}
print(add(store, "x"), use(store))
]])
  assert(msg:find("invalid key", 1, true), "wrong error: " .. msg)
  assert(hint:find("dot%-called", 1, false), "wrong hint: " .. hint)
end
test_hint_colon_call_on_module_function()

local function test_hint_unannotated_nil_local()
  -- `local x = nil` infers the type nil itself; the assignment error is
  -- the shape everyone hits first (the operator shape rides the same
  -- hint).
  local msg, hint = first_hinted_error("h_nil_local.tl", [[
local function lowest(ts: {integer}): integer | nil
  local earliest = nil
  for _, t in ipairs(ts) do
    if not earliest or t < earliest then
      earliest = t
    end
  end
  return earliest
end
print(lowest({3, 1}))
]])
  assert(msg:find("expected nil", 1, true) or msg:find("and nil", 1, true),
    "wrong error: " .. msg)
  assert(hint:find("type nil forever", 1, true), "wrong hint: " .. hint)
end
test_hint_unannotated_nil_local()

local function test_hint_excess_return_values()
  local msg, hint = first_hinted_error("h_excess.tl", [[
local function f(): string
  return "a", "b"
end
print(f())
]])
  assert(msg:find("excess return values", 1, true), "wrong error: " .. msg)
  assert(hint:find("capture multiple returns", 1, true), "wrong hint: " .. hint)
end
test_hint_excess_return_values()

-- A multi-return call in the LAST argument slot spreads its declared
-- tuple into the argument list, so the call site presents more
-- arguments than any overload accepts (the check.must-as-last-argument
-- trap). The hint names the parenthesize fix.
local function test_hint_multi_return_spread_in_last_argument()
  local msg, hint = first_hinted_error("h_spread.tl", [[
local function pair(): string, string
  return "a", "b"
end
local function one(x: string): string
  return x
end
print(one(pair()))
]])
  assert(msg:find("wrong number of arguments", 1, true), "wrong error: " .. msg)
  assert(hint:find("parenthesize", 1, true), "wrong hint: " .. hint)
end
test_hint_multi_return_spread_in_last_argument()

local function test_hint_ipairs_on_any()
  local msg, hint = first_hinted_error("h_ipairs.tl", [[
local function f(v: any)
  for _, x in ipairs(v) do
    print(x)
  end
end
f({})
]])
  assert(msg:find("attempting ipairs", 1, true), "wrong error: " .. msg)
  assert(hint:find("as {any}", 1, true), "wrong hint: " .. hint)
end
test_hint_ipairs_on_any()

local function test_hint_concat_any()
  local msg, hint = first_hinted_error("h_concat.tl", [[
local function f(v: any): string
  return "x" .. v
end
print(f(1))
]])
  assert(msg:find("cannot use operator", 1, true)
    and msg:find("<any type>", 1, true), "wrong error: " .. msg)
  assert(hint:find("as string", 1, true), "wrong hint: " .. hint)
end
test_hint_concat_any()

local function test_hint_index_any()
  local msg, hint = first_hinted_error("h_index.tl", [[
local function f(v: any)
  print(v.x)
end
f({})
]])
  assert(msg:find("cannot index", 1, true)
    and msg:find("<any type>", 1, true), "wrong error: " .. msg)
  assert(hint:find("as {string: any}", 1, true), "wrong hint: " .. hint)
end
test_hint_index_any()

-- The lax/strict contract, asserted rather than only documented:
-- --compile (default) is the permissive gradual-typing on-ramp; strict
-- compile refuses everything --check types refuses (type errors AND
-- warnings) and generates from the checked AST.
local function test_compile_lax_strict_contract()
  -- Lax forgives UNKNOWNS (the plain-Lua on-ramp), not explicit
  -- contradictions: an undeclared variable passes lax and fails strict.
  local unknown = fs.join(tmpdir, "c_unknown.tl")
  assert(fs.write(unknown, "print(xyzzy)\n"))
  assert(teal.compile_file(unknown).ok,
    "default compile is lax: unknown variables must not stop codegen")
  local strict = teal.compile_file(unknown, {strict = true})
  assert(not strict.ok, "strict compile must reject unknown variables")
  assert(#strict.errors > 0 and strict.errors[1].severity == "error")
  assert(not teal.check_file(unknown).ok, "check must reject what strict compile rejects")

  -- An explicitly annotated contradiction fails both ways: lax still
  -- checks what you declared.
  local type_err = fs.join(tmpdir, "c_type_err.tl")
  assert(fs.write(type_err, "local s: string = 42\nprint(s)\n"))
  assert(not teal.compile_file(type_err).ok,
    "even lax compile rejects an annotated contradiction")
  assert(not teal.compile_file(type_err, {strict = true}).ok)

  local warn_only = fs.join(tmpdir, "c_warn.tl")
  assert(fs.write(warn_only, "local unused = 1\nprint(\"hi\")\n"))
  assert(teal.compile_file(warn_only).ok,
    "default compile must not fail on warnings")
  local strict_warn = teal.compile_file(warn_only, {strict = true})
  assert(not strict_warn.ok, "strict compile must fail on warnings, matching check")
  assert(strict_warn.errors[1].severity == "warning",
    "the failure should carry the warning issue")
end
test_compile_lax_strict_contract()

-- A clean file must generate identical code both ways (same AST, same
-- 5.4 target), and 5.4-only syntax must survive the strict path.
local function test_strict_compile_codegen()
  local clean = fs.join(tmpdir, "c_clean.tl")
  assert(fs.write(clean,
      "local function add(a: integer, b: integer): integer\n"
      .. "  return a + b\n"
      .. "end\n"
      .. "print(add(1, 2))\n"))
  local lax = teal.compile_file(clean)
  local strict = teal.compile_file(clean, {strict = true})
  assert(lax.ok and strict.ok, "clean file should compile both ways")
  assert(lax.code == strict.code,
    "lax and strict codegen of a clean file must be identical")

  local closer = fs.join(tmpdir, "c_close.tl")
  assert(fs.write(closer,
      "local f <close> = assert(io.open(\"/dev/null\", \"r\"))\n"
      .. "print(f ~= nil)\n"))
  local sc = teal.compile_file(closer, {strict = true})
  assert(sc.ok, "strict compile of <close> should pass: "
    .. (sc.ok and "" or teal.format_issues(sc.errors)))
  assert(string.find(sc.code or "", "<close>", 1, true),
    "strict compile must keep the 5.4 <close> attribute")
end
test_strict_compile_codegen()

-- gen_compat must actually reach tl's codegen: targeting a pre-5.4
-- runtime with gen_compat="required" inserts a table.pack polyfill;
-- "off" (the default) must not.
local function test_compile_gen_compat_wired()
  local pack_file = fs.join(tmpdir, "c_gen_compat.tl")
  assert(fs.write(pack_file, "local t = table.pack(1, 2, 3)\nprint(t.n)\n"))

  local off = teal.compile_file(pack_file, {gen_target = "5.3", gen_compat = "off"})
  assert(off.ok, "gen_compat=off compile should succeed: "
    .. (off.ok and "" or teal.format_issues(off.errors)))
  assert(not string.find(off.code or "", "_tl_table_pack", 1, true),
    "gen_compat=off must not add compat shims")

  local required = teal.compile_file(pack_file, {gen_target = "5.3", gen_compat = "required"})
  assert(required.ok, "gen_compat=required compile should succeed: "
    .. (required.ok and "" or teal.format_issues(required.errors)))
  assert(string.find(required.code or "", "_tl_table_pack", 1, true),
    "gen_compat=required must add a table.pack compat shim when targeting 5.3")
end
test_compile_gen_compat_wired()

-- tl.new_env itself rejects gen_target="5.4" paired with a non-"off"
-- gen_compat; compile must surface that as an ordinary ok=false error
-- (a "tl.new_env:" prefixed message), not a Lua exception.
local function test_compile_rejects_incompatible_gen_target_and_compat()
  local clean = fs.join(tmpdir, "c_incompatible.tl")
  assert(fs.write(clean, "print(1)\n"))
  local result = teal.compile_file(clean, {gen_target = "5.4", gen_compat = "required"})
  assert(not result.ok, "5.4 + gen_compat=required must be rejected")
  assert(#result.errors > 0 and result.errors[1].message:find("tl.new_env", 1, true),
    "expected a tl.new_env error, got: " .. teal.format_issues(result.errors))
end
test_compile_rejects_incompatible_gen_target_and_compat()

local function test_no_hint_for_plain_errors()
  -- A message outside every known trap must produce no hint at all.
  assert(teal.hint_for_message("unknown variable: x") == nil,
    "plain error should have no hint")
  assert(teal.hint_for_message("syntax error, expected 'end'") == nil,
    "syntax error should have no hint")
end
test_no_hint_for_plain_errors()
