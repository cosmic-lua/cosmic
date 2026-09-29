--- `build.invoke`'s runs that read the store beyond this closure
--- (build/invoke_test.tl holds the rest).

local Store = require("cosmic.store")
local invoke = require("build.invoke")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The whole projection: `help` reads every module's docs through
--- `Store.databases()`, and the run's own count of the databases it
--- searches is `Store.databases()`'s, which a handle on every module's
--- rows answers.
Test.needs{ store = true }

--- A verb's output and exit come back as a started binary's would.
local function test_a_run_captures_a_verbs_output(tmp: string)
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
