--- The compiles and parses a leg keeps from one run to the next: the file
--- COSMIC_BUILD_CACHE names (build/shared_compiles.tl in the candidate),
--- which ci.yml restores before the leg's builds and saves after them.
---
--- The file bounds itself only at 256 MB and thirty days, and a change
--- to the build's own modules moves every row's key. A file that each
--- run saved back whole would grow by a tree's worth of compiles (about
--- 3 MB) with most commits to main, up to that bound, and the
--- repository's cache, which holds 10 GB in all, would hold that much
--- again with each save. So a leg keeps only what its own run used or
--- compiled (`trim`): what the next run of the tree it built needs.
---
--- Like the builds, which never fail over this cache, a trim that cannot
--- read it never fails the leg (cosmic_ci/cache_trim.tl, which the
--- verdicts' trim shares).
---
--- A branch's push saves its trimmed cache too, under a key of the
--- branch's own, where its builds compiled many modules the entry it
--- restored did not hold (`fresh`): a change to the compiler's identity
--- moves every row's key, so each later push of that branch would
--- otherwise compile the whole tree again on every leg.

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local Predicate = require("cosmic_ci.fs_predicate")
local Sqlite = require("cosmic.sqlite")

local record Compiles
end

--- The tables of build/shared_compiles.tl's formats (`compiled_v<n>`,
--- `parsed_v<n>`), every row of which goes where no build used or made
--- it since.
local tables: CacheTrim.Tables = { patterns = { "compiled_v[0-9]*", "parsed_v[0-9]*" },
  whole_unless_reached = false }

--- Removes from the cache at `path` every compile and parse no build
--- has used or made since `since_ns` (the wall clock, as the cache's
--- `used_ns` is), then rewrites the file without the space they took
--- ([`CacheTrim.trim`]). Nil and "" for a file that is not there, which a
--- leg whose builds never started leaves, and nil and why where the
--- file could not be trimmed.
function Compiles.trim(path: string, since_ns: integer): CacheTrim.Trimmed | nil, string
  return CacheTrim.trim(path, since_ns, tables)
end

--- How many compiles the cache at `path` holds that the file at
--- `restored` does not: what a run compiled rather than took from the
--- entry it restored, where `restored` is a copy of that entry made
--- before the run's builds. Every row of each compiles table
--- (`compiled_v<n>`) counts where `restored` is not there, or has no
--- table of that name. Nil and why where either file cannot be read.
function Compiles.fresh(path: string, restored: string): integer | nil, string
  -- Writable, as the trim opens it: a reader of a file in write-ahead
  -- mode leaves its log and index behind, which the save would carry.
  local opened, open_trouble = Sqlite.open(path, { writable = true })
  if opened == nil then return nil, open_trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): integer | nil, string
    local _, _ = db:close()
    return nil, why
  end
  local has_restored = Predicate.exists(restored)
  if has_restored then
    local attached, attach_trouble = Sqlite.run(db, "ATTACH ?1 AS restored", { { text = restored } })
    if not attached then return fail(attach_trouble) end
  end
  local names, trouble = Sqlite.text_rows(db, "SELECT name FROM main.sqlite_schema " ..
    "WHERE type = 'table' AND name GLOB 'compiled_v[0-9]*' ORDER BY name")
  if names == nil then return fail(trouble) end
  local fresh = 0
  for _, row in ipairs(names) do
    local q = '"' .. row[1]:gsub('"', '""') .. '"'
    local sql = "SELECT count(*) FROM main." .. q
    if has_restored then
      local there, there_trouble = Sqlite.text_rows(db, "SELECT count(*) FROM restored.sqlite_schema " ..
        "WHERE type = 'table' AND name = ?1", { { text = row[1] } })
      if there == nil then return fail(there_trouble) end
      if there[1][1] ~= "0" then
        sql = sql .. " WHERE key NOT IN (SELECT key FROM restored." .. q .. ")"
      end
    end
    local counted, count_trouble = Sqlite.text_rows(db, sql)
    if counted == nil then return fail(count_trouble) end
    fresh = fresh + (math.tointeger(tonumber(counted[1][1])) or 0)
  end
  local closed, close_trouble = db:close()
  if not closed then return nil, close_trouble end
  return fresh, ""
end

--- `driver.tl compiles-trim SINCE` in `env`: its exit status, and what
--- it says on standard output and on standard error. It trims the cache
--- `env.COSMIC_BUILD_CACHE` names to what was used since SINCE, in Unix
--- seconds, and removes the caches set aside beside it
--- ([`CacheTrim.file`]), then writes `digest=<hex>` of the rows left
--- ([`CacheTrim.digest`]) to the step's outputs ([`CacheTrim.output`]), the
--- tail of the key ci.yml saves the cache under. Nothing to do, and no
--- digest, where the variable names no file or the file is not there.
--- Only a SINCE that is no count of seconds fails it (2): a cache it
--- cannot trim is said so, on standard error, and left, or removed where
--- it is no database.
---
--- `compiles-trim SINCE RESTORED` also writes `fresh=<n>`, how many of
--- the compiles kept the copy RESTORED of what the leg restored does not
--- hold ([`fresh`]), which ci.yml's save for a branch's later pushes
--- reads, and removes that copy, which no save is to carry.
function Compiles.command(argv: {string}, env: {string:string}): integer, string, string
  local since = CacheTrim.since(argv)
  if since == nil then
    return 2, "", "compiles-trim: SINCE must be Unix seconds\n"
  end
  local restored = argv[2]
  if restored ~= nil and restored:sub(1, 1) ~= "/" then
    return 2, "", "compiles-trim: RESTORED must be an absolute path\n"
  end
  local path = env.COSMIC_BUILD_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    if restored ~= nil then CacheTrim.remove_database(restored) end
    return 0, "compiles-trim: COSMIC_BUILD_CACHE names no file ('" .. path ..
      "'); nothing to trim\n", ""
  end
  local out, err = CacheTrim.file("compiles-trim", path, since, tables)
  if Predicate.exists(path) then
    local digest, trouble = CacheTrim.digest({ path })
    if trouble ~= "" then err = err .. "compiles-trim: " .. trouble .. "\n" end
    out = out .. "compiles-trim: digest " .. digest .. "\n"
    local unsaid = CacheTrim.output(env, "digest", digest)
    if unsaid ~= "" then err = err .. "compiles-trim: " .. unsaid .. "\n" end
    if restored ~= nil then
      local fresh, fresh_trouble = Compiles.fresh(path, restored)
      if fresh == nil then
        err = err .. "compiles-trim: " .. restored .. ": " .. fresh_trouble .. "\n"
      else
        out = out .. "compiles-trim: " .. Plural.count(fresh, "compile") ..
          " not in what was restored\n"
        unsaid = CacheTrim.output(env, "fresh", tostring(fresh))
        if unsaid ~= "" then err = err .. "compiles-trim: " .. unsaid .. "\n" end
      end
    end
  end
  if restored ~= nil then CacheTrim.remove_database(restored) end
  return 0, out, err
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
