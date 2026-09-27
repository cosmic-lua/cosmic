--- The passing test verdicts every checkout of a tree shares: a SQLite
--- database under the cosmic cache directory -- `verdicts/verdicts.db`
--- by default, or the absolute path `COSMIC_VERDICT_CACHE` names, and
--- none at all when it is `0` -- beside the one each checkout keeps in
--- `o/build.db`. Only a sandboxed run's verdicts are shared: its key is
--- the digest of everything its test was given (`build.declared_key`),
--- naming nothing of where the tree is, so a verdict one checkout reached
--- stands in another of the same content, and a fresh worktree runs only
--- what no sibling has run already. An unsandboxed run's verdicts, keyed
--- by what its test was seen to read, are its checkout's alone.
---
--- The cache is a plain map from key to verdict: a row holds no
--- evidence of what the run read to check again -- the key reached is
--- the whole check -- only the test it is of, the lines it hit, for the
--- coverage it is credited, and how long it took.
---
--- Many runs share the file at once: it is in WAL mode, so a reader
--- never waits on a writer, and a run reads it a statement at a time
--- and writes what it owes it in one short transaction as it ends. It
--- is bounded: a row no run has relied on for `kept_ns` goes, and past
--- `kept_rows` rows, the least lately relied on go first. A failing
--- run of a key takes the key's row out, and a checkout that holds a
--- verdict of its own under a key never takes another's for it. A
--- cache that cannot be opened, read or written -- corrupt, or holding
--- this format's table in another shape -- is said so and done
--- without: it never fails a run.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")

local record shared_verdicts
  --- An open cache.
  record Cache
    db: Sqlite.Handle
    path: string
  end

  --- A passing verdict's coverage and duration.
  record Found
    hits: string
    elapsed_ns: integer
  end

  --- One passing verdict a run reached, to keep.
  record Kept
    key: string
    test: string
    hits: string
    elapsed_ns: integer
  end

  --- What a run owes the cache when it ends.
  record Owed
    kept: {Kept}
    --- Keys the run relied on, which stay the longer for it.
    used: {string}
    --- Keys the run failed under, whose rows go.
    failed: {string}
  end
end

--- The variable that moves the cache, or turns it off with `0`.
local variable <const> = "COSMIC_VERDICT_CACHE"

--- How many rows the cache keeps: some five whole runs of this tree,
--- at a few kilobytes a row.
local kept_rows <const> = 8192

--- How long a row no run relies on is kept: thirty days.
local kept_ns <const> = 30 * 24 * 3600 * 1000000000

--- How long a write waits on another run's: its transactions are short.
local busy_ms <const> = 10000

--- The table rows are in, by their declared key alone: `declared_v1`.
--- A later format keeps a table of its own, so a binary of it sharing
--- the file never empties this one's; nor does this one empty the
--- tables observation-keyed runs shared (`prepare`).
local declared <const> = "declared_v1"

local text = bind.text

--- Where the cache is: `COSMIC_VERDICT_CACHE` when it names a path,
--- else `verdicts.db` in `Fs.cache_dir("verdicts")`, made if missing.
--- Nil and "" when the variable is `0`, or nil and why when there is
--- nowhere to keep it.
function shared_verdicts.location(environment?: {string:string}): string | nil, string
  local value: string
  if environment ~= nil then
    value = environment[variable] or ""
  else
    value = Env.get_or(variable, "")
  end
  if value == "0" then return nil, "" end
  if value ~= "" then
    if value:sub(1, 1) ~= "/" then
      return nil, variable .. " names no absolute path: " .. value
    end
    return value, ""
  end
  local dir, trouble = Fs.cache_dir("verdicts", environment)
  if dir == nil then return nil, trouble end
  return dir .. "/verdicts.db", ""
end

--- Turns the cache off in `environment`, for a process that is to
--- neither read nor write it.
function shared_verdicts.turn_off(environment: {string:string})
  environment[variable] = "0"
end

local schema <const> = {
  "CREATE TABLE IF NOT EXISTS " .. declared .. [[ (key TEXT PRIMARY KEY,
                                                  test TEXT NOT NULL,
                                                  hits BLOB NOT NULL,
                                                  elapsed_ns INTEGER NOT NULL,
                                                  used_ns INTEGER NOT NULL,
                                                  origin TEXT NOT NULL)]],
  "CREATE INDEX IF NOT EXISTS " .. declared .. "_by_use ON " .. declared .. " (used_ns)",
}

--- Hits as `build.test` encodes them -- a line per module, its path, a
--- tab, then the lines it hit, ascending and comma-separated -- with
--- each line after a module's first as its distance from the one
--- before: runs of adjacent lines, which most hits are, deflate to
--- little that way.
local function packed(hits: string): string
  return (hits:gsub("([^\t\n]*)\t([^\n]*)\n", function(path: string, lines: string): string
    local out: {string} = {}
    local last = 0
    for line in lines:gmatch("%d+") do
      local number = math.tointeger(tonumber(line)) or 0
      out[#out + 1] = tostring(number - last)
      last = number
    end
    return path .. "\t" .. table.concat(out, ",") .. "\n"
  end))
end

--- `packed` undone.
local function unpacked(hits: string): string
  return (hits:gsub("([^\t\n]*)\t([^\n]*)\n", function(path: string, lines: string): string
    local out: {string} = {}
    local last = 0
    for step in lines:gmatch("%d+") do
      last = last + (math.tointeger(tonumber(step)) or 0)
      out[#out + 1] = tostring(last)
    end
    return path .. "\t" .. table.concat(out, ",") .. "\n"
  end))
end

--- Makes this format's table when the file has none yet, in one
--- transaction; a file that has it is only read. The tables
--- observation-keyed runs shared (`verdicts_v<n>`) are left as they
--- are: a binary of that format sharing the file still writes its own
--- and ages its rows out, and none of this one's reads them.
local function prepare(db: Sqlite.Handle): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = '" .. declared .. "'")
  if rows == nil then return false, trouble end
  if #rows > 0 then return true, "" end
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  for _, statement in ipairs(schema) do
    local ok, statement_trouble = db:exec(statement)
    if not ok then
      local _, _ = db:exec("ROLLBACK")
      return false, statement_trouble
    end
  end
  return db:exec("COMMIT")
end

--- Opens the cache at `path`, making it and its directory when missing.
function shared_verdicts.open(path: string): shared_verdicts.Cache | nil, string
  local made, made_trouble = Fs.mkdirs(Fs.dirname(path))
  if not made then return nil, made_trouble end
  local opened, trouble = Sqlite.open(path, true)
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): shared_verdicts.Cache | nil, string
    local _, _ = db:close()
    return nil, path .. ": " .. why
  end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. busy_ms)
  if not timed then return fail(time_trouble) end
  local journal, journal_trouble = Sqlite.text_rows(db, "PRAGMA journal_mode = WAL")
  if journal == nil then return fail(journal_trouble) end
  local prepared, prepare_trouble = prepare(db)
  if not prepared then return fail(prepare_trouble) end
  return { db = db, path = path }
end

function shared_verdicts.close(cache: shared_verdicts.Cache)
  local _, _ = cache.db:close()
end

--- Whether `trouble`, from a query of the cache, says the file itself
--- is broken, rather than, say, busy.
function shared_verdicts.corrupt(trouble: string): boolean
  return trouble:find("malformed", 1, true) ~= nil or
    trouble:find("not a database", 1, true) ~= nil
end

--- Moves a broken cache aside, write-ahead log and all -- the log and
--- its index first, so no one opening the path meanwhile finds the old
--- log beside a new file -- to `<path>.corrupt-<now_ns>`, removing any
--- earlier one set aside there, so the next run starts a fresh cache
--- rather than meeting it again, and at most one is kept. Answers where
--- it went, or nil and why.
function shared_verdicts.set_aside(path: string, now_ns: integer): string | nil, string
  local dir, name = Fs.dirname(path), Fs.basename(path)
  local listed, _ = Fs.list(dir)
  for _, entry in ipairs(listed or {}) do
    if entry:sub(1, #name + 9) == name .. ".corrupt-" then
      local _, _ = Fs.remove(dir .. "/" .. entry)
    end
  end
  local aside = path .. ".corrupt-" .. tostring(now_ns)
  for _, suffix in ipairs({ "-wal", "-shm" }) do
    local there, _ = Fs.stat(path .. suffix)
    if there ~= nil then
      local _, _ = Fs.rename(path .. suffix, aside .. suffix)
    end
  end
  local moved_file, trouble = Fs.rename(path, aside)
  if not moved_file then return nil, trouble end
  return aside, ""
end

--- The coverage and duration of the passing verdict under the declared
--- `key` (`build.declared_key`), or nil: the key is the whole check.
function shared_verdicts.declared(cache: shared_verdicts.Cache,
                                  key: string): shared_verdicts.Found | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT CAST(inflate(hits) AS TEXT), elapsed_ns FROM " .. declared .. " WHERE key = ?1",
    { text(key) })
  if rows == nil then return nil, trouble end
  if rows[1] == nil then return nil, "" end
  return { hits = unpacked(rows[1][1]),
    elapsed_ns = math.tointeger(tonumber(rows[1][2]) or 0) or 0 }, ""
end

--- Writes what a run owes the cache, at `now_ns`, and drops what it no
--- longer keeps, in one transaction. `origin` names the checkout
--- writing each row.
function shared_verdicts.settle(cache: shared_verdicts.Cache, origin: string,
                                owed: shared_verdicts.Owed, now_ns: integer): boolean, string
  local db = cache.db
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    local tables: {string} = { declared }
    for _, key in ipairs(owed.failed) do
      for _, name in ipairs(tables) do
        local ok, trouble = Sqlite.run(db, "DELETE FROM " .. name .. " WHERE key = ?1", { text(key) })
        if not ok then return false, trouble end
      end
    end
    for _, kept in ipairs(owed.kept) do
      local ok, trouble = Sqlite.run(db,
        "INSERT OR REPLACE INTO " .. declared .. " (key, test, hits, elapsed_ns, used_ns, " ..
        "origin) VALUES (?1, ?2, deflate(?3), ?4, ?5, ?6)",
        { text(kept.key), text(kept.test), text(packed(kept.hits)),
          { integer = kept.elapsed_ns }, { integer = now_ns }, text(origin) })
      if not ok then return false, trouble end
    end
    for _, key in ipairs(owed.used) do
      for _, name in ipairs(tables) do
        local ok, trouble = Sqlite.run(db, "UPDATE " .. name .. " SET used_ns = ?1 WHERE key = ?2",
          { { integer = now_ns }, text(key) })
        if not ok then return false, trouble end
      end
    end
    for _, name in ipairs(tables) do
      local aged, age_trouble = Sqlite.run(db, "DELETE FROM " .. name .. " WHERE used_ns < ?1",
        { { integer = now_ns - kept_ns } })
      if not aged then return false, age_trouble end
      local bounded, bound_trouble = Sqlite.run(db, "DELETE FROM " .. name ..
        " WHERE key IN (SELECT key FROM " .. name .. " " ..
        "ORDER BY used_ns DESC LIMIT -1 OFFSET " .. kept_rows .. ")")
      if not bounded then return false, bound_trouble end
    end
    return true, ""
  end
  local ok, trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, trouble
  end
  return db:exec("COMMIT")
end

return shared_verdicts
