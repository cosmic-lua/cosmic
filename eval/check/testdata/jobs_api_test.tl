--- The jobs task's hidden API test: eval/check/grade.tl runs it
--- against a copy of a solver's project, never shown to the solver.
local jobs = require("jobs")

local function test_a_plan_fills_in_what_a_job_leaves_out()
  local plan, why = jobs.plan('{"b": {"cmd": ["/bin/true"]}}')
  assert(plan ~= nil, why)
  local job: jobs.Job = plan.jobs["b"]
  assert(job.name == "b", "name " .. tostring(job.name))
  assert(#job.cmd == 1 and job.cmd[1] == "/bin/true", "cmd")
  assert(#job.needs == 0, "needs")
  assert(job.timeout == nil, "timeout " .. tostring(job.timeout))
  assert(job.retries == 0 and math.type(job.retries) == "integer", "retries")
  assert(next(job.env) == nil, "env")
  assert(job.cwd == nil, "cwd")
end

local function test_a_plan_keeps_each_field()
  local plan, why = jobs.plan([[{"a": {"cmd": ["/bin/sh", "-c", "exit 0"], "timeout": 0.5,
    "retries": 2, "env": {"X": "1"}, "cwd": "/tmp", "needs": []}}]])
  assert(plan ~= nil, why)
  local job = plan.jobs["a"]
  assert(job.cmd[3] == "exit 0", "cmd")
  assert(job.timeout * 4 == 2, "timeout " .. tostring(job.timeout))
  assert(job.retries + 1 == 3 and math.type(job.retries) == "integer", "retries")
  assert(job.env["X"] == "1", "env")
  assert(job.cwd == "/tmp", "cwd")
end

local function test_a_plan_orders_jobs_after_their_needs_then_by_name()
  local plan, why = jobs.plan([[{
    "d": {"cmd": ["/bin/true"]},
    "b": {"cmd": ["/bin/true"], "needs": ["c"]},
    "c": {"cmd": ["/bin/true"], "needs": ["a"]},
    "a": {"cmd": ["/bin/true"]}
  }]])
  assert(plan ~= nil, why)
  local order = table.concat(plan.order, " ")
  assert(order == "a c b d", "order " .. order)
end

local function test_a_plan_refuses_the_first_problem_exactly()
  local cases: {{string}} = {
    { '[{"cmd": ["/bin/true"]}]', "jobfile: must be an object of jobs" },
    { '{"build": 5}', "job build: must be an object" },
    { '{"build": {"cmd": "make"}}', "job build: cmd must be a non-empty array of strings" },
    { '{"build": {"cmd": []}}', "job build: cmd must be a non-empty array of strings" },
    { '{"build": {}}', "job build: cmd must be a non-empty array of strings" },
    { '{"build": {"cmd": ["/bin/true", 3]}}',
      "job build: cmd must be a non-empty array of strings" },
    { '{"build": {"cmd": ["/bin/true"], "needs": "a"}}',
      "job build: needs must be an array of strings" },
    { '{"build": {"cmd": ["/bin/true"], "timeout": "5"}}',
      "job build: timeout must be a positive number" },
    { '{"build": {"cmd": ["/bin/true"], "timeout": 0}}',
      "job build: timeout must be a positive number" },
    { '{"build": {"cmd": ["/bin/true"], "retries": 1.5}}',
      "job build: retries must be a non-negative integer" },
    { '{"build": {"cmd": ["/bin/true"], "retries": -1}}',
      "job build: retries must be a non-negative integer" },
    { '{"build": {"cmd": ["/bin/true"], "env": {"A": 1}}}',
      "job build: env must be an object of strings" },
    { '{"build": {"cmd": ["/bin/true"], "cwd": 5}}', "job build: cwd must be a string" },
    { '{"build": {"cmd": ["/bin/true"], "zeta": 1, "alpha": 2}}',
      "job build: unknown field alpha" },
    { '{"z": {"cmd": 1}, "a": {"cmd": ["/bin/true"], "timeout": -1, "retries": -1}}',
      "job a: timeout must be a positive number" },
    { '{"a": {"cmd": ["/bin/true"], "needs": ["ghost"]}, "b": {"cmd": 1}}',
      "job b: cmd must be a non-empty array of strings" },
    { '{"b": {"cmd": ["/bin/true"], "needs": ["x", "y"]}, "a": {"cmd": ["/bin/true"], ' ..
        '"needs": ["c", "ghost"]}, "c": {"cmd": ["/bin/true"]}}',
      "job a: needs unknown job ghost" },
  }
  for _, case in ipairs(cases) do
    local plan, why = jobs.plan(case[1])
    assert(plan == nil, "a plan for " .. case[1])
    assert(why == case[2], case[1] .. " -> '" .. tostring(why) .. "', wanted '" .. case[2] .. "'")
  end
end

local function test_a_plan_refuses_a_cycle_naming_a_job_in_it()
  local plan, why = jobs.plan([[{"free": {"cmd": ["/bin/true"]},
    "x": {"cmd": ["/bin/true"], "needs": ["y"]}, "y": {"cmd": ["/bin/true"], "needs": ["x"]}}]])
  assert(plan == nil, "a plan for a cycle")
  assert(why == "job x: needs form a cycle" or why == "job y: needs form a cycle", why)
end

-- Every member must type-check as a `jobs.Status`; nothing a test can
-- compile tells an enum from an alias of string, which would pass too.
local function test_status_holds_the_five_words()
  local all: {jobs.Status} = { "ok", "failed", "timeout", "skipped", "interrupted" }
  local seen: {jobs.Status: boolean} = {}
  for _, status in ipairs(all) do
    seen[status] = true
  end
  assert(seen["interrupted"] and #all == 5)
end
