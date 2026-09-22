local Fs = require("cosmic.fs")
local Runner = require("cosmic_ci.runner")
local Sqlite = require("cosmic.sqlite")

local function test_runner_records_without_aliasing_subject_or_project(tmp: string)
  local candidate, project, state = tmp .. "/candidate", tmp .. "/project", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(project .. "/cosmic_ci") and Fs.mkdirs(state))
  local c: Runner.Context = { database = state .. "/operations.db",
    worker = "worker", run = "run", attempt = "1", candidate = candidate,
    driver = project .. "/cosmic_ci/driver.tl" }
  local function execute(phase: string, argv: {string}, timeout?: integer): Runner.Outcome
    return Runner.operation(c, phase, { argv = argv, cwd = candidate,
      timeout_ms = timeout or 1000 })
  end
  assert(execute("success", { "/bin/true" }).code == 0)
  assert(execute("exit", { "/bin/sh", "-c", "exit 23" }).code == 23)
  assert(execute("start", { "/missing/command" }).status == "start-error")
  assert(execute("timeout", { "/bin/sh", "-c", "sleep 30" }, 20).code == 124)
  assert(Fs.write(candidate .. "/o.db", "candidate state"))
  assert(Fs.exists(c.database) and assert(Fs.read(candidate .. "/o.db")) == "candidate state")
  local bad_candidate: Runner.Context = { database = candidate .. "/bad.db",
    worker = c.worker, run = c.run, attempt = c.attempt,
    candidate = candidate, driver = c.driver }
  assert(not pcall(Runner.operation, bad_candidate, "bad",
    { argv = { "/bin/true" }, cwd = candidate } as Runner.Request),
    "candidate database was accepted")
  local bad_project: Runner.Context = { database = project .. "/bad.db",
    worker = c.worker, run = c.run, attempt = c.attempt,
    candidate = candidate, driver = c.driver }
  assert(not pcall(Runner.operation, bad_project, "bad",
    { argv = { "/bin/true" }, cwd = candidate } as Runner.Request),
    "driver database was accepted")
end

local function test_runner_owns_input_and_retained_output(tmp: string)
  assert(Fs.write(tmp .. "/input", "input bytes"))
  local outcome = Runner.execute({
    argv = { "/bin/sh", "-c", "cat; printf error-bytes >&2" }, cwd = tmp,
    input = tmp .. "/input", output = tmp .. "/out", error = tmp .. "/err",
    timeout_ms = 1000,
  })
  assert(outcome.code == 0 and assert(Fs.read(tmp .. "/out")) == "input bytes")
  assert(assert(Fs.read(tmp .. "/err")) == "error-bytes")
  local reopened = assert(Fs.open_write(tmp .. "/out"))
  assert(Fs.close(reopened), "retained output descriptor remained open")
  assert(not pcall(Runner.execute, {
    argv = { "/bin/true" }, cwd = tmp, output = tmp .. "/missing/out",
  } as Runner.Request), "retained output open failure was hidden")
end

local function test_operation_records_retained_open_failure_as_error(tmp: string)
  local candidate, project, state = tmp .. "/candidate", tmp .. "/project",
    tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(project .. "/cosmic_ci") and
    Fs.mkdirs(state))
  local database = state .. "/operations.db"
  local context: Runner.Context = { database = database, worker = "worker",
    run = "run", attempt = "1", candidate = candidate,
    driver = project .. "/cosmic_ci/driver.tl" }
  local outcome = Runner.operation(context, "retained-open", {
    argv = { "/bin/true" }, cwd = candidate,
    output = tmp .. "/missing/out",
  })
  assert(outcome.status == "error" and outcome.code == 1 and outcome.trouble,
    "retained open failure did not return an error outcome")
  local db = assert(Sqlite.open(database, false))
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT c.status, c.detail
      FROM operation_events s JOIN operation_events c ON c.start_id = s.id
     WHERE s.phase = 'retained-open' AND c.event = 'complete'
  ]]))
  assert(db:close())
  assert(#rows == 1 and rows[1][1] == "error" and rows[1][2] ~= "",
    "retained open failure was left incomplete")
end
