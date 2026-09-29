--- The test verdicts a leg keeps from one run to the next: the
--- directory of the file COSMIC_VERDICT_CACHE names
--- (build/shared_verdicts.tl in the candidate), which ci.yml restores
--- before the leg's suites and saves after them. It holds `verdicts.db`,
--- the native suite's; `portable.db` beside it, the portable suite's;
--- `fixtures.db`, the sandboxed fixtures' (cosmic_ci/orchestration.tl's
--- `sandboxed_fixtures`); or, in ci.yml's checked job, which runs no
--- other suite, `checked.db` alone, the checked suite's
--- (COSMIC_CI_CHECKED_SUITE; cosmic_ci/orchestration.tl's
--- `suite_verdicts`).
---
--- A file bounds itself at 8192 rows and thirty days, some 3 KB a row
--- (the lines each test hit, deflated, most of it), and SQLite keeps
--- the pages its bound frees: 32 MB where it is full. A row is keyed by
--- everything its test was given, the harness and the runtime among
--- them, which every change to build/ moves. So most of what a file
--- holds is under keys no later run reaches, and a leg's save of both
--- carried some 42 MB compressed each main push into the repository's
--- cache, which holds 10 GB in all, the zig caches among them. A leg
--- that passed therefore keeps only the verdicts its own run relied on
--- or reached (`trim`): the keys a later run of the same tree reaches
--- again, and no more. A run's suites stamp each row they stood on or
--- wrote with the time (`used_ns`), and take out a row whose test
--- failed.
---
--- A file none of whose rows the run reached (the portable suite's, on
--- a run that has none, or on a leg that skips it,
--- COSMIC_CI_PORTABLE_SUITE; the fixtures', on a run whose scope runs
--- none) keeps them all: that is no sign they are dead. Like the suites, which never fail over the cache, a trim that
--- cannot read it never fails the leg (cosmic_ci/cache_trim.tl).

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record Verdicts
end

--- The tables of build/shared_verdicts.tl's formats: `declared_v<n>`,
--- and the observation-keyed `verdicts_v<n>`, which the tree's tool does
--- not stamp, so every row of it goes wherever the file is trimmed.
local tables: CacheTrim.Tables = { patterns = { "declared_v[0-9]*", "verdicts_v[0-9]*" },
  whole_unless_reached = true }

--- The caches in `dir`, each a `.db` file: not their logs, nor what
--- was set aside beside them, which `CacheTrim.file` removes.
local function caches(dir: string): {string}
  local listed, _ = Fs.list(dir)
  local out: {string} = {}
  for _, entry in ipairs(listed or {}) do
    if entry:sub(-3) == ".db" then out[#out + 1] = dir .. "/" .. entry end
  end
  table.sort(out)
  return out
end

--- `driver.tl verdicts-trim SINCE|whole` in `env`: its exit status,
--- and what it says on standard output and on standard error. It trims
--- every cache in the directory of the file `env.COSMIC_VERDICT_CACHE`
--- names (the directory ci.yml saves) to the verdicts used since SINCE,
--- in Unix seconds (`CacheTrim.file`). Given `whole`, it trims none, so
--- a run that failed saves what it restored with what it reached;
--- either way it removes what was set aside beside them. Then it writes
--- `digest=<hex>` of the caches' rows (`CacheTrim.digest`) to the
--- step's outputs (`CacheTrim.output`), the tail of the key ci.yml
--- saves them under. Nothing to do, and no digest, where the variable
--- names no file or its directory holds no cache. Only a SINCE that is
--- no count of seconds fails it (2): a cache it cannot trim is reported
--- on standard error and left, or removed where it is no database.
function Verdicts.command(argv: {string}, env: {string:string}): integer, string, string
  local whole = argv[1] == "whole"
  local since = CacheTrim.since(argv)
  if since == nil and not whole then
    return 2, "", "verdicts-trim: SINCE must be Unix seconds, or whole\n"
  end
  local path = env.COSMIC_VERDICT_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    return 0, "verdicts-trim: COSMIC_VERDICT_CACHE names no file ('" .. path ..
      "'); nothing to trim\n", ""
  end
  local dir = Fs.dirname(path)
  local found = caches(dir)
  if #found == 0 then
    return 0, "verdicts-trim: " .. dir .. " holds no cache; nothing to trim\n", ""
  end
  local outs, errs: {string}, {string} = {}, {}
  for _, cache in ipairs(found) do
    if whole then
      local aside = CacheTrim.remove_set_aside(cache)
      if #aside > 0 then
        outs[#outs + 1] = "verdicts-trim: removed what was set aside: " ..
          table.concat(aside, ", ") .. "\n"
      end
      outs[#outs + 1] = "verdicts-trim: kept every row of " .. cache .. ", as asked\n"
    else
      local out, err = CacheTrim.file("verdicts-trim", cache, since, tables)
      outs[#outs + 1], errs[#errs + 1] = out, err
    end
  end
  -- Listed again, since a trim removes a cache that is no database.
  local kept = caches(dir)
  if #kept > 0 then
    local digest, trouble = CacheTrim.digest(kept)
    if trouble ~= "" then errs[#errs + 1] = "verdicts-trim: " .. trouble .. "\n" end
    outs[#outs + 1] = "verdicts-trim: digest " .. digest .. " of " .. #kept .. " caches\n"
    local unsaid = CacheTrim.output(env, "digest", digest)
    if unsaid ~= "" then errs[#errs + 1] = "verdicts-trim: " .. unsaid .. "\n" end
  end
  return 0, table.concat(outs), table.concat(errs)
end

--- Writes what a command said, and answers its status.
local function said(code: integer, out: string, err: string): integer
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

--- `driver.tl verdicts-trim SINCE|whole`, in the driver's environment
--- (`command`).
function Verdicts.trim_command(argv: {string}): integer
  return said(Verdicts.command(argv, Env.all()))
end

--- How long a merge waits on another connection's lock, as the trim
--- and the suites wait.
local busy_ms <const> = 10000

local function quote(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

--- The columns of `schema`'s table `name`, in order, and which of them
--- the primary key holds; nil and why where they could not be read.
local function columns(db: Sqlite.Handle, schema: string, name: string): {string} | nil, boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name, pk FROM pragma_table_info(?1, ?2) ORDER BY cid",
    { { text = name }, { text = schema } })
  if rows == nil then return nil, false, trouble end
  local out: {string} = {}
  local keyed = false
  for _, row in ipairs(rows) do
    out[#out + 1] = row[1]
    keyed = keyed or row[2] ~= "0"
  end
  return out, keyed, ""
end

--- A count the query answers, or nil and why.
local function counted(db: Sqlite.Handle, sql: string): integer | nil, string
  local rows, trouble = Sqlite.text_rows(db, sql)
  if rows == nil then return nil, trouble end
  return math.tointeger(tonumber(rows[1][1])) or 0, ""
end

--- Adds to the cache at `into` (made where it is not there) the rows of
--- the cache at `from` that `into` has no row of under the same primary
--- key, in the tables of the tool's formats (`tables`), in one
--- transaction. It is a union: it never replaces a row `into` holds nor
--- makes one neither file held, so a second merge of the same file adds
--- nothing. A table `into` lacks is made as `from` declares it, with its
--- indexes. Each row added is stamped used at 0, by no run: a lookup
--- reads a row by its key alone, so it stands all the same, and the
--- suite stamps it again where it stands on it, but a row it never
--- reaches is the trim's to take out (and the cache's own bound's)
--- rather than saved as though this run had reached it. A table of
--- another shape in the two, or with no primary key to tell a row
--- already held by, is left as it is and said so. Answers what to say
--- on standard output and on standard error.
local function merge_file(from: string, into: string): string, string
  local opened, open_trouble = Sqlite.open(into, true)
  if opened == nil then
    return "", "verdicts-merge: " .. into .. ": " .. open_trouble .. "; nothing merged\n"
  end
  local db: Sqlite.Handle = opened
  local skipped: {string} = {}
  local added: {string} = {}
  local attached = false
  local function work(): boolean, string
    local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. busy_ms)
    if not timed then return false, time_trouble end
    local ok, attach_trouble = Sqlite.run(db, "ATTACH DATABASE ?1 AS ahead", { { text = from } })
    if not ok then return false, attach_trouble end
    attached = true
    local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
    if not begun then return false, begin_trouble end
    local globs: {string} = {}
    for _, pattern in ipairs(tables.patterns) do
      globs[#globs + 1] = "name GLOB '" .. pattern .. "'"
    end
    local names, trouble = Sqlite.text_rows(db, "SELECT name, sql FROM ahead.sqlite_schema " ..
      "WHERE type = 'table' AND (" .. table.concat(globs, " OR ") .. ") ORDER BY name")
    if names == nil then return false, trouble end
    for _, row in ipairs(names) do
      local name, sql = row[1], row[2]
      local q = quote(name)
      local theirs, keyed, their_trouble = columns(db, "ahead", name)
      if theirs == nil then return false, their_trouble end
      local ours, _, our_trouble = columns(db, "main", name)
      if ours == nil then return false, our_trouble end
      if not keyed then
        skipped[#skipped + 1] = name .. " (no primary key)"
      elseif #ours == 0 and sql:sub(1, 13) ~= "CREATE TABLE " then
        skipped[#skipped + 1] = name .. " (declared as no table)"
      elseif #ours > 0 and table.concat(ours, ",") ~= table.concat(theirs, ",") then
        skipped[#skipped + 1] = name .. " (another shape)"
      else
        if #ours == 0 then
          local made, made_trouble = db:exec(sql)
          if not made then return false, made_trouble end
          local indexes, index_trouble = Sqlite.text_rows(db, "SELECT sql FROM ahead.sqlite_schema " ..
            "WHERE type = 'index' AND tbl_name = ?1 AND sql IS NOT NULL ORDER BY name", { { text = name } })
          if indexes == nil then return false, index_trouble end
          for _, index in ipairs(indexes) do
            if index[1]:sub(1, 13) == "CREATE INDEX " then
              local indexed, indexed_trouble = db:exec(index[1])
              if not indexed then return false, indexed_trouble end
            end
          end
        end
        local list: {string} = {}
        local values: {string} = {}
        for i, column in ipairs(theirs) do
          list[i] = quote(column)
          values[i] = column == "used_ns" and "0" or quote(column)
        end
        local before, before_trouble = counted(db, "SELECT count(*) FROM main." .. q)
        if before == nil then return false, before_trouble end
        local inserted, insert_trouble = Sqlite.run(db, "INSERT OR IGNORE INTO main." .. q ..
          " (" .. table.concat(list, ", ") .. ") SELECT " .. table.concat(values, ", ") ..
          " FROM ahead." .. q)
        if not inserted then return false, insert_trouble end
        local after, after_trouble = counted(db, "SELECT count(*) FROM main." .. q)
        if after == nil then return false, after_trouble end
        added[#added + 1] = (after - before) .. " rows to " .. name
      end
    end
    local committed, commit_trouble = db:exec("COMMIT")
    if not committed then return false, commit_trouble end
    return true, ""
  end
  local ok, trouble = work()
  if not ok then local _, _ = db:exec("ROLLBACK") end
  if attached then local _, _ = db:exec("DETACH DATABASE ahead") end
  local _, _ = db:close()
  if not ok then
    return "", "verdicts-merge: " .. from .. " into " .. into .. ": " .. trouble ..
      "; nothing merged\n"
  end
  local err = ""
  if #skipped > 0 then
    err = "verdicts-merge: " .. from .. ": left as they are: " .. table.concat(skipped, ", ") .. "\n"
  end
  local what = #added > 0 and table.concat(added, ", ") or "no table of the tool's"
  return "verdicts-merge: added " .. what .. "; " .. from .. " -> " .. into .. "\n", err
end

--- `driver.tl verdicts-merge DIR` in `env`: its exit status, and what
--- it says on standard output and on standard error. It merges each
--- cache in DIR (the verdicts of the merge queue's run ahead of this
--- one, which ci.yml's `verdicts-ahead` downloads) into the cache of the
--- same name in the directory of the file `env.COSMIC_VERDICT_CACHE`
--- names (`merge_file`), made where it is not there. The run ahead
--- tested the tree this one's change is made on, and every row is keyed
--- by all its test was given, so a verdict it reached under a key this
--- run reaches again stands here too. Nothing to do where the variable
--- names no file or DIR holds no cache. Only a missing DIR argument
--- fails it (2): a cache it cannot merge is reported on standard error,
--- and this run goes on with what it restored.
function Verdicts.merge(argv: {string}, env: {string:string}): integer, string, string
  local from = argv[1] or ""
  if from == "" or argv[2] ~= nil then
    return 2, "", "usage: verdicts-merge DIR\n"
  end
  local path = env.COSMIC_VERDICT_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    return 0, "verdicts-merge: COSMIC_VERDICT_CACHE names no file ('" .. path ..
      "'); nothing to merge\n", ""
  end
  local found = caches(from)
  if #found == 0 then
    return 0, "verdicts-merge: " .. from .. " holds no cache; nothing to merge\n", ""
  end
  local dir = Fs.dirname(path)
  local made, trouble = Fs.mkdirs(dir)
  if not made then
    return 0, "", "verdicts-merge: " .. dir .. ": " .. trouble .. "; nothing merged\n"
  end
  local outs, errs: {string}, {string} = {}, {}
  for _, cache in ipairs(found) do
    outs[#outs + 1], errs[#errs + 1] = merge_file(cache, dir .. "/" .. Fs.basename(cache))
  end
  return 0, table.concat(outs), table.concat(errs)
end

--- `driver.tl verdicts-merge DIR`, in the driver's environment
--- (`merge`).
function Verdicts.merge_command(argv: {string}): integer
  return said(Verdicts.merge(argv, Env.all()))
end

return Verdicts
