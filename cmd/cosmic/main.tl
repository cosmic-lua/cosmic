--- The binary's main: [`build.dispatch`] runs the command line, but for
--- one test's worker (`cosmic test --worker`, `--worker-no-tool` or
--- `--worker-held`),
--- which [`build.test`] starts and [`build.test_worker`] runs. A worker
--- comes here first, ahead of dispatch, since what a worker loads is
--- in every sandboxed test's key (build/test_worker.tl's
--- [`worker.loads`]): dispatch, and what only it requires, would run
--- every test again on every edit to it. So each is required only on
--- the way that runs it.

local Env = require("cosmic.env")

--- Defines the hook the calls of `__fact` run ([`lang.fact_wraps`]) in a process that checks nothing: it answers the value.
--- A chunk, since the checker types `_G` as the record of the standard library, which has no such name.
local function define_fact()
  local chunk = load("if __fact == nil then __fact = function(v) return v end end", "=define_fact", "t")
  if chunk ~= nil then
    chunk()
  end
end

--- Runs the command line and answers its exit code.
--- @param argv the command line, with the program's own name at slot 0
local function main(argv: {integer:string}): integer
  local mode = argv[2]
  if argv[1] == "test" and (mode == "--worker" or mode == "--worker-no-tool" or
      mode == "--worker-held") then
    -- Never stale-checked or rebuilt, since the run that started it
    -- already was.
    return require("build.test_worker").run(argv)
  end
  -- A process a checked run's test starts (COSMIC_TEST_TYPES, which the
  -- worker's environment holds) can run the code the new checker's
  -- generator wrote with the calls of `__fact`; only the worker checks
  -- them, so here they answer what they are given.
  if Env.get("COSMIC_TEST_TYPES") == "1" then
    define_fact()
  end
  return require("build.dispatch").main(argv)
end

return main
