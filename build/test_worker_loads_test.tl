--- What a worker loads of the tree besides its test's closure is
--- `worker.loads` (build/test_worker.tl), and no more: a worker started
--- by hand, as `cosmic test` starts one, runs a module whose closure is
--- small, and what its report says it ran of the tree -- all but Lua's
--- libraries and the core's own -- is that module's closure and
--- `worker.loads`, which
--- names nothing it did not run but `cosmic.removed`, which the core
--- loads only for a test that reaches for a removed global. Nor does it
--- run the code that computes a key but the parts it spells
--- (build.key_parts). It starts this program, so it declares `tool`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local worker = require("build.test_worker")
-- The module the worker below runs, which its store must hold.
local _ = require("build.key_parts")

--- The program itself, which it starts as a worker.
Test.needs{ tool = true }

--- What a worker loads that is no module of the tree: Lua's own
--- libraries, beside the core's `cosmic.sys` and `cosmic.internal.*`,
--- which the runtime's identity keys.
local lua <const>: {string:boolean} = {
  _G = true, coroutine = true, debug = true, io = true, math = true, os = true,
  package = true, string = true, table = true, utf8 = true,
}

local function test_a_worker_loads_what_worker_loads_names(tmp: string)
  local root = assert(Fs.absolute("."))
  assert(Fs.mkdirs(tmp .. "/tmp"))
  local started = this_program.program({ "test", "--worker", root, "build.key_parts",
    "test_none", tmp .. "/tmp", tmp .. "/children" }, {
    cwd = root, stdin = "null", stdout = "capture", stderr = "stdout",
    fds = { [worker.report_fd] = "capture" }, timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  local report = worker.decode(result.captured[worker.report_fd])
  assert(report ~= nil, tostring(result.stdout))
  assert(report.message == "build.key_parts has no test named test_none", report.message)
  local ran: {string:boolean} = {}
  for _, name in ipairs(report.modules) do ran[name] = true end
  local listed: {string:boolean} = {}
  for _, name in ipairs(worker.loads) do
    listed[name] = true
    assert(ran[name] or name == "cosmic.removed",
      "worker.loads names " .. name .. ", which a worker did not load")
  end
  for _, name in ipairs(report.modules) do
    if not lua[name] and name ~= "cosmic.sys" and name:match("^cosmic%.internal%.") == nil then
      assert(listed[name], "a worker loaded " .. name .. ", which worker.loads does not name")
    end
  end
  for _, name in ipairs({ "build.declared_key", "build.artifact", "build.core_image",
                          "build.launcher", "build.verdict", "cosmic.time", "cosmic.log",
                          "cosmic.string" }) do
    assert(not ran[name], "a worker loaded " .. name)
  end
end
