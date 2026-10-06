local Compiles = require("cosmic_ci.compiles")
local CommitVerdicts = require("cosmic_ci.commit_verdicts")
local Context = require("cosmic_ci.context")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Fuzz = require("cosmic_ci.fuzz")
local Images = require("cosmic_ci.images")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")
local Orchestration = require("cosmic_ci.orchestration")
local Prerelease = require("cosmic_ci.prerelease")
local QueueSeed = require("cosmic_ci.queue_seed")
local Runner = require("cosmic_ci.runner")
local Report = require("cosmic_ci.report")
local State = require("cosmic_ci.state")
local SuiteOutput = require("cosmic_ci.suite_output")
local Verdicts = require("cosmic_ci.verdicts")
local ZigPrune = require("cosmic_ci.zig_prune")
local ZigRestat = require("cosmic_ci.zig_restat")

local function open_database(path: string): Sqlite.Handle
  return State.open(path)
end

local function run(argv: {string}): integer
  local phase, timeout_text, executable = argv[1], argv[2], argv[3]
  assert(phase and timeout_text and executable,
    "usage: driver.tl run PHASE TIMEOUT_NS -- EXECUTABLE [ARG...]")
  local timeout = math.tointeger(tonumber(timeout_text))
  assert(timeout and timeout >= 0, "timeout must be a non-negative integer")
  local context = Context.read()
  local command: {string} = { executable }
  for i = 4, #argv do command[#command + 1] = argv[i] end
  local runner: Runner.Context = { database = context.db, worker = context.worker,
    run = context.run, attempt = context.attempt, candidate = context.root }
  return Runner.operation(runner, phase, { argv = command, cwd = context.root,
    timeout_ns = timeout }).code
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
    local suites = State.suite_rows(db)
    assert(db:close())
    lines[#lines + 1] = "| Worker | Run | Attempt | Phase | Status | ms | Exit | Signal | Detail |\n"
    lines[#lines + 1] = "|---|---|---|---|---:|---:|---:|---:|---|\n"
    for _, row in ipairs(rows) do
      local cells: {string} = {}
      for i = 1, 9 do cells[i] = clean(row[i]) end
      lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |\n"
    end
    -- Each suite's row (orchestration's `record_suite`), for a reader
    -- and for `report`, which reads the same rows from the uploaded
    -- database.
    if #suites > 0 then
      lines[#lines + 1] = "\n## Cosmic CI suites\n\n"
      lines[#lines + 1] = SuiteOutput.markdown(suites)
    end
  end
  Context.summarize(table.concat(lines))
  return 0
end

--- Each command: what it does and takes, for `driver.tl --help`, and
--- its handler, which gets the words after the command with the
--- driver's own path at slot 0. A command that takes options names
--- them in `spec` and is run by `options`, given what its line held;
--- the rest take none, so a word that begins with "-" goes after a
--- "--": `run`'s command line does.
local record Command
  about: string
  usage: string
  handler: function({string}): integer
  spec: {string:boolean | Flags.Option}
  options: function(Flags.Parsed): integer
end

local commands: {string:Command} = {
  run = { about = "run a command as one recorded operation of the phase",
    usage = "PHASE TIMEOUT_NS -- EXECUTABLE [ARG...]", handler = run },
  summarize = { about = "write the operations recorded so far as a table",
    usage = "", handler = summarize },
  ["compiles-trim"] = { about = "trim the build cache to the compiles used since SINCE, digest it, and count those RESTORED lacks",
    usage = "SINCE [RESTORED]", handler = Compiles.trim_command },
  ["verdicts-trim"] = { about = "trim the test verdicts to those used since SINCE, and digest them",
    usage = "SINCE|whole", handler = Verdicts.trim_command },
  ["zig-prune"] = { about = "remove the zig build outputs no manifest of a current step vouches for",
    usage = "", handler = ZigPrune.prune_command },
  ["zig-restat"] = { about = "take restored zig caches' new inodes into their manifests",
    usage = "", handler = ZigRestat.restat_command },
  ["verdicts-merge"] = { about = "add the verdicts of the merge queue's run ahead, in DIR, to this run's",
    usage = "DIR", handler = Verdicts.merge_command },
  ["queue-find"] = { about = "find the merge queue's passing run of this commit, for ci.yml's reuse job",
    usage = "", handler = QueueSeed.find_command },
  ["queue-ahead"] = { about = "find the run ahead in the merge queue, and whether it holds the verdicts this run takes",
    usage = "", handler = QueueSeed.ahead_command },
  ["merge-base"] = { about = "name the main commit this run's tree grew from, whose verdicts the restore takes",
    usage = "", handler = CommitVerdicts.merge_base_command },
  ["prune-commit-verdicts"] = { about = "delete main's commit-keyed verdicts and the branches' compiles a day old",
    usage = "", handler = CommitVerdicts.prune_command },
  platform = { about = "run one phase of this worker's platform job",
    usage = "PHASE [ARG]", handler = Orchestration.platform },
  provenance = { about = "check that every worker tested the same bytes",
    usage = "", handler = Orchestration.provenance },
  ["prerelease-stage"] = { about = "check every worker's product and stage the prerelease",
    usage = "", handler = Prerelease.stage_command },
  ["prerelease-publish"] = { about = "publish the staged prerelease, or verify the one there",
    usage = "", handler = Prerelease.publish_command },
  fuzz = { about = "fuzz every property on the checked core, for fuzz.yml",
    usage = "", handler = Fuzz.fuzz },
  ["fuzz-cancelled"] = { about = "say how far a cancelled fuzz run got",
    usage = "", handler = Fuzz.cancelled },
  ["image-build"] = { about = "build one of ci/images/ for one architecture",
    usage = "", handler = Images.build_command },
  ["image-publish"] = { about = "join one image's architectures under one tag",
    usage = "", handler = Images.publish_command },
  report = { about = "print CI's recent runs' times and suites, from GitHub through gh",
    usage = "[options]", spec = Report.spec, options = Report.command },
}

return function(argv: {integer:string}): integer
  local dispatched: {string:Flags.Command} = {}
  for name, entry in pairs(commands) do
    local handler = entry.handler
    local options = entry.options
    dispatched[name] = {
      about = entry.about,
      usage = entry.usage,
      spec = entry.spec,
      run = function(got: Flags.Parsed): integer
        if options then return options(got) end
        local rest: {integer:string} = { [0] = argv[0] }
        for i, word in ipairs(got.words) do rest[i] = word end
        return handler(rest)
      end,
    }
  end
  local ran, why = Flags.dispatch(argv, 1, dispatched, "driver.tl")
  if ran == nil then
    local named = argv[1] ~= nil and commands[argv[1]] or nil
    local usage = named ~= nil and "; usage: driver.tl " .. argv[1] .. " " .. named.usage or ""
    local _, _ = Fs.put(Fs.stderr, "driver.tl: " .. why .. usage .. "\n")
    return 2
  end
  if ran.help ~= "" then
    local _, _ = Fs.put(Fs.stdout, ran.help .. "\n")
  end
  return ran.code
end
