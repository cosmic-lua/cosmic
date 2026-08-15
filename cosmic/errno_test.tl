#!/usr/bin/env cosmic
local errno = require("cosmic.errno")

-- str: nil and plain strings, with and without prefix.
local function test_str_fallbacks()
  assert(errno.format(nil) == "unknown error")
  assert(errno.format(nil, "op") == "op: unknown error")
  assert(errno.format("boom") == "boom")
  assert(errno.format("boom", "op") == "op: boom")
  assert(errno.format("boom", "") == "boom", "empty prefix is ignored")
end
test_str_fallbacks()

-- str: a prefix replaces a lowercase `call: ` head so the failing
-- operation is not stated twice.
local function test_str_prefix_strips_call_head()
  local got = errno.format("mkdir: EACCES: Permission denied", "mkdir: /x")
  assert(got == "mkdir: /x: EACCES: Permission denied", "got: " .. got)
end
test_str_prefix_strips_call_head()

-- str: without a prefix, the message is passed through untouched.
local function test_str_no_prefix_keeps_call_head()
  local got = errno.format("mkdir: EACCES: Permission denied")
  assert(got == "mkdir: EACCES: Permission denied", "got: " .. got)
end
test_str_no_prefix_keeps_call_head()

-- str: uppercase errno names are never mistaken for a call head.
local function test_str_prefix_keeps_errno_head()
  local got = errno.format("ENOENT: No such file or directory", "open: /x")
  assert(got == "open: /x: ENOENT: No such file or directory", "got: " .. got)
end
test_str_prefix_keeps_errno_head()

-- str: non-string values fall back to tostring.
local function test_str_non_string()
  assert(errno.format(42) == "42")
  assert(errno.format(42, "op") == "op: 42")
end
test_str_non_string()

-- code: known constants resolve to numbers; unknown ones are nil.
local function test_code()
  local n = errno.code_of("ENOENT")
  assert(type(n) == "number", "ENOENT should resolve to a number")
  assert(errno.code_of("E_NOT_A_REAL_ERRNO") == nil, "unknown errno is nil")
end
test_code()

-- is: matches by numeric errno; false for nil, non-numbers, wrong or
-- unknown names.
local function test_is()
  local enoent = errno.code_of("ENOENT")
  assert(errno.is_code(enoent, "ENOENT"), "should match ENOENT")
  assert(not errno.is_code(enoent, "EACCES"), "should not match EACCES")
  assert(not errno.is_code(nil, "ENOENT"), "nil is never a match")
  assert(not errno.is_code("a string", "ENOENT"), "non-number is never a match")
  assert(not errno.is_code(enoent, "E_NOT_A_REAL_ERRNO"), "unknown name is never a match")
end
test_is()

-- name_of: extracts the errno name from canonical error strings.
local function test_name_of()
  assert(errno.name_in("open: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_in("stat: /no/such: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_in("ENOENT: No such file or directory") == "ENOENT")
  assert(errno.name_in("exec: E2BIG: Argument list too long") == "E2BIG")
  assert(errno.name_in("send: EPIPE: Broken pipe") == "EPIPE")
end
test_name_of()

-- name_of: nil when no errno name is present; uppercase tails of other
-- words (e.g. "FAILED:") are never mistaken for an errno name.
local function test_name_of_no_match()
  assert(errno.name_in("timeout") == nil)
  assert(errno.name_in("OPERATION FAILED: try again") == nil)
  assert(errno.name_in("handle closed") == nil)
  assert(errno.name_in("") == nil)
end
test_name_of_no_match()

print("errno_test: PASS")

-- constants: a name -> number table mirroring errno.code_of.
local function test_constants_lookup()
  local enoent = errno.codes.ENOENT
  assert(type(enoent) == "number", "ENOENT should be a number")
  assert(enoent == errno.code_of("ENOENT"), "constants must agree with code()")
  assert(errno.codes.EAGAIN == errno.code_of("EAGAIN"), "EAGAIN must agree")
  assert(errno.codes["E_NOT_A_REAL_ERRNO"] == nil, "unknown name is nil")
end
test_constants_lookup()

-- constants: every entry is a well-formed errno name with an integer
-- value, usable with errno.is_code; and the table is non-trivially populated.
local function test_constants_shape()
  local n = 0
  for name, value in pairs(errno.codes) do
    n = n + 1
    assert(string.match(name, "^E[%u%d]+$"), "bad errno name: " .. name)
    assert(math.type(value) == "integer", name .. " value must be an integer")
    assert(errno.is_code(value, name), name .. " must round-trip through errno.is_code")
  end
  assert(n >= 50, "expected a populated table, got " .. tostring(n) .. " entries")
end
test_constants_shape()

-- constants: the termios ECHO* flags are not errnos and must be absent.
local function test_constants_excludes_termios()
  for _, name in ipairs({"ECHO", "ECHOE", "ECHOK", "ECHONL"}) do
    assert(errno.codes[name] == nil, name .. " is a termios flag, not an errno")
  end
end
test_constants_excludes_termios()

-- The canonical names share one grammar: format, is_code, code_of,
-- name_in, and codes are exercised together here.
local function test_canonical_names()
  assert(errno.format("mkdir: EACCES: denied", "mkdir: /x")
    == "mkdir: /x: EACCES: denied")
  assert(errno.is_code(errno.code_of("ENOENT"), "ENOENT"))
  assert(errno.name_in("open: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.codes.ENOENT == errno.code_of("ENOENT"))
end
test_canonical_names()
