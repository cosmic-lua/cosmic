#!/usr/bin/env cosmic
-- test cosmic bundled binary

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

-- a clean environment without LUA_PATH ensures we test the bundled
-- libraries, not the repo
local function clean_env(): {string}
  return cenv.list({drop = {"LUA_PATH", "LUA_CPATH"}})
end

local function test_cosmic_child()
  local h1 = check.must(child.start({cosmic, "-e", "local c = require('cosmic.child'); print(c and 'ok' or 'fail')"}, {env = clean_env()}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic exited with error")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end

local function test_cosmic_visit()
  local h2 = check.must(child.start({cosmic, "-e", "local fs = require('cosmic.fs'); print(fs.visit and 'ok' or 'fail')"}, {env = clean_env()}))
  local __r2 = check.must(h2:wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic exited with error")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end

local function test_cosmic_help()
  local h3 = check.must(child.start({cosmic, "--help"}, {env = clean_env()}))
  local __r3 = check.must(h3:wait())
  local ok, out = __r3.ok, __r3.stdout
  assert(ok, "cosmic --help exited with error")
  assert(out:find("cosmic", 1, true), "expected output to contain 'cosmic'")
  assert(out:find("%-%-help", 1, false), "expected output to contain '--help'")
  assert(out:find("Low%-level cosmo", 1, false), "expected output to contain note about cosmo bindings")
end

local function test_warnings_flag()
  -- -W should convert warnings to errors; the warning message lands on stderr
  local h4 = check.must(child.start({cosmic, "-W", "-e", "warn('test warning')"}, {env = clean_env()}))
  local __r4 = check.must(h4:wait())
  local ok, out, code = __r4.ok, __r4.stderr, __r4.code
  assert(not ok, "cosmic should fail with -W when warning is issued")
  assert(out:find("warning: test warning", 1, true), "expected output to contain 'warning: test warning'")
  assert(code == 1, "expected exit code 1, got " .. tostring(code))
end

local function test_warnings_without_flag()
  -- without -W, warnings should not cause errors
  local h5 = check.must(child.start({cosmic, "-e", "warn('test warning'); print('ok')"}, {env = clean_env()}))
  local __r5 = check.must(h5:wait())
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "cosmic should succeed without -W")
  assert(out:find("ok", 1, true), "expected output to contain 'ok'")
end

local function test_interactive_mode()
  -- -i should enter interactive mode (REPL)
  local proc = check.must(child.start({cosmic, "-i"}, {env = clean_env(), stdin = "print('hello')\nos.exit(0)\n"}))
  local __r6 = check.must(proc:wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "cosmic -i should succeed")
  assert(out:find("Lua 5.5", 1, true), "expected output to contain 'Lua 5.5'")
  assert(out:find("hello", 1, true), "expected output to contain 'hello'")
end

local function test_no_args_piped_stdin_runs_as_script()
  -- no args with piped (non-tty) stdin must run the pipe as ONE script
  -- -- not drop into the line-by-line REPL, where every `local` dies
  -- at the end of its own line. (A spawned child's stdin is always a
  -- pipe, never a tty, so this exercises the same dispatch a real
  -- `cosmic <<EOF` hits.)
  local proc = check.must(child.start({cosmic}, {env = clean_env(),
        stdin = "local x = 21\nlocal y = 21\nprint(x + y)\n"}))
  local __r7 = check.must(proc:wait())
  local ok, out = __r7.ok, __r7.stdout
  assert(ok, "cosmic with no args and piped stdin should run as a script: " .. out)
  assert(not out:find("Lua 5.5", 1, true),
    "piped stdin must not show the REPL banner, got: " .. out)
  assert(out:find("42", 1, true), "expected the script's own output, got: " .. out)
end
