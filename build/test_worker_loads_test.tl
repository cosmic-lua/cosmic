--- What a worker loads of the tree besides its test's closure is
--- [`worker.loads`] (build/test_worker.tl), and no more: a worker started
--- by hand, as `cosmic test` starts one, runs a module whose closure is
--- small, and what its report says it ran of the tree -- all but Lua's
--- libraries and the core's own -- is that module's closure and
--- [`worker.loads`], which names nothing it did not run. Nor does it run the code that computes a key
--- but the parts it spells (build.key_parts), nor hash through
--- cosmic.hash and cosmic.codec rather than build.digest. It starts this
--- program, so it declares `tool`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local worker = require("build.test_worker")
-- The module the worker below runs, which its store must hold.
local _ = require("build.key_parts")
local Clock = require("cosmic.clock")

--- The program itself, which it starts as a worker.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- What a worker loads that is no module of the tree: Lua's own
--- libraries, beside the core's [`cosmic.sys`] and `cosmic.internal.*`,
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
      fds = { [worker.report_fd] = "capture" }, timeout_ns = Clock.seconds(30),
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
    assert(ran[name], "worker.loads names " .. name .. ", which a worker did not load")
  end
  for _, name in ipairs(report.modules) do
    if not lua[name] and name ~= "cosmic.sys" and name:match("^cosmic%.internal%.") == nil then
      assert(listed[name], "a worker loaded " .. name .. ", which worker.loads does not name")
    end
  end
  for _, name in ipairs({ "build.declared_key", "build.artifact", "build.core_image",
      "build.launcher", "build.verdict", "cosmic.time", "cosmic.log",
      "cosmic.string", "cosmic.hash", "cosmic.codec" }) do
    assert(not ran[name], "a worker loaded " .. name)
  end
end

--- Given `--store`, a worker attaches that store in place of the
--- tree's o/cosmic.db, as an unsandboxed worker keyed by declarations
--- is given the store of its closure: one that is not there fails it
--- before anything loads, naming it.
local function test_a_worker_attaches_the_store_it_is_given(tmp: string)
  local root = assert(Fs.absolute("."))
  assert(Fs.mkdirs(tmp .. "/tmp"))
  local missing = tmp .. "/missing/closure.db"
  local started = this_program.program({ "test", "--worker", root, "build.key_parts",
    "test_none", tmp .. "/tmp", tmp .. "/children", "", "--store", missing,
    "build.key_parts", "--tree", "build.key_parts", "--declared" }, {
      cwd = root, stdin = "null", stdout = "capture", stderr = "stdout",
      fds = { [worker.report_fd] = "capture" }, timeout_ns = Clock.seconds(30),
    })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 2, tostring(result.code) .. ": " .. tostring(result.stdout))
  assert(tostring(result.stdout):find(missing, 1, true), tostring(result.stdout))
  -- Without it, the same worker attaches the tree's own and runs.
  started = this_program.program({ "test", "--worker", root, "build.key_parts",
    "test_none", tmp .. "/tmp", tmp .. "/children-again", "",
    "build.key_parts", "--tree", "build.key_parts", "--declared" }, {
      cwd = root, stdin = "null", stdout = "capture", stderr = "stdout",
      fds = { [worker.report_fd] = "capture" }, timeout_ns = Clock.seconds(30),
    })
  result = assert(Child.run(started.argv, started.options))
  local report = worker.decode(result.captured[worker.report_fd])
  assert(report ~= nil, tostring(result.stdout))
  assert(report.message == "build.key_parts has no test named test_none", report.message)
end
