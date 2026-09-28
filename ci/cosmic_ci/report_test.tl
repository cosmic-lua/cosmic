local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Report = require("cosmic_ci.report")
local State = require("cosmic_ci.state")

local repository <const> = "owner/repo"

local function write(path: string, data: string) assert(Fs.write(path, data)) end

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

local function test_median()
  assert(Report.median({}) == nil)
  assert(Report.median({ 3, 1, 2 }) == 2)
  assert(Report.median({ 4, 1, 3, 2 }) == 2.5)
end

--- A fake GitHub: a gh on PATH answering from `state` (testdata/report/gh.tl).
local record Fake
  state: string
  env: {string:string}
end

local function fake(tmp: string): Fake
  local state, bin = tmp .. "/state", tmp .. "/bin"
  assert(Fs.mkdirs(state .. "/api") and Fs.mkdirs(bin))
  local script = assert(Fs.absolute(".")) .. "/testdata/report/gh.tl"
  write(bin .. "/gh", "#!/bin/sh\nexec '" .. assert(Proc.executable()) ..
    "' --standalone '" .. script .. "' \"$@\"\n")
  assert(Fs.chmod(bin .. "/gh", 0x1ed))
  local env = Env.all()
  env.PATH = bin .. ":/usr/bin:/bin"
  env.FAKE_GH_STATE = state
  env.GITHUB_REPOSITORY = nil
  return { state = state, env = env }
end

local function answer(f: Fake, endpoint: string, value: any)
  write(f.state .. "/api/" .. (endpoint:gsub("[^%w]", "_")), (assert(Json.encode(value))))
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

--- A run's `ci-driver-linux-x86_64` artifact, whose database holds a
--- native and a checked suite row keyed by `runtime` and `harness`.
local function artifact(f: Fake, id: string, runtime: string, harness: string,
    stood: integer)
  local directory = f.state .. "/artifacts/" .. id .. "/ci-driver-linux-x86_64"
  assert(Fs.mkdirs(directory))
  local database = directory .. "/operations.db"
  for _, suite in ipairs({ "local", "checked", "fixture runtime-regression" }) do
    local keyed = not suite:match("^fixture")
    State.suite(database, { worker = "linux-x86_64", run = id, attempt = "1",
      phase = suite == "local" and "build" or "assemble", suite = suite, status = "pass",
      exit_code = 0, tests = 100, ran = 100 - stood, stood = stood, elapsed_ms = 1000 * stood,
      parts = keyed and { runtime = runtime, harness = harness } or {} })
  end
  answer(f, "repos/" .. repository .. "/actions/runs/" .. id .. "/artifacts?per_page=100",
    { artifacts = {
      { name = "ci-driver-linux-x86_64", expired = false },
      { name = "portable-product-linux-x86_64", expired = false },
      { name = "ci-driver-macos-aarch64", expired = true },
    } })
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
  local code, out, err = Report.answer(got, f.env)
  return { code = code, ok = code == 0, stdout = out }, out .. err
end

--- Four merge-queue runs, newest first: 40 moved the harness from 30's;
--- 30 held 20's; 20 is compared to 10, which predates suite rows (no
--- artifact) and is reported from its step times alone.
local function test_report_reads_runs_jobs_and_suite_rows(tmp: string)
  local f = fake(tmp)
  answer(f, "repos/" .. repository .. "/actions/workflows/ci.yml/runs?status=completed" ..
    "&per_page=4&event=merge_group", { workflow_runs = {
      { id = 40, event = "merge_group", head_branch = "gh-readonly-queue/main/pr-4",
        head_sha = string.rep("4", 40), conclusion = "success", run_attempt = 1 },
      { id = 30, event = "merge_group", head_branch = "gh-readonly-queue/main/pr-3",
        head_sha = string.rep("3", 40), conclusion = "success", run_attempt = 1 },
      { id = 20, event = "merge_group", head_branch = "gh-readonly-queue/main/pr-2",
        head_sha = string.rep("2", 40), conclusion = "success", run_attempt = 2 },
      { id = 10, event = "merge_group", head_branch = "gh-readonly-queue/main/pr-1",
        head_sha = string.rep("1", 40), conclusion = "failure", run_attempt = 1 },
    } })
  jobs(f, "40", 13); jobs(f, "30", 11); jobs(f, "20", 12); jobs(f, "10", 14)
  artifact(f, "40", "rrrr", "h2", 90)
  artifact(f, "30", "rrrr", "h1", 100)
  artifact(f, "20", "rrrr", "h1", 50)
  answer(f, "repos/" .. repository .. "/actions/runs/10/artifacts?per_page=100",
    { artifacts = Json.array() })
  local result, said = report(f, { "--runs", "4", "--repo", repository })
  assert(result.ok, said)
  local text = result.stdout or ""
  local function has(needle: string)
    assert(text:find(needle, 1, true), "the report lacks " .. needle .. ":\n" .. text)
  end
  has("# CI runs: ci.yml, merge_group event, last 4")
  has("## Run 40 (success, gh-readonly-queue/main/pr-4, attempt 1, 444444444444)")
  has("- Wall: 13m 00s (linux-x86_64, the slowest platform job)")
  has("- Qualifies: no (linux-x86_64 checked: harness moved; linux-x86_64 local: harness moved)")
  has("- Qualifies: yes (runtime and harness held since run 20)")
  has("- Qualifies: no (linux-x86_64 checked: not in run 10; linux-x86_64 local: not in run 10)")
  has("- Qualifies: no (no checked or native suite rows)")
  has("| linux-x86_64 | 13m 00s | assemble 11m 00s; build 55s; set up 5s |")
  has("| macos-aarch64 | 8m 00s |  |")
  has("| linux-x86_64 | checked | pass | 100 | 0 | 100 | 100.0 | 100000 |")
  has("| linux-x86_64 | local | pass | 100 | 50 | 50 | 50.0 | 50000 |")
  has("No suite rows: the run predates them")
  -- The join job is no leg, and an expired artifact is not fetched.
  assert(not text:find("| ci |", 1, true), text)
  -- Medians over 30 alone: the one run that qualified.
  has("## Medians over 1 qualifying successful runs of 4")
  has("- Wall: 11m 00s")
  -- 11 + 8 + 59 minutes: the join's time is runner time too.
  has("- Runner time: 78m 00s")
  has("| linux-x86_64 | local | 0 | 100.0 | 100000 |")
  has("| linux-x86_64 | fixture runtime-regression | 0 | 100.0 | 100000 |")
  local calls = assert(Fs.read(f.state .. "/calls"))
  assert(calls:find("run download 30 --repo owner/repo --name ci-driver-linux-x86_64 --dir ",
    1, true), calls)
  assert(not calls:find("ci-driver-macos-aarch64", 1, true), calls)
  assert(not calls:find("portable-product", 1, true), calls)
end

--- A push's runs are main's unless a branch is named; a run whose
--- artifact cannot be downloaded is still reported, and says so.
local function test_report_of_pushes_names_main_and_survives_a_lost_artifact(tmp: string)
  local f = fake(tmp)
  answer(f, "repos/cosmic-lua/cosmic/actions/workflows/ci.yml/runs?status=completed" ..
    "&per_page=1&event=push&branch=main", { workflow_runs = {
      { id = 5, event = "push", head_branch = "main", head_sha = string.rep("5", 40),
        conclusion = "success", run_attempt = 1 } } })
  answer(f, "repos/cosmic-lua/cosmic/actions/runs/5/jobs?per_page=100", { jobs = Json.array() })
  answer(f, "repos/cosmic-lua/cosmic/actions/runs/5/artifacts?per_page=100",
    { artifacts = { { name = "ci-driver-linux-x86_64", expired = false } } })
  local result, said = report(f, { "--runs=1", "--event", "push" })
  assert(result.ok, said)
  local text = result.stdout or ""
  assert(text:find("- Not read: ci-driver-linux-x86_64: gh run download 5", 1, true), text)
  assert(text:find("- Wall: -", 1, true), text)
  assert(text:find("None qualifies.", 1, true), text)
end

local function test_report_refuses_a_bad_line_and_a_missing_gh(tmp: string)
  local f = fake(tmp)
  for _, args in ipairs({ { "--runs", "0" }, { "--runs", "101" }, { "--runs", "x" },
      { "--repo", "nobody" }, { "--event", "a&b=c" }, { "extra" }, { "--nope" } }) do
    local result, said = report(f, args)
    assert(result.code == 2, table.concat(args, " ") .. ": " .. said)
  end
  -- GitHub's refusal is gh's failure, and the report's.
  local failed, why = report(f, { "--runs", "3" })
  assert(failed.code == 1 and why:find("HTTP 404", 1, true), why)
  f.env.PATH = tmp .. "/nowhere"
  local lost, told = report(f, {})
  assert(lost.code == 1 and told:find("no gh on PATH", 1, true), told)
end
