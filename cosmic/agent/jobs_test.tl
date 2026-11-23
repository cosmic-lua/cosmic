--- Background jobs: bash started in the background, read, waited for,
--- killed, and ended with the session, under the policy.

local agent_fixture = require("build.agent_fixture")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Jobs = require("cosmic.agent.jobs")
local Policy = require("cosmic.agent.policy")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ profiles = { "system" }, env = { "PATH", "TMPDIR" }, promises = { "nest" }, requires = { "nest" } }

local scratch = agent_fixture.scratch

local function test_background_jobs_run_until_read_killed_or_the_session_ends()
  local dir = scratch()
  local set = Jobs.new()
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local ctx: Tools.Context = { cwd = dir, policy = p, jobs = set }
  local r = Tools.run("bash", { command = "echo started; sleep 30", background = true }, ctx)
  assert(not r.is_error and r.text:find("Started job 1", 1, true) ~= nil, r.text)
  r = Tools.run("bash", { command = "for i in $(seq 3000); do echo line$i; done; echo err >&2; exit 3",
    background = true }, ctx)
  assert(r.text:find("Started job 2", 1, true) ~= nil, r.text)
  assert(Tools.run("bash", { command = "true", background = "yes" }, ctx).is_error)
  -- Waited for: the last of its output, all of it kept, the status an error.
  r = Tools.run("jobs", { id = 2, wait = 20 }, ctx)
  assert(r.is_error and r.text:find("exited with code 3", 1, true) ~= nil, r.text)
  assert(r.text:find("err\n", 1, true) ~= nil and r.text:find("Showing the last lines", 1, true) ~= nil, r.text)
  assert((r.raw or ""):sub(1, 6) == "line1\n", r.raw)
  r = Tools.run("jobs", { id = 2 }, ctx)
  assert(r.text:find("(no new output)", 1, true) ~= nil and r.raw == nil, r.text)
  -- A command run meanwhile leaves the jobs running.
  assert(not Tools.run("bash", { command = "true" }, ctx).is_error)
  r = Tools.run("jobs", { id = 1, wait = 1 }, ctx)
  assert(not r.is_error and r.text:find("Job 1 running", 1, true) ~= nil and r.text:find("started", 1, true) ~= nil,
    r.text)
  r = Tools.run("jobs", {}, ctx)
  assert(r.text:find("job 1  running", 1, true) ~= nil and r.text:find("job 2  exited", 1, true) ~= nil, r.text)
  r = Tools.run("jobs", { id = 1, kill = true }, ctx)
  assert(not r.is_error and r.text:find("Job 1 killed", 1, true) ~= nil and r.raw ~= nil, r.text)
  -- A character half written waits for its end.
  assert(not Tools.run("bash", { command = "printf 'a\\303'; sleep 1; printf '\\251\\n'", background = true },
    ctx).is_error)
  local half = assert(Jobs.find(set, 3))
  for _ = 1, 250 do
    if Jobs.size(half) >= 2 then break end
    local _, _ = Clock.sleep_ns(Clock.ms(20))
  end
  r = Tools.run("jobs", { id = 3 }, ctx)
  assert(r.text:find("\n\na$") ~= nil, r.text)
  r = Tools.run("jobs", { id = 3, wait = 10 }, ctx)
  assert(r.text:find("\n\n\195\169$") ~= nil, r.text)
  assert(Tools.run("jobs", { id = 9 }, ctx).is_error and Tools.run("jobs", { kill = true }, ctx).is_error)
  assert(Tools.run("jobs", {}, { cwd = dir }).is_error)
  -- The session's end ends the rest, and hands on what was not read.
  assert(not Tools.run("bash", { command = "echo unread; sleep 30", background = true }, ctx).is_error)
  local job = assert(Jobs.find(set, 4))
  -- Once it has said what it says: a sandbox takes a moment to start.
  for _ = 1, 100 do
    if Jobs.size(job) > 0 then break end
    local _, _ = Clock.sleep_ns(Clock.ms(50))
  end
  local handed: mut {string} = {}
  Jobs.close(set, function(j: Jobs.Job, output: string)
    local entry = tostring(j.id) .. ":" .. output
    handed[#handed + 1] = entry
  end)
  assert(#handed == 1 and handed[1] == "4:unread\n" and job.result ~= nil, table.concat(handed, ","))
  assert(not assert(Fs.status(job.file)).exists)
end
