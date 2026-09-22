local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record State
  schema: string
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
]]

local function parent(path: string): string
  local directory = path:match("^(.*)/[^/]+$")
  if directory == "" then return "/" end
  return directory or "."
end

local function inside(path: string, directory: string): boolean
  return path == directory or path:sub(1, #directory + 1) == directory .. "/"
end

function State.canonical_directory(path: string): string
  local absolute = assert(Fs.absolute(path))
  assert(Fs.is_dir(absolute), "directory does not exist: " .. path)
  return absolute
end

function State.external_path(path: string, candidate: string): string
  local directory = State.canonical_directory(parent(path))
  local leaf = path:match("([^/]+)$") or path
  local unresolved = directory == "/" and "/" .. leaf or directory .. "/" .. leaf
  local absolute, trouble = Fs.absolute(unresolved)
  if not absolute then
    for _, entry in ipairs(assert(Fs.list(directory))) do
      assert(entry ~= leaf, "path cannot be resolved: " .. trouble)
    end
    absolute = unresolved
  end
  local candidate_absolute = State.canonical_directory(candidate)
  assert(not inside(absolute, candidate_absolute),
    "path must be outside candidate checkout: " .. absolute)
  return absolute
end

function State.open(path: string): Sqlite.Handle
  local db = assert(Sqlite.open(path, true)); assert(db:exec(State.schema))
  return db
end

function State.start(path: string, worker: string, run: string, attempt: string,
    phase: string, at: integer): integer
  local db = State.open(path)
  assert(Sqlite.run(db, [[INSERT INTO operation_events
    (event,worker,run,attempt,phase,monotonic_ns)
    VALUES('start',?1,?2,?3,?4,?5)]],
    { text(worker), text(run), text(attempt), text(phase), integer(at) }))
  local id = Sqlite.last_insert_rowid(db); assert(db:close()); return id
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

return State
