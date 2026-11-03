--- `build.invoke`: a command line run in this process as the binary
--- would run it. A run that reads the store beyond this closure -- a
--- verb over every module's docs, the databases it searches -- is
--- build/invoke_store_test.tl's.

local Store = require("cosmic.store")
local invoke = require("build.invoke")
local sys = require("cosmic.sys")
-- The `-e` chunks below require it, which the checker types from its text: named here, the pure store keeps it.
local type _proc = require("cosmic.proc")

--- What a verb writes -- `print`'s C included -- and what it exits with
--- come back as a started binary's would.
local function test_a_run_captures_what_it_writes_and_exits_with(tmp: string)
  local result = invoke.run({ "-e", "print('out') return 3" }, { cwd = tmp })
  assert(result.code == 3, result.stderr)
  assert(result.stdout == "out\n", result.stdout)
  assert(result.stderr == "", result.stderr)
end

--- A command line only a process of its own can run raises to the
--- caller and leaves everything as it found it. A file run raises before
--- anything runs. A call that would end the process raises once
--- everything is put back, even when the verb catches it.
local function test_what_only_a_process_can_do_raises(tmp: string)
  local exit, execve, attach = sys.exit, sys.execve, Store.attach
  local here = assert(sys.getcwd())
  --- Whether [`invoke.run`] raised, and what it raised or, where it did not, what it answered: a result's `tostring` is a
  --- table's address, which says nothing of why the call did not raise.
  local function attempt(args: {string}): boolean, string
    local answered: mut {invoke.Result} = {}
    local ok, trouble = pcall(function() answered[1] = invoke.run(args, { cwd = tmp }) end)
    if ok then
      local result = assert(answered[1])
      return false, "invoke.run did not raise; it answered code " .. tostring(result.code) ..
        ", stderr " .. string.format("%q", result.stderr)
    end
    return true, tostring(trouble)
  end
  local raised, trouble = attempt({ "-e", "require('cosmic.proc').exit(0)" })
  assert(raised and trouble:find("called sys.exit", 1, true) ~= nil, trouble)
  local swallowed, why = attempt({ "-e", "pcall(require('cosmic.proc').exit, 0)" })
  assert(swallowed and why:find("called sys.exit", 1, true) ~= nil, why)
  local file, file_trouble = attempt({ "main.tl" })
  assert(file and file_trouble:find("runs a file", 1, true) ~= nil, file_trouble)
  assert(sys.exit == exit and sys.execve == execve and Store.attach == attach)
  assert(sys.getcwd() == here)
  local again = invoke.run({ "-e", "print('after')" }, { cwd = tmp })
  assert(again.stdout == "after\n", again.stdout)
end

--- An uncaught error ends the run as it ends the binary: its message on
--- stderr after `cosmic: `, or `failed` for one that is no text, and
--- exit 1.
local function test_an_uncaught_error_exits_1(tmp: string)
  local result = invoke.run({ "-e", "error('boom', 0)" }, { cwd = tmp })
  assert(result.code == 1, result.stdout)
  assert(result.stderr == "cosmic: boom\n", result.stderr)
  local table_error = invoke.run({ "-e", "local value: {string:string} = {} error(value)" }, { cwd = tmp })
  assert(table_error.code == 1 and table_error.stderr == "cosmic: failed\n",
    table_error.stderr)
  local number_error = invoke.run({ "-e", "error(42)" }, { cwd = tmp })
  assert(number_error.code == 1 and number_error.stderr == "cosmic: 42\n",
    number_error.stderr)
end
