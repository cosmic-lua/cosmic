#!/usr/bin/env cosmic
-- test cosmic bundled binary

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

-- helper to create clean environment without LUA_PATH
-- this ensures we test the bundled libraries, not the repo
local function clean_env(): {string}
  local env: {string} = {}
  for _, entry in ipairs(cenv.list()) do
    if not entry:match("^LUA_PATH=") and not entry:match("^LUA_CPATH=") then
      env[#env + 1] = entry
    end
  end
  return env
end

local function test_cosmic_child()
  local h1 = check.must(spawn.spawn({cosmic, "-e", "local c = require('cosmic.child'); print(c and 'ok' or 'fail')"}, {env = clean_env()}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic exited with error")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end
test_cosmic_child()

local function test_cosmic_walk()
  local h2 = check.must(spawn.spawn({cosmic, "-e", "local fs = require('cosmic.fs'); print(fs.walk and 'ok' or 'fail')"}, {env = clean_env()}))
  local __r2 = check.must(h2:wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic exited with error")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end
test_cosmic_walk()

local function test_cosmic_help()
  local h3 = check.must(spawn.spawn({cosmic, "--help"}, {env = clean_env()}))
  local __r3 = check.must(h3:wait())
  local ok, out = __r3.ok, __r3.stdout
  assert(ok, "cosmic --help exited with error")
  assert(out:find("cosmic", 1, true), "expected output to contain 'cosmic'")
  assert(out:find("%-%-help", 1, false), "expected output to contain '--help'")
  assert(out:find("Low%-level cosmo", 1, false), "expected output to contain note about cosmo bindings")
end
test_cosmic_help()

local function test_warnings_flag()
  -- -W should convert warnings to errors; the warning message lands on stderr
  local h4 = check.must(spawn.spawn({cosmic, "-W", "-e", "warn('test warning')"}, {env = clean_env()}))
  local __r4 = check.must(h4:wait())
  local ok, out, code = __r4.ok, __r4.stderr, __r4.code
  assert(not ok, "cosmic should fail with -W when warning is issued")
  assert(out:find("warning: test warning", 1, true), "expected output to contain 'warning: test warning'")
  assert(code == 1, "expected exit code 1, got " .. tostring(code))
end
test_warnings_flag()

local function test_warnings_without_flag()
  -- without -W, warnings should not cause errors
  local h5 = check.must(spawn.spawn({cosmic, "-e", "warn('test warning'); print('ok')"}, {env = clean_env()}))
  local __r5 = check.must(h5:wait())
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "cosmic should succeed without -W")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end
test_warnings_without_flag()

local function test_interactive_mode()
  -- -i should enter interactive mode (REPL)
  local proc = check.must(spawn.spawn({cosmic, "-i"}, {env = clean_env(), stdin = "print('hello')\nos.exit(0)\n"}))
  local __r6 = check.must(proc:wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "cosmic -i should succeed")
  assert(out:find("Lua 5.4", 1, true), "expected output to contain 'Lua 5.4'")
  assert(out:find("hello", 1, true), "expected output to contain 'hello'")
end
test_interactive_mode()

local function test_repl_no_args()
  -- no args should enter REPL
  local proc = check.must(spawn.spawn({cosmic}, {env = clean_env(), stdin = "print('repl test')\nos.exit(0)\n"}))
  local __r7 = check.must(proc:wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "cosmic with no args should enter REPL")
  assert(out:find("Lua 5.4", 1, true), "expected output to contain 'Lua 5.4'")
  assert(out:find("repl test", 1, true), "expected output to contain 'repl test'")
end
test_repl_no_args()
