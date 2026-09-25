local Store = require("cosmic.store")
local invoke = require("build.invoke")
local sys = require("cosmic.sys")

--- What a verb writes -- `print`'s C included -- and what it exits with
--- come back as a started binary's would.
local function test_a_run_captures_what_it_writes_and_exits_with(tmp: string)
  local result = invoke.run({ "-e", "print('out') return 3" }, { cwd = tmp })
  assert(result.code == 3, result.stderr)
  assert(result.stdout == "out\n", result.stdout)
  assert(result.stderr == "", result.stderr)
  local verb = invoke.run({ "help", "sql" }, { cwd = tmp })
  assert(verb.code == 0, verb.stderr)
  assert(verb.stdout:match("help: PASS [^\n]*\n$"), verb.stdout)
end

--- The working directory and environment asked for are the run's, only
--- the binary's own database is searched, and this process's own are
--- back after it.
local function test_a_run_has_its_own_directory_environment_and_store(tmp: string)
  local here = assert(sys.getcwd())
  local real = assert(sys.realpath(tmp))
  local databases = #Store.databases()
  local result = invoke.run({ "-e", [[
    local Env = require("cosmic.env")
    local Store = require("cosmic.store")
    local sys = require("cosmic.sys")
    print(assert(sys.getcwd()))
    print(Env.get("INVOKE_GIVEN"), Env.all().INVOKE_GIVEN, Env.get("HOME"))
    print(#Store.databases())
  ]] }, { cwd = tmp, env = { INVOKE_GIVEN = "yes" } })
  assert(result.code == 0, result.stderr)
  assert(result.stdout == real .. "\nyes\tyes\tnil\n1\n", result.stdout)
  assert(sys.getcwd() == here)
  assert(#Store.databases() == databases)
end

--- A command line only a process of its own can run raises to the
--- caller -- a file run before anything runs, a call that would end the
--- process once everything is put back, even one the verb caught -- and
--- leaves everything as it found it.
local function test_what_only_a_process_can_do_raises(tmp: string)
  local exit, execve, attach = sys.exit, sys.execve, Store.attach
  local here = assert(sys.getcwd())
  local ran, trouble = pcall(invoke.run, { "-e", "require('cosmic.proc').exit(0)" },
    { cwd = tmp })
  assert(not ran and tostring(trouble):find("called sys.exit", 1, true), tostring(trouble))
  local swallowed, why = pcall(invoke.run, { "-e", "pcall(require('cosmic.proc').exit, 0)" },
    { cwd = tmp })
  assert(not swallowed and tostring(why):find("called sys.exit", 1, true), tostring(why))
  local file, file_trouble = pcall(invoke.run, { "main.tl" }, { cwd = tmp })
  assert(not file and tostring(file_trouble):find("runs a file", 1, true),
    tostring(file_trouble))
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
  local table_error = invoke.run({ "-e", "error({})" }, { cwd = tmp })
  assert(table_error.code == 1 and table_error.stderr == "cosmic: failed\n",
    table_error.stderr)
  local number_error = invoke.run({ "-e", "error(42)" }, { cwd = tmp })
  assert(number_error.code == 1 and number_error.stderr == "cosmic: 42\n",
    number_error.stderr)
end
