--- Waits for the jobs of this run that others' results stand on (ci.yml's
--- "wait for the shares" in `checked`: the four shares of the checked
--- suite, which `checked` gathers after its own boot and build), asking
--- the API as queue_seed.tl does, and writes to $GITHUB_OUTPUT
--- `result=<success|failure|timeout>` and `failed=<names>`:
---
--- - `success`, once every job of JOBS (blank-separated names) completed
---   with success;
--- - `failure`, as soon as one of them completed with anything else
---   (failure, cancelled, skipped, timed out), naming it in `failed`, or
---   has run longer than SHARE_SECONDS since it started, which its own
---   timeout-minutes forbids, so the API's answer is no sign it will finish;
--- - `timeout`, once LIMIT_SECONDS have passed since the step began with
---   one not completed, or none listed (a job still queued has no start to
---   bound, so this alone ends a wait for one that never gets a runner).
---
--- It reads the jobs of the run's latest execution (`filter=latest`, the
--- API's default), not of one attempt: a re-run of the failed jobs lists
--- the jobs it carried over from the attempt before, which an attempt's
--- own listing leaves out. A job listed more than once is read by its
--- newest start. A call that fails is asked again after WAIT_SECONDS (20),
--- until LIMIT_SECONDS. A job not listed counts as not completed. It never
--- fails its step but for an environment it cannot read (2): the step's
--- `if` decides what each result does. Each call is cut off after
--- CALL_SECONDS (15).
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Shape = require("cosmic.shape")
local Time = require("cosmic.time")

local record SharesWait
  --- `wait` in `env` (the process's environment) over `host`: 0, or 2
  --- for a line it cannot read.
  wait: function(env: {string:string}, host: Github.Host): integer
  --- `driver.tl shares-wait`, in the process's environment.
  command: function(argv: {string}): integer
end

--- A whole number of seconds `env` names, `default` where it names none.
local function whole(env: {string:string}, name: string, default: integer): integer?, string
  local text = env[name]
  if text == nil or text == "" then return default, "" end
  local value = math.tointeger(tonumber(text))
  if value == nil or value < 0 then
    return nil, name .. " is no whole number of seconds: " .. text
  end
  return value, ""
end

local record JobRow
  name?: any
  status?: any
  conclusion?: any
  started_at?: any
end
local record JobsPage
  jobs: {JobRow}
end
local JOBS_PAGE <const> = Shape.record_of("JobsPage")

--- A job as the API lists it.
local record Job
  completed: boolean
  conclusion: string
  --- Seconds since the epoch where it has started.
  started?: integer
end

--- The jobs of the run's listing by name (the newest start of each), or
--- nil where the answer holds no list of jobs or a start is no time.
local function jobs_of(pages: {string}): {string:Job}?
  local out: mut {string:Job} = {}
  for _, text in ipairs(pages) do
    local page, _ = JOBS_PAGE:decode_into(text)
    if page == nil then return nil end
    for _, row in ipairs(page.jobs) do
      local started: integer? = nil
      if row.started_at ~= nil and row.started_at ~= "" then
        local ns, _ = Time.parse_rfc3339(tostring(row.started_at))
        if ns == nil then return nil end
        started = ns // 1000000000
      end
      local name = tostring(row.name)
      local seen = out[name]
      if seen == nil or (started or 0) >= (seen.started or 0) then
        out[name] = { completed = row.status == "completed",
          conclusion = if row.conclusion == nil then "none" else tostring(row.conclusion) end,
          started = started }
      end
    end
  end
  return out
end

function SharesWait.wait(env: {string:string}, host: Github.Host): integer
  local function refuse(why: string): integer
    local _, _ = Fs.put(Fs.stderr, "shares-wait: " .. why .. "\n")
    return 2
  end
  local repository, run = env["REPOSITORY"] or "", env["RUN_ID"] or ""
  if repository == "" or run == "" then return refuse("no REPOSITORY or RUN_ID") end
  local names: mut {string} = {}
  for name in (env["JOBS"] or ""):gmatch("%S+") do names[#names + 1] = name end
  if #names == 0 then return refuse("no JOBS") end
  local call, wait, limit, share: integer?, integer?, integer?, integer?
  local why: string
  call, why = whole(env, "CALL_SECONDS", 15)
  if call == nil then return refuse(why) end
  wait, why = whole(env, "WAIT_SECONDS", 20)
  if wait == nil then return refuse(why) end
  limit, why = whole(env, "LIMIT_SECONDS", 3000)
  if limit == nil then return refuse(why) end
  share, why = whole(env, "SHARE_SECONDS", 1620)
  if share == nil then return refuse(why) end
  local path = "repos/" .. repository .. "/actions/runs/" .. run .. "/jobs?per_page=100"
  local deadline = host.now() + limit
  local result, failed = "", ""
  while true do
    local pages = Github.ask(host, path, false, call)
    local listed = pages and jobs_of(pages) or nil
    if listed ~= nil then
      local pending: mut {string} = {}
      local bad: mut {string} = {}
      for _, name in ipairs(names) do
        local job = listed[name]
        if job == nil then
          pending[#pending + 1] = name
        elseif job.completed then
          if job.conclusion ~= "success" then
            bad[#bad + 1] = name .. " (" .. job.conclusion .. ")"
          end
        elseif job.started ~= nil and host.now() > job.started + share then
          bad[#bad + 1] = name .. " (still running " .. tostring(share) .. " s after it started)"
        else
          pending[#pending + 1] = name
        end
      end
      if #bad > 0 then
        result, failed = "failure", table.concat(bad, ", ")
        break
      elseif #pending == 0 then
        result = "success"
        break
      end
      host.print("waiting for: " .. table.concat(pending, ", "))
    end
    if host.now() + wait > deadline then
      result = "timeout"
      break
    end
    host.sleep(wait)
  end
  host.output("result=" .. result)
  host.output("failed=" .. failed)
  if result == "success" then
    Github.say(host, "every share of the checked suite passed: the gathering suite takes their verdicts.")
  elseif result == "failure" then
    Github.say(host, "a share of the checked suite did not pass: " .. failed .. ".")
  else
    Github.say(host, "the shares of the checked suite did not finish within " .. tostring(limit) .. " s.")
  end
  return 0
end

function SharesWait.command(_argv: {string}): integer
  local env = Env.all()
  return SharesWait.wait(env, Github.live(env))
end

return SharesWait
