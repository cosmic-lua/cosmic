--- What the compile and verdict trims share: a cache the tree's tool
--- keeps in SQLite, rows stamped with the wall clock of the last run
--- that used or made them (`used_ns`), cut to what one run reached
--- before ci.yml saves it (cosmic_ci/compiles.tl, cosmic_ci/verdicts.tl).
---
--- Like the builds and the suites, which never fail over these caches,
--- a trim that cannot read one never fails the leg: it says why and
--- leaves the file, or removes one that is no database, and the next
--- run compiles or runs what it must.

local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")

local record CacheTrim
  --- What a trim left, and what it found.
  record Trimmed
    kept: integer
    removed: integer
    before_bytes: integer
    after_bytes: integer
    --- Whether any row was used since: false where the run reached
    --- none of the file, whose rows `trim` then keeps where asked to.
    reached: boolean
  end

  --- What `file` trims: the tables, by GLOB patterns, and whether a
  --- file the run reached none of keeps its rows.
  record Tables
    patterns: {string}
    whole_unless_reached: boolean
  end
end

--- How long a trim waits on another connection's lock, as the builds
--- and the suites wait (the `busy_ms` of build/shared_compiles.tl and
--- build/shared_verdicts.tl).
local busy_ms <const> = 10000

local function size(path: string): integer
  local st = Fs.stat(path)
  return st ~= nil and st.size or 0
end

local function count(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): integer | nil, string
  local rows, trouble = Sqlite.text_rows(db, sql, values)
  if rows == nil then return nil, trouble end
  return math.tointeger(tonumber(rows[1][1])) or 0, ""
end

--- Whether `trouble`, from SQLite, says the file is no database, or a
--- broken one, as build/shared_compiles.tl's and
--- build/shared_verdicts.tl's `corrupt` read it.
function CacheTrim.corrupt(trouble: string): boolean
  return trouble:find("malformed", 1, true) ~= nil or
    trouble:find("not a database", 1, true) ~= nil
end

--- Removes `path` and its write-ahead log and index, answering what it
--- removed.
function CacheTrim.remove_database(path: string): {string}
  local removed: {string} = {}
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    if Predicate.exists(path .. suffix) and (Fs.remove(path .. suffix)) then
      removed[#removed + 1] = path .. suffix
    end
  end
  return removed
end

--- Removes the caches the tool set aside beside `path` as broken
--- (`<name>.corrupt-<ns>`, with their logs: the `set_aside` of
--- build/shared_compiles.tl and build/shared_verdicts.tl), which no run
--- reads again and a save would otherwise carry from run to run.
--- Answers what it removed.
function CacheTrim.remove_set_aside(path: string): {string}
  local dir, name = Fs.dirname(path), Fs.basename(path)
  local prefix = name .. ".corrupt-"
  local removed: {string} = {}
  local listed, _ = Fs.list(dir)
  for _, entry in ipairs(listed or {}) do
    if entry:sub(1, #prefix) == prefix and (Fs.remove(dir .. "/" .. entry)) then
      removed[#removed + 1] = dir .. "/" .. entry
    end
  end
  return removed
end

--- Removes from the cache at `path` every row of the tables `tables`
--- names that no run has used or made since `since_ns` (the wall clock,
--- as a cache's `used_ns` is), then rewrites the file without the space
--- they took, and without the pages the tool's own bounds freed, which
--- SQLite keeps. Where `tables.whole_unless_reached`, a file none of
--- whose rows was used since -- one whose run never started -- keeps
--- them all. A table without a `used_ns` column is left whole. Nil and
--- "" for a file that is not there, and nil and why where the file
--- could not be trimmed.
-- TODO: ask the tool to trim its caches to what one run used, once
-- build/shared_compiles.tl and build/shared_verdicts.tl can (a verb, or
-- a bound the environment sets), rather than reach into their tables
-- here: this reads every table of their formats by its `used_ns`
-- column, and leaves a table without one whole.
function CacheTrim.trim(path: string, since_ns: integer,
                        tables: CacheTrim.Tables): CacheTrim.Trimmed | nil, string
  if not Predicate.exists(path) then return nil, "" end
  local before_bytes = size(path)
  local opened, open_trouble = Sqlite.open(path, true)
  if opened == nil then return nil, open_trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): CacheTrim.Trimmed | nil, string
    local _, _ = db:close()
    return nil, why
  end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. busy_ms)
  if not timed then return fail(time_trouble) end
  local globs: {string} = {}
  local values: {Sqlite.Value} = {}
  for i, pattern in ipairs(tables.patterns) do
    globs[#globs + 1] = "name GLOB ?" .. i
    values[#values + 1] = { text = pattern }
  end
  local names, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND (" ..
    table.concat(globs, " OR ") .. ") ORDER BY name", values)
  if names == nil then return fail(trouble) end
  local all_rows, used_rows = 0, 0
  local quoted: {string} = {}
  local stamped: {string} = {}
  for _, row in ipairs(names) do
    local name = row[1]
    local q = '"' .. name:gsub('"', '""') .. '"'
    quoted[#quoted + 1] = q
    local all, all_trouble = count(db, "SELECT count(*) FROM " .. q)
    if all == nil then return fail(all_trouble) end
    all_rows = all_rows + all
    local has, has_trouble = count(db,
      "SELECT count(*) FROM pragma_table_info(?1) WHERE name = 'used_ns'", { { text = name } })
    if has == nil then return fail(has_trouble) end
    if has == 1 then
      stamped[#stamped + 1] = q
      local used, used_trouble = count(db,
        "SELECT count(*) FROM " .. q .. " WHERE used_ns >= ?1", { { integer = since_ns } })
      if used == nil then return fail(used_trouble) end
      used_rows = used_rows + used
    end
  end
  local reached = used_rows > 0
  local left = all_rows
  if reached or not tables.whole_unless_reached then
    for _, q in ipairs(stamped) do
      local deleted, delete_trouble = Sqlite.run(db,
        "DELETE FROM " .. q .. " WHERE used_ns < ?1", { { integer = since_ns } })
      if not deleted then return fail(delete_trouble) end
    end
    left = 0
    for _, q in ipairs(quoted) do
      local n, n_trouble = count(db, "SELECT count(*) FROM " .. q)
      if n == nil then return fail(n_trouble) end
      left = left + n
    end
  end
  local vacuumed, vacuum_trouble = db:exec("VACUUM")
  if not vacuumed then return fail(vacuum_trouble) end
  local closed, close_trouble = db:close()
  if not closed then return nil, close_trouble end
  return { kept = left, removed = all_rows - left, before_bytes = before_bytes,
    after_bytes = size(path), reached = reached }, ""
end

--- Trims the cache at `path` (`trim`) to what was used since `since`,
--- in Unix seconds, after removing what was set aside beside it
--- (`remove_set_aside`), for the driver command `verb`: what it says on
--- standard output and on standard error. A cache it cannot trim is
--- said so, on standard error, and left, or removed where it is no
--- database.
function CacheTrim.file(verb: string, path: string, since: integer,
                        tables: CacheTrim.Tables): string, string
  local out = ""
  local aside = CacheTrim.remove_set_aside(path)
  if #aside > 0 then
    out = verb .. ": removed what was set aside: " .. table.concat(aside, ", ") .. "\n"
  end
  local trimmed, trouble = CacheTrim.trim(path, since * 1000000000, tables)
  if trimmed == nil and trouble == "" then
    return out .. verb .. ": " .. path .. " is not there; nothing to trim\n", ""
  end
  if trimmed == nil then
    if CacheTrim.corrupt(trouble) then
      local gone = CacheTrim.remove_database(path)
      return out, verb .. ": " .. path .. ": " .. trouble ..
        "; removed " .. table.concat(gone, ", ") .. "\n"
    end
    return out, verb .. ": " .. path .. ": " .. trouble .. "; the cache is left as it is\n"
  end
  local what: string
  if not trimmed.reached and trimmed.removed == 0 and tables.whole_unless_reached then
    what = "kept all " .. trimmed.kept .. ", none used since " .. since ..
      " (no run reached it)"
  else
    what = "kept " .. trimmed.kept .. " used since " .. since .. ", removed " .. trimmed.removed
  end
  return out .. verb .. ": " .. what .. "; " .. path .. " " .. trimmed.before_bytes ..
    " -> " .. trimmed.after_bytes .. " bytes\n", ""
end

--- SINCE, the first of `argv`, in Unix seconds, or nil where it is none.
function CacheTrim.since(argv: {string}): integer | nil
  local since = math.tointeger(tonumber(argv[1] or ""))
  if since == nil or since < 0 then return nil end
  return since
end

return CacheTrim
