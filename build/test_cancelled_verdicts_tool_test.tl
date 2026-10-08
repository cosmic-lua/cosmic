--- Completed failures invalidate old passes even when a later worker is
--- cancelled. The incomplete run publishes neither passes nor coverage.

local build_paths = require("build.paths")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local cache_formats = require("build.cache_formats")

local declared = cache_formats.declared

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

local function snapshot(path: string, query: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, query))
  assert(db:close())
  local out: {string} = {}
  for _, row in ipairs(rows) do out[#out + 1] = table.concat(row, "|") end
  return table.concat(out, "\n")
end

local function test_cancellation_keeps_failures_but_no_incomplete_run(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local root, flag, marker = tmp .. "/project", tmp .. "/flag", tmp .. "/waiting"
  local cache = tmp .. "/cache/verdicts.db"
  assert(Fs.mkdirs(root))
  assert(Fs.write(flag, "unchanged\n"))
  assert(Fs.set_mtime(flag, 1700000000))
  -- Keys hold contents, never times. Changing only this mtime gives the
  -- same source/key a deterministic pass then fail, as a flaky test can.
  assert(Fs.write(root .. "/work_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.policy { grants = { { path = "]] .. flag .. [[", letters = "r" } } }
local function test_a_completed_pass() assert(true) end
local function test_b_observed_failure()
  assert(assert(Fs.stat("]] .. flag .. [[")).mtime == 1700000000, "controlled failure")
end
local function test_c_unfinished()
  assert(Fs.write("]] .. marker .. [[", "waiting"))
  while true do end
end
local function test_d_unstarted() assert(true) end
]]))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_VERDICT_CACHE = cache
  local function run(name: string, words: {string}, passes: boolean): string
    local output = tmp .. "/" .. name .. ".out"
    local fd = assert(Fs.open_write(output))
    local args: {string} = { "test", "--jobs", "1" }
    for _, word in ipairs(words) do args[#args + 1] = word end
    local start = this_program.program(args, { cwd = root, env = env, stdout = fd, stderr = fd })
    local result = assert(Child.run(start.argv, start.options))
    assert(Fs.close(fd))
    local text = assert(Fs.read(output))
    assert(result.ok == passes, text)
    return text
  end
  local passed = run("prime", { "work_test.tl:test_b_observed_failure", "work_test.tl:test_d_unstarted" }, true)
  assert(passed:find("2 ran, 0 stood", 1, true), passed)
  local records = build_paths.required(root) .. "/build.db"
  local key = snapshot(cache, "SELECT key FROM " .. declared .. " WHERE test = 'work_test test_b_observed_failure'")
  assert(key ~= "")
  local histories: {string:string} = {}
  for _, name in ipairs({ "runs", "test_runs", "coverage", "coverage_by_test" }) do
    histories[name] = snapshot(records, "SELECT * FROM " .. name .. " ORDER BY 1")
  end
  local others = snapshot(records, "SELECT * FROM verdicts WHERE key <> '" .. key .. "' ORDER BY key")
  local shared_others = snapshot(cache, "SELECT * FROM " .. declared .. " WHERE key <> '" .. key .. "' ORDER BY key")
  assert(Fs.set_mtime(flag, 1600000000))
  local output = tmp .. "/cancelled.out"
  local fd = assert(Fs.open_write(output))
  local start = this_program.program({ "test", "--all", "--jobs", "1" },
    { cwd = root, env = env, stdout = fd, stderr = fd })
  local handle <close> = assert(Child.start(start.argv, start.options))
  assert(Fs.close(fd))
  local deadline = Clock.monotonic_ns() + Clock.seconds(20)
  while not Fs.exists(marker) do
    assert(Clock.monotonic_ns() < deadline, assert(Fs.read(output)))
    local done = Child.wait_any({ handle }, Clock.ms(10))
    assert(done == nil, assert(Fs.read(output)))
  end
  -- Jobs run singly: the unfinished worker starts only after the failure
  -- has been collected and the preceding unprimed pass has completed.
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(Clock.seconds(5)))
  local cancelled = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGTERM, cancelled)
  assert(cancelled:find("controlled failure", 1, true), cancelled)
  assert(cancelled:find("test: cancelled; every running test was ended", 1, true), cancelled)
  for name, before in pairs(histories) do
    assert(snapshot(records, "SELECT * FROM " .. name .. " ORDER BY 1") == before, name)
  end
  assert(snapshot(records, "SELECT * FROM verdicts WHERE key <> '" .. key .. "' ORDER BY key") == others)
  assert(snapshot(cache, "SELECT * FROM " .. declared .. " WHERE key <> '" .. key .. "' ORDER BY key") == shared_others)
  assert(snapshot(records, "SELECT passed FROM verdicts WHERE key = '" .. key .. "'") == "0", "local pass survived")
  assert(snapshot(cache, "SELECT key FROM " .. declared .. " WHERE key = '" .. key .. "'") == "", "shared pass survived")
  -- Unsandboxed keys include the checkout path. Temporarily set aside
  -- its working database so a fresh consumer meets exactly the same key.
  assert(Fs.rename(build_paths.required(root), tmp .. "/saved-o"))
  local fresh = run("fresh", { "work_test.tl:test_b_observed_failure" }, false)
  assert(fresh:find("1 of 1 failed, 0 infrastructure errors", 1, true), fresh)
  assert(Fs.remove_tree(build_paths.required(root)))
  assert(Fs.rename(tmp .. "/saved-o", build_paths.required(root)))
  -- Another checkout may subsequently share a pass. The local failure
  -- still wins: deletion alone would allow this replacement to stand.
  local shared = assert(Sqlite.open(cache, { writable = true }))
  assert(shared:exec("INSERT INTO " .. declared ..
      " SELECT '" .. key .. "', 'work_test test_b_observed_failure', hits, elapsed_ns, used_ns, origin, parts FROM " ..
      declared .. " LIMIT 1"))
  assert(shared:close())
  assert(snapshot(cache, "SELECT key FROM " .. declared .. " WHERE key = '" .. key .. "'") == key)
  local again = run("again", { "work_test.tl:test_b_observed_failure" }, false)
  assert(again:find("1 of 1 failed, 0 infrastructure errors", 1, true), again)
end
