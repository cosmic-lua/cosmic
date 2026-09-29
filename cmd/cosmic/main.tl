--- The binary's main: `build.dispatch` runs the command line, but for
--- one test's worker (`cosmic test --worker`, `--worker-no-tool` or
--- `--worker-held`),
--- which `build.test` starts and `build.test_worker` runs. A worker
--- comes here first, ahead of dispatch, since what a worker loads is
--- in every sandboxed test's key (build/test_worker.tl's
--- `worker.loads`): dispatch, and what only it requires, would run
--- every test again on every edit to it. So each is required only on
--- the way that runs it.

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
  return require("build.dispatch").main(argv)
end

return main
