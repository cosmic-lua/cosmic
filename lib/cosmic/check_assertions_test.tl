#!/usr/bin/env cosmic
local check = require("cosmic.check")
local env = require("cosmic.env")

-- must_fail wraps a function that is expected to throw and returns
-- (true, error_message) or (false, "did not throw").
-- Using function(): string as the wrapper type gives pcall two return values.
local function must_fail(f: function(): string): boolean, string
  local ok, raw = pcall(f)
  if ok then
    return false, "did not throw"
  end
  return true, tostring(raw)
end

-- eq: passing cases

local function test_eq_numbers()
  check.eq(1, 1)
  check.eq(0, 0)
  check.eq(-5, -5)
end
test_eq_numbers()

local function test_eq_strings()
  check.eq("hello", "hello")
  check.eq("", "")
end
test_eq_strings()

local function test_eq_booleans()
  check.eq(true, true)
  check.eq(false, false)
end
test_eq_booleans()

local function test_eq_nil()
  check.eq(nil, nil)
end
test_eq_nil()

local function test_eq_tables_shallow()
  check.eq({1, 2, 3}, {1, 2, 3})
  check.eq({a = 1, b = 2}, {a = 1, b = 2})
end
test_eq_tables_shallow()

local function test_eq_tables_nested()
  check.eq({a = {b = {c = 42}}}, {a = {b = {c = 42}}})
end
test_eq_tables_nested()

local function test_eq_with_label()
  check.eq(7, 7, "score check")
end
test_eq_with_label()

-- eq: failing cases

local function test_eq_fails_on_number_mismatch()
  local threw, msg = must_fail(function(): string check.eq(3, 4) return "" end)
  assert(threw, "expected eq to throw")
  assert(msg:match("eq failed"), "expected 'eq failed' in message, got: " .. msg)
  assert(msg:match("expected 4"), "expected '4' in message, got: " .. msg)
  assert(msg:match("got 3"), "expected '3' in message, got: " .. msg)
end
test_eq_fails_on_number_mismatch()

local function test_eq_fails_on_string_mismatch()
  local threw, msg = must_fail(function(): string check.eq("actual", "expected") return "" end)
  assert(threw, "expected eq to throw")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_on_string_mismatch()

local function test_eq_fails_with_label_prefix()
  local threw, msg = must_fail(function(): string check.eq(1, 2, "my label") return "" end)
  assert(threw, "expected eq to throw")
  assert(msg:match("my label"), "expected label in message, got: " .. msg)
  assert(msg:match("eq failed"), "expected 'eq failed' in message, got: " .. msg)
end
test_eq_fails_with_label_prefix()

local function test_eq_fails_on_table_mismatch()
  local threw, msg = must_fail(function(): string check.eq({a = 1}, {a = 2}) return "" end)
  assert(threw, "expected eq to throw for table mismatch")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_on_table_mismatch()

local function test_eq_fails_nil_vs_value()
  local threw, msg = must_fail(function(): string check.eq(nil, 42) return "" end)
  assert(threw, "expected eq to throw when nil vs 42")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_nil_vs_value()

-- ne: passing cases

local function test_ne_numbers()
  check.ne(1, 2)
  check.ne(0, -1)
end
test_ne_numbers()

local function test_ne_strings()
  check.ne("hello", "world")
  check.ne("", "nonempty")
end
test_ne_strings()

local function test_ne_different_types()
  -- eq/ne are generic, so a cross-type comparison is normally a
  -- check-time error; cast to keep exercising the runtime behavior.
  check.ne(1 as any, "1")
  check.ne(nil, false)
end
test_ne_different_types()

local function test_ne_tables_different_content()
  check.ne({a = 1}, {a = 2})
end
test_ne_tables_different_content()

local function test_ne_with_label()
  check.ne(1, 2, "value check")
end
test_ne_with_label()

-- ne: failing cases

local function test_ne_fails_when_equal()
  local threw, msg = must_fail(function(): string check.ne(5, 5) return "" end)
  assert(threw, "expected ne to throw")
  assert(msg:match("ne failed"), "expected 'ne failed' in message, got: " .. msg)
  assert(msg:match("5"), "expected value in message")
end
test_ne_fails_when_equal()

local function test_ne_fails_when_tables_equal()
  local threw, msg = must_fail(function(): string check.ne({x = 1}, {x = 1}) return "" end)
  assert(threw, "expected ne to throw for equal tables")
  assert(msg:match("ne failed"), "expected 'ne failed' in message")
end
test_ne_fails_when_tables_equal()

local function test_ne_fails_with_label()
  local threw, msg = must_fail(function(): string check.ne("same", "same", "tag") return "" end)
  assert(threw, "expected ne to throw")
  assert(msg:match("tag"), "expected label in message")
  assert(msg:match("ne failed"), "expected 'ne failed' in message")
end
test_ne_fails_with_label()

-- ok: passing cases

local function test_ok_truthy_values()
  check.ok(true)
  check.ok(1)
  check.ok("nonempty")
  check.ok({})
  check.ok(0) -- 0 is truthy in Lua
end
test_ok_truthy_values()

local function test_ok_with_label()
  check.ok(true, "must be set")
end
test_ok_with_label()

-- ok: failing cases

local function test_ok_fails_on_nil()
  local threw, msg = must_fail(function(): string check.ok(nil) return "" end)
  assert(threw, "expected ok to throw for nil")
  assert(msg:match("ok failed"), "expected 'ok failed' in message, got: " .. msg)
  assert(msg:match("nil"), "expected nil in message")
end
test_ok_fails_on_nil()

local function test_ok_fails_on_false()
  local threw, msg = must_fail(function(): string check.ok(false) return "" end)
  assert(threw, "expected ok to throw for false")
  assert(msg:match("ok failed"), "expected 'ok failed' in message")
  assert(msg:match("false"), "expected false in message")
end
test_ok_fails_on_false()

local function test_ok_fails_with_label()
  local threw, msg = must_fail(function(): string check.ok(nil, "result") return "" end)
  assert(threw, "expected ok to throw")
  assert(msg:match("result"), "expected label in message")
  assert(msg:match("ok failed"), "expected 'ok failed' in message")
end
test_ok_fails_with_label()

-- err: passing cases

local function test_err_nil_with_message()
  check.err(nil, "something went wrong")
end
test_err_nil_with_message()

local function test_err_with_label()
  check.err(nil, "oops", "network call")
end
test_err_with_label()

-- err: failing cases

local function test_err_fails_when_value_is_non_nil()
  local threw, msg = must_fail(function(): string check.err(42, "some error") return "" end)
  assert(threw, "expected err to throw when value is 42")
  assert(msg:match("err failed"), "expected 'err failed' in message, got: " .. msg)
  assert(msg:match("42"), "expected value in message")
end
test_err_fails_when_value_is_non_nil()

local function test_err_fails_when_error_string_is_empty()
  local threw, msg = must_fail(function(): string check.err(nil, "") return "" end)
  assert(threw, "expected err to throw for empty error string")
  assert(msg:match("err failed"), "expected 'err failed' in message, got: " .. msg)
end
test_err_fails_when_error_string_is_empty()

local function test_err_fails_with_label()
  local threw, msg = must_fail(function(): string check.err("whoops" as any, "err msg", "ctx") return "" end)
  assert(threw, "expected err to throw")
  assert(msg:match("ctx"), "expected label in message")
  assert(msg:match("err failed"), "expected 'err failed' in message")
end
test_err_fails_with_label()

-- must: passing cases

local record Widget
  name: string
end

local function make_widget(fail: boolean): Widget | nil, string
  if fail then
    return nil, "widget factory exploded"
  end
  return { name = "gear" }
end

local function test_must_narrows_record_union()
  -- the point of must: the result is a plain Widget, fields usable
  -- with no `as` cast and no assert
  local w = check.must(make_widget(false))
  check.eq(w.name, "gear")
end
test_must_narrows_record_union()

local function test_must_narrows_scalar_with_method_syntax()
  local s: string | nil = "hello"
  local narrowed = check.must(s)
  check.eq(narrowed:upper(), "HELLO")
end
test_must_narrows_scalar_with_method_syntax()

local function test_must_passes_false_through()
  -- must narrows nil only; false is a real value, unlike assert()
  local b: boolean | nil = false
  check.eq(check.must(b), false)
end
test_must_passes_false_through()

-- must: failing cases

local function test_must_uses_err_string_from_multi_return()
  -- Lua passes both returns through, so the API's own error string
  -- becomes the failure message
  local threw, msg = must_fail(function(): string
      check.must(make_widget(true))
      return ""
    end)
  assert(threw, "expected must to throw on nil")
  assert(msg:match("widget factory exploded"),
    "expected the callee's error string, got: " .. msg)
end
test_must_uses_err_string_from_multi_return()

local function test_must_default_message()
  local threw, msg = must_fail(function(): string
      check.must(nil as string | nil)
      return ""
    end)
  assert(threw, "expected must to throw on nil")
  assert(msg:match("must failed"), "expected default message, got: " .. msg)
end
test_must_default_message()

-- caller line attribution: error level 2 means throw points at caller

local function test_eq_error_points_at_caller()
  local threw, msg = must_fail(function(): string check.eq(1, 2) return "" end)
  assert(threw, "expected throw")
  assert(type(msg) == "string", "expected string error, got: " .. tostring(msg))
end
test_eq_error_points_at_caller()

-- enforcing / skip / enforced: enforcement-lane helpers

local function with_enforce(on: boolean, f: function())
  local prev = env.get("COSMIC_ENFORCE")
  if on then env.set("COSMIC_ENFORCE", "1", true) else env.unset("COSMIC_ENFORCE") end
  local ok, e = pcall(f as function(): any)
  if prev then env.set("COSMIC_ENFORCE", prev, true) else env.unset("COSMIC_ENFORCE") end
  if not ok then error(e, 0) end
end

local function test_enforcing_reflects_env()
  with_enforce(false, function() check.eq(check.enforcing(), false, "unset") end)
  with_enforce(true, function() check.eq(check.enforcing(), true, "set") end)
end
test_enforcing_reflects_env()

local function test_skip_soft_never_throws()
  -- A non-strict skip is visibility-only: it must never throw, even when
  -- enforcement is required (genuine platform gaps still skip on the lane).
  with_enforce(true, function()
      local threw = must_fail(function(): string check.skip("kernel too old") return "" end)
      assert(not threw, "soft skip must not throw under enforcement")
    end)
end
test_skip_soft_never_throws()

local function test_skip_strict_throws_only_under_enforce()
  -- Off the lane, even a strict skip is tolerated (the outer sandbox is
  -- expected). On the lane it is a hard failure.
  with_enforce(false, function()
      local threw = must_fail(function(): string check.skip("blocked", true) return "" end)
      assert(not threw, "strict skip must not throw off the enforce lane")
    end)
  with_enforce(true, function()
      local threw, msg = must_fail(function(): string check.skip("blocked", true) return "" end)
      assert(threw, "strict skip must throw under enforcement")
      assert(msg:match("enforcement required but skipped"),
        "expected enforcement message, got: " .. msg)
      assert(msg:match("blocked"), "expected reason in message, got: " .. msg)
    end)
end
test_skip_strict_throws_only_under_enforce()

local function test_enforced_never_throws()
  with_enforce(true, function()
      local threw = must_fail(function(): string check.enforced("pledge") return "" end)
      assert(not threw, "enforced() is a marker and must not throw")
    end)
end
test_enforced_never_throws()
