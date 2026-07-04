--- SQLite scenarios: transactional writes, point queries, aggregate scans.
--- Exercises the cosmic.sqlite ergonomic API and the bundled lsqlite3
--- C binding end to end, against a real database file on disk.

local sqlite = require("cosmic.sqlite")
local fs = require("cosmic.fs")
local pt = require("perf.perf_types")

local ROWS = 2000
local INSERT_BATCH = 100

local tmpdir: string
local db: sqlite.Database

--- Base directory for scratch files.
--- @return string An existing writable directory
local function tmp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Create the scratch database and seed deterministic rows.
--- @return string Error message, or nil on success
local function init_db(): string
  local dir, derr = fs.mkdtemp(fs.join(tmp_base(), "perf-sqlite-XXXXXX"))
  if dir == nil then
    return "mkdtemp: " .. tostring(derr)
  end
  tmpdir = dir
  local d, oerr = sqlite.open(fs.join(dir, "bench.db"))
  if d == nil then
    return "open: " .. tostring(oerr)
  end
  db = d
  -- WAL with NORMAL sync keeps commit costs realistic while avoiding
  -- fsync dominating every sample with filesystem-dependent noise.
  local pragmas = "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"
  local ok, err = db:exec(pragmas)
  if not ok then
    return "pragma: " .. tostring(err)
  end
  ok, err = db:exec([[
    CREATE TABLE kv (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL NOT NULL);
    CREATE TABLE scratch (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score REAL NOT NULL);
  ]])
  if not ok then
    return "create: " .. tostring(err)
  end
  local tok, terr = db:transaction(function(tx: sqlite.Database)
      for i = 1, ROWS do
        assert(tx:exec("INSERT INTO kv (id, name, score) VALUES (?, ?, ?)",
            i, "row-" .. i, i * 0.25))
      end
    end)
  if not tok then
    return "seed: " .. tostring(terr)
  end
  return nil
end

local function scenarios(): {pt.Scenario}, string
  local ierr = init_db()
  if ierr then
    return nil, ierr
  end

  local query_id = 0

  return {
    {
      -- Insert a batch then delete it inside one transaction, so the
      -- database stays the same size and samples remain comparable.
      name = "sqlite_insert_delete_tx",
      fn = function(_: any): any
        local ok, err = db:transaction(function(tx: sqlite.Database)
            for i = 1, INSERT_BATCH do
              assert(tx:exec("INSERT INTO scratch (name, score) VALUES (?, ?)",
                  "s-" .. i, i * 1.5))
            end
            assert(tx:exec("DELETE FROM scratch"))
          end)
        assert(ok, err)
        return ok
      end,
      check = function(_: any, res: any): boolean, string
        if res ~= true then
          return false, "transaction did not succeed"
        end
        local row, qerr = db:query_one("SELECT COUNT(*) AS n FROM scratch")
        if row == nil then
          return false, "count query failed: " .. tostring(qerr)
        end
        if row.n ~= 0 then
          return false, "scratch table not empty: " .. tostring(row.n)
        end
        return true
      end,
    },
    {
      name = "sqlite_point_query",
      fn = function(_: any): any
        query_id = (query_id % ROWS) + 1
        local row, err = db:query_one("SELECT id, name, score FROM kv WHERE id = ?", query_id)
        assert(row, err)
        return row
      end,
      -- Validated against the row's own id (the harness may run extra
      -- probe iterations, so query_id has moved on by check time).
      check = function(_: any, res: any): boolean, string
        local row = res as {string: any}
        if row == nil then
          return false, "no row returned"
        end
        local id = row.id as number
        if id == nil or row.name ~= "row-" .. math.floor(id) then
          return false, "wrong row: " .. tostring(row.name)
        end
        if row.score as number ~= id * 0.25 then
          return false, "wrong score: " .. tostring(row.score)
        end
        return true
      end,
    },
    {
      name = "sqlite_scan_aggregate",
      fn = function(_: any): any
        local row, err = db:query_one("SELECT COUNT(*) AS n, SUM(score) AS total FROM kv")
        assert(row, err)
        return row
      end,
      check = function(_: any, res: any): boolean, string
        local row = res as {string: any}
        if row == nil then
          return false, "no row returned"
        end
        if row.n ~= ROWS then
          return false, "wrong count: " .. tostring(row.n)
        end
        -- SUM(i * 0.25) for i in 1..ROWS
        local expected = ROWS * (ROWS + 1) / 2 * 0.25
        local total = row.total as number
        if total == nil or math.abs(total - expected) > 0.001 then
          return false, "wrong sum: " .. tostring(row.total)
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if db then
    db:close()
    db = nil
  end
  if tmpdir then
    fs.rmrf(tmpdir)
    tmpdir = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
