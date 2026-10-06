local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local GithubApi = require("cosmic_ci.github_api")
local Report = require("cosmic_ci.report")
local State = require("cosmic_ci.state")
local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local repository <const> = "owner/repo"

local function test_seconds_of_reads_githubs_times()
  assert(Report.seconds_of("1970-01-01T00:00:00Z") == 0)
  assert(Report.seconds_of("2000-03-01T00:00:01Z") == 951868801)
  assert(Report.seconds_of("2026-09-28T12:34:56Z") == 1790598896)
  assert(Report.seconds_of("2024-02-29T23:59:59Z") == 1709251199)
  assert(Report.seconds_of(nil) == nil and Report.seconds_of("yesterday") == nil)
  assert(Report.seconds_of(12) == nil)
  assert(Report.duration(45) == "45s" and Report.duration(812) == "13m 32s")
  assert(Report.duration(nil) == "-")
end

--- The lists the API answers are checked against the records `Report`
--- reads: a value of another shape is refused naming where it is, where
--- the entries once read as empty, were skipped, or were taken as text.
local function test_an_answer_of_another_shape_is_refused_by_path()
  local function refused(read: function(string): any, text: string, list: string,
                         at: string, expected: string)
    local ok, why = pcall(read, text)
    assert(not ok, "accepted " .. text)
    local said = tostring(why)
    assert(said:find("the " .. list .. " list: ", 1, true) and said:find('pointer "' .. at .. '": expected ' .. expected, 1, true),
      ("wanted %s at %s, expected %s; got %q"):format(list, at, expected, said))
  end
  refused(Report.runs, "[]", "runs", "", "record, got array")
  refused(Report.runs, '{"workflow_runs":[7]}', "runs", "/workflow_runs/0", "record, got integer")
  refused(Report.runs, '{"workflow_runs":[{"event":"push","head_sha":"s"}]}', "runs",
    "/workflow_runs/0/id", "integer, got nothing")
  refused(Report.runs, '{"workflow_runs":[{"id":"7","event":"push","head_sha":"s"}]}', "runs",
    "/workflow_runs/0/id", "integer, got string")
  refused(Report.jobs, '{"jobs":[{"name":"a","steps":[7]}]}', "jobs", "/jobs/0/steps/0", "record, got integer")
  refused(Report.jobs, '{"jobs":[{"name":"a","started_at":12}]}', "jobs", "/jobs/0/started_at",
    "string, got integer")
  refused(Report.driver_artifacts, '{"artifacts":[{"name":"ci-driver-x","id":"9"}]}', "artifacts",
    "/artifacts/0/id", "integer, got string")
  refused(Report.driver_artifacts, '{"artifacts":{"a":1}}', "artifacts", "/artifacts",
    "list, got the string key")
  -- The nulls GitHub writes for what it has not got are nothing.
  local runs = Report.runs('{"workflow_runs":[{"id":7,"event":"push","head_sha":"s",' ..
      '"head_branch":null,"conclusion":null,"run_attempt":null}]}')
  assert(runs[1].id == "7" and runs[1].branch == "" and runs[1].conclusion == "" and
      runs[1].attempt == "", runs[1].branch)
  assert(#Report.jobs('{"jobs":[{"name":"a","started_at":null,"completed_at":null}]}') == 1)
end

local function test_median()
  assert(Report.median({}) == nil)
  assert(Report.median({ 3, 1, 2 }) == 2)
  assert(Report.median({ 4, 1, 3, 2 }) == 2.5)
end

--- A push to main that reuses the queue's run has no platform legs but
--- `reuse` and the `seed` legs, which are none: its wall is no seed's,
--- and it adds no row to the legs' medians. The checked job, beside the
--- legs, is one, and a run's wall where it is the slowest.
local function test_reuse_and_seed_are_no_platform_jobs()
  for _, name in ipairs({ "ci", "reuse", "seed", "seed (macos-aarch64, macos-15)",
      "seed (linux-x86_64-checked, ubuntu-24.04, true)" }) do
    assert(not Report.is_platform_job(name), name)
  end
  for _, name in ipairs({ "linux-x86_64", "macos-aarch64", "linux-x86_64-checked", "seeder" }) do
    assert(Report.is_platform_job(name), name)
  end
  local run: Report.Run = { id = "1", event = "push", branch = "main", sha = "a", conclusion = "success",
    attempt = "1", suites = {}, missing = {}, qualifies = false, why = "", jobs = {
      { name = "reuse", seconds = 20, steps = {} },
      { name = "seed (macos-aarch64, macos-15)", seconds = 90, steps = {} },
      { name = "ci", seconds = 120, steps = {} },
    } }
  assert(Report.slowest(run) == nil, "a seeded run's slowest platform job")
  table.insert(run.jobs, { name = "linux-x86_64", seconds = 60, steps = {} })
  assert((Report.slowest(run) as Report.Job).name == "linux-x86_64")
  table.insert(run.jobs, { name = "linux-x86_64-checked", seconds = 61, steps = {} })
  assert((Report.slowest(run) as Report.Job).name == "linux-x86_64-checked")
end

--- A run whose rows say what its restored cache held qualifies by
--- that, not by the run before it: its own parts among the cache's,
--- though the earlier run's harness differs, qualifies; parts the cache
--- did not hold, though the earlier run's are the same, do not; nor
--- does an empty cache. A row from before the census falls back to the
--- earlier run.
local function test_a_run_qualifies_by_what_its_restored_cache_held()
  local function run(id: string, harness: string, held?: string): Report.Run
    local suites: {State.SuiteRun} = {}
    for _, suite in ipairs({ "local", "checked" }) do
      suites[#suites + 1] = { worker = "linux-x86_64", suite = suite,
        parts = { runtime = "rrrr", harness = harness }, held = held }
    end
    return { id = id, conclusion = "success", jobs = {}, suites = suites, missing = {} }
  end
  local runs = {
    run("50", "h2", "10 rows under runtime rrrr, harness h2; 2 rows under no parts named"),
    run("40", "h1", "12 rows under runtime rrrr, harness h2"),
    run("30", "h1", ""),
    run("20", "h1"),
    run("10", "h9"),
  }
  Report.qualify(runs, 4)
  assert(runs[1].qualifies, runs[1].why)
  assert(runs[1].why == "runtime and harness epoch and timeout among the restored cache's " ..
      "(linux-x86_64 checked: 10 of 12 rows; linux-x86_64 local: 10 of 12 rows)", runs[1].why)
  assert(not runs[2].qualifies and runs[2].why == "linux-x86_64 checked: runtime or harness " ..
      "not among the restored cache's (12 rows); linux-x86_64 local: runtime or harness not " ..
      "among the restored cache's (12 rows)", runs[2].why)
  assert(not runs[3].qualifies and
      runs[3].why:find("linux-x86_64 local: the restored cache held no rows", 1, true), runs[3].why)
  assert(not runs[4].qualifies and runs[4].why:find("harness moved", 1, true), runs[4].why)
  -- Restored rows that name no parts (a cache kept from before rows
  -- named them) tell nothing: the earlier run decides, and the reason
  -- says so.
  local unnamed = "7 rows under no parts named"
  runs = { run("70", "h1", unnamed), run("60", "h1"), run("55", "h1", unnamed), run("50", "h0") }
  Report.qualify(runs, 3)
  assert(runs[1].qualifies and runs[1].why == "restored rows name no parts; runtime and " ..
      "harness epoch and timeout held since run 60", runs[1].why)
  assert(not runs[3].qualifies and runs[3].why:find("linux-x86_64 local: restored rows name " ..
      "no parts, harness moved", 1, true), runs[3].why)
end

--- A fake GitHub: a `Send` answering from `answers`, by the path it was
--- asked for, and logging each path in `calls`. An artifact's zip is
--- served as GitHub does, a redirect to a link `fetch` writes from `zips`.
local record Fake
  answers: {string:string}
  zips: {string:string}
  calls: {string}
  client: GithubApi.Client
  env: {string:string}
  dir: string
end

local api <const> = "https://api.test/"

local function fake(tmp: string): Fake
  local f: Fake = { answers = {}, zips = {}, calls = {}, dir = tmp, env = Env.all() } as Fake
  f.client = {
    base = "https://api.test",
    send = function(request: GithubApi.Request): GithubApi.Reply | nil, string
      assert(request.method == "GET" and request.url:sub(1, #api) == api, request.url)
      local path = request.url:sub(#api + 1)
      f.calls[#f.calls + 1] = path
      if f.zips[path] then
        return { status = 302, headers = { location = "https://blob.test/" .. path }, body = "" }, ""
      end
      local text = f.answers[path]
      if text == nil then
        return { status = 404, headers = {}, body = '{"message":"Not Found"}' }, ""
      end
      return { status = 200, headers = {}, body = text }, ""
    end,
    fetch = function(url: string, to: string): boolean, string
      local zip = f.zips[url:sub(#"https://blob.test/" + 1)]
      if zip == nil then return false, "HTTP 404" end
      return Fs.write(to, zip)
    end,
  }
  f.env.GITHUB_REPOSITORY = nil
  return f
end

local function answer(f: Fake, endpoint: string, value: any)
  f.answers[endpoint] = assert(Json.encode(value))
end

local function at(minutes: integer, seconds?: integer): string
  return string.format("2026-09-28T10:%02d:%02dZ", minutes, seconds or 0)
end

--- A run's jobs: two legs and the join, the first leg `slow` minutes long.
local function jobs(f: Fake, id: string, slow: integer)
  answer(f, "repos/" .. repository .. "/actions/runs/" .. id .. "/jobs?per_page=100", { jobs = {
    { name = "linux-x86_64", started_at = at(0), completed_at = at(slow), steps = {
      { name = "set up", started_at = at(0), completed_at = at(0, 5) },
      { name = "assemble", started_at = at(1), completed_at = at(slow - 1) },
      { name = "build", started_at = at(0, 5), completed_at = at(1) },
      { name = "skipped", started_at = Json.null, completed_at = Json.null },
    } },
    { name = "macos-aarch64", started_at = at(0), completed_at = at(8), steps = Json.array() },
    { name = "ci", started_at = at(0), completed_at = at(59), steps = Json.array() },
  } })
end

--- A `ci-driver-linux-x86_64` artifact `id`, as the API serves it: a
--- zip of an operations database holding run `run`'s native, checked
--- and one fixture's suite rows, those two keyed by `runtime` and
--- `harness`, `stood` of 100 tests standing.
local function artifact_zip(f: Fake, id: string, run: string, runtime: string,
                            harness: string, stood: integer)
  local database = f.dir .. "/db-" .. id
  for _, suite in ipairs({ "local", "checked", "fixture runtime-regression" }) do
    local keyed = not suite:match("^fixture")
    State.suite(database, { worker = "linux-x86_64", run = run, attempt = "1",
      phase = suite == "local" and "build" or "assemble", suite = suite, status = "pass",
      exit_code = 0, tests = 100, ran = 100 - stood, stood = stood, elapsed_ms = 1000 * stood,
      parts = keyed and { runtime = runtime, harness = harness } or {} })
  end
  local path = f.dir .. "/zip-" .. id
  local stream = assert(Stream.create(path))
  local zip = Zip.writer(stream, { deterministic = true })
  assert(zip:add_file("operations.db", (assert(Fs.read(database)))))
  assert(zip:close())
  f.zips["repos/" .. repository .. "/actions/artifacts/" .. id .. "/zip"] = assert(Fs.read(path))
end

--- Run `run`'s artifacts list: `listed`, each {name, id, created, expired}.
local function artifacts(f: Fake, run: string, listed: {{string:any}})
  answer(f, "repos/" .. repository .. "/actions/runs/" .. run .. "/artifacts?per_page=100",
    { artifacts = #listed > 0 and listed or Json.array() })
end

--- Run `run`'s one ci-driver artifact, and two it does not read.
local function artifact(f: Fake, run: string, runtime: string, harness: string,
                        stood: integer)
  local id = run .. "1"
  artifact_zip(f, id, run, runtime, harness, stood)
  artifacts(f, run, {
    { name = "ci-driver-linux-x86_64", id = math.tointeger(tonumber(id)), expired = false,
      created_at = at(1) },
    { name = "portable-product-linux-x86_64", id = 7, expired = false, created_at = at(1) },
    { name = "ci-driver-macos-aarch64", id = 8, expired = true, created_at = at(1) },
  })
end

local function run_entry(id: integer, conclusion: string, attempt: integer): {string:any}
  return { id = id, event = "merge_group",
    head_branch = "gh-readonly-queue/main/pr-" .. id,
    head_sha = string.rep(tostring(id % 10), 40), conclusion = conclusion,
    run_attempt = attempt }
end

local record Answer
  code: integer
  ok: boolean
  stdout: string
end

--- `driver.tl report` with `args`, in `f`'s environment; an unreadable
--- line answers 2, as the driver's dispatch does.
local function report(f: Fake, args: {string}): Answer, string
  local argv: {integer:string} = { [0] = "report" }
  for i, word in ipairs(args) do argv[i] = word end
  local got, why = Flags.parse(argv, 1, Report.spec)
  if got == nil then return { code = 2, ok = false, stdout = "" }, why end
  local code, out, err = Report.answer(got, f.env, f.client)
  return { code = code, ok = code == 0, stdout = out }, out .. err
end

--- Six merge-queue runs, newest first, four shown (--runs 4):
--- - 40 moved the harness from 30's;
--- - 30 held 20's: the runs between were cancelled (25) or kept no
---   artifact (22), and tell nothing;
--- - 25, cancelled, moved it from 20's;
--- - 22 has no suite rows, and is reported from step times alone;
--- - 20, past those shown, is fetched to compare with: its re-run's
---   artifact (the newer of two of one name) holds h1;
--- - 10 is listed but never fetched, 20 having rows.
local function test_report_reads_runs_jobs_and_suite_rows(tmp: string)
  local f = fake(tmp)
  answer(f, "repos/" .. repository .. "/actions/workflows/ci.yml/runs?status=completed" ..
      "&per_page=14&event=merge_group", { workflow_runs = {
        run_entry(40, "success", 1), run_entry(30, "success", 1),
        run_entry(25, "cancelled", 1), run_entry(22, "failure", 1),
        run_entry(20, "success", 2), run_entry(10, "success", 1) } })
  jobs(f, "40", 13)
  jobs(f, "30", 11)
  jobs(f, "25", 12)
  jobs(f, "22", 14)
  artifact(f, "40", "rrrr", "h2", 90)
  artifact(f, "30", "rrrr", "h1", 100)
  artifact(f, "25", "rrrr", "h9", 50)
  artifacts(f, "22", {})
  artifact_zip(f, "201", "20", "rrrr", "stale", 10)
  artifact_zip(f, "202", "20", "rrrr", "h1", 60)
  artifacts(f, "20", {
    { name = "ci-driver-linux-x86_64", id = 201, expired = false, created_at = at(1) },
    { name = "ci-driver-linux-x86_64", id = 202, expired = false, created_at = at(30) },
  })
  local result, said = report(f, { "--runs", "4", "--repo", repository })
  assert(result.ok, said)
  local text = result.stdout or ""
  local function has(needle: string)
    assert(text:find(needle, 1, true), "the report lacks " .. needle .. ":\n" .. text)
  end
  has("# CI runs: ci.yml, merge_group event, last 4")
  has("## Run 40 (success, gh-readonly-queue/main/pr-40, attempt 1, 000000000000)")
  has("- Wall: 13m 00s (linux-x86_64, the slowest platform job)")
  has("- Qualifies: no (linux-x86_64 checked: harness moved; linux-x86_64 local: harness moved)")
  has("- Qualifies: yes (runtime and harness epoch and timeout held since run 20)")
  has("- Qualifies: no (no checked or native suite rows)")
  has("| linux-x86_64 | 13m 00s | assemble 11m 00s; build 55s; set up 5s |")
  has("| macos-aarch64 | 8m 00s |  |")
  has("| linux-x86_64 | checked | pass | 100 | 0 | 100 | 100.0 | 100000 |")
  has("| linux-x86_64 | local | pass | 100 | 50 | 50 | 50.0 | 50000 |")
  has("No suite rows: the run predates them")
  -- 25 is compared with 20's newer artifact, not its stale one.
  local run25 = text:match("## Run 25 .-\n## Run 22")
  assert(run25 and run25:find("harness moved", 1, true), tostring(run25))
  -- Only the runs shown are.
  assert(not text:find("## Run 20", 1, true) and not text:find("## Run 10", 1, true), text)
  -- The join job is no leg.
  assert(not text:find("| ci |", 1, true), text)
  -- Medians over 30 alone: the one successful run that qualified.
  has("## Medians over 1 qualifying successful runs of 4")
  has("- Wall: 11m 00s")
  -- 11 + 8 + 59 minutes: the join's time is runner time too.
  has("- Runner time: 78m 00s")
  has("| linux-x86_64 | local | 0 | 100.0 | 100000 |")
  has("| linux-x86_64 | fixture runtime-regression | 0 | 100.0 | 100000 |")
  local calls = table.concat(f.calls, "\n")
  assert(calls:find("repos/owner/repo/actions/artifacts/301/zip", 1, true), calls)
  assert(calls:find("repos/owner/repo/actions/artifacts/202/zip", 1, true), calls)
  for _, absent in ipairs({ "artifacts/201/", "artifacts/7/", "artifacts/8/",
      "runs/10/", "runs/20/jobs" }) do
    assert(not calls:find(absent, 1, true), absent .. " was fetched:\n" .. calls)
  end
end

--- A push's runs are main's unless a branch is named; a run whose
--- artifact cannot be downloaded is still reported, and says so.
local function test_report_of_pushes_names_main_and_survives_a_lost_artifact(tmp: string)
  local f = fake(tmp)
  answer(f, "repos/cosmic-lua/cosmic/actions/workflows/ci.yml/runs?status=completed" ..
      "&per_page=11&event=push&branch=main", { workflow_runs = {
        { id = 5, event = "push", head_branch = "main", head_sha = string.rep("5", 40),
          conclusion = "success", run_attempt = 1 } } })
  answer(f, "repos/cosmic-lua/cosmic/actions/runs/5/jobs?per_page=100", { jobs = Json.array() })
  answer(f, "repos/cosmic-lua/cosmic/actions/runs/5/artifacts?per_page=100",
    { artifacts = { { name = "ci-driver-linux-x86_64", id = 9, expired = false } } })
  local result, said = report(f, { "--runs=1", "--event", "push" })
  assert(result.ok, said)
  local text = result.stdout or ""
  assert(text:find("- Not read: ci-driver-linux-x86_64: GET " ..
      "repos/cosmic-lua/cosmic/actions/artifacts/9/zip: HTTP 404: Not Found", 1, true), text)
  assert(text:find("- Wall: -", 1, true), text)
  assert(text:find("None qualifies.", 1, true), text)
end

local function test_report_refuses_a_bad_line_and_a_missing_token(tmp: string)
  local f = fake(tmp)
  for _, args in ipairs({ { "--runs", "0" }, { "--runs", "101" }, { "--runs", "x" },
      { "--repo", "nobody" }, { "--event", "a&b=c" }, { "--event", "a/b" },
      { "--branch", "../x" }, { "--branch", "/x" }, { "--branch", "x&y=z" },
      { "extra" }, { "--nope" } }) do
    local result, said = report(f, args)
    assert(result.code == 2, table.concat(args, " ") .. ": " .. said)
  end
  -- GitHub's refusal is the report's failure, and names its status.
  local failed, why = report(f, { "--runs", "3" })
  assert(failed.code == 1 and why:find("HTTP 404", 1, true), why)
  -- A branch may hold "/", as a merge queue's and feature/x do.
  local branched, asked = report(f, { "--branch", "gh-readonly-queue/main/pr-1" })
  assert(branched.code == 1 and asked:find("&branch=gh-readonly-queue/main/pr-1", 1, true), asked)
  -- Without a client of its own, the report makes the live one from its
  -- environment, which needs a token.
  local got = assert(Flags.parse({ [0] = "report" }, 1, Report.spec))
  f.env.GH_TOKEN, f.env.GITHUB_TOKEN = nil, nil
  local code, _, told = Report.answer(got, f.env)
  assert(code == 1 and told:find("no GitHub token", 1, true), told)
end
