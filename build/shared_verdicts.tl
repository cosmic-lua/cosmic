--- The passing test verdicts every checkout of a tree shares: a SQLite
--- database under the cosmic cache directory, beside the one each
--- checkout keeps in `o/build.db`. The file is `verdicts/verdicts.db` by
--- default, or the absolute path `COSMIC_VERDICT_CACHE` names; `0` turns
--- the cache off. A sandboxed run's verdicts are shared. Its key is the
--- digest of everything its test was given ([`build.declared_key`]) and
--- names nothing of where the tree is, so a verdict one checkout reached
--- stands in another of the same content, and a fresh worktree runs
--- only what no sibling has run already. An unsandboxed run's verdicts,
--- keyed the same way but for where the tree is and under a runtime of
--- their own, are shared only through a file `COSMIC_VERDICT_CACHE`
--- names (`chosen`), and so only with a checkout at the same path.
---
--- The cache is a plain map from key to verdict. The key reached is the
--- whole check, so a row holds no evidence of what the run read. It
--- holds the test it is of, the lines it hit (the coverage the test is
--- credited), how long it took, and the key parts its key holds (the
--- runtime's digest, the harness's epoch, ...). Nothing looks a verdict
--- up by the parts; they say what a cache holds (`held`), as `cosmic
--- test --census` does.
---
--- Many runs share the file at once. It is in WAL mode, so a reader
--- never waits on a writer; a run reads it a statement at a time and
--- writes what it owes it in one short transaction as it ends. The file
--- is bounded: a row no run has relied on for `kept_ns` goes, and past
--- `kept_rows` rows, the least lately relied on go first. A failing run
--- of a key takes the key's row out, and a checkout that holds a verdict
--- of its own under a key never takes another's for it. A cache that
--- cannot be opened, read or written (corrupt, or holding this format's
--- table in another shape) is reported and done without: it never fails
--- a run.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")
local plural = require("build.plural")
local shared_sqlite = require("build.shared_sqlite")
local cache_formats = require("build.cache_formats")

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

  --- How many rows the cache holds, and how many of them are of the
  --- tests a run looked up (`census`).
  record Census
    rows: integer
    of_tests: integer
  end

  --- How many rows the cache holds under one set of key parts, as
  --- `named` says them ("" for rows kept by a run that named none).
  record Held
    parts: string
    rows: integer
  end

  --- What a run owes the cache when it ends.
  record Owed
    --- The key parts the run's keys hold (`named`): those every key
    --- holds, and the system, compiler and program that only some do.
    --- Each row it keeps, or stands on unnamed, is stamped with them;
    --- nil for none.
    parts: string
    kept: {Kept}
    --- Keys the run relied on, which stay the longer for it.
    used: {string}
    --- Keys the run failed under, whose rows go.
    failed: {string}
    --- The digest of the bytes of each closure store the run keyed a
    --- test by, by the store's address ([`build.closure_store`]'s
    --- `address`): kept, or stamped as relied on, so a checkout without
    --- the store keys its tests without writing it ([`store_digest`]).
    stores: {string:string}
  end
end

--- The variable that moves the cache, or turns it off with `0`.
local variable <const> = "COSMIC_VERDICT_CACHE"

--- How many rows the cache keeps: some five whole runs of this tree,
--- at a few kilobytes a row.
local kept_rows <const> = 8192

--- How long a row no run relies on is kept: thirty days.
local kept_ns <const> = 30 * 24 * 3600 * 1000000000

--- The table rows are in, by their declared key alone: `declared_v1`.
--- A later format keeps a table of its own, so a binary of it sharing
--- the file never empties this one's; nor does this one empty the
--- tables observation-keyed runs shared (`prepare`).
local declared <const> = cache_formats.declared

--- The table of what each closure store's bytes digest to, by its
--- address: `stores_v1`. An address digests everything a store's bytes
--- follow from -- its rows, the code that writes it and the runtime that
--- runs that code ([`build.test`]'s `address_stores`) -- so one address
--- names one store's bytes wherever it is written, and a checkout can
--- key a test by a store it has not written. Bounded as `declared` is.
local stores <const> = cache_formats.stores

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
  local dir, trouble = Fs.cache_dir("verdicts", { environment = environment })
  if dir == nil then return nil, trouble end
  return dir .. "/verdicts.db", ""
end

--- Whether `COSMIC_VERDICT_CACHE` names a file, in `environment` or
--- this process's own: set, and neither empty nor `0`. An unsandboxed
--- run shares only then ([`build.test`]), never through the file every
--- checkout shares by default, since nothing held its workers to what
--- its keys trust.
function shared_verdicts.chosen(environment?: {string:string}): boolean
  local value: string
  if environment ~= nil then
    value = environment[variable] or ""
  else
    value = Env.get_or(variable, "")
  end
  return value ~= "" and value ~= "0"
end

--- Turns the cache off in `environment`, for a process that is to
--- neither read nor write it.
function shared_verdicts.turn_off(environment: {string:string})
  environment[variable] = "0"
end

local schema <const> = cache_formats.verdicts

--- Hits as [`build.test`] encodes them -- a line per module, its path, a
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

--- Whether `db`'s table of this format has its `parts` column, which a
--- file from a binary without it lacks.
local function has_parts(db: Sqlite.Handle): boolean | nil, string
  local rows, trouble = Sqlite.text_rows(db, "SELECT 1 FROM pragma_table_info('" ..
      declared .. "') WHERE name = 'parts'")
  if rows == nil then return nil, trouble end
  return #rows > 0, ""
end

--- Makes this format's tables when the file lacks one, or adds the
--- `parts` column to a table that lacks it, in one transaction. A file
--- that has them all is only read. A binary without the column may share the
--- file: its rows name no parts, until a run that names them stands on
--- one (`settle`). The tables observation-keyed runs shared
--- (`verdicts_v<n>`) are left as they are: a binary of that format
--- sharing the file still writes its own and ages its rows out, and none
--- of this one's reads them.
local function prepare(db: Sqlite.Handle): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name IN ('" .. declared ..
      "', '" .. stores .. "')")
  if rows == nil then return false, trouble end
  if #rows > 1 then
    local named, named_trouble = has_parts(db)
    if named == nil then return false, named_trouble end
    if named then return true, "" end
  end
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    for _, statement in ipairs(schema) do
      local ok, statement_trouble = db:exec(statement)
      if not ok then return false, statement_trouble end
    end
    -- Another run may have added it since the look above.
    local named, named_trouble = has_parts(db)
    if named == nil then return false, named_trouble end
    if named then return true, "" end
    return db:exec("ALTER TABLE " .. declared .. " ADD COLUMN parts TEXT NOT NULL DEFAULT ''")
  end
  local ok, step_trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, step_trouble
  end
  return db:exec("COMMIT")
end

--- Opens the cache at `path`, making it and its directory when missing,
--- in write-ahead mode ([`shared_sqlite.open`]).
function shared_verdicts.open(path: string): shared_verdicts.Cache | nil, string
  local made, made_trouble = Fs.mkdirs(Fs.dirname(path))
  if not made then return nil, made_trouble end
  local db, trouble = shared_sqlite.open(path, prepare)
  if db == nil then return nil, trouble end
  return { db = db, path = path }
end

function shared_verdicts.close(cache: shared_verdicts.Cache)
  local _, _ = cache.db:close()
end

--- Whether `trouble`, from a query of the cache, says the file itself
--- is broken ([`shared_sqlite.corrupt`]).
function shared_verdicts.corrupt(trouble: string): boolean
  return shared_sqlite.corrupt(trouble)
end

--- Moves a broken cache aside, write-ahead log and all, to
--- `<path>.corrupt-<now_ns>` ([`shared_sqlite.set_aside`]). Answers where
--- it went, or nil and why.
function shared_verdicts.set_aside(path: string, now_ns: integer): string | nil, string
  return shared_sqlite.set_aside(path, now_ns)
end

--- The coverage and duration of the passing verdict under the declared
--- `key` ([`build.declared_key`]), or nil: the key is the whole check.
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

--- The digest of the bytes of the closure store at `address`, as a run
--- that had it kept it (`settle`), or nil.
function shared_verdicts.store_digest(cache: shared_verdicts.Cache,
                                      address: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT digest FROM " .. stores .. " WHERE address = ?1", { text(address) })
  if rows == nil then return nil, trouble end
  if rows[1] == nil then return nil, "" end
  return rows[1][1], ""
end

--- How many rows the cache holds, and how many are of a test in
--- `tests` (each `"path name"`). For a run none of whose lookups found a
--- verdict, it tells whether the cache is empty or holds these very
--- tests under keys the run no longer reaches (a host, runtime or
--- harness that moved), which `unmatched` says.
function shared_verdicts.census(cache: shared_verdicts.Cache,
                                tests: {string:boolean}): shared_verdicts.Census | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT test, COUNT(*) FROM " .. declared .. " GROUP BY test")
  if rows == nil then return nil, trouble end
  local out: shared_verdicts.Census = { rows = 0, of_tests = 0 }
  for _, row in ipairs(rows) do
    local count = math.tointeger(tonumber(row[2]) or 0) or 0
    out.rows = out.rows + count
    if tests[row[1]] then out.of_tests = out.of_tests + count end
  end
  return out, ""
end

--- `parts`, the digests a run's keys hold, as the run says them:
--- "name digest, name digest". Each is a name and a digest, in order.
--- Some, as the runtime's and the harness's, every key holds; others, as
--- the system's, the compiler's and the program's, only the keys of
--- modules given them.
function shared_verdicts.named(parts: {{string}}): string
  local named: {string} = {}
  for _, part in ipairs(parts) do named[#named + 1] = part[1] .. " " .. part[2] end
  return table.concat(named, ", ")
end

--- The line a run asked for its key parts (`cosmic test --census`) says
--- where it says no `unmatched` line: `parts`, the digests the run's keys
--- hold, as `named` says them.
function shared_verdicts.key_parts(parts: {{string}}): string
  return "test: key parts: " .. shared_verdicts.named(parts)
end

--- How many rows the cache holds under each set of key parts its rows
--- name, the most first: what a run found in the cache before it
--- stood on or kept anything (`cosmic test --census`).
function shared_verdicts.held(cache: shared_verdicts.Cache): {shared_verdicts.Held} | nil, string
  local rows, trouble = Sqlite.text_rows(cache.db, "SELECT parts, COUNT(*) FROM " ..
      declared .. " GROUP BY parts ORDER BY COUNT(*) DESC, parts")
  if rows == nil then return nil, trouble end
  local out: {shared_verdicts.Held} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { parts = row[1] or "", rows = math.tointeger(tonumber(row[2]) or 0) or 0 }
  end
  return out, ""
end

--- The line a run asked for its census (`cosmic test --census`) says of
--- what the cache held (`held`): each set of key parts and how many
--- rows it keys, "; " between them, or that it held none, so a report
--- says whether the run's own parts were among what it restored:
---
---     test: census: 1994 rows under host features X, ..., harness e1-00000000-t60000; 3 rows under no parts named
---     test: census: no rows
function shared_verdicts.census_line(held: {shared_verdicts.Held}): string
  if #held == 0 then return "test: census: no rows" end
  local groups: {string} = {}
  for _, group in ipairs(held) do
    groups[#groups + 1] = string.format("%d %s under %s", group.rows,
      plural.noun(group.rows, "row"),
      group.parts ~= "" and group.parts or "no parts named")
  end
  return "test: census: " .. table.concat(groups, "; ")
end

--- The line a run says where it looked `looked` tests up in the cache
--- at `path` and none stood though it holds rows (`census`), with
--- `parts`, the digests every key of the run holds (`named`), so two
--- runs' lines say which of them moved. Nil where the cache holds
--- nothing to stand on.
function shared_verdicts.unmatched(path: string, looked: integer,
                                   census: shared_verdicts.Census,
                                   parts: {{string}}): string | nil
  if looked == 0 or census.rows == 0 then return nil end
  local why = census.of_tests > 0 and "none under the keys this run reached" or
    "no other run reached them"
  return string.format("test: shared verdicts: none of %s looked up stood, " ..
      "though %s holds %s, %d of them of those tests: %s (%s)",
    plural.count(looked, "test"), path, plural.count(census.rows, "row"), census.of_tests,
    why, shared_verdicts.named(parts))
end

--- Writes what a run owes the cache, at `now_ns`, and drops what it no
--- longer keeps, in one transaction. `origin` names the checkout
--- writing each row, and `owed.parts` its key parts: a row stood on
--- that names none is stamped with them too, since its key, reached
--- again, holds the same.
function shared_verdicts.settle(cache: shared_verdicts.Cache, origin: string,
                                owed: shared_verdicts.Owed, now_ns: integer): boolean, string
  local db = cache.db
  local parts = owed.parts or ""
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
          "origin, parts) VALUES (?1, ?2, deflate(?3), ?4, ?5, ?6, ?7)",
        { text(kept.key), text(kept.test), text(packed(kept.hits)),
          { integer = kept.elapsed_ns }, { integer = now_ns }, text(origin), text(parts) })
      if not ok then return false, trouble end
    end
    for _, key in ipairs(owed.used) do
      for _, name in ipairs(tables) do
        local ok, trouble = Sqlite.run(db, "UPDATE " .. name .. " SET used_ns = ?1, " ..
            "parts = CASE WHEN parts = '' THEN ?3 ELSE parts END WHERE key = ?2",
          { { integer = now_ns }, text(key), text(parts) })
        if not ok then return false, trouble end
      end
    end
    local addresses: {string} = {}
    for address in pairs(owed.stores or {}) do addresses[#addresses + 1] = address end
    table.sort(addresses)
    -- A digest here that differs from the run's for the same address
    -- was reported by the run as an error ([`build.test`]'s
    -- `mismatched`), which says the run's replaces it.
    for _, address in ipairs(addresses) do
      local ok, trouble = Sqlite.run(db, "INSERT OR REPLACE INTO " .. stores ..
          " (address, digest, used_ns) VALUES (?1, ?2, ?3)",
        { text(address), text(owed.stores[address]), { integer = now_ns } })
      if not ok then return false, trouble end
    end
    for _, bound in ipairs({ { declared, "key" }, { stores, "address" } }) do
      local name, key = bound[1], bound[2]
      local aged, age_trouble = Sqlite.run(db, "DELETE FROM " .. name .. " WHERE used_ns < ?1",
        { { integer = now_ns - kept_ns } })
      if not aged then return false, age_trouble end
      local bounded, bound_trouble = Sqlite.run(db, "DELETE FROM " .. name ..
          " WHERE " .. key .. " IN (SELECT " .. key .. " FROM " .. name .. " " ..
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
