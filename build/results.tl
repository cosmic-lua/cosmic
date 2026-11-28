--- The results store: `results.db` in the build directory, the history of what timed runs found, kept apart from
--- `build.db` ([`build.work`]), which is a cache that a change of its schema makes again from nothing.
---
--- A round is one run of a comparison or a timing. An arm is one binary a round ran, named by the lowercase hex sha256
--- of its bytes, so two rounds compare by what they ran and not by the name they gave it. `rounds` and `arms` are
--- shared: the agent evals keep their rounds in a database of the same shape (eval/runs.tl), with what only an eval has
--- in tables of its own (`eval_rounds`), as `bench_runs` is a bench's. Times are integer nanoseconds.
---
--- `cosmic test --bench` keeps a round of one arm, "this", with every timed batch of each bench a row of
--- `bench_runs`. `cosmic test --bench --against` keeps a round of two arms, "old" and "new", with each round's best
--- batch of each side a row.
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local record results
  --- The statements of the tables any kind of round shares: `rounds` and `arms`.
  SHARED: string
  --- The statements of `bench_runs`.
  BENCH: string

  --- One timed sample of a bench.
  record Sample
    --- The bench, as a bench run prints it: `<file>:<bench_name>`.
    bench: string
    --- Which sample of the bench this is, from 1.
    rep: integer
    ns_per_op: number
    --- The operations of the batch timed.
    n: integer
    --- The bytes one operation reads, 0 for none.
    bytes: integer
  end

  --- An arm of a bench round: what it ran and what that timed.
  record Arm
    name: string
    --- The path the binary was run as.
    path: string
    samples: {Sample}
  end

  --- A bench round to keep.
  record Round
    started_ns: integer
    arms: {Arm}
  end

  --- A results store, open.
  type Store = Sqlite.Handle
end

results.SHARED = [[
CREATE TABLE IF NOT EXISTS rounds (
  id TEXT PRIMARY KEY,
  started_ns INTEGER NOT NULL,
  finished_ns INTEGER,
  stopped TEXT
);
CREATE TABLE IF NOT EXISTS arms (
  round TEXT NOT NULL REFERENCES rounds (id),
  name TEXT NOT NULL,
  binary TEXT NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (round, name)
);
]]

results.BENCH = [[
CREATE TABLE IF NOT EXISTS bench_runs (
  round TEXT NOT NULL REFERENCES rounds (id),
  arm TEXT NOT NULL,
  bench TEXT NOT NULL,
  rep INTEGER NOT NULL,
  ns_per_op REAL NOT NULL,
  n INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (round, arm, bench, rep),
  FOREIGN KEY (round, arm) REFERENCES arms (round, name)
);
CREATE INDEX IF NOT EXISTS bench_runs_by_bench ON bench_runs (bench, round);
]]

--- The store's path in the build directory `dir`.
function results.path(dir: string): string
  return dir .. "/results.db"
end

--- Opens the store at `path`, made with its tables where it is new. Many processes may share it.
function results.open(path: string): (results.Store) | (nil, string)
  local db, why = Sqlite.open(path, { writable = true, wal = true, synchronous = "normal" })
  if db == nil then return nil, "results " .. path .. ": " .. tostring(why) end
  local made, made_why = db:exec(results.SHARED .. results.BENCH)
  if not made then
    local _, _ = db:close()
    return nil, "results " .. path .. ": " .. tostring(made_why)
  end
  return db
end

--- Keeps `round` in `db`, all or none, and returns its id: "bench-" and its start in nanoseconds. Each arm's binary
--- is named by the sha256 of the file at its path.
function results.keep_bench(db: results.Store, round: results.Round): (string) | (nil, string)
  local id = "bench-" .. tostring(round.started_ns)
  local shas: mut {string} = {}
  for _, arm in ipairs(round.arms) do
    local sha, why = Hash.hex_file("sha256", arm.path)
    if sha == nil then
      return nil, "results: arm " .. arm.name .. ": " .. arm.path .. ": " .. tostring(why)
    end
    shas[#shas + 1] = sha
  end
  local ok, why = db:transact(function(): (true) | (nil, Failure)
    local noted, noted_why = db:run("INSERT INTO rounds (id, started_ns, finished_ns) VALUES (?1, ?2, ?3)",
      { { text = id }, { integer = round.started_ns }, { integer = Clock.now_ns() } })
    if not noted then return nil, noted_why end
    local sample, sample_why = db:prepare("INSERT INTO bench_runs (round, arm, bench, rep, ns_per_op, n, bytes) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
    if sample == nil then return nil, sample_why end
    for i, arm in ipairs(round.arms) do
      local put, put_why = db:run("INSERT INTO arms (round, name, binary, path) VALUES (?1, ?2, ?3, ?4)",
        { { text = id }, { text = arm.name }, { text = assert(shas[i]) }, { text = arm.path } })
      if not put then
        sample:close()
        return nil, put_why
      end
      for _, s in ipairs(arm.samples) do
        local kept, kept_why = sample:run({ { text = id }, { text = arm.name }, { text = s.bench },
          { integer = s.rep }, { number = s.ns_per_op }, { integer = s.n }, { integer = s.bytes } })
        if not kept then
          sample:close()
          return nil, kept_why
        end
      end
    end
    sample:close()
    return true
  end)
  if not ok then return nil, "results: " .. tostring(why) end
  return id
end

--- The samples of `arm` in the round `round`, in the order of their bench and rep.
function results.bench_samples(db: results.Store, round: string, arm: string): ({results.Sample}) | (nil, string)
  local rows, why = db:rows("SELECT bench, rep, ns_per_op, n, bytes FROM bench_runs WHERE round = ?1 AND arm = ?2 " ..
      "ORDER BY bench, rep", { { text = round }, { text = arm } })
  if rows == nil then return nil, "results: " .. tostring(why) end
  local found: mut {results.Sample} = {}
  for _, row in ipairs(rows) do
    found[#found + 1] = { bench = row:text(1), rep = row:integer(2), ns_per_op = row:number(3), n = row:integer(4),
      bytes = row:integer(5) }
  end
  return found
end

return results
