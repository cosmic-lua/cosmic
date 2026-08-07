#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local env = require("cosmic.env")

local saved_home = env.get("HOME")
local saved_profile = env.get("USERPROFILE")

local function restore()
  if saved_home then
    assert(env.set("HOME", saved_home))
  else
    assert(env.unset("HOME"))
  end
  if saved_profile then
    assert(env.set("USERPROFILE", saved_profile))
  else
    assert(env.unset("USERPROFILE"))
  end
end

-- home tests

local function test_home_from_env()
  assert(env.set("HOME", "/home/tester"))
  local dir, err = fs.home()
  assert(dir == "/home/tester", "expected /home/tester, got " .. tostring(dir) .. " (" .. tostring(err) .. ")")
  restore()
end
test_home_from_env()

local function test_home_userprofile_fallback()
  assert(env.unset("HOME"))
  assert(env.set("USERPROFILE", "/users/tester"))
  local dir = fs.home()
  assert(dir == "/users/tester", "expected USERPROFILE fallback, got " .. tostring(dir))
  restore()
end
test_home_userprofile_fallback()

local function test_home_unset()
  assert(env.unset("HOME"))
  assert(env.unset("USERPROFILE"))
  local dir, err = fs.home()
  assert(dir == nil, "expected nil when no home is set")
  assert(err ~= nil, "expected an error message")
  restore()
end
test_home_unset()

-- expanduser tests

local function test_expanduser_bare_tilde()
  assert(env.set("HOME", "/home/tester"))
  assert(fs.expanduser("~") == "/home/tester", "expected bare ~ expanded")
  restore()
end
test_expanduser_bare_tilde()

local function test_expanduser_tilde_slash()
  assert(env.set("HOME", "/home/tester"))
  assert(fs.expanduser("~/docs/x.txt") == "/home/tester/docs/x.txt",
    "expected ~/ expanded, got " .. fs.expanduser("~/docs/x.txt"))
  restore()
end
test_expanduser_tilde_slash()

local function test_expanduser_trailing_slash_home()
  assert(env.set("HOME", "/home/tester/"))
  local p = fs.expanduser("~/docs")
  assert(p == "/home/tester/docs", "expected joined path without double slash, got " .. p)
  restore()
end
test_expanduser_trailing_slash_home()

local function test_expanduser_untouched_forms()
  assert(env.set("HOME", "/home/tester"))
  assert(fs.expanduser("/abs/path") == "/abs/path", "absolute path must be unchanged")
  assert(fs.expanduser("rel/path") == "rel/path", "relative path must be unchanged")
  assert(fs.expanduser("~other/docs") == "~other/docs", "~user form must be unchanged")
  assert(fs.expanduser("mid~dle") == "mid~dle", "interior ~ must be unchanged")
  assert(fs.expanduser("") == "", "empty path must be unchanged")
  restore()
end
test_expanduser_untouched_forms()

local function test_expanduser_no_home()
  assert(env.unset("HOME"))
  assert(env.unset("USERPROFILE"))
  assert(fs.expanduser("~/docs") == "~/docs", "expected unchanged path when no home is set")
  assert(fs.expanduser("~") == "~", "expected bare ~ unchanged when no home is set")
  restore()
end
test_expanduser_no_home()
