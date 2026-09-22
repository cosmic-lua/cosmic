local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Orchestration = require("cosmic_ci.orchestration")
local Runner = require("cosmic_ci.runner")
local State = require("cosmic_ci.state")

local function open_database(path: string): Sqlite.Handle
  return State.open(path)
end

local function database_path(path: string, candidate: string,
    driver_path: string): string
  return State.external_path(path, candidate, driver_path)
end

local function run(argv: {string}): integer
  local database, worker, run_name, attempt, phase =
    argv[1], argv[2], argv[3], argv[4], argv[5]
  local candidate, timeout_text, executable = argv[6], argv[7], argv[8]
  assert(database and worker and run_name and attempt and phase and candidate and
    timeout_text and executable,
    "usage: driver.tl run DB WORKER RUN ATTEMPT PHASE CANDIDATE TIMEOUT_MS EXECUTABLE [ARG...]")
  local timeout = math.tointeger(tonumber(timeout_text))
  assert(timeout and timeout >= 0, "timeout must be a non-negative integer")
  database = database_path(database, candidate, assert(argv[0]))
  local command: {string} = { executable }
  for i = 9, #argv do command[#command + 1] = argv[i] end
  local context: Runner.Context = { database = database, worker = worker,
    run = run_name, attempt = attempt, candidate = candidate,
    driver = assert(argv[0]) }
  return Runner.operation(context, phase, { argv = command, cwd = candidate,
    timeout_ms = timeout }).code
end

local function clean(value: string): string
  local without_pipes = value:gsub("|", "\\|")
  local one_line = without_pipes:gsub("[\r\n]", " ")
  return one_line
end

local function report(argv: {string}): integer
  local database, output = argv[1], argv[2]
  assert(database and output, "usage: driver.tl report DB OUTPUT")
  assert(Fs.exists(database), "operation database does not exist: " .. database)
  local db = open_database(database)
  local rows = assert(Sqlite.text_rows(db, [[
    SELECT s.worker, s.run, s.attempt, s.phase,
           COALESCE(c.status, 'incomplete'),
           COALESCE(CAST(c.elapsed_ns / 1000000 AS TEXT), ''),
           COALESCE(CAST(c.exit_code AS TEXT), ''),
           COALESCE(CAST(c.signal AS TEXT), ''),
           COALESCE(c.detail, '')
      FROM operation_events s
      LEFT JOIN operation_events c ON c.start_id = s.id AND c.event = 'complete'
     WHERE s.event = 'start'
     ORDER BY s.id
  ]]))
  assert(db:close())
  local lines = {
    "## Cosmic CI operations\n\n",
    "| Worker | Run | Attempt | Phase | Status | ms | Exit | Signal | Detail |\n",
    "|---|---|---|---|---:|---:|---:|---:|---|\n",
  }
  for _, row in ipairs(rows) do
    local cells: {string} = {}
    for i = 1, 9 do cells[i] = clean(row[i]) end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |\n"
  end
  assert(Fs.write(output, table.concat(lines)))
  return 0
end

local commands: {string:function({string}):integer} = {
  run = run,
  report = report,
  platform = Orchestration.platform,
  provenance = Orchestration.provenance,
}

return function(argv: {string}): integer
  local handler = argv[1] and commands[argv[1]] or nil
  if not handler then
    Fs.put(Fs.stderr, "usage: driver.tl run|report|platform|provenance ...\n")
    return 2
  end
  local rest: {string} = { [0] = argv[0] }
  for i = 2, #argv do rest[#rest + 1] = argv[i] end
  return handler(rest)
end
