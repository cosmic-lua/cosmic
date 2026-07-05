#!/usr/bin/env cosmic
local errno = require("cosmic.errno")

-- str: nil, string, and prefix handling (no Errno object needed).
local function test_str_fallbacks()
  assert(errno.str(nil) == "unknown error")
  assert(errno.str(nil, "op") == "op: unknown error")
  assert(errno.str("boom") == "boom")
  assert(errno.str("boom", "op") == "op: boom")
  assert(errno.str("boom", "") == "boom", "empty prefix is ignored")
end
test_str_fallbacks()

-- str: an Errno-shaped object renders "NAME: doc", with optional prefix.
local function test_str_errno()
  local e: any = {
    errno = function(_: any): integer return errno.code("ENOENT") end,
    name = function(_: any): string return "ENOENT" end,
    doc = function(_: any): string return "No such file or directory" end,
  }
  assert(errno.str(e) == "ENOENT: No such file or directory",
    "got: " .. errno.str(e))
  assert(errno.str(e, "open: /x") == "open: /x: ENOENT: No such file or directory",
    "got: " .. errno.str(e, "open: /x"))
end
test_str_errno()

-- str: an Errno with no name() still renders its doc.
local function test_str_errno_no_name()
  local e: any = {
    doc = function(_: any): string return "Permission denied" end,
  }
  assert(errno.str(e) == "Permission denied", "got: " .. errno.str(e))
end
test_str_errno_no_name()

-- code: known constants resolve to numbers; unknown ones are nil.
local function test_code()
  assert(type(errno.code("ENOENT")) == "number", "ENOENT should resolve")
  assert(errno.code("E_NOT_A_REAL_ERRNO") == nil, "unknown errno is nil")
end
test_code()

-- is: matches by errno number; false for nil, wrong name, and non-Errno.
local function test_is()
  local e: any = {
    errno = function(_: any): integer return errno.code("ENOENT") end,
  }
  assert(errno.is(e, "ENOENT"), "should match ENOENT")
  assert(not errno.is(e, "EACCES"), "should not match EACCES")
  assert(not errno.is(nil, "ENOENT"), "nil err is never a match")
  assert(not errno.is("a string", "ENOENT"), "non-Errno is never a match")
  assert(not errno.is(e, "E_NOT_A_REAL_ERRNO"), "unknown name is never a match")
end
test_is()

-- constants: table exists and maps known errno names to numbers.
local function test_constants_type()
  assert(type(errno.constants) == "table", "constants should be a table")
end
test_constants_type()

local function test_constants_values()
  local v = errno.constants["ENOENT"]
  assert(type(v) == "number", "ENOENT should be a number, got: " .. tostring(v))
  assert(v == errno.code("ENOENT"), "constants[ENOENT] should equal code(ENOENT)")
end
test_constants_values()

local function test_constants_eagain()
  local v = errno.constants["EAGAIN"]
  assert(type(v) == "number", "EAGAIN should be a number, got: " .. tostring(v))
end
test_constants_eagain()

local function test_constants_unknown()
  assert(errno.constants["E_NOT_REAL"] == nil, "unknown key should be nil")
end
test_constants_unknown()

print("errno_test: PASS")
