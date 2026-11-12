--- The binary's main: [`build.dispatch`] runs the command line, but for
--- one test's worker (`cosmic test --worker`, `--worker-no-tool` or
--- `--worker-held`),
--- which [`build.test`] starts and [`build.test_worker`] runs. A worker
--- comes here first, ahead of dispatch, since what a worker loads is
--- in every sandboxed test's key (build/test_worker.tl's
--- [`worker.loads`]): dispatch, and what only it requires, would run
--- every test again on every edit to it. So each is required only on
--- the way that runs it.
---
--- The probe of whether a worker can be sandboxed (`cosmic test
--- --sandbox-probe <program>`, started by [`build.test_sandbox_probe`]'s
--- `available` once a run) comes here too: every `cosmic test` waits for
--- it, and it needs [`build.confine`] alone, where dispatch's `-e` would
--- load the checker to type a chunk.

--- Runs the command line and answers its exit code.
--- @param argv the command line, the verb at slot 1
local function main(argv: {string}): integer
  local mode = argv[2]
  if argv[1] == "test" and (mode == "--worker" or mode == "--worker-no-tool" or
      mode == "--worker-held") then
    -- Never stale-checked or rebuilt, since the run that started it
    -- already was.
    return require("build.test_worker").run(argv)
  end
  if argv[1] == "test" and mode == "--sandbox-probe" then
    local program = argv[3]
    local Fs = require("cosmic.fs")
    if program == nil or argv[4] ~= nil then
      local _, _ = Fs.put(Fs.stderr, "usage: cosmic test --sandbox-probe <program>\n")
      return 2
    end
    -- As a worker whose test does not declare `tool` holds itself.
    local confine = require("build.confine")
    local ok, why = confine.forbid_running(confine.itself(), { program })
    if not ok then
      local _, _ = Fs.put(Fs.stderr, why .. "\n")
      return 1
    end
    return 0
  end
  return require("build.dispatch").main(argv)
end

return main
