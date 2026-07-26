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
  local result = teal.check(path)
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

-- The lax/strict contract, previously asserted only by docstring:
-- --compile (default) is the permissive gradual-typing on-ramp; strict
-- compile refuses everything --check types refuses (type errors AND
-- warnings) and generates from the checked AST.
local function test_compile_lax_strict_contract()
  -- Lax forgives UNKNOWNS (the plain-Lua on-ramp), not explicit
  -- contradictions: an undeclared variable passes lax and fails strict.
  local unknown = fs.join(tmpdir, "c_unknown.tl")
  assert(fs.write(unknown, "print(xyzzy)\n"))
  assert(teal.compile(unknown).ok,
    "default compile is lax: unknown variables must not stop codegen")
  local strict = teal.compile(unknown, {strict = true})
  assert(not strict.ok, "strict compile must reject unknown variables")
  assert(#strict.errors > 0 and strict.errors[1].severity == "error")
  assert(not teal.check(unknown).ok, "check must reject what strict compile rejects")

  -- An explicitly annotated contradiction fails both ways: lax still
  -- checks what you declared.
  local type_err = fs.join(tmpdir, "c_type_err.tl")
  assert(fs.write(type_err, "local s: string = 42\nprint(s)\n"))
  assert(not teal.compile(type_err).ok,
    "even lax compile rejects an annotated contradiction")
  assert(not teal.compile(type_err, {strict = true}).ok)

  local warn_only = fs.join(tmpdir, "c_warn.tl")
  assert(fs.write(warn_only, "local unused = 1\nprint(\"hi\")\n"))
  assert(teal.compile(warn_only).ok,
    "default compile must not fail on warnings")
  local strict_warn = teal.compile(warn_only, {strict = true})
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
  local lax = teal.compile(clean)
  local strict = teal.compile(clean, {strict = true})
  assert(lax.ok and strict.ok, "clean file should compile both ways")
  assert(lax.code == strict.code,
    "lax and strict codegen of a clean file must be identical")

  local closer = fs.join(tmpdir, "c_close.tl")
  assert(fs.write(closer,
      "local f <close> = assert(io.open(\"/dev/null\", \"r\"))\n"
      .. "print(f ~= nil)\n"))
  local sc = teal.compile(closer, {strict = true})
  assert(sc.ok, "strict compile of <close> should pass: "
    .. (sc.ok and "" or teal.format_issues(sc.errors)))
  assert(sc.code:find("<close>", 1, true),
    "strict compile must keep the 5.4 <close> attribute")
end
test_strict_compile_codegen()

local function test_no_hint_for_plain_errors()
  -- A message outside every known trap must produce no hint at all.
  assert(teal.hint_for_message("unknown variable: x") == nil,
    "plain error should have no hint")
  assert(teal.hint_for_message("syntax error, expected 'end'") == nil,
    "syntax error should have no hint")
end
test_no_hint_for_plain_errors()
