#!/usr/bin/env cosmic
local errno = require("cosmic.errno")

-- str: nil and plain strings, with and without prefix.
local function test_str_fallbacks()
  assert(errno.wrap(nil) == "unknown error")
  assert(errno.wrap(nil, "op") == "op: unknown error")
  assert(errno.wrap("boom") == "boom")
  assert(errno.wrap("boom", "op") == "op: boom")
  assert(errno.wrap("boom", "") == "boom", "empty prefix is ignored")
end
test_str_fallbacks()

-- str: a prefix replaces a lowercase `call: ` head so the failing
-- operation is not stated twice.
local function test_str_prefix_strips_call_head()
  local got = errno.wrap("mkdir: EACCES: Permission denied", "mkdir: /x")
  assert(got == "mkdir: /x: EACCES: Permission denied", "got: " .. got)
end
test_str_prefix_strips_call_head()

-- str: without a prefix, the message is passed through untouched.
local function test_str_no_prefix_keeps_call_head()
  local got = errno.wrap("mkdir: EACCES: Permission denied")
  assert(got == "mkdir: EACCES: Permission denied", "got: " .. got)
end
test_str_no_prefix_keeps_call_head()

-- str: uppercase errno names are never mistaken for a call head.
local function test_str_prefix_keeps_errno_head()
  local got = errno.wrap("ENOENT: No such file or directory", "open: /x")
  assert(got == "open: /x: ENOENT: No such file or directory", "got: " .. got)
end
test_str_prefix_keeps_errno_head()

-- str: non-string values fall back to tostring.
local function test_str_non_string()
  assert(errno.wrap(42) == "42")
  assert(errno.wrap(42, "op") == "op: 42")
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

-- constants: a name -> number table mirroring errno.code.
local function test_constants_lookup()
  local enoent = errno.constants.ENOENT
  assert(type(enoent) == "number", "ENOENT should be a number")
  assert(enoent == errno.code("ENOENT"), "constants must agree with code()")
  assert(errno.constants.EAGAIN == errno.code("EAGAIN"), "EAGAIN must agree")
  assert(errno.constants["E_NOT_A_REAL_ERRNO"] == nil, "unknown name is nil")
end
test_constants_lookup()

-- constants: every entry is a well-formed errno name with an integer
-- value, usable with errno.is; and the table is non-trivially populated.
local function test_constants_shape()
  local n = 0
  for name, value in pairs(errno.constants) do
    n = n + 1
    assert(string.match(name, "^E[%u%d]+$"), "bad errno name: " .. name)
    assert(math.type(value) == "integer", name .. " value must be an integer")
    assert(errno.is(value, name), name .. " must round-trip through errno.is")
  end
  assert(n >= 50, "expected a populated table, got " .. tostring(n) .. " entries")
end
test_constants_shape()

-- constants: the termios ECHO* flags are not errnos and must be absent.
local function test_constants_excludes_termios()
  for _, name in ipairs({"ECHO", "ECHOE", "ECHOK", "ECHONL"}) do
    assert(errno.constants[name] == nil, name .. " is a termios flag, not an errno")
  end
end
test_constants_excludes_termios()

-- The canonical names (D20 rename, #981): same functions, one grammar.
-- The old names are transition aliases until the pin advance.
local function test_canonical_names_and_aliases()
  assert(errno.format("mkdir: EACCES: denied", "mkdir: /x")
    == "mkdir: /x: EACCES: denied")
  assert(errno.is_code(errno.code_of("ENOENT"), "ENOENT"))
  assert(errno.name_in("open: ENOENT: No such file or directory") == "ENOENT")
  assert(errno.codes.ENOENT == errno.code_of("ENOENT"))
  assert(errno.wrap == errno.format, "wrap aliases format")
  assert(errno.is == errno.is_code, "is aliases is_code")
  assert(errno.code == errno.code_of, "code aliases code_of")
  assert(errno.name_of == errno.name_in, "name_of aliases name_in")
  assert(errno.constants == errno.codes, "constants aliases codes")
end
test_canonical_names_and_aliases()
