--- Each test runs in a worker process of its own: a test that hangs is
--- ended at its deadline, one that ends its process fails by itself,
--- and neither takes the rest of the run with it. What a test prints is
--- shown only when it fails.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local worker = require("build.test_worker")

local function invoke(root: string, output: string, args: {string},
    env?: {string:string}): Child.Result
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, value in ipairs(args) do argv[#argv + 1] = value end
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run(argv, {
    cwd = root, env = env or Env.all(), stdout = fd, stderr = fd, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- A hung test that also started a process group of its own, which the
--- end of its worker's group does not reach; a test that ends its own
--- process after printing; and a quiet one that passes.
local function project(tmp: string): string, string
  local root = tmp .. "/project"
  local pidfile = tmp .. "/nested.pid"
  assert(Fs.mkdirs(root .. "/suite"))
  local hang = [[
local Child = require("cosmic.child")
local held: {Child.Handle} = {}
local function test_hangs()
  held[1] = assert(Child.start({ "/bin/sh", "-c",
    "sleep 60 & printf %s $! >'PIDFILE'; wait" }))
  while true do end
end
]]
  assert(Fs.write(root .. "/suite/hang_test.tl", (hang:gsub("PIDFILE", pidfile))))
  assert(Fs.write(root .. "/suite/exits_test.tl", [[
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local function test_exits()
  Fs.put(Fs.stdout, "said something\n")
  Proc.exit(0)
end
]]))
  assert(Fs.write(root .. "/suite/fine_test.tl", [[
local Fs = require("cosmic.fs")
local function test_fine()
  Fs.put(Fs.stdout, "quiet\n")
end
]]))
  return root, pidfile
end

local function test_a_hung_or_exiting_test_fails_alone(tmp: string)
  local root, pidfile = project(tmp)
  local output = tmp .. "/run.out"
  local started = assert(Time.monotonic_ns())
  local result = invoke(root, output, { "--timeout", "1", "--jobs", "2" })
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(assert(Time.monotonic_ns()) - started < 30 * 1000 * 1000 * 1000, text)
  assert(text:find("suite.hang_test test_hangs: timed out after 1 s", 1, true), text)
  assert(text:find("suite.exits_test test_exits: the test process exited with status 0 " ..
    "before it reported", 1, true), text)
  assert(text:find("  | said something", 1, true), text)
  assert(not text:find("quiet", 1, true), text)
  assert(text:find("2 of 3 failed", 1, true), text)
  -- Where the runner can find what a dead worker left behind (Linux),
  -- the hung test's own process group is gone too.
  if Fs.exists("/proc/self/task") then
    local pid = assert(math.tointeger(tonumber((assert(Fs.read(pidfile))))))
    local alive, _, errno = sys.kill(pid, 0)
    assert(not alive and errno == sys.ESRCH, "nested process " .. tostring(pid) .. " survived")
  end
end

local function test_limits_must_be_positive_whole_numbers(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/limits.out"
  local result = invoke(root, output, { "--timeout", "0", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("--timeout must be a positive whole number", 1, true))
  result = invoke(root, output, { "--jobs", "x", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  local env = Env.all()
  env.COSMIC_TEST_TIMEOUT = "soon"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("COSMIC_TEST_TIMEOUT must be", 1, true))
  env.COSMIC_TEST_TIMEOUT = "5"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.ok, assert(Fs.read(output)))
end

local function test_a_report_reads_back_whole_or_not_at_all()
  local report: worker.Report = {
    loaded = true, passed = false, message = "line one\nline two", elapsed_ns = 42,
    load_reads = { { kind = "o", path = "a b\n", answer = "" } },
    test_reads = { { kind = "e", path = "HOME", answer = "ok /root" } },
    load_hits = { ["x.y"] = { [3] = true, [1] = true } },
    test_hits = {},
  }
  local text = worker.encode(report)
  local back = assert(worker.decode(text))
  assert(back.loaded and not back.passed and back.elapsed_ns == 42)
  assert(back.message == "line one\nline two")
  assert(back.load_reads[1].path == "a b\n" and back.load_reads[1].kind == "o")
  assert(back.test_reads[1].answer == "ok /root")
  assert(back.load_hits["x.y"][1] and back.load_hits["x.y"][3])
  local cut, trouble = worker.decode(text:sub(1, #text - 5))
  assert(cut == nil and trouble == "the report was cut short")
  assert(worker.decode("") == nil)
  assert(worker.decode("something else\nend\n") == nil)
  assert(worker.decode(text .. "extra\n") == nil)
end
