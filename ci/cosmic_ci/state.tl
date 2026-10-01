local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")
local SqliteOpen = require("cosmic_ci.sqlite_open")

local record State
  schema: string
  --- One suite's row of `suite_runs`: what ran it, how it ended, and
  --- the figures and key parts its output said ([`cosmic_ci.suite_output`]),
  --- each nil where the output said none.
  record SuiteRun
    worker: string
    run: string
    attempt: string
    phase: string
    suite: string
    status: string
    exit_code: integer
    tests: integer
    modules: integer
    ran: integer
    stood: integer
    every: integer
    assumed: integer
    shared: integer
    failed: integer
    elapsed_ms: integer
    sandbox: string
    parts: {string:string}
    --- What its verdict cache held as it began, as its census line
    --- said it ([`SuiteOutput.held`] reads it); nil where it said none.
    held: string
  end
  key_parts: {{string}}
  suite_columns: {string}
end

local function text(v: string): Sqlite.Value return { text = v } end
local function integer(v: integer): Sqlite.Value return { integer = v } end
local function null(): Sqlite.Value return {} end

State.schema = [[
CREATE TABLE IF NOT EXISTS operation_events (
  id INTEGER PRIMARY KEY, start_id INTEGER,
  event TEXT NOT NULL CHECK(event IN ('start', 'complete')),
  worker TEXT NOT NULL, run TEXT NOT NULL, attempt TEXT NOT NULL,
  phase TEXT NOT NULL, monotonic_ns INTEGER NOT NULL, elapsed_ns INTEGER,
  status TEXT, exit_code INTEGER, signal INTEGER, timed_out INTEGER,
  detail TEXT, FOREIGN KEY(start_id) REFERENCES operation_events(id));
CREATE INDEX IF NOT EXISTS operation_completion ON operation_events(start_id);
CREATE TABLE IF NOT EXISTS suite_runs (
  id INTEGER PRIMARY KEY, worker TEXT NOT NULL, run TEXT NOT NULL,
  attempt TEXT NOT NULL, phase TEXT NOT NULL, suite TEXT NOT NULL,
  status TEXT NOT NULL, exit_code INTEGER, tests INTEGER, modules INTEGER,
  ran INTEGER, stood INTEGER, every INTEGER, assumed INTEGER, shared INTEGER,
  failed INTEGER, elapsed_ms INTEGER, sandbox TEXT, host_features TEXT,
  host TEXT, system TEXT, runtime TEXT, compiler TEXT, harness TEXT,
  launcher TEXT, program TEXT, held TEXT, store TEXT);
]]

function State.canonical_directory(path: string): string
  local absolute = assert(Fs.absolute(path))
  local directory = Predicate.is_dir(absolute)
  assert(directory, "directory does not exist: " .. path)
  return absolute
end

function State.external_path(path: string, candidate: string): string
  local directory = State.canonical_directory(Fs.dirname(path))
  local leaf = Fs.basename(path)
  local unresolved = directory == "/" and "/" .. leaf or directory .. "/" .. leaf
  local absolute, trouble = Fs.absolute(unresolved)
  if not absolute then
    for _, entry in ipairs((assert(Fs.list(directory)))) do
      assert(entry ~= leaf, "path cannot be resolved: " .. trouble)
    end
    absolute = unresolved
  end
  local candidate_absolute = State.canonical_directory(candidate)
  assert(not Fs.within(absolute, candidate_absolute),
    "path must be outside candidate checkout: " .. absolute)
  return absolute
end

--- The columns of `suite_runs` in `db`, as a set: one written before a
--- column was lacks it.
local function suite_columns_of(db: Sqlite.Handle): {string:boolean}
  local out: {string:boolean} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT name FROM pragma_table_info('suite_runs')")))) do
    out[row[1]] = true
  end
  return out
end

function State.open(path: string): Sqlite.Handle
  local db = assert(SqliteOpen.writable(path)); assert(db:exec(State.schema))
  -- A table written before a key part or `held` was gains its column.
  local present = suite_columns_of(db)
  local wanted: {string} = { "held" }
  for _, part in ipairs(State.key_parts) do wanted[#wanted + 1] = part[2] end
  for _, name in ipairs(wanted) do
    if not present[name] then
      assert(db:exec("ALTER TABLE suite_runs ADD COLUMN " .. name .. " TEXT"))
    end
  end
  return db
end

function State.start(path: string, worker: string, run: string, attempt: string,
    phase: string, at: integer): integer
  local db = State.open(path)
  assert(Sqlite.run(db, [[INSERT INTO operation_events
    (event,worker,run,attempt,phase,monotonic_ns)
    VALUES('start',?1,?2,?3,?4,?5)]],
    { text(worker), text(run), text(attempt), text(phase), integer(at) }))
  local id = db:last_insert_rowid(); assert(db:close()); return id
end

function State.complete(path: string, id: integer, worker: string, run: string,
    attempt: string, phase: string, at: integer, elapsed: integer,
    status: string, code: integer | nil, signal: integer | nil,
    timed_out: integer, detail: string | nil)
  local db = State.open(path)
  assert(Sqlite.run(db, [[INSERT INTO operation_events
    (start_id,event,worker,run,attempt,phase,monotonic_ns,elapsed_ns,status,
     exit_code,signal,timed_out,detail)
    VALUES(?1,'complete',?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)]],
    { integer(id), text(worker), text(run), text(attempt), text(phase), integer(at),
     integer(elapsed), text(status), code and integer(code) or null(),
     signal and integer(signal) or null(), integer(timed_out),
     detail and text(detail) or null() })); assert(db:close())
end

--- The key parts `suite_runs` keeps, by the name `cosmic test` says each
--- by, beside its column.
State.key_parts = {
  { "host features", "host_features" }, { "host", "host" }, { "system", "system" },
  { "runtime", "runtime" }, { "compiler", "compiler" }, { "harness", "harness" },
  { "launcher", "launcher" }, { "program", "program" }, { "store", "store" },
}

--- `suite_runs`' columns before its key parts, in order.
State.suite_columns = { "worker", "run", "attempt", "phase", "suite",
  "status", "exit_code", "tests", "modules", "ran", "stood", "every",
  "assumed", "shared", "failed", "elapsed_ms", "sandbox" }

local integer_columns: {string:boolean} = { exit_code = true, tests = true,
  modules = true, ran = true, stood = true, every = true, assumed = true,
  shared = true, failed = true, elapsed_ms = true }

--- The rows of `suite_runs` in `db`, in the order written; none where
--- `db`, an operations database written before the table was, lacks it.
function State.suite_rows(db: Sqlite.Handle): {State.SuiteRun}
  local present = assert(Sqlite.text_rows(db,
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'suite_runs'"))
  if #present == 0 then return {} end
  local selected: {string} = {}
  for _, name in ipairs(State.suite_columns) do
    selected[#selected + 1] = name .. " IS NULL, COALESCE(CAST(" .. name .. " AS TEXT), '')"
  end
  -- An operations database written before a column was lacks it.
  local columns = suite_columns_of(db)
  for _, part in ipairs(State.key_parts) do
    selected[#selected + 1] = columns[part[2]] and
      (part[2] .. " IS NULL, COALESCE(" .. part[2] .. ", '')") or "1, ''"
  end
  selected[#selected + 1] = columns.held and "held IS NULL, COALESCE(held, '')" or "1, ''"
  local rows = assert(Sqlite.text_rows(db, "SELECT " .. table.concat(selected, ", ") ..
    " FROM suite_runs ORDER BY id"))
  local out: {State.SuiteRun} = {}
  for _, cells in ipairs(rows) do
    local row: {string:any} = {}
    local column = 1
    for _, name in ipairs(State.suite_columns) do
      if cells[column] ~= "1" then
        local value = cells[column + 1]
        row[name] = integer_columns[name] and math.tointeger(tonumber(value)) or value
      end
      column = column + 2
    end
    local parts: {string:string} = {}
    for _, part in ipairs(State.key_parts) do
      if cells[column] ~= "1" then parts[part[1]] = cells[column + 1] end
      column = column + 2
    end
    row.parts = parts
    if cells[column] ~= "1" then row.held = cells[column + 1] end
    out[#out + 1] = row as State.SuiteRun
  end
  return out
end

function State.suite(path: string, row: State.SuiteRun)
  local function maybe_integer(v: integer | nil): Sqlite.Value
    return v and integer(v) or null()
  end
  local function maybe_text(v: string | nil): Sqlite.Value
    return v and text(v) or null()
  end
  local columns: {string} = {}
  for i, name in ipairs(State.suite_columns) do columns[i] = name end
  local values: {Sqlite.Value} = { text(row.worker), text(row.run),
    text(row.attempt), text(row.phase), text(row.suite), text(row.status),
    maybe_integer(row.exit_code), maybe_integer(row.tests),
    maybe_integer(row.modules), maybe_integer(row.ran), maybe_integer(row.stood),
    maybe_integer(row.every), maybe_integer(row.assumed),
    maybe_integer(row.shared), maybe_integer(row.failed),
    maybe_integer(row.elapsed_ms), maybe_text(row.sandbox) }
  local parts = row.parts or {}
  for _, part in ipairs(State.key_parts) do
    columns[#columns + 1] = part[2]
    values[#values + 1] = maybe_text(parts[part[1]])
  end
  columns[#columns + 1] = "held"
  values[#values + 1] = maybe_text(row.held)
  local marks: {string} = {}
  for i = 1, #columns do marks[i] = "?" .. i end
  local db = State.open(path)
  assert(Sqlite.run(db, "INSERT INTO suite_runs (" .. table.concat(columns, ",") ..
    ") VALUES (" .. table.concat(marks, ",") .. ")", values)); assert(db:close())
end

return State
