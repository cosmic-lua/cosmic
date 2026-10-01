--- What the compile and verdict trims share. Each cache is a SQLite
--- file the tree's tool keeps, whose rows carry the wall clock of the
--- last run that used or made them (`used_ns`). Before ci.yml saves a
--- cache, a trim cuts it to the rows one run reached
--- (cosmic_ci/compiles.tl, cosmic_ci/verdicts.tl). The key ci.yml saves
--- it under ends in a `digest` of the rows kept, so a run that kept the
--- rows of an earlier save names that save's key and saves nothing new.
---
--- Like the builds and the suites, which never fail over these caches,
--- a trim that cannot read one never fails the leg. It says why, then
--- leaves the file or, where the file is no database, removes it; the
--- next run compiles or runs what it must.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")
local SqliteOpen = require("cosmic_ci.sqlite_open")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")

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
    --- The tables matched that have no `used_ns` column to trim by,
    --- which `trim` keeps whole: a format of the tool's this trim does
    --- not know.
    unstamped: {string}
  end

  --- What `file` trims: the tables, by GLOB patterns, and whether a
  --- file the run reached none of keeps its rows.
  record Tables
    patterns: {string}
    whole_unless_reached: boolean
  end
end

--- How long a trim waits on another connection's lock, as the builds
--- and the suites wait (the `busy_ms` of build/shared_sqlite.tl).
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
--- broken one, as build/shared_sqlite.tl's `corrupt` reads it.
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
--- (`<name>.corrupt-<ns>`, with their logs: build/shared_sqlite.tl's
--- `set_aside`), which no run
--- reads again and a save would otherwise carry from run to run.
--- Answers what it removed.
function CacheTrim.remove_set_aside(path: string): {string}
  local dir, name = Fs.dirname(path), Fs.basename(path)
  local prefix = name .. ".corrupt-"
  local removed: {string} = {}
  local listed, _ = Fs.list(dir)
  for _, entry in ipairs(listed or {}) do
    if String.starts_with(entry, prefix) and (Fs.remove(dir .. "/" .. entry)) then
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
--- whose rows was used since (one whose run never started) keeps them
--- all. A table without a `used_ns` column is left whole and named in
--- the answer's `unstamped`. Answers nil and "" for a file that is not
--- there, and nil and why where the file could not be trimmed.
-- TODO: ask the tool to trim its caches to what one run used, rather
-- than reach into their tables here, once ci/cosmic-driver.pin names a
-- release with a verb that does (through build/shared_sqlite.tl, beside
-- build/shared_compiles.tl's and build/shared_verdicts.tl's formats),
-- which the tree has yet to add: the trims run where the tree's
-- o/bin/cosmic may never have been built (ci.yml's steps need only the
-- driver), and this module, on the pinned release, cannot require the
-- tree's. This reads every table of their formats by its `used_ns`
-- column, and leaves a table without one whole.
function CacheTrim.trim(path: string, since_ns: integer,
                        tables: CacheTrim.Tables): CacheTrim.Trimmed | nil, string
  if not Predicate.exists(path) then return nil, "" end
  local before_bytes = size(path)
  local opened, open_trouble = SqliteOpen.writable(path)
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
  local unstamped: {string} = {}
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
    else
      unstamped[#unstamped + 1] = name
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
    after_bytes = size(path), reached = reached, unstamped = unstamped }, ""
end

--- Trims the cache at `path` (`trim`) to what was used since `since`,
--- in Unix seconds, after removing what was set aside beside it
--- ([`remove_set_aside`]), for the driver command `verb`. Answers what to
--- say on standard output and on standard error. A cache it cannot trim
--- is reported on standard error and left, or removed where it is no
--- database. A table kept whole for want of a `used_ns` column is
--- reported too, since a save would carry it from run to run unseen.
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
  local err = ""
  if #trimmed.unstamped > 0 then
    err = verb .. ": " .. path .. ": kept whole, with no used_ns column to trim by: " ..
      table.concat(trimmed.unstamped, ", ") .. "\n"
  end
  return out .. verb .. ": " .. what .. "; " .. path .. " " .. trimmed.before_bytes ..
    " -> " .. Plural.count(trimmed.after_bytes, "byte") .. "\n", err
end

--- Feeds `hasher` the rows of the cache at `path`: every table of it
--- but SQLite's own, by name, each row in order, every column but
--- `used_ns`. Each run that stands on a row stamps `used_ns` again, and
--- it decides only what a trim keeps, so two files that hold the same
--- rows feed the same bytes whatever SQLite made of their pages or when
--- a run last used them. Answers why where it could not read the file.
local function feed_rows(hasher: Hash.Hasher, path: string): boolean, string
  -- Writable, as the trim opens it: a reader of a file in write-ahead
  -- mode leaves its log and index behind, which the save would carry.
  local opened, open_trouble = SqliteOpen.writable(path)
  if opened == nil then return false, open_trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): boolean, string
    local _, _ = db:close()
    return false, why
  end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. busy_ms)
  if not timed then return fail(time_trouble) end
  local names, trouble = Sqlite.text_rows(db, "SELECT name FROM sqlite_schema " ..
    "WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
  if names == nil then return fail(trouble) end
  for _, row in ipairs(names) do
    local name = row[1]
    local columns, column_trouble = Sqlite.text_rows(db,
      "SELECT name FROM pragma_table_info(?1) WHERE name <> 'used_ns' ORDER BY cid",
      { { text = name } })
    if columns == nil then return fail(column_trouble) end
    local quoted: {string} = {}
    local order: {string} = {}
    for i, column in ipairs(columns) do
      quoted[i] = '"' .. column[1]:gsub('"', '""') .. '"'
      order[i] = tostring(i)
      hasher:update("column\0" .. #column[1] .. ":" .. column[1])
    end
    hasher:update("table\0" .. #name .. ":" .. name .. "\0" .. #columns .. "\0")
    if #quoted > 0 then
      local query, query_trouble = Sqlite.query(db, "SELECT " .. table.concat(quoted, ", ") ..
        ' FROM "' .. name:gsub('"', '""') .. '" ORDER BY ' .. table.concat(order, ", "))
      if query == nil then return fail(query_trouble) end
      do
        local q <close> = query
        for cells in q:each() do
          for _, cell in ipairs(cells) do
            local value = cell.text or cell.blob or
              (cell.integer ~= nil and tostring(cell.integer)) or
              (cell.number ~= nil and string.format("%.17g", cell.number)) or ""
            hasher:update(cell.kind .. "\0" .. #value .. ":" .. value)
          end
          hasher:update("\n")
        end
        if q:failure() ~= "" then return fail(q:failure()) end
      end
    end
  end
  local closed, close_trouble = db:close()
  if not closed then return false, close_trouble end
  return true, ""
end

--- The digest of what `paths` hold, as ci.yml's save of them names it,
--- in hexadecimal: each file by its name and its rows ([`feed_rows`]), so
--- a run whose trimmed cache holds the rows of one saved already names
--- that save's key again, and saves nothing new. A file not there is
--- fed as absent; one whose rows cannot be read, by its bytes, which
--- differ from run to run, so its cache is saved again rather than
--- mistaken for another; and the second answer says why, for the log.
function CacheTrim.digest(paths: {string}): string, string
  local hasher = assert(Hash.hasher("sha256"))
  local troubles: {string} = {}
  for _, path in ipairs(paths) do
    local name = Fs.basename(path)
    hasher:update("file\0" .. #name .. ":" .. name .. "\0")
    if not Predicate.exists(path) then
      hasher:update("absent\0")
    else
      local fed, trouble = feed_rows(hasher, path)
      if not fed then
        troubles[#troubles + 1] = path .. ": " .. trouble .. "; digested by its bytes"
        hasher:update("bytes\0" .. (Fs.read(path) or ""))
      end
    end
  end
  return Codec.hex((assert(hasher:digest()))), table.concat(troubles, "\n")
end

--- Appends `name=value` to the file `env.GITHUB_OUTPUT` names, a
--- workflow step's outputs, where it names one, as
--- cosmic_ci/context.tl's `summarize` appends to the step's summary;
--- answers why where it could not.
function CacheTrim.output(env: {string:string}, name: string, value: string): string
  local file = env.GITHUB_OUTPUT or ""
  if file == "" then return "" end
  local existing = ""
  if Predicate.exists(file) then
    local read, read_trouble = Fs.read(file)
    if read == nil then return file .. ": " .. read_trouble end
    existing = read
  end
  local wrote, trouble = Fs.write(file, existing .. name .. "=" .. value .. "\n")
  if not wrote then return file .. ": " .. trouble end
  return ""
end

--- SINCE, the first of `argv`, in Unix seconds, or nil where it is none.
function CacheTrim.since(argv: {string}): integer | nil
  local since = math.tointeger(tonumber(argv[1] or ""))
  if since == nil or since < 0 then return nil end
  return since
end

return CacheTrim
