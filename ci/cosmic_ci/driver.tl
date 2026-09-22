local Context = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")
local Orchestration = require("cosmic_ci.orchestration")
local Runner = require("cosmic_ci.runner")
local State = require("cosmic_ci.state")

local function open_database(path: string): Sqlite.Handle
  return State.open(path)
end

local function run(argv: {string}): integer
  local phase, timeout_text, executable = argv[1], argv[2], argv[3]
  assert(phase and timeout_text and executable,
    "usage: driver.tl run PHASE TIMEOUT_MS EXECUTABLE [ARG...]")
  local timeout = math.tointeger(tonumber(timeout_text))
  assert(timeout and timeout >= 0, "timeout must be a non-negative integer")
  local context = Context.read()
  local command: {string} = { executable }
  for i = 4, #argv do command[#command + 1] = argv[i] end
  local runner: Runner.Context = { database = context.db, worker = context.worker,
    run = context.run, attempt = context.attempt, candidate = context.root }
  return Runner.operation(runner, phase, { argv = command, cwd = context.root,
    timeout_ms = timeout }).code
end

local function clean(value: string): string
  local without_pipes = value:gsub("|", "\\|")
  local one_line = without_pipes:gsub("[\r\n]", " ")
  return one_line
end

local function summarize(_argv: {string}): integer
  local db_path = Context.database()
  local lines: {string} = { "## Cosmic CI operations\n\n" }
  local database_exists = Predicate.exists(db_path)
  if not database_exists then
    lines[#lines + 1] =
      "Operation database unavailable: no operation ran (the self-check failed first).\n"
  else
    local db = open_database(db_path)
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
    lines[#lines + 1] = "| Worker | Run | Attempt | Phase | Status | ms | Exit | Signal | Detail |\n"
    lines[#lines + 1] = "|---|---|---|---|---:|---:|---:|---:|---|\n"
    for _, row in ipairs(rows) do
      local cells: {string} = {}
      for i = 1, 9 do cells[i] = clean(row[i]) end
      lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |\n"
    end
  end
  local text = table.concat(lines)
  local output = Env.get("GITHUB_STEP_SUMMARY")
  if output and output ~= "" then
    local output_exists = Predicate.exists(output)
    local existing = output_exists and assert(Fs.read(output)) or ""
    assert(Fs.write(output, existing .. text))
  else
    assert(Fs.put(Fs.stdout, text))
  end
  return 0
end

local commands: {string:function({string}):integer} = {
  run = run,
  summarize = summarize,
  platform = Orchestration.platform,
  provenance = Orchestration.provenance,
}

return function(argv: {string}): integer
  local handler = argv[1] and commands[argv[1]] or nil
  if not handler then
    Fs.put(Fs.stderr, "usage: driver.tl run|summarize|platform|provenance ...\n")
    return 2
  end
  local rest: {string} = { [0] = argv[0] }
  for i = 2, #argv do rest[#rest + 1] = argv[i] end
  return handler(rest)
end
