#!/usr/bin/env cosmic
local errno = require("cosmic.errno")

-- str: nil and plain strings, with and without prefix.
local function test_str_fallbacks()
  assert(errno.str(nil) == "unknown error")
  assert(errno.str(nil, "op") == "op: unknown error")
  assert(errno.str("boom") == "boom")
  assert(errno.str("boom", "op") == "op: boom")
  assert(errno.str("boom", "") == "boom", "empty prefix is ignored")
end
test_str_fallbacks()

-- str: a prefix replaces a lowercase `call: ` head so the failing
-- operation is not stated twice.
local function test_str_prefix_strips_call_head()
  local got = errno.str("mkdir: EACCES: Permission denied", "mkdir: /x")
  assert(got == "mkdir: /x: EACCES: Permission denied", "got: " .. got)
end
test_str_prefix_strips_call_head()

-- str: without a prefix, the message is passed through untouched.
local function test_str_no_prefix_keeps_call_head()
  local got = errno.str("mkdir: EACCES: Permission denied")
  assert(got == "mkdir: EACCES: Permission denied", "got: " .. got)
end
test_str_no_prefix_keeps_call_head()

-- str: uppercase errno names are never mistaken for a call head.
local function test_str_prefix_keeps_errno_head()
  local got = errno.str("ENOENT: No such file or directory", "open: /x")
  assert(got == "open: /x: ENOENT: No such file or directory", "got: " .. got)
end
test_str_prefix_keeps_errno_head()

-- str: non-string values fall back to tostring.
local function test_str_non_string()
  assert(errno.str(42) == "42")
  assert(errno.str(42, "op") == "op: 42")
end
test_str_non_string()

-- code: known constants resolve to numbers; unknown ones are nil.
local function test_code()
  local n = errno.code("ENOENT")
  assert(type(n) == "number", "ENOENT should resolve to a number")
  assert(errno.code("E_NOT_A_REAL_ERRNO") == nil, "unknown errno is nil")
end
test_code()

-- is: matches by numeric errno; false for nil, non-numbers, wrong or
-- unknown names.
local function test_is()
  local enoent = errno.code("ENOENT")
  assert(errno.is(enoent, "ENOENT"), "should match ENOENT")
  assert(not errno.is(enoent, "EACCES"), "should not match EACCES")
  assert(not errno.is(nil, "ENOENT"), "nil is never a match")
  assert(not errno.is("a string", "ENOENT"), "non-number is never a match")
  assert(not errno.is(enoent, "E_NOT_A_REAL_ERRNO"), "unknown name is never a match")
end
test_is()

-- name_of: extracts the errno name from canonical error strings.
local function test_name_of()
  assert(errno.name_of("open: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_of("stat: /no/such: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_of("ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_of("exec: E2BIG: Argument list too long") == "E2BIG")
  assert(errno.name_of("send: EPIPE: Broken pipe") == "EPIPE")
end
test_name_of()

-- name_of: nil when no errno name is present; uppercase tails of other
-- words (e.g. "FAILED:") are never mistaken for an errno name.
local function test_name_of_no_match()
  assert(errno.name_of("timeout") == nil)
  assert(errno.name_of("OPERATION FAILED: try again") == nil)
  assert(errno.name_of("handle closed") == nil)
  assert(errno.name_of("") == nil)
end
test_name_of_no_match()

print("errno_test: PASS")
