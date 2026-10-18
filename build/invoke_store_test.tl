--- [`build.invoke`]'s runs that read the store beyond this closure
--- (build/invoke_test.tl holds the rest).

local Store = require("cosmic.store")
local invoke = require("build.invoke")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

-- The import closure, which holds every verb through build.verb_list, is
-- one grant a module, and a worker's start takes 255: build/lsp/ is given
-- as one directory, which shows the closure's modules beneath it.
-- TODO: drop the build/lsp/ grant once a worker's grants show a directory's
-- modules as one (build.test_sandbox's `plan`), which a closure past 255 needs.
--- `help` reads every module's docs through [`Store.databases()`], and a
--- test here counts the databases it returns. Without `store`, it raises.
Test.policy{ grants = { { path = "build/lsp/", letters = "r" }, { path = "o/cosmic.db", letters = "r" } } }

--- A verb's output and exit come back as a started binary's would.
local function test_a_run_captures_a_verbs_output(tmp: string)
  local verb = invoke.run({ "help", "sql" }, { cwd = tmp })
  assert(verb.code == 0, verb.stderr)
  assert(verb.stdout:find("cosmic sql", 1, true), verb.stdout)
  assert(verb.stderr:match("^help: 1 verb, %d+ ms\n$"), verb.stderr)
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
