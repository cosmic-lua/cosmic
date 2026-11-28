--- The database of the agent evals: a round's runs, one row each, and the arms (tools) that ran them. It is the source
--- of truth: the report and results.json are read from it, `--against` reads an earlier round from it, and a round
--- that ended early goes on from it, as each run is committed alone, once graded.
---
--- `runs` has a row for each round, arm, task and rep: its grade, its spending, and its refusal causes (as JSON
--- objects, which `json_each` reads: the `causes` view lists them a row each). `arms` names the binary of each arm by its
--- sha256, so two rounds' arms compare by what they ran and not by the name they were given.
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")

local record Runs
  --- What one run spent, from its session in sessions.db.
  record Spent
    requests: integer
    input: integer
    output: integer
    cache_read: integer
    cache_write: integer
    cost: number
    seconds: number
    tools: integer
    runs: integer
    --- How many run calls the checker refused, and how often each of its codes was named in them.
    refused: integer
    codes: {string: integer}
    --- How often each root cause ("TAG: name", from [`Causes.of`]) was named in a refused snippet, once a snippet.
    causes: {string: integer}
    --- How many refused snippets each layer ("lang", "stdlib", "prompt", "untagged") was a cause in, once a snippet.
    layers: {string: integer}
    --- Each name the model tried that does not exist ("NAME (CODE)", from [`Causes.guess`]), once a run.
    guesses: {string: integer}
    --- How many run snippets repeated the one before them to the letter.
    resends: integer
    --- How many run snippets sorted (`table.sort` or `version_sort`).
    sorts: integer
    --- How many snippets of run named each Host helper, by its name (`bash` for Host.bash, a command no other
    --- helper served): the use a helper is kept or pruned by.
    helpers: {string: integer}
    --- What the session's first request read from the cache: the prefix it shared with another session.
    first_read: integer
  end

  --- One run's result.
  record Result
    tool: string
    task: string
    rep: integer
    --- "pass", "fail", "unfit" (the truth was empty on the fixture) or "broken" (the agent ended with an error
    --- before its first request: the harness or the setup failed, and the model was not tried).
    grade: string
    --- The first line of the standard error of a broken run; nil for any other.
    why?: string
    --- Why the round ended with this run, on the last result of one that did not run to its end.
    mut stopped?: string
    --- nil where no session was found for the run.
    mut spent?: Spent
    --- How long the agent ran, by the wall clock, tools and all.
    wall: number
  end

  --- What an earlier round says of one tool: the refused snippets and their causes ("TAG: name", as [`Runs.Spent`]'s) and
  --- layers, each summed over the tool's runs.
  record Earlier
    mut refused: integer
    --- The runs that kept causes.
    mut runs: integer
    causes: mut {string: integer}
    layers: mut {string: integer}
  end

  --- An arm of a round: the name its runs have in the report, and what ran them.
  record Arm
    name: string
    --- The sha256 of the binary the arm ran: a copy made when the round began, so a rebuild of the tree under it
    --- does not change the arm.
    sha: string
    --- The path the binary was given as.
    path: string
    effort?: string
    --- The run text bullets left out (`--drop`).
    drop?: string
    commands?: boolean
  end

  --- What a round was run with.
  record Round
    id: string
    model: string
    reps: integer
    fixture: string
  end

  --- A database of rounds, open.
  type Store = Sqlite.Handle
end

local DDL <const> = [[
CREATE TABLE IF NOT EXISTS rounds (
  id TEXT PRIMARY KEY,
  started INTEGER NOT NULL,
  finished INTEGER,
  model TEXT NOT NULL,
  reps INTEGER NOT NULL,
  fixture TEXT NOT NULL,
  stopped TEXT
);
CREATE TABLE IF NOT EXISTS arms (
  round TEXT NOT NULL REFERENCES rounds (id),
  name TEXT NOT NULL,
  binary TEXT NOT NULL,
  path TEXT NOT NULL,
  effort TEXT,
  drop_bullets TEXT,
  commands INTEGER NOT NULL,
  PRIMARY KEY (round, name)
);
CREATE TABLE IF NOT EXISTS runs (
  round TEXT NOT NULL REFERENCES rounds (id),
  arm TEXT NOT NULL,
  task TEXT NOT NULL,
  rep INTEGER NOT NULL,
  model TEXT NOT NULL,
  binary TEXT NOT NULL,
  grade TEXT NOT NULL,
  why TEXT,
  wall REAL NOT NULL,
  requests INTEGER,
  input INTEGER,
  output INTEGER,
  cache_read INTEGER,
  cache_write INTEGER,
  cost REAL,
  seconds REAL,
  tools INTEGER,
  runs INTEGER,
  refused INTEGER,
  first_read INTEGER,
  resends INTEGER,
  sorts INTEGER,
  codes TEXT,
  causes TEXT,
  layers TEXT,
  guesses TEXT,
  helpers TEXT,
  PRIMARY KEY (round, arm, task, rep)
);
CREATE VIEW IF NOT EXISTS causes AS
  SELECT runs.round, runs.arm, runs.task, runs.rep, j.key AS cause, j.value AS n
  FROM runs, json_each(runs.causes) AS j
  WHERE runs.causes IS NOT NULL;
]]

--- `counts` as a JSON object.
local function counted(counts: {string: integer}): string
  local object: mut {string: Json.Value} = {}
  for key, n in pairs(counts) do object[key] = n end
  return assert(Json.encode(object))
end

--- The counts of the JSON object `text`; none for NULL or what is not one.
local function uncounted(text: string?): {string: integer}
  local found: mut {string: integer} = {}
  if text == nil then return found end
  local object, _ = Json.decode_object(text)
  for key, n in pairs(object or {}) do
    if n is integer then found[key] = n end
  end
  return found
end

local function text_or_null(text: string?): Sqlite.Value
  if text == nil then return Sqlite.NULL end
  return { text = text }
end

--- The cell `i` of `row` as text, or nil for NULL.
local function maybe_text(row: Sqlite.Row, i: integer): string?
  if row:is_null(i) then return nil end
  return row:text(i)
end

--- Opens the database at `path`, made with its tables where it is new. Many processes may share it: one for each
--- arm of a round.
function Runs.open(path: string): (Runs.Store) | (nil, string)
  local db, why = Sqlite.open(path, { writable = true, wal = true, synchronous = "normal" })
  if db == nil then return nil, "runs database " .. path .. ": " .. tostring(why) end
  local made, made_why = db:exec(DDL)
  if not made then return nil, "runs database " .. path .. ": " .. tostring(made_why) end
  return db
end

--- Notes the round `round` and its `arms`, or finds them noted by an earlier call, when a round goes on. An arm whose
--- binary is not the one noted is refused, with why: its runs would not be of one binary. All or none.
function Runs.begin(db: Runs.Store, round: Runs.Round, arms: {Runs.Arm}): (true) | (nil, string)
  local ok, why = db:transact(function(): (true) | (nil, Failure)
    local noted, noted_why = db:run("INSERT OR IGNORE INTO rounds (id, started, model, reps, fixture) VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = round.id }, { integer = Clock.now_ns() // 1000000000 }, { text = round.model },
        { integer = round.reps }, { text = round.fixture } })
    if not noted then return nil, noted_why end
    local held, held_why = db:rows("SELECT model, reps FROM rounds WHERE id = ?1", { { text = round.id } })
    if held == nil then return nil, held_why end
    local was = held[1]
    if was ~= nil and (was:text(1) ~= round.model or was:integer(2) ~= round.reps) then
      return nil, Failure.new("round " .. round.id .. " began with model " .. was:text(1) .. " and " ..
          tostring(was:integer(2)) .. " reps, and is now asked for " .. round.model .. " and " .. tostring(round.reps) ..
          ": go on with the same, or begin another round")
    end
    for _, arm in ipairs(arms) do
      local found, found_why = db:rows("SELECT binary, effort, drop_bullets, commands FROM arms WHERE round = ?1 AND name = ?2",
        { { text = round.id }, { text = arm.name } })
      if found == nil then return nil, found_why end
      local row = found[1]
      if row == nil then
        local put, put_why = db:run("INSERT INTO arms (round, name, binary, path, effort, drop_bullets, commands) " ..
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)", { { text = round.id }, { text = arm.name }, { text = arm.sha },
              { text = arm.path }, text_or_null(arm.effort), text_or_null(arm.drop),
              { integer = (if arm.commands == true then 1 else 0 end) } })
        if not put then return nil, put_why end
      elseif row:text(1) ~= arm.sha then
        return nil, Failure.new("arm " .. arm.name .. " of round " .. round.id .. " ran binary " .. row:text(1) ..
            ", and --tool now names " .. arm.sha .. ": go on with the same binary, or begin another round")
      elseif maybe_text(row, 2) ~= arm.effort or maybe_text(row, 3) ~= arm.drop or
          (row:integer(4) == 1) ~= (arm.commands == true) then
        return nil, Failure.new("arm " .. arm.name .. " of round " .. round.id .. " ran with another --effort, " ..
            "--drop or --commands than now: go on with the same, or begin another round")
      end
    end
    return true
  end)
  if not ok then return nil, tostring(why) end
  return true
end

--- Notes that `round` goes on: it has not ended, and its last reason to stop is no longer one. The call that starts a
--- round's arms makes it, once, before they run: an arm that began later would clear what another noted.
function Runs.reopen(db: Runs.Store, round: string): (true) | (nil, string)
  local ok, why = db:run("UPDATE rounds SET finished = NULL, stopped = NULL WHERE id = ?1", { { text = round } })
  if not ok then return nil, tostring(why) end
  return true
end

--- Commits one graded run of the arm `arm`, replacing one of the same round, arm, task and rep.
function Runs.put(db: Runs.Store, round: string, arm: Runs.Arm, model: string, result: Runs.Result): (true) | (nil, string)
  local s = result.spent
  local values: mut {Sqlite.Value} = { { text = round }, { text = arm.name }, { text = result.task },
    { integer = result.rep }, { text = model }, { text = arm.sha }, { text = result.grade },
    text_or_null(result.why), { number = result.wall } }
  if s ~= nil then
    for _, v in ipairs({ { integer = s.requests }, { integer = s.input }, { integer = s.output },
        { integer = s.cache_read }, { integer = s.cache_write }, { number = s.cost }, { number = s.seconds },
        { integer = s.tools }, { integer = s.runs }, { integer = s.refused }, { integer = s.first_read },
        { integer = s.resends }, { integer = s.sorts }, { text = counted(s.codes) }, { text = counted(s.causes) },
        { text = counted(s.layers) }, { text = counted(s.guesses) }, { text = counted(s.helpers) } }) do
      values[#values + 1] = v
    end
  else
    for _ = 1, 18 do values[#values + 1] = Sqlite.NULL end
  end
  local ok, why = db:run("INSERT OR REPLACE INTO runs (round, arm, task, rep, model, binary, grade, why, wall, requests, " ..
      "input, output, cache_read, cache_write, cost, seconds, tools, runs, refused, first_read, resends, sorts, codes, " ..
      "causes, layers, guesses, helpers) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, " ..
      "?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27)", values)
  if not ok then return nil, tostring(why) end
  return true
end

local COLUMNS <const> = "arm, task, rep, grade, why, wall, requests, input, output, cache_read, cache_write, cost, " ..
  "seconds, tools, runs, refused, first_read, resends, sorts, codes, causes, layers, guesses, helpers"

--- The result a row of `COLUMNS` holds.
local function result_of(row: Sqlite.Row): Runs.Result
  local result: Runs.Result = { tool = row:text(1), task = row:text(2), rep = row:integer(3), grade = row:text(4),
    why = maybe_text(row, 5), wall = row:number(6) }
  if not row:is_null(7) then
    result.spent = { requests = row:integer(7), input = row:integer(8), output = row:integer(9),
      cache_read = row:integer(10), cache_write = row:integer(11), cost = row:number(12), seconds = row:number(13),
      tools = row:integer(14), runs = row:integer(15), refused = row:integer(16), first_read = row:integer(17),
      resends = row:integer(18), sorts = row:integer(19), codes = uncounted(maybe_text(row, 20)),
      causes = uncounted(maybe_text(row, 21)), layers = uncounted(maybe_text(row, 22)),
      guesses = uncounted(maybe_text(row, 23)), helpers = uncounted(maybe_text(row, 24)) }
  end
  return result
end

--- The run of the round, arm, task and rep that was committed, or nil: what a round that goes on skips.
function Runs.known(db: Runs.Store, round: string, arm: string, task: string, rep: integer): Runs.Result?
  local found, _ = db:rows("SELECT " .. COLUMNS .. " FROM runs WHERE round = ?1 AND arm = ?2 AND task = ?3 AND rep = ?4",
    { { text = round }, { text = arm }, { text = task }, { integer = rep } })
  local row = found and found[1]
  if row == nil then return nil end
  return result_of(row)
end

--- Every run of `round`, in the order they were committed.
function Runs.results(db: Runs.Store, round: string): ({Runs.Result}) | (nil, string)
  local found, why = db:rows("SELECT " .. COLUMNS .. " FROM runs WHERE round = ?1 ORDER BY rowid", { { text = round } })
  if found == nil then return nil, tostring(why) end
  local results: mut {Runs.Result} = {}
  for _, row in ipairs(found) do results[#results + 1] = result_of(row) end
  return results
end

--- The names of the arms of `round`, in the order they were noted.
function Runs.arms(db: Runs.Store, round: string): ({string}) | (nil, string)
  local found, why = db:rows("SELECT name FROM arms WHERE round = ?1 ORDER BY rowid", { { text = round } })
  if found == nil then return nil, tostring(why) end
  local names: mut {string} = {}
  for _, row in ipairs(found) do names[#names + 1] = row:text(1) end
  return names
end

--- The round noted last, but `except`: the one `--against` reads where none is named, which is not the round that reads.
function Runs.latest(db: Runs.Store, except: string?): string?
  local found, _ = db:rows("SELECT id FROM rounds WHERE id IS NOT ?1 AND EXISTS (SELECT 1 FROM runs WHERE runs.round = rounds.id) ORDER BY started DESC, rowid DESC LIMIT 1",
    { text_or_null(except) })
  local row = found and found[1]
  if row == nil then return nil end
  return row:text(1)
end

--- What `round` says of each arm: refused snippets, causes and layers. An arm none of whose runs kept a spending is left
--- out. Nil and why for a round with no runs.
function Runs.earlier(db: Runs.Store, round: string): ({string: Runs.Earlier}) | (nil, string)
  local found, why = Runs.results(db, round)
  if found == nil then return nil, why end
  if #found == 0 then return nil, "round " .. round .. " has no runs" end
  local by_arm: mut {string: Runs.Earlier} = {}
  for _, r in ipairs(found) do
    local s = r.spent
    if s ~= nil then
      local name = r.tool
      local into = by_arm[name] or { refused = 0, runs = 0, causes = {}, layers = {} }
      into.refused = into.refused + s.refused
      into.runs = into.runs + 1
      for cause, k in pairs(s.causes) do into.causes[cause] = (into.causes[cause] or 0) + k end
      for tag, k in pairs(s.layers) do into.layers[tag] = (into.layers[tag] or 0) + k end
      by_arm[name] = into
    end
  end
  return by_arm
end

--- The reason `round` ended before its last run, if it did.
function Runs.stopped(db: Runs.Store, round: string): string?
  local found, _ = db:rows("SELECT stopped FROM rounds WHERE id = ?1", { { text = round } })
  local row = found and found[1]
  if row == nil then return nil end
  return maybe_text(row, 1)
end

--- Notes that `round` ended, and why where it ended before its last run; a reason noted stays until the round goes on.
function Runs.finish(db: Runs.Store, round: string, stopped: string?): (true) | (nil, string)
  local ok, why = db:run("UPDATE rounds SET finished = ?2, stopped = coalesce(?3, stopped) WHERE id = ?1",
    { { text = round }, { integer = Clock.now_ns() // 1000000000 }, text_or_null(stopped) })
  if not ok then return nil, tostring(why) end
  return true
end

return Runs
