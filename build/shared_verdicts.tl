--- The passing test verdicts every checkout of a tree shares: a SQLite
--- database under the cosmic cache directory -- `verdicts/verdicts.db`
--- by default, or the absolute path `COSMIC_VERDICT_CACHE` names, and
--- none at all when it is `0` -- beside the one each checkout keeps in
--- `o/build.db`. A verdict key names nothing of where the tree is (see
--- `build.test`'s `verdict_key`), so a verdict one checkout reached
--- stands in another of the same content: a fresh worktree runs only
--- what no sibling has run already.
---
--- A row holds one passing verdict: its key, the test and module key it
--- is of, what the run read -- as `o/build.db`'s `runs` holds it, with
--- every path under the tree named by `observations.tree_name` so any
--- checkout reads it back as its own -- the lines it hit, for the
--- coverage it is credited, and how long it took. A run no key could
--- hold is kept too, marked as `runs` marks it, with what it was
--- compiled from and ran under: it is assumed in another checkout on
--- the same terms as in its own, and never under `--all`.
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
local observations = require("build.filesystem_observations")

local record shared_verdicts
  --- An open cache.
  record Cache
    db: Sqlite.Handle
    path: string
  end

  --- One passing verdict the cache holds for a test: the key it was
  --- reached under, and what its run read, as `runs` encodes it, in
  --- the paths of the checkout that asked.
  record Candidate
    key: string
    reads: string
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
    module_key: string
    --- What the run read, as `runs` encodes it, in its own paths.
    reads: string
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

--- How many of a test's verdicts, most lately relied on first, a run
--- tries: one per state of what it read that a checkout ran it in --
--- few for most, more for one that reads what every change moves.
local candidates_tried <const> = 32

--- The table rows of this format are in: `verdicts_v<format>`. Each
--- format keeps a table of its own, so binaries of two formats sharing
--- one file each keep theirs rather than emptying the other's.
local verdicts <const> = "verdicts_v3"

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
  "CREATE TABLE IF NOT EXISTS " .. verdicts .. [[ (key TEXT PRIMARY KEY,
                                                   test TEXT NOT NULL,
                                                   module_key TEXT NOT NULL,
                                                   reads BLOB NOT NULL,
                                                   hits BLOB NOT NULL,
                                                   elapsed_ns INTEGER NOT NULL,
                                                   used_ns INTEGER NOT NULL)]],
  "CREATE INDEX IF NOT EXISTS " .. verdicts .. "_by_test ON " .. verdicts ..
    " (test, module_key, used_ns)",
  "CREATE INDEX IF NOT EXISTS " .. verdicts .. "_by_use ON " .. verdicts .. " (used_ns)",
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
--- transaction; a file that has it is only read.
local function prepare(db: Sqlite.Handle): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = ?1",
    { text(verdicts) })
  if rows == nil then return false, trouble end
  if rows[1] ~= nil and rows[1][1] ~= "0" then return true, "" end
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

--- `encoded`, as `runs` encodes what a run read, with each path of it
--- moved by `move`; nil when it is no such encoding.
local function moved(encoded: string, move: function(string): string): string | nil
  local function each(reads: {observations.Observation}): {observations.Observation}
    local out: {observations.Observation} = {}
    for i, observation in ipairs(reads) do
      local kind = observation.kind
      local path = observation.path
      if kind ~= "e" then path = move(path) end
      out[i] = { kind = kind, path = path, answer = observation.answer }
    end
    return out
  end
  local reads = observations.decode(encoded)
  if reads ~= nil then return observations.encode(each(reads)) end
  local unstable = observations.decode_unstable(encoded)
  if unstable ~= nil then
    return observations.encode_unstable(unstable.identity, each(unstable.reads))
  end
  return nil
end

--- What a run under `root` read, as `runs` encodes it, with each path
--- under the root named as any checkout reads it back
--- (`rooted`); nil when it is no such encoding.
local function portable(root: string, encoded: string): string | nil
  return moved(encoded, function(path: string): string
    return observations.tree_name(path, root)
  end)
end

--- `portable` undone under `root`, which may be
--- another checkout's.
local function rooted(root: string, encoded: string): string | nil
  return moved(encoded, function(name: string): string
    return observations.tree_path(name, root)
  end)
end

--- The passing verdicts the cache holds for one test of a module at
--- `module_key`, most lately relied on first, with what each run read
--- in `root`'s paths.
function shared_verdicts.candidates(cache: shared_verdicts.Cache, root: string, test: string,
                                    module_key: string): {shared_verdicts.Candidate} | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT key, CAST(inflate(reads) AS TEXT) FROM " .. verdicts .. " " ..
    "WHERE test = ?1 AND module_key = ?2 ORDER BY used_ns DESC LIMIT " .. candidates_tried,
    { text(test), text(module_key) })
  if rows == nil then return nil, trouble end
  local out: {shared_verdicts.Candidate} = {}
  for _, row in ipairs(rows) do
    local reads = rooted(root, row[2])
    if reads ~= nil then out[#out + 1] = { key = row[1], reads = reads } end
  end
  return out, ""
end

--- The coverage and duration of the verdict under `key`, or nil.
function shared_verdicts.found(cache: shared_verdicts.Cache,
                               key: string): shared_verdicts.Found | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT CAST(inflate(hits) AS TEXT), elapsed_ns FROM " .. verdicts .. " WHERE key = ?1",
    { text(key) })
  if rows == nil then return nil, trouble end
  if rows[1] == nil then return nil, "" end
  return { hits = unpacked(rows[1][1]),
    elapsed_ns = math.tointeger(tonumber(rows[1][2]) or 0) or 0 }, ""
end

--- Writes what a run under `root` owes the cache, at `now_ns`, and
--- drops what it no longer keeps, in one transaction.
function shared_verdicts.settle(cache: shared_verdicts.Cache, root: string,
                                owed: shared_verdicts.Owed, now_ns: integer): boolean, string
  local db = cache.db
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    for _, key in ipairs(owed.failed) do
      local ok, trouble = Sqlite.run(db, "DELETE FROM " .. verdicts .. " WHERE key = ?1", { text(key) })
      if not ok then return false, trouble end
    end
    for _, kept in ipairs(owed.kept) do
      local reads = portable(root, kept.reads)
      if reads ~= nil then
        local ok, trouble = Sqlite.run(db,
          "INSERT OR REPLACE INTO " .. verdicts .. " (key, test, module_key, reads, hits, " ..
          "elapsed_ns, used_ns) VALUES (?1, ?2, ?3, deflate(?4), deflate(?5), ?6, ?7)",
          { text(kept.key), text(kept.test), text(kept.module_key), text(reads),
            text(packed(kept.hits)), { integer = kept.elapsed_ns }, { integer = now_ns } })
        if not ok then return false, trouble end
      end
    end
    for _, key in ipairs(owed.used) do
      local ok, trouble = Sqlite.run(db, "UPDATE " .. verdicts .. " SET used_ns = ?1 WHERE key = ?2",
        { { integer = now_ns }, text(key) })
      if not ok then return false, trouble end
    end
    local aged, age_trouble = Sqlite.run(db, "DELETE FROM " .. verdicts .. " WHERE used_ns < ?1",
      { { integer = now_ns - kept_ns } })
    if not aged then return false, age_trouble end
    return Sqlite.run(db, "DELETE FROM " .. verdicts .. " WHERE key IN (SELECT key FROM " ..
      verdicts .. " " ..
      "ORDER BY used_ns DESC LIMIT -1 OFFSET " .. kept_rows .. ")")
  end
  local ok, trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, trouble
  end
  return db:exec("COMMIT")
end

return shared_verdicts
