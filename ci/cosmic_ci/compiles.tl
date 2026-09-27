--- The compiles and parses a leg keeps from one run to the next: the file
--- COSMIC_BUILD_CACHE names (build/shared_compiles.tl in the candidate),
--- which ci.yml restores before the leg's builds and saves after them.
---
--- The file bounds itself only at 256 MB and thirty days, and every
--- change to the build's own modules moves every row's key, so a file
--- each run saves back grows by a tree's worth of compiles (about 3 MB)
--- with most commits to main, to that bound, and the repository's cache,
--- which holds 10 GB for every entry, would hold that much again with
--- each save. So a leg keeps only what its own run used or compiled
--- (`trim`): what the next run of the tree it built needs, and no more.
---
--- Like the builds, which never fail over this cache, a trim that cannot
--- read it never fails the leg: it says why and leaves the file, or
--- removes one that is no database, and the next run's builds compile
--- what they must.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")

local record Compiles
  --- What a trim left, and what it found.
  record Trimmed
    kept: integer
    removed: integer
    before_bytes: integer
    after_bytes: integer
  end
end

--- How long the trim waits on another connection's lock, as the builds
--- wait (build/shared_compiles.tl's `busy_ms`).
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
--- broken one, as build/shared_compiles.tl's `corrupt` reads it.
local function corrupt(trouble: string): boolean
  return trouble:find("malformed", 1, true) ~= nil or
    trouble:find("not a database", 1, true) ~= nil
end

--- Removes `path` and its write-ahead log and index, answering what it
--- removed.
local function remove_database(path: string): {string}
  local removed: {string} = {}
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    if Predicate.exists(path .. suffix) and (Fs.remove(path .. suffix)) then
      removed[#removed + 1] = path .. suffix
    end
  end
  return removed
end

--- Removes the caches the builds set aside beside `path` as broken
--- (`<name>.corrupt-<ns>`, with their logs: build/shared_compiles.tl's
--- `set_aside`), which no build reads again and a save would otherwise
--- carry from run to run. Answers what it removed.
function Compiles.remove_set_aside(path: string): {string}
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

--- Removes from the cache at `path` every compile and parse no build has
--- used or made since `since_ns` (the wall clock, as the cache's `used_ns` is),
--- then rewrites the file without the space they took. Nil and "" for a
--- file that is not there, which a leg whose builds never started
--- leaves, and nil and why where the file could not be trimmed.
-- TODO: ask the tool to trim its cache to what one run used, once
-- build/shared_compiles.tl can (a verb, or a bound the environment
-- sets), rather than reach into its tables here: this reads every table
-- of its formats (`compiled_v<n>`, `parsed_v<n>`) by its `used_ns`
-- column, and leaves a table without one whole.
function Compiles.trim(path: string, since_ns: integer): Compiles.Trimmed | nil, string
  if not Predicate.exists(path) then return nil, "" end
  local before_bytes = size(path)
  local opened, open_trouble = Sqlite.open(path, true)
  if opened == nil then return nil, open_trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): Compiles.Trimmed | nil, string
    local _, _ = db:close()
    return nil, why
  end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. busy_ms)
  if not timed then return fail(time_trouble) end
  local tables, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND " ..
    "(name GLOB 'compiled_v[0-9]*' OR name GLOB 'parsed_v[0-9]*')")
  if tables == nil then return fail(trouble) end
  local kept, removed = 0, 0
  for _, row in ipairs(tables) do
    local name = row[1]
    local quoted = '"' .. name:gsub('"', '""') .. '"'
    local all, all_trouble = count(db, "SELECT count(*) FROM " .. quoted)
    if all == nil then return fail(all_trouble) end
    local used, used_trouble = count(db,
      "SELECT count(*) FROM pragma_table_info(?1) WHERE name = 'used_ns'", { { text = name } })
    if used == nil then return fail(used_trouble) end
    if used == 1 then
      local deleted, delete_trouble = Sqlite.run(db,
        "DELETE FROM " .. quoted .. " WHERE used_ns < ?1", { { integer = since_ns } })
      if not deleted then return fail(delete_trouble) end
      local left, left_trouble = count(db, "SELECT count(*) FROM " .. quoted)
      if left == nil then return fail(left_trouble) end
      kept, removed = kept + left, removed + all - left
    else
      kept = kept + all
    end
  end
  local vacuumed, vacuum_trouble = db:exec("VACUUM")
  if not vacuumed then return fail(vacuum_trouble) end
  local closed, close_trouble = db:close()
  if not closed then return nil, close_trouble end
  return { kept = kept, removed = removed, before_bytes = before_bytes,
    after_bytes = size(path) }, ""
end

--- `driver.tl compiles-trim SINCE` in `env`: its exit status, and what
--- it says on standard output and on standard error. It trims the cache
--- `env.COSMIC_BUILD_CACHE` names to what was used since SINCE, in Unix
--- seconds, and removes the caches set aside beside it
--- (`remove_set_aside`); nothing to do where the variable names no file.
--- Only a SINCE that is no count of seconds fails it (2): a cache it
--- cannot trim is said so, on standard error, and left, or removed where
--- it is no database.
function Compiles.command(argv: {string}, env: {string:string}): integer, string, string
  local since = math.tointeger(tonumber(argv[1] or ""))
  if since == nil or since < 0 then
    return 2, "", "compiles-trim: SINCE must be Unix seconds\n"
  end
  local path = env.COSMIC_BUILD_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    return 0, "compiles-trim: COSMIC_BUILD_CACHE names no file ('" .. path ..
      "'); nothing to trim\n", ""
  end
  local out = ""
  local aside = Compiles.remove_set_aside(path)
  if #aside > 0 then
    out = "compiles-trim: removed what the builds set aside: " .. table.concat(aside, ", ") .. "\n"
  end
  local trimmed, trouble = Compiles.trim(path, since * 1000000000)
  if trimmed == nil and trouble == "" then
    return 0, out .. "compiles-trim: " .. path .. " is not there; nothing to trim\n", ""
  end
  if trimmed == nil then
    if corrupt(trouble) then
      local gone = remove_database(path)
      return 0, out, "compiles-trim: " .. path .. ": " .. trouble ..
        "; removed " .. table.concat(gone, ", ") .. "\n"
    end
    return 0, out, "compiles-trim: " .. path .. ": " .. trouble ..
      "; the cache is left as it is\n"
  end
  return 0, out .. "compiles-trim: kept " .. trimmed.kept .. " used since " .. since ..
    ", removed " .. trimmed.removed .. "; " .. path .. " " .. trimmed.before_bytes ..
    " -> " .. trimmed.after_bytes .. " bytes\n", ""
end

--- `driver.tl compiles-trim SINCE`, in the driver's environment
--- (`command`).
function Compiles.trim_command(argv: {string}): integer
  local code, out, err = Compiles.command(argv, Env.all())
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return Compiles
