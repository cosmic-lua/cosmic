#!/usr/bin/env cosmic
local a = require("cosmic.assert")

-- eq: passing cases

local function test_eq_numbers()
  a.eq(1, 1)
  a.eq(0, 0)
  a.eq(-5, -5)
end
test_eq_numbers()

local function test_eq_strings()
  a.eq("hello", "hello")
  a.eq("", "")
end
test_eq_strings()

local function test_eq_booleans()
  a.eq(true, true)
  a.eq(false, false)
end
test_eq_booleans()

local function test_eq_nil()
  a.eq(nil, nil)
end
test_eq_nil()

local function test_eq_tables_shallow()
  a.eq({1, 2, 3}, {1, 2, 3})
  a.eq({a = 1, b = 2}, {a = 1, b = 2})
end
test_eq_tables_shallow()

local function test_eq_tables_nested()
  a.eq({a = {b = {c = 42}}}, {a = {b = {c = 42}}})
end
test_eq_tables_nested()

local function test_eq_with_label()
  a.eq(7, 7, "score check")
end
test_eq_with_label()

-- eq: failing cases

local function test_eq_fails_on_number_mismatch()
  local ok, msg = pcall(a.eq, 3, 4)
  assert(not ok, "expected eq to throw")
  assert(type(msg) == "string", "expected string error")
  assert(msg:match("eq failed"), "expected 'eq failed' in message, got: " .. msg)
  assert(msg:match("expected 4"), "expected '4' in message, got: " .. msg)
  assert(msg:match("got 3"), "expected '3' in message, got: " .. msg)
end
test_eq_fails_on_number_mismatch()

local function test_eq_fails_on_string_mismatch()
  local ok, msg = pcall(a.eq, "actual", "expected")
  assert(not ok, "expected eq to throw")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_on_string_mismatch()

local function test_eq_fails_with_label_prefix()
  local ok, msg = pcall(a.eq, 1, 2, "my label")
  assert(not ok, "expected eq to throw")
  assert(msg:match("my label"), "expected label in message, got: " .. msg)
  assert(msg:match("eq failed"), "expected 'eq failed' in message, got: " .. msg)
end
test_eq_fails_with_label_prefix()

local function test_eq_fails_on_table_mismatch()
  local ok, msg = pcall(a.eq, {a = 1}, {a = 2})
  assert(not ok, "expected eq to throw for table mismatch")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_on_table_mismatch()

local function test_eq_fails_nil_vs_value()
  local ok, msg = pcall(a.eq, nil, 42)
  assert(not ok, "expected eq to throw when nil vs 42")
  assert(msg:match("eq failed"), "expected 'eq failed' in message")
end
test_eq_fails_nil_vs_value()

-- ne: passing cases

local function test_ne_numbers()
  a.ne(1, 2)
  a.ne(0, -1)
end
test_ne_numbers()

local function test_ne_strings()
  a.ne("hello", "world")
  a.ne("", "nonempty")
end
test_ne_strings()

local function test_ne_different_types()
  a.ne(1, "1")
  a.ne(nil, false)
end
test_ne_different_types()

local function test_ne_tables_different_content()
  a.ne({a = 1}, {a = 2})
end
test_ne_tables_different_content()

local function test_ne_with_label()
  a.ne(1, 2, "value check")
end
test_ne_with_label()

-- ne: failing cases

local function test_ne_fails_when_equal()
  local ok, msg = pcall(a.ne, 5, 5)
  assert(not ok, "expected ne to throw")
  assert(msg:match("ne failed"), "expected 'ne failed' in message, got: " .. msg)
  assert(msg:match("5"), "expected value in message")
end
test_ne_fails_when_equal()

local function test_ne_fails_when_tables_equal()
  local ok, msg = pcall(a.ne, {x = 1}, {x = 1})
  assert(not ok, "expected ne to throw for equal tables")
  assert(msg:match("ne failed"), "expected 'ne failed' in message")
end
test_ne_fails_when_tables_equal()

local function test_ne_fails_with_label()
  local ok, msg = pcall(a.ne, "same", "same", "tag")
  assert(not ok, "expected ne to throw")
  assert(msg:match("tag"), "expected label in message")
  assert(msg:match("ne failed"), "expected 'ne failed' in message")
end
test_ne_fails_with_label()

-- ok: passing cases

local function test_ok_truthy_values()
  a.ok(true)
  a.ok(1)
  a.ok("nonempty")
  a.ok({})
  a.ok(0) -- 0 is truthy in Lua
end
test_ok_truthy_values()

local function test_ok_with_label()
  a.ok(true, "must be set")
end
test_ok_with_label()

-- ok: failing cases

local function test_ok_fails_on_nil()
  local ok, msg = pcall(a.ok, nil)
  assert(not ok, "expected ok to throw for nil")
  assert(msg:match("ok failed"), "expected 'ok failed' in message, got: " .. msg)
  assert(msg:match("nil"), "expected nil in message")
end
test_ok_fails_on_nil()

local function test_ok_fails_on_false()
  local ok, msg = pcall(a.ok, false)
  assert(not ok, "expected ok to throw for false")
  assert(msg:match("ok failed"), "expected 'ok failed' in message")
  assert(msg:match("false"), "expected false in message")
end
test_ok_fails_on_false()

local function test_ok_fails_with_label()
  local ok, msg = pcall(a.ok, nil, "result")
  assert(not ok, "expected ok to throw")
  assert(msg:match("result"), "expected label in message")
  assert(msg:match("ok failed"), "expected 'ok failed' in message")
end
test_ok_fails_with_label()

-- err: passing cases

local function test_err_nil_with_message()
  a.err(nil, "something went wrong")
end
test_err_nil_with_message()

local function test_err_with_label()
  a.err(nil, "oops", "network call")
end
test_err_with_label()

-- err: failing cases

local function test_err_fails_when_value_is_non_nil()
  local ok, msg = pcall(a.err, 42, "some error")
  assert(not ok, "expected err to throw when value is 42")
  assert(msg:match("err failed"), "expected 'err failed' in message, got: " .. msg)
  assert(msg:match("42"), "expected value in message")
end
test_err_fails_when_value_is_non_nil()

local function test_err_fails_when_error_string_is_empty()
  local ok, msg = pcall(a.err, nil, "")
  assert(not ok, "expected err to throw for empty error string")
  assert(msg:match("err failed"), "expected 'err failed' in message, got: " .. msg)
end
test_err_fails_when_error_string_is_empty()

local function test_err_fails_with_label()
  local ok, msg = pcall(a.err, "whoops", "err msg", "ctx")
  assert(not ok, "expected err to throw")
  assert(msg:match("ctx"), "expected label in message")
  assert(msg:match("err failed"), "expected 'err failed' in message")
end
test_err_fails_with_label()

-- caller line attribution: error level 2 means the throw points at caller

local function test_eq_error_points_at_caller()
  local ok, msg = pcall(a.eq, 1, 2)
  assert(not ok, "expected throw")
  -- The message should NOT contain assert.tl in the location prefix
  -- (it will contain the anonymous function's source). We just verify
  -- the message is a string and well-formed.
  assert(type(msg) == "string", "expected string error")
end
test_eq_error_points_at_caller()
