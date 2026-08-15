#!/usr/bin/env cosmic
local check = require("cosmic.check")
local env = require("cosmic.env")
local fetch = require("cosmic.fetch")

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

-- equal: passing cases

local function test_equal_numbers()
  check.equal(1, 1)
  check.equal(0, 0)
  check.equal(-5, -5)
end
test_equal_numbers()

local function test_equal_strings()
  check.equal("hello", "hello")
  check.equal("", "")
end
test_equal_strings()

local function test_equal_booleans()
  check.equal(true, true)
  check.equal(false, false)
end
test_equal_booleans()

local function test_equal_nil()
  check.equal(nil, nil)
end
test_equal_nil()

local function test_equal_tables_shallow()
  check.equal({1, 2, 3}, {1, 2, 3})
  check.equal({a = 1, b = 2}, {a = 1, b = 2})
end
test_equal_tables_shallow()

local function test_equal_tables_nested()
  check.equal({a = {b = {c = 42}}}, {a = {b = {c = 42}}})
end
test_equal_tables_nested()

local function test_equal_with_label()
  check.equal(7, 7, "score check")
end
test_equal_with_label()

-- equal: failing cases

local function test_equal_fails_on_number_mismatch()
  local threw, msg = must_fail(function(): string check.equal(3, 4) return "" end)
  assert(threw, "expected equal to throw")
  assert(msg:match("equal failed"), "expected 'equal failed' in message, got: " .. msg)
  assert(msg:match("expected 4"), "expected '4' in message, got: " .. msg)
  assert(msg:match("got 3"), "expected '3' in message, got: " .. msg)
end
test_equal_fails_on_number_mismatch()

local function test_equal_fails_on_string_mismatch()
  local threw, msg = must_fail(function(): string check.equal("actual", "expected") return "" end)
  assert(threw, "expected equal to throw")
  assert(msg:match("equal failed"), "expected 'equal failed' in message")
end
test_equal_fails_on_string_mismatch()

local function test_equal_fails_with_label_prefix()
  local threw, msg = must_fail(function(): string check.equal(1, 2, "my label") return "" end)
  assert(threw, "expected equal to throw")
  assert(msg:match("my label"), "expected label in message, got: " .. msg)
  assert(msg:match("equal failed"), "expected 'equal failed' in message, got: " .. msg)
end
test_equal_fails_with_label_prefix()

local function test_equal_fails_on_table_mismatch()
  local threw, msg = must_fail(function(): string check.equal({a = 1}, {a = 2}) return "" end)
  assert(threw, "expected equal to throw for table mismatch")
  assert(msg:match("equal failed"), "expected 'equal failed' in message")
end
test_equal_fails_on_table_mismatch()

local function test_equal_fails_nil_vs_value()
  local threw, msg = must_fail(function(): string check.equal(nil, 42) return "" end)
  assert(threw, "expected equal to throw when nil vs 42")
  assert(msg:match("equal failed"), "expected 'equal failed' in message")
end
test_equal_fails_nil_vs_value()

-- not_equal: passing cases

local function test_not_equal_numbers()
  check.not_equal(1, 2)
  check.not_equal(0, -1)
end
test_not_equal_numbers()

local function test_not_equal_strings()
  check.not_equal("hello", "world")
  check.not_equal("", "nonempty")
end
test_not_equal_strings()

local function test_not_equal_different_types()
  -- cast: cross-type not_equal is a check-time error; exercise runtime
  check.not_equal(1 as any, "1")
  check.not_equal(nil, false)
end
test_not_equal_different_types()

local function test_not_equal_tables_different_content()
  check.not_equal({a = 1}, {a = 2})
end
test_not_equal_tables_different_content()

local function test_not_equal_with_label()
  check.not_equal(1, 2, "value check")
end
test_not_equal_with_label()

-- not_equal: failing cases

local function test_not_equal_fails_when_equal()
  local threw, msg = must_fail(function(): string check.not_equal(5, 5) return "" end)
  assert(threw, "expected not_equal to throw")
  assert(msg:match("not_equal failed"), "expected 'not_equal failed' in message, got: " .. msg)
  assert(msg:match("5"), "expected value in message")
end
test_not_equal_fails_when_equal()

local function test_not_equal_fails_when_tables_equal()
  local threw, msg = must_fail(function(): string check.not_equal({x = 1}, {x = 1}) return "" end)
  assert(threw, "expected not_equal to throw for equal tables")
  assert(msg:match("not_equal failed"), "expected 'not_equal failed' in message")
end
test_not_equal_fails_when_tables_equal()

local function test_not_equal_fails_with_label()
  local threw, msg = must_fail(function(): string check.not_equal("same", "same", "tag") return "" end)
  assert(threw, "expected not_equal to throw")
  assert(msg:match("tag"), "expected label in message")
  assert(msg:match("not_equal failed"), "expected 'not_equal failed' in message")
end
test_not_equal_fails_with_label()

-- truthy: passing cases

local function test_truthy_truthy_values()
  check.truthy(true)
  check.truthy(1)
  check.truthy("nonempty")
  check.truthy({})
  check.truthy(0) -- 0 is truthy in Lua
end
test_truthy_truthy_values()

local function test_truthy_with_label()
  check.truthy(true, "must be set")
end
test_truthy_with_label()

-- truthy: failing cases

local function test_truthy_fails_on_nil()
  local threw, msg = must_fail(function(): string check.truthy(nil) return "" end)
  assert(threw, "expected truthy to throw for nil")
  assert(msg:match("truthy failed"), "expected 'truthy failed' in message, got: " .. msg)
  assert(msg:match("nil"), "expected nil in message")
end
test_truthy_fails_on_nil()

local function test_truthy_fails_on_false()
  local threw, msg = must_fail(function(): string check.truthy(false) return "" end)
  assert(threw, "expected truthy to throw for false")
  assert(msg:match("truthy failed"), "expected 'truthy failed' in message")
  assert(msg:match("false"), "expected false in message")
end
test_truthy_fails_on_false()

local function test_truthy_fails_with_label()
  local threw, msg = must_fail(function(): string check.truthy(nil, "result") return "" end)
  assert(threw, "expected truthy to throw")
  assert(msg:match("result"), "expected label in message")
  assert(msg:match("truthy failed"), "expected 'truthy failed' in message")
end
test_truthy_fails_with_label()

-- err: passing cases

local function test_failed_nil_with_message()
  check.failed(nil, "something went wrong")
end
test_failed_nil_with_message()

local function test_failed_with_label()
  check.failed(nil, "oops", "network call")
end
test_failed_with_label()

-- err: failing cases

local function test_failed_when_value_is_non_nil()
  local threw, msg = must_fail(function(): string check.failed(42, "some error") return "" end)
  assert(threw, "expected err to throw when value is 42")
  assert(msg:match("failed:"), "expected 'failed:' in message, got: " .. msg)
  assert(msg:match("42"), "expected value in message")
end
test_failed_when_value_is_non_nil()

local function test_failed_when_error_string_is_empty()
  local threw, msg = must_fail(function(): string check.failed(nil, "") return "" end)
  assert(threw, "expected err to throw for empty error string")
  assert(msg:match("failed:"), "expected 'failed:' in message, got: " .. msg)
end
test_failed_when_error_string_is_empty()

local function test_failed_reports_with_label()
  local threw, msg = must_fail(function(): string check.failed("whoops", "err msg", "ctx") return "" end)
  assert(threw, "expected failed to throw")
  assert(msg:match("ctx"), "expected label in message")
  assert(msg:match("failed:"), "expected 'failed:' in message")
end
test_failed_reports_with_label()

-- must: passing cases

local record Widget
  name: string
end

local function make_widget(fail: boolean): Widget | nil, string
  if fail then
    return nil, "widget factory exploded"
  end
  return {name = "gear"}
end

local function test_must_narrows_record_union()
  -- the point of must: the result is a plain Widget, fields usable
  -- with no `as` cast and no assert
  local w = check.must(make_widget(false))
  check.equal(w.name, "gear")
end
test_must_narrows_record_union()

local function test_must_narrows_scalar_with_method_syntax()
  local s: string | nil = "hello"
  local narrowed = check.must(s)
  check.equal(narrowed:upper(), "HELLO")
end
test_must_narrows_scalar_with_method_syntax()

local function test_must_passes_false_through()
  -- must narrows nil only; false is a real value, unlike assert()
  local b: boolean | nil = false
  check.equal(check.must(b), false)
end
test_must_passes_false_through()

-- must: one declared return (the assert-parity contract)
--
-- must forwards nothing past the value, because a fallible return has
-- two slots and no more. What that buys is composition: must appears
-- in return position, in last-argument position, and as a for-in
-- iterator without a single parenthesis-truncation.

local type Iter = function(): string

local function two_paths(): Iter | nil, string
  local n = 0
  return function(): string
    n = n + 1
    if n <= 2 then
      return "f" .. n
    end
    return nil
  end
end

local function test_must_returns_exactly_one_value()
  -- a value, err pair yields exactly one value: no trailing nil in
  -- print()/varargs contexts, and none for the checker either
  check.equal(select("#", check.must(make_widget(false))), 1)
end
test_must_returns_exactly_one_value()

local function widget_or_throw(): Widget
  -- return position: `assert` type-checks here and so does must
  return check.must(make_widget(false))
end

local function test_must_composes_in_return_position()
  check.equal(widget_or_throw().name, "gear")
end
test_must_composes_in_return_position()

local function test_must_composes_as_last_argument()
  -- no parenthesis-truncation: must contributes one argument, not three
  local chunk: string | nil = "x"
  local parts: {string} = {}
  table.insert(parts, check.must(chunk))
  check.equal(#parts, 1)
  check.equal(parts[1], "x")
end
test_must_composes_as_last_argument()

local function test_must_drives_a_for_in_loop()
  -- a two-slot fallible iterator needs the value alone; anything the
  -- loop must release rides on the value's own __close (fs.find_iter)
  local seen = 0
  for _ in check.must(two_paths()) do
    seen = seen + 1
  end
  check.equal(seen, 2)
end
test_must_drives_a_for_in_loop()

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

local function test_must_renders_structured_error()
  -- Slot 2 may be a structured Failure: a concrete error record
  -- like fetch.Error reaches must through the same multiple-return
  -- passthrough as a string, and must throws its rendered tostring —
  -- so a failing test prints the classified message, never a table
  -- address. The ftp URL fails validation, so no network is touched.
  local threw, msg = must_fail(function(): string
      check.must(fetch.fetch("ftp://example.com/x"))
      return ""
    end)
  assert(threw, "expected must to throw on nil")
  assert(msg:match("invalid_request: "),
    "expected the rendered structured error, got: " .. msg)
end
test_must_renders_structured_error()

local function test_must_default_message()
  local threw, msg = must_fail(function(): string
      check.must(nil as string | nil) -- cast: deliberate invalid input
      return ""
    end)
  assert(threw, "expected must to throw on nil")
  assert(msg:match("must failed"), "expected default message, got: " .. msg)
end
test_must_default_message()

-- caller line attribution: error level 2 means throw points at caller

local function test_equal_error_points_at_caller()
  local threw, msg = must_fail(function(): string check.equal(1, 2) return "" end)
  assert(threw, "expected throw")
  assert(type(msg) == "string", "expected string error, got: " .. tostring(msg))
end
test_equal_error_points_at_caller()

-- enforcing / skip / enforced: enforcement-lane helpers

local function with_enforce(on: boolean, f: function())
  local prev = env.get("COSMIC_ENFORCE")
  if on then assert(env.set("COSMIC_ENFORCE", "1", true)) else assert(env.unset("COSMIC_ENFORCE")) end
  local ok, e = pcall(f as function(): any) -- cast: function shape
  if prev then assert(env.set("COSMIC_ENFORCE", prev, true)) else assert(env.unset("COSMIC_ENFORCE")) end
  if not ok then error(e, 0) end
end

local function test_enforcing_reflects_env()
  with_enforce(false, function() check.equal(check.enforcing(), false, "unset") end)
  with_enforce(true, function() check.equal(check.enforcing(), true, "set") end)
end
test_enforcing_reflects_env()

local function test_skip_soft_never_throws()
  -- A non-strict skip is visibility-only: it must never throw, even when
  -- enforcement is required (genuine platform gaps still skip on the lane).
  with_enforce(true, function()
      local threw = must_fail(function(): string check.enforce_skip("kernel too old") return "" end)
      assert(not threw, "soft skip must not throw under enforcement")
    end)
end
test_skip_soft_never_throws()

local function test_skip_strict_throws_only_under_enforce()
  -- Off the lane, even a strict skip is tolerated (the outer sandbox is
  -- expected). On the lane it is a hard failure.
  with_enforce(false, function()
      local threw = must_fail(function(): string check.enforce_skip("blocked", true) return "" end)
      assert(not threw, "strict skip must not throw off the enforce lane")
    end)
  with_enforce(true, function()
      local threw, msg = must_fail(function(): string check.enforce_skip("blocked", true) return "" end)
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
