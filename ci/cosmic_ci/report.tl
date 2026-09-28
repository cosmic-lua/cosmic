-- `driver.tl report`: what CI's recent runs took and what their suites
-- ran, the figures doc/plan-fast-correct-builds.md's milestones are
-- decided on. For the last N completed runs of ci.yml of one event
-- (merge_group by default; a push's on main), newest first, it reads
-- through `gh` (found on PATH, as prerelease.tl finds it) each run's jobs
-- and their steps' times and each leg's `ci-driver-<leg>` artifact, the
-- operations database whose `suite_runs` rows orchestration.tl wrote,
-- and prints per run:
--
-- - the wall time of its slowest platform job (started_at..completed_at,
--   which leaves out queueing), each leg's time and its slowest steps;
-- - each suite's row: ran, stood, the share that stood, elapsed;
-- - whether it qualifies: its checked and native suites' runtime and
--   harness key parts are those of the run listed before it (the next
--   older), so it moved neither the core nor the test harness.
--
-- then the medians over the qualifying runs that succeeded. A run
-- older than `suite_runs`, or whose artifacts have expired, is reported
-- from its step times alone and qualifies for nothing.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local State = require("cosmic_ci.state")
local SuiteOutput = require("cosmic_ci.suite_output")
local Zip = require("cosmic.zip")

local record Report
  record Step
    name: string
    seconds: integer
  end
  record Job
    name: string
    seconds: integer | nil
    steps: {Step}
  end
  record Run
    id: string
    event: string
    branch: string
    sha: string
    conclusion: string
    attempt: string
    jobs: {Job}
    suites: {State.SuiteRun}
    --- Each `ci-driver-` artifact that could not be had, and why.
    missing: {string}
    qualifies: boolean
    why: string
  end
  record Artifact
    name: string
    id: string
    created: integer
  end
  record Options
    runs: integer
    event: string
    branch: string | nil
    repo: string
    workflow: string
    gh: string
    --- The environment gh runs in.
    env: {string:string}
  end
  spec: {string:Flags.Option}
end

--- The join job of ci.yml (`ci`): every other job of a run is a leg of
--- the platform matrix, named by its leg.
local join_job <const> = "ci"
--- The suites whose key parts decide whether a run qualifies: the
--- checked suite's and each leg's native one (orchestration.tl's
--- `record_suite` names them).
local deciding: {string:boolean} = { checked = true, ["local"] = true }
local capture_limit <const> = 1 << 30
--- How many runs older than the N shown `report` lists, to find one to
--- compare the oldest shown with.
local lookback <const> = 10
--- How many of a leg's slowest steps a run's table names.
local slowest_steps <const> = 3

Report.spec = {
  ["--runs"] = { value = "n", about = "how many completed runs to report (1 to 100; 10)" },
  ["--event"] = { value = "event", about = "the event whose runs to report (merge_group)" },
  ["--branch"] = { value = "branch", about = "the branch whose runs to report (main for push)" },
  ["--repo"] = { value = "owner/name",
    about = "the repository ($GITHUB_REPOSITORY, else cosmic-lua/cosmic)" },
  ["--workflow"] = { value = "file", about = "the workflow whose runs to report (ci.yml)" },
}

--- Seconds since 1970 of an ISO 8601 UTC time as GitHub writes one
--- ("2026-09-28T12:34:56Z"), or nil for anything else (JSON null).
function Report.seconds_of(value: any): integer | nil
  if not value is string then return nil end
  local y, mo, d, h, mi, s = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  local year, month = math.tointeger(tonumber(y)), math.tointeger(tonumber(mo))
  local day = math.tointeger(tonumber(d))
  -- Days from the civil date (Howard Hinnant's days_from_civil).
  if month <= 2 then year = year - 1 end
  local era = year // 400
  local yoe = year - era * 400
  local mp = (month + 9) % 12
  local doy = (153 * mp + 2) // 5 + day - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + math.tointeger(tonumber(h)) * 3600 +
    math.tointeger(tonumber(mi)) * 60 + math.tointeger(tonumber(s))
end

local function span(from: any, to: any): integer | nil
  local a, b = Report.seconds_of(from), Report.seconds_of(to)
  if a == nil or b == nil or b < a then return nil end
  return b - a
end

--- "13m 32s", "45s", or "-" for none.
function Report.duration(seconds: integer | nil): string
  if seconds == nil then return "-" end
  if seconds < 60 then return seconds .. "s" end
  return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

local function text_of(value: any): string
  if value is string then return value end
  if value is number then
    local whole = math.tointeger(value)
    if whole then return string.format("%d", whole) end
    return tostring(value)
  end
  return ""
end

--- The runs a `gh api .../runs` answer lists, in its order (newest
--- first), without their jobs or suites.
function Report.runs(text: string): {Report.Run}
  local answer = assert(Json.decode_object(text))
  local listed = answer.workflow_runs
  assert(listed is {any} and Json.is_array(listed), "the runs list is no array")
  local out: {Report.Run} = {}
  for _, item in ipairs(listed as {any}) do
    assert(item is {string:any}, "a run is no object")
    local run = item as {string:any}
    out[#out + 1] = { id = text_of(run.id), event = text_of(run.event),
      branch = text_of(run.head_branch), sha = text_of(run.head_sha),
      conclusion = text_of(run.conclusion), attempt = text_of(run.run_attempt),
      jobs = {}, suites = {}, missing = {}, qualifies = false, why = "" }
  end
  return out
end

--- The jobs a `gh api .../runs/<id>/jobs` answer lists, each with its
--- steps, slowest first.
function Report.jobs(text: string): {Report.Job}
  local answer = assert(Json.decode_object(text))
  local listed = answer.jobs
  assert(listed is {any} and Json.is_array(listed), "the jobs list is no array")
  local out: {Report.Job} = {}
  for _, item in ipairs(listed as {any}) do
    assert(item is {string:any}, "a job is no object")
    local job = item as {string:any}
    local steps: {Report.Step} = {}
    local listed_steps = job.steps
    if listed_steps is {any} and Json.is_array(listed_steps) then
      for _, entry in ipairs(listed_steps as {any}) do
        if entry is {string:any} then
          local step = entry as {string:any}
          local seconds = span(step.started_at, step.completed_at)
          if seconds then steps[#steps + 1] = { name = text_of(step.name), seconds = seconds } end
        end
      end
    end
    table.sort(steps, function(a: Report.Step, b: Report.Step): boolean
      return a.seconds > b.seconds
    end)
    out[#out + 1] = { name = text_of(job.name),
      seconds = span(job.started_at, job.completed_at), steps = steps }
  end
  return out
end

--- The `ci-driver-<leg>` artifacts a `gh api .../runs/<id>/artifacts`
--- answer lists that have not expired, sorted by name: of each name,
--- the newest (by `created_at`), which a run's latest attempt uploaded.
function Report.driver_artifacts(text: string): {Report.Artifact}
  local answer = assert(Json.decode_object(text))
  local listed = answer.artifacts
  assert(listed is {any} and Json.is_array(listed), "the artifacts list is no array")
  local newest: {string:Report.Artifact} = {}
  local names: {string} = {}
  for _, item in ipairs(listed as {any}) do
    if item is {string:any} then
      local artifact = item as {string:any}
      local name, id = text_of(artifact.name), text_of(artifact.id)
      local created = Report.seconds_of(artifact.created_at) or 0
      if name:match("^ci%-driver%-") and artifact.expired ~= true and id:match("^%d+$") then
        local held = newest[name]
        if held == nil then names[#names + 1] = name end
        if held == nil or created > held.created then
          newest[name] = { name = name, id = id, created = created }
        end
      end
    end
  end
  table.sort(names)
  local out: {Report.Artifact} = {}
  for _, name in ipairs(names) do out[#out + 1] = newest[name] end
  return out
end

local function platform_jobs(run: Report.Run): {Report.Job}
  local out: {Report.Job} = {}
  for _, job in ipairs(run.jobs) do
    if job.name ~= join_job then out[#out + 1] = job end
  end
  return out
end

--- The sum of a run's jobs' times, the join's included: what the run
--- cost in runner time.
function Report.runner_seconds(run: Report.Run): integer
  local sum = 0
  for _, job in ipairs(run.jobs) do sum = sum + (job.seconds or 0) end
  return sum
end

--- A run's slowest platform job, or nil where none has both times.
function Report.slowest(run: Report.Run): Report.Job | nil
  local slowest: Report.Job | nil = nil
  for _, job in ipairs(platform_jobs(run)) do
    if job.seconds and (slowest == nil or job.seconds > slowest.seconds) then slowest = job end
  end
  return slowest
end

local function deciding_rows(run: Report.Run): {string:State.SuiteRun}
  local rows: {string:State.SuiteRun} = {}
  for _, row in ipairs(run.suites) do
    if deciding[row.suite] then rows[row.worker .. " " .. row.suite] = row end
  end
  return rows
end

--- Sets `qualifies` and `why` of each of the first `shown` of `runs`,
--- newest first: a run qualifies when each of its checked and native
--- suites keyed its tests by the runtime and harness the same leg's
--- same suite did in the next older run of `runs` that has such rows
--- and was not cancelled: one that stopped short, or kept no artifact,
--- tells nothing of what the cache held. Runs past `shown` are only
--- compared against.
-- TODO: qualify a run by whether its key parts matched those of the
-- verdicts its restored cache held, as doc/plan-fast-correct-builds.md's
-- milestones define it, once `cosmic test --census` says the parts the
-- cache's rows were keyed by (build/shared_verdicts.tl's `census` counts
-- them and keeps no parts): the next older run with rows is only the
-- likeliest to have saved the cache this one restored, not surely it.
function Report.qualify(runs: {Report.Run}, shown?: integer)
  for i = 1, math.min(shown or #runs, #runs) do
    local run = runs[i]
    run.qualifies, run.why = false, ""
    local rows = deciding_rows(run)
    local earlier: Report.Run | nil = nil
    for j = i + 1, #runs do
      if runs[j].conclusion ~= "cancelled" and next(deciding_rows(runs[j])) ~= nil then
        earlier = runs[j]; break
      end
    end
    local keys: {string} = {}
    for key in pairs(rows) do keys[#keys + 1] = key end
    table.sort(keys)
    if #keys == 0 then
      run.why = "no checked or native suite rows"
    elseif earlier == nil then
      run.why = "no earlier run with suite rows listed to compare"
    else
      local before = deciding_rows(earlier)
      local moved: {string} = {}
      for _, key in ipairs(keys) do
        local now, was = rows[key].parts or {}, before[key] and before[key].parts
        if (now.runtime or "") == "" or (now.harness or "") == "" then
          moved[#moved + 1] = key .. ": no key parts"
        elseif was == nil then
          moved[#moved + 1] = key .. ": not in run " .. earlier.id
        else
          for _, part in ipairs({ "runtime", "harness" }) do
            if now[part] ~= was[part] then moved[#moved + 1] = key .. ": " .. part .. " moved" end
          end
        end
      end
      if #moved == 0 then
        run.qualifies = true
        run.why = "runtime and harness held since run " .. earlier.id
      else
        run.why = table.concat(moved, "; ")
      end
    end
  end
end

--- The median of `values`, or nil for none.
function Report.median(values: {number}): number | nil
  if #values == 0 then return nil end
  local sorted: {number} = {}
  for i, v in ipairs(values) do sorted[i] = v end
  table.sort(sorted)
  local middle = (#sorted + 1) // 2
  if #sorted % 2 == 1 then return sorted[middle] end
  return (sorted[middle] + sorted[middle + 1]) / 2
end

local function whole(value: number | nil): integer | nil
  if value == nil then return nil end
  return math.floor(value + 0.5)
end

local function suite_table(rows: {State.SuiteRun}): string
  local lines: {string} = { "| Leg | Suite | Status | Tests | Ran | Stood | Stood % | ms |\n",
    "|---|---|---|---:|---:|---:|---:|---:|\n" }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("| %s | %s | %s | %s | %s | %s | %s | %s |\n",
      row.worker or "", row.suite or "", row.status or "", tostring(row.tests or ""),
      tostring(row.ran or ""), tostring(row.stood or ""), SuiteOutput.stood_percent(row),
      tostring(row.elapsed_ms or ""))
  end
  return table.concat(lines)
end

--- `runs`, qualified (`qualify`), as the report's markdown.
function Report.render(runs: {Report.Run}, o: Report.Options): string
  local out: {string} = { string.format("# CI runs: %s, %s event%s, last %d\n",
    o.workflow, o.event, o.branch and (" on " .. o.branch) or "", #runs) }
  local qualifying: {Report.Run} = {}
  for _, run in ipairs(runs) do
    out[#out + 1] = string.format("\n## Run %s (%s, %s, attempt %s, %s)\n\n",
      run.id, run.conclusion, run.branch, run.attempt, run.sha:sub(1, 12))
    local slowest = Report.slowest(run)
    local wall = "-"
    if slowest ~= nil then
      wall = Report.duration(slowest.seconds) .. " (" .. slowest.name ..
        ", the slowest platform job)"
    end
    out[#out + 1] = "- Wall: " .. wall .. "\n"
    out[#out + 1] = "- Runner time: " .. Report.duration(Report.runner_seconds(run)) .. "\n"
    out[#out + 1] = "- Qualifies: " .. (run.qualifies and "yes" or "no") ..
      " (" .. run.why .. ")\n"
    for _, missing in ipairs(run.missing) do
      out[#out + 1] = "- Not read: " .. missing .. "\n"
    end
    out[#out + 1] = "\n| Leg | Time | Slowest steps |\n|---|---:|---|\n"
    for _, job in ipairs(platform_jobs(run)) do
      local named: {string} = {}
      for i = 1, math.min(slowest_steps, #job.steps) do
        named[i] = job.steps[i].name .. " " .. Report.duration(job.steps[i].seconds)
      end
      out[#out + 1] = "| " .. job.name .. " | " .. Report.duration(job.seconds) ..
        " | " .. table.concat(named, "; ") .. " |\n"
    end
    if #run.suites > 0 then
      out[#out + 1] = "\n" .. suite_table(run.suites)
    else
      out[#out + 1] = "\nNo suite rows: the run predates them, or its " ..
        "ci-driver artifacts are gone.\n"
    end
    if run.qualifies and run.conclusion == "success" then qualifying[#qualifying + 1] = run end
  end
  out[#out + 1] = string.format("\n## Medians over %d qualifying successful runs of %d\n\n",
    #qualifying, #runs)
  if #qualifying == 0 then
    out[#out + 1] = "None qualifies.\n"
    return table.concat(out)
  end
  local walls: {number} = {}
  local runner: {number} = {}
  local legs: {string:{number}} = {}
  local leg_names: {string} = {}
  local suites: {string:{string:{number}}} = {}
  local suite_names: {string} = {}
  for _, run in ipairs(qualifying) do
    local slowest = Report.slowest(run)
    if slowest then walls[#walls + 1] = slowest.seconds end
    runner[#runner + 1] = Report.runner_seconds(run)
    for _, job in ipairs(platform_jobs(run)) do
      if job.seconds then
        if not legs[job.name] then legs[job.name] = {}; leg_names[#leg_names + 1] = job.name end
        table.insert(legs[job.name], job.seconds)
      end
    end
    for _, row in ipairs(run.suites) do
      local key = row.worker .. " | " .. row.suite
      if not suites[key] then
        suites[key] = { ms = {}, stood = {}, ran = {} }; suite_names[#suite_names + 1] = key
      end
      if row.elapsed_ms then table.insert(suites[key].ms, row.elapsed_ms) end
      if row.ran then table.insert(suites[key].ran, row.ran) end
      local percent = tonumber(SuiteOutput.stood_percent(row))
      if percent then table.insert(suites[key].stood, percent) end
    end
  end
  table.sort(leg_names); table.sort(suite_names)
  out[#out + 1] = "- Wall: " .. Report.duration(whole(Report.median(walls))) .. "\n"
  out[#out + 1] = "- Runner time: " .. Report.duration(whole(Report.median(runner))) .. "\n"
  out[#out + 1] = "\n| Leg | Time |\n|---|---:|\n"
  for _, name in ipairs(leg_names) do
    out[#out + 1] = "| " .. name .. " | " .. Report.duration(whole(Report.median(legs[name]))) .. " |\n"
  end
  out[#out + 1] = "\n| Leg | Suite | Ran | Stood % | ms |\n|---|---|---:|---:|---:|\n"
  for _, key in ipairs(suite_names) do
    local figures = suites[key]
    local stood = Report.median(figures.stood)
    out[#out + 1] = "| " .. key .. " | " .. tostring(whole(Report.median(figures.ran)) or "") ..
      " | " .. (stood and string.format("%.1f", stood) or "") ..
      " | " .. tostring(whole(Report.median(figures.ms)) or "") .. " |\n"
  end
  return table.concat(out)
end

--- Runs gh with `args`; its stdout, or nil and why it failed.
local function gh(o: Report.Options, args: {string}): string | nil, string
  local argv: {string} = { o.gh }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, { env = o.env, stdin = "null", stdout = "capture",
    stderr = "capture", capture_limit = capture_limit })
  if result == nil then return nil, "gh " .. args[1] .. ": " .. trouble end
  if not result.ok then
    local said = (result.stderr or ""):gsub("%s+$", "")
    return nil, "gh " .. table.concat(args, " ") .. " failed" ..
      (said ~= "" and (": " .. said) or "")
  end
  return result.stdout or "", ""
end

local function api(o: Report.Options, endpoint: string): string
  local text, why = gh(o, { "api", endpoint })
  if text == nil then error(why, 0) end
  return text
end

--- The suite rows of `bytes`, an operations database, or nil and why
--- they cannot be read.
local function rows_of(bytes: string, path: string): {State.SuiteRun} | nil, string
  local written, why = Fs.write(path, bytes)
  if not written then return nil, why end
  local db, trouble = Sqlite.open(path)
  if db == nil then return nil, trouble end
  local called, rows = pcall(State.suite_rows, db)
  db:close()
  if not called then return nil, tostring(rows) end
  return rows as {State.SuiteRun}, ""
end

--- The operations database a `ci-driver-` artifact's zip, `zip`, holds,
--- or nil and why it holds none.
local function database_of(zip: string): string | nil, string
  local reader, why = Zip.open_string(zip)
  if reader == nil then return nil, why end
  local found: string | nil = nil
  local trouble = "no operations.db"
  for _, entry in ipairs(reader:entries()) do
    if entry.path == "operations.db" and entry.kind == "file" then
      local stream, opened = entry.open(entry)
      if stream == nil then trouble = opened
      else
        local bytes, read_trouble = Stream.read_all(stream)
        if bytes == nil then trouble = read_trouble else found = bytes end
      end
    end
  end
  reader:close()
  if found == nil then return nil, trouble end
  return found, ""
end

--- A run's suite rows, read from each of its `ci-driver-` artifacts --
--- its latest attempt's (`driver_artifacts`), fetched by id through the
--- API and written under `scratch`; each one that cannot be had is
--- named in its `missing` instead.
local function read_suites(o: Report.Options, run: Report.Run, scratch: string)
  local listed = api(o, "repos/" .. o.repo .. "/actions/runs/" .. run.id .. "/artifacts?per_page=100")
  for _, artifact in ipairs(Report.driver_artifacts(listed)) do
    local zip, why = gh(o, { "api", "repos/" .. o.repo .. "/actions/artifacts/" ..
      artifact.id .. "/zip" })
    local rows: {State.SuiteRun} | nil = nil
    if zip ~= nil then
      local database: string | nil
      database, why = database_of(zip)
      if database ~= nil then
        rows, why = rows_of(database, scratch .. "/" .. run.id .. "-" .. artifact.id .. ".db")
      end
    end
    if rows == nil then
      run.missing[#run.missing + 1] = artifact.name .. ": " .. why
    else
      for _, row in ipairs(rows) do run.suites[#run.suites + 1] = row end
    end
  end
end

--- The report for `o`: each run fetched through gh, qualified and
--- rendered.
function Report.report(o: Report.Options): string
  -- Runs past the N shown are listed too, up to `lookback` of them, so
  -- the oldest shown has an earlier run to be compared with
  -- (`qualify`); each one's rows are fetched only while no earlier run
  -- has any.
  local listed = math.min(o.runs + lookback, 100)
  local query = "status=completed&per_page=" .. listed .. "&event=" .. o.event
  if o.branch then query = query .. "&branch=" .. o.branch end
  local runs = Report.runs(api(o, "repos/" .. o.repo .. "/actions/workflows/" ..
    o.workflow .. "/runs?" .. query))
  local shown: {Report.Run} = {}
  for i = 1, math.min(o.runs, #runs) do shown[i] = runs[i] end
  local scratch = assert(Fs.mkdtemp("cosmic-ci-report-"))
  local called, trouble = pcall(function(): boolean
    for _, run in ipairs(shown) do
      run.jobs = Report.jobs(api(o, "repos/" .. o.repo .. "/actions/runs/" .. run.id ..
        "/jobs?per_page=100"))
      read_suites(o, run, scratch)
    end
    for i = #shown + 1, #runs do
      read_suites(o, runs[i], scratch)
      if runs[i].conclusion ~= "cancelled" and next(deciding_rows(runs[i])) ~= nil then
        break
      end
    end
    return true
  end)
  local removed, remove_trouble = Fs.remove_tree(scratch)
  if not called then error(trouble, 0) end
  assert(removed, remove_trouble)
  Report.qualify(runs, #shown)
  return Report.render(shown, o)
end

local function word(value: string): boolean
  return value:match("^[%w_.-]+$") ~= nil
end

--- A branch's name as the runs list takes it: `word`'s, and "/" between
--- them (feature/x, gh-readonly-queue/main/pr-1-...), with no ".."
--- and no "/" at either end.
local function branch_name(value: string): boolean
  return value:match("^[%w_./-]+$") ~= nil and not value:find("..", 1, true) and
    value:sub(1, 1) ~= "/" and value:sub(-1) ~= "/"
end

--- What `driver.tl report` answers for `got`, its line, in `env`, its
--- environment: the status, 0 with the report, 2 for a line it cannot
--- read, 1 where gh or GitHub failed; and what it says on stdout and on
--- stderr.
function Report.answer(got: Flags.Parsed, env: {string:string}): integer, string, string
  local function refuse(why: string): integer, string, string
    return 2, "", "driver.tl report: " .. why .. "\n"
  end
  if #got.words > 0 then return refuse("takes no words: " .. got.words[1]) end
  local runs = math.tointeger(tonumber(got.values["--runs"] or "10"))
  if runs == nil or runs < 1 or runs > 100 then
    return refuse("--runs must be a whole number from 1 to 100")
  end
  local event = got.values["--event"] or "merge_group"
  local branch = got.values["--branch"]
  if branch == nil and event == "push" then branch = "main" end
  local repository = got.values["--repo"] or env.GITHUB_REPOSITORY or ""
  if repository == "" then repository = "cosmic-lua/cosmic" end
  local workflow = got.values["--workflow"] or "ci.yml"
  if branch and not branch_name(branch) then
    return refuse("not a branch name: " .. branch)
  end
  for _, value in ipairs({ event, workflow }) do
    if not word(value) then return refuse("not a plain name: " .. value) end
  end
  if not repository:match("^[%w_.-]+/[%w_.-]+$") then
    return refuse("--repo must be owner/name: " .. repository)
  end
  local found, why = Proc.find("gh", env.PATH or "")
  if found == nil then return 1, "", "driver.tl report: no gh on PATH: " .. why .. "\n" end
  local called, answer = pcall(Report.report, { runs = runs, event = event,
    branch = branch, repo = repository, workflow = workflow, gh = found, env = env })
  if not called then return 1, "", "driver.tl report: " .. tostring(answer) .. "\n" end
  return 0, answer as string, ""
end

--- `driver.tl report [options]`, in this process's environment.
function Report.command(got: Flags.Parsed): integer
  local code, out, err = Report.answer(got, Env.all())
  if out ~= "" then Fs.put(Fs.stdout, out) end
  if err ~= "" then Fs.put(Fs.stderr, err) end
  return code
end

return Report
