local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Runner = require("cosmic_ci.runner")
local Sqlite = require("cosmic.sqlite")

--- The bound for a child that should finish at once (`exit 0`, a `cat`):
--- only a hang reaches it, so it leaves a slow or loaded runner room. It
--- stays under the 30 s a test of cosmic_ci gets (ci.yml's "check the
--- pinned CI driver" sets no COSMIC_TEST_TIMEOUT), so a hang in a test's
--- first wait fails here, recorded, rather than by the runner ending the
--- test.
local hang_guard = Clock.seconds(20)

local function test_runner_records_without_aliasing_subject(tmp: string)
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state))
  local c: Runner.Context = { database = state .. "/operations.db",
    worker = "worker", run = "run", attempt = "1", candidate = candidate }
  local function execute(phase: string, argv: {string}, timeout?: integer): Runner.Outcome
    return Runner.operation(c, phase, { argv = argv, cwd = candidate,
      timeout_ns = timeout or hang_guard })
  end
  assert(execute("success", { "/bin/sh", "-c", "exit 0" }).code == 0)
  assert(execute("exit", { "/bin/sh", "-c", "exit 23" }).code == 23)
  assert(execute("start", { "/missing/command" }).status == "start-error")
  assert(execute("delayed-success", { "/bin/sh", "-c", "sleep 0.05" }).code == 0)
  local timed = execute("timeout", { "/bin/sh", "-c", "sleep 30" }, Clock.ms(20))
  assert(timed.code == 124 and timed.elapsed_ns >= Clock.ms(10) and
      timed.elapsed_ns < Clock.seconds(5), "timeout did not preserve its nanosecond duration")
  assert(Fs.write(candidate .. "/o.db", "candidate state"))
  local database_exists = Predicate.exists(c.database)
  assert(database_exists and assert(Fs.read(candidate .. "/o.db")) == "candidate state")
  local bad_candidate: Runner.Context = { database = candidate .. "/bad.db",
    worker = c.worker, run = c.run, attempt = c.attempt, candidate = candidate }
  assert(not pcall(Runner.operation, bad_candidate, "bad",
    { argv = { "/bin/sh", "-c", "exit 0" }, cwd = candidate } as Runner.Request),
    "candidate database was accepted")
end

local function test_runner_owns_input_and_retained_output(tmp: string)
  assert(Fs.write(tmp .. "/input", "input bytes"))
  local outcome = Runner.execute({
    argv = { "/bin/sh", "-c", "cat; printf error-bytes >&2" }, cwd = tmp,
    input = tmp .. "/input", output = tmp .. "/out", error = tmp .. "/err",
    timeout_ns = hang_guard,
  })
  assert(outcome.code == 0 and assert(Fs.read(tmp .. "/out")) == "input bytes")
  assert(assert(Fs.read(tmp .. "/err")) == "error-bytes")
  local reopened = assert(Fs.open_write(tmp .. "/out"))
  assert(Fs.close(reopened), "retained output descriptor remained open")
  assert(not pcall(Runner.execute, {
    argv = { "/bin/sh", "-c", "exit 0" }, cwd = tmp, output = tmp .. "/missing/out",
  } as Runner.Request), "retained output open failure was hidden")
end

local function test_operation_records_retained_open_failure_as_error(tmp: string)
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state))
  local database = state .. "/operations.db"
  local context: Runner.Context = { database = database, worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  local outcome = Runner.operation(context, "retained-open", {
    argv = { "/bin/sh", "-c", "exit 0" }, cwd = candidate,
    output = tmp .. "/missing/out",
  })
  assert(outcome.status == "error" and outcome.code == 1 and outcome.trouble,
    "retained open failure did not return an error outcome")
  local db = assert(Sqlite.open(database))
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT c.status, c.detail
      FROM operation_events s JOIN operation_events c ON c.start_id = s.id
     WHERE s.phase = 'retained-open' AND c.event = 'complete'
  ]]))
  assert(db:close())
  assert(#rows == 1 and rows[1][1] == "error" and rows[1][2] ~= "",
    "retained open failure was left incomplete")
end

local function test_step_records_work_done_in_process(tmp: string)
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state))
  local database = state .. "/operations.db"
  local context: Runner.Context = { database = database, worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  local done = Runner.step(context, "done", function(): boolean, string
    return true
  end)
  assert(done.status == "success" and done.code == 0)
  local refused = Runner.step(context, "refused", function(): boolean, string
    return false, "no such thing"
  end)
  assert(refused.status == "error" and refused.code == 1 and
      refused.trouble == "no such thing")
  local long_error = string.rep("step error; ", 100)
  local raised = Runner.step(context, "raised", function(): boolean, string
    error(long_error, 0)
  end)
  assert(raised.status == "error" and raised.code == 1 and
      raised.trouble == long_error:sub(1, 1000))
  local db = assert(Sqlite.open(database))
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT s.phase, c.status, coalesce(c.detail, ''), c.exit_code IS NULL
      FROM operation_events s JOIN operation_events c ON c.start_id = s.id
     WHERE c.event = 'complete' ORDER BY s.id
  ]]))
  assert(db:close())
  assert(#rows == 3 and rows[1][1] == "done" and rows[1][2] == "success" and
      rows[2][2] == "error" and rows[2][3] == "no such thing" and
      rows[3][1] == "raised" and rows[3][3] == long_error:sub(1, 1000),
    "a step was not recorded with its outcome")
  for _, row in ipairs(rows) do assert(row[4] == "1", "a boolean step acquired an exit code") end
end

local function test_execute_passes_more_descriptors(tmp: string)
  assert(Fs.write(tmp .. "/eight", "on eight"))
  local fd = assert(Fs.open_read(tmp .. "/eight"))
  local outcome = Runner.execute({
    argv = { "/bin/sh", "-c", "cat <&8" }, cwd = tmp,
    output = tmp .. "/out", fds = { [8] = fd }, timeout_ns = hang_guard,
  })
  assert(Fs.close(fd))
  assert(outcome.code == 0 and assert(Fs.read(tmp .. "/out")) == "on eight",
    "the child did not read the descriptor it was given")
end

local function test_phase_keeps_exit_codes_full_errors_and_callback_times(tmp: string)
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state))
  local context: Runner.Context = { database = state .. "/operations.db", worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  local detail = string.rep("full phase failure; ", 100)
  local messages: {string} = {}
  local put = Fs.put
  Fs.put = function(fd: integer, bytes: string): boolean, string
    if fd ~= Fs.stderr then return put(fd, bytes) end
    messages[#messages + 1] = bytes
    return true
  end
  local entered, leaving, returned = 0, 0, 0
  local called, failure = pcall(function(): boolean
    assert(Runner.phase(context, "done", function(): integer
      entered = Clock.monotonic_ns()
      Clock.sleep_ns(Clock.ms(1))
      leaving = Clock.monotonic_ns()
      return 0
    end) == 0)
    returned = Clock.monotonic_ns()
    assert(Runner.phase(context, "refused", function(): integer return 23 end) == 23)
    assert(#messages == 0, "a returned status logged another diagnostic")
    assert(Runner.phase(context, "raised", function(): integer error(detail, 0) end) == 1)
    return true
  end)
  Fs.put = put
  assert(called, tostring(failure))
  assert(#messages == 1 and messages[1] == detail .. "\n", "phase error logging changed")
  local db = assert(Sqlite.open(context.database))
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT s.phase, c.status, c.exit_code, coalesce(c.detail, ''),
           s.monotonic_ns, c.monotonic_ns, c.elapsed_ns, c.signal IS NULL, c.timed_out
      FROM operation_events s JOIN operation_events c ON c.start_id = s.id
     WHERE c.event = 'complete' ORDER BY s.id
  ]]))
  assert(db:close())
  assert(#rows == 3 and rows[1][1] == "done" and rows[1][2] == "success" and rows[1][3] == "0")
  assert(rows[2][1] == "refused" and rows[2][2] == "exit" and rows[2][3] == "23")
  assert(rows[3][1] == "raised" and rows[3][2] == "error" and rows[3][3] == "1" and
      rows[3][4] == detail, "the phase's full error or durable exit code was lost")
  local started = assert(tonumber(rows[1][5]))
  local finished = assert(tonumber(rows[1][6]))
  assert(started <= entered and finished >= leaving and finished <= returned and
      tonumber(rows[1][7]) == finished - started, "phase timestamps do not enclose its callback")
  for _, row in ipairs(rows) do
    assert(row[8] == "1" and row[9] == "0", "a phase acquired a child's signal or timeout")
  end
end

local function test_phase_keeps_a_nested_child_timeout_separate(tmp: string)
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state))
  local context: Runner.Context = { database = state .. "/operations.db", worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  assert(Runner.phase(context, "outer", function(): integer
    return Runner.operation(context, "child", { argv = { "/bin/sh", "-c", "sleep 30" },
      cwd = candidate, timeout_ns = Clock.ms(20) }).code
  end) == 124)
  local db = assert(Sqlite.open(context.database))
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT s.phase, c.status, coalesce(c.exit_code, -1), c.timed_out, s.id, c.id
      FROM operation_events s JOIN operation_events c ON c.start_id = s.id
     WHERE c.event = 'complete' ORDER BY s.id
  ]]))
  assert(db:close())
  assert(#rows == 2 and rows[1][1] == "outer" and rows[1][2] == "exit" and
      rows[1][3] == "124" and rows[1][4] == "0", "parent phase lost its returned exit status")
  assert(rows[2][1] == "child" and rows[2][2] == "timeout" and rows[2][4] == "1",
    "the child timeout lost its own operation row")
  assert(tonumber(rows[1][5]) < tonumber(rows[2][5]) and
      tonumber(rows[2][6]) < tonumber(rows[1][6]), "nested operation events are out of order")
end

local function test_phase_rejects_a_candidate_database_before_its_action(tmp: string)
  local candidate = tmp .. "/candidate"
  assert(Fs.mkdirs(candidate))
  local context: Runner.Context = { database = candidate .. "/operations.db", worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  local ran = false
  local called, failure = pcall(Runner.phase, context, "refused", function(): integer
    ran = true
    return 0
  end)
  assert(not called and tostring(failure):find("outside candidate checkout", 1, true))
  assert(not ran and not Predicate.exists(context.database), "a refused phase did work")
end
