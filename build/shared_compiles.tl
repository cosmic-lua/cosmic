--- The compiles every checkout shares: a SQLite database under the
--- cosmic cache directory -- `build/cache.db` in `Fs.cache_dir`'s
--- `$XDG_CACHE_HOME/cosmic` (`~/.cache/cosmic`) by default, or the
--- absolute path `COSMIC_BUILD_CACHE` names, and none at all when it is
--- `0` -- beside the `compiled` table each checkout keeps in
--- `o/build.db`. A module's key (`build.importer`'s) names no path: the
--- module's import graph by name and content, and the compiler's
--- identity. So a compile one checkout made stands in another of the
--- same content, and a fresh worktree compiles only what no sibling has
--- compiled already.
---
--- A row is keyed by more than the local key (`key`): what else decides
--- whether a compile is accepted, which a checkout's own cache leaves
--- out -- whether the tree is cosmic's own (`build.contracts` runs only
--- there), whether the module was extracted from a doc, the file the
--- module is read from, and the names the checker's environment strips
--- (`cosmic.removed`) -- so a row never stands where a compile of the
--- module here would refuse it. A compile refused and kept only for
--- the run that made it (an unjudged run's, `seen = -1`) is never
--- shared.
---
--- A row holds what a local compile writes: the Lua, the bytecode and
--- the record-field uses its checker found (`typed_refs`), so a
--- projection built from shared rows is the one a compile would have
--- made, and a digest of the three: a row that does not decode to what
--- its digest says is a miss, and is deleted.
---
--- A row's bytecode runs -- a build of cosmic's own tree carries the
--- `build.*` modules' in `o/bin/cosmic` -- so whoever can write the
--- file can run code as every user of it. The file and its directory
--- are held to what `Fs.cache_dir` holds its directories to, wherever
--- the file is: owned by this user, and writable by no one else.
---
--- Many builds share the file at once: it is in WAL mode, so a reader
--- never waits on a writer; a build reads a row at a time and writes
--- what it compiled in one short transaction as its compile ends, and
--- two writers of one key write the same bytes. It is bounded: a row no
--- build has used for `kept_ns` goes, and past `kept_bytes`, the least
--- lately used go first. A cache that cannot be opened, read or written
--- is said so once and done without: it never fails a build.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local Compress = require("cosmic.compress")
local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local type importer = require("build.importer")
local type receivers = require("build.receivers")

local record shared_compiles
  --- An open cache.
  record Cache
    db: Sqlite.Handle
    path: string
  end

  --- One compile to keep, under its shared key.
  record Kept
    key: string
    lua: string
    bytecode: string
    references: {receivers.Reference}
  end

  --- What a build owes the cache when its compile ends.
  record Owed
    kept: {Kept}
    --- Keys the build took a compile from, which stay the longer for it.
    used: {string}
  end
end

--- The variable that moves the cache, or turns it off with `0`.
local variable <const> = "COSMIC_BUILD_CACHE"

--- How many bytes of compiles the cache keeps: some twenty whole
--- states of cosmic's own tree.
local kept_bytes <const> = 256 * 1024 * 1024

--- How long a row no build uses is kept: thirty days.
local kept_ns <const> = 30 * 24 * 3600 * 1000000000

--- How long a write waits on another build's: its transactions are short.
local busy_ms <const> = 10000

--- The table rows are in, named by the format's version, which any
--- change to the table's shape or to what a row holds bumps. A later
--- format keeps a table of its own, so a binary of it sharing the file
--- never empties this one's; an earlier format's table is dropped
--- (`prepare`): only an older binary reads it, and this one's rows stand
--- in for it.
local version <const> = 2
local compiled <const> = "compiled_v" .. version

local log = Log.new("cosmic")

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Where the cache is: `COSMIC_BUILD_CACHE` when it names a path, else
--- `cache.db` in `Fs.cache_dir("build")`, made if missing. Nil and ""
--- when the variable is `0`, or nil and why when there is nowhere to
--- keep it.
local function location(environment?: {string:string}): string | nil, string
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
  local dir, trouble = Fs.cache_dir("build", environment)
  if dir == nil then return nil, trouble end
  return dir .. "/cache.db", ""
end

--- Turns the cache off in `environment`, for a process that is to
--- neither read nor write it.
function shared_compiles.turn_off(environment: {string:string})
  environment[variable] = "0"
end

--- The names the checker's environment strips (`build.teal`'s
--- `environment_for`), which decide what it accepts beside the key.
local removed_digest = Hash.hex_sha256(table.concat(Removed.order, "\n"))

--- The key a compile is shared under: the module's own key
--- (`importer.Module.key`) and what else decides whether it is
--- accepted, and the format it is kept in. `removed` is the stripped
--- names' digest, by default the running binary's, and `format` the
--- format's table, by default this one's.
-- The file and the removed names are salts only because the local key
-- lacks them: see the TODOs in build.importer's `dependency_keys` and
-- build.work's `compiler_identity`.
function shared_compiles.key(key: string, own_tree: boolean, generated: boolean,
                             file: string, removed?: string, format?: string): string
  return Hash.hex_sha256((format or compiled) .. "\n" .. key .. "\n" ..
    (own_tree and "own" or "project") .. "\n" ..
    (generated and "doctest" or "tree") .. "\n" .. file .. "\n" ..
    (removed or removed_digest))
end

local schema <const> = {
  "CREATE TABLE IF NOT EXISTS " .. compiled .. [[ (key TEXT PRIMARY KEY,
                                                  lua BLOB NOT NULL,
                                                  bytecode BLOB NOT NULL,
                                                  refs BLOB NOT NULL,
                                                  digest TEXT NOT NULL,
                                                  size INTEGER NOT NULL,
                                                  used_ns INTEGER NOT NULL)]],
  "CREATE INDEX IF NOT EXISTS " .. compiled .. "_by_use ON " .. compiled .. " (used_ns)",
}

--- The record-field uses, a line each: module, member and line, by tabs.
local function packed(references: {receivers.Reference}): string
  local out: {string} = {}
  for _, r in ipairs(references) do
    out[#out + 1] = r.module .. "\t" .. r.member .. "\t" .. tostring(r.line) .. "\n"
  end
  return table.concat(out)
end

--- `packed` undone: nil for what `packed` never writes.
local function unpacked(refs: string): {receivers.Reference} | nil
  local out: {receivers.Reference} = {}
  local rest = refs:gsub("([^\t\n]*)\t([^\t\n]*)\t(%d+)\n", function(module: string,
                                                                     member: string,
                                                                     line: string): string
    out[#out + 1] = { module = module, member = member,
      line = math.tointeger(tonumber(line)) or 0 }
    return ""
  end)
  if rest ~= "" then return nil end
  return out
end

--- What a row's digest is of: its Lua, bytecode and packed uses, each
--- but the last led by its length, so no two rows' parts run together.
local function digest_of(lua: string, bytecode: string, refs: string): string
  return Hash.hex_sha256(#lua .. "\n" .. lua .. #bytecode .. "\n" .. bytecode .. refs)
end

--- Whether `path` is `kind` (a "dir" or a "file"), this user's and
--- writable by no one else, as `Fs.cache_dir` holds its directories.
--- A file is taken as it is, never through a link: SQLite writes its
--- log beside where a link leads, which the directory checked is not.
local function private(path: string, kind: string): boolean, string
  local st, trouble: sys.Stat, string = nil, ""
  if kind == "file" then st, trouble = sys.lstat(path) else st, trouble = sys.stat(path) end
  if st == nil then return false, path .. ": " .. trouble end
  if st.kind == "link" then return false, path .. ": a symbolic link" end
  if st.kind ~= kind then return false, path .. ": not a " .. (kind == "dir" and "directory" or kind) end
  if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
  if st.mode & 0x12 ~= 0 then return false, path .. ": writable by its group or others" end
  return true, ""
end

--- Makes this format's table when the file has none yet, dropping any
--- earlier format's, in one transaction; a file that has it is only read.
local function prepare(db: Sqlite.Handle): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name GLOB 'compiled_v*'")
  if rows == nil then return false, trouble end
  local stale: {string} = {}
  local current = false
  for _, row in ipairs(rows) do
    local number = math.tointeger(tonumber(row[1]:match("^compiled_v(%d+)$")))
    if row[1] == compiled then
      current = true
    elseif number ~= nil and number < version then
      stale[#stale + 1] = row[1]
    end
  end
  if current and #stale == 0 then return true, "" end
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local statements: {string} = {}
  for _, name in ipairs(stale) do statements[#statements + 1] = "DROP TABLE IF EXISTS " .. name end
  for _, statement in ipairs(schema) do statements[#statements + 1] = statement end
  for _, statement in ipairs(statements) do
    local ok, statement_trouble = db:exec(statement)
    if not ok then
      local _, _ = db:exec("ROLLBACK")
      return false, statement_trouble
    end
  end
  return db:exec("COMMIT")
end

--- Opens the cache at `path`, making it and its directory when missing.
--- Its directory is made 0700 when missing, and the file 0600 before
--- SQLite opens it, so no build ever meets it wider; it and the file must be
--- private (`private`): a file made here is made 0600.
function shared_compiles.open(path: string): shared_compiles.Cache | nil, string
  local dir = Fs.dirname(path)
  local made, made_trouble = Fs.mkdirs(Fs.dirname(dir))
  if not made then return nil, made_trouble end
  local _, _, _ = sys.mkdir(dir, 0x1c0)
  local dir_held, dir_trouble = private(dir, "dir")
  if not dir_held then return nil, dir_trouble end
  -- Made here, whoever else is making it: O_EXCL takes no link, and a
  -- file already there is held below.
  local fd, create_trouble, number = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
  if fd ~= nil then
    local _, _ = sys.close(fd)
  elseif number ~= sys.EEXIST then
    return nil, path .. ": " .. create_trouble
  end
  local file_held, file_trouble = private(path, "file")
  if not file_held then return nil, file_trouble end
  local opened, trouble = Sqlite.open(path, true)
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): shared_compiles.Cache | nil, string
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

function shared_compiles.close(cache: shared_compiles.Cache)
  local _, _ = cache.db:close()
end

--- Whether `trouble`, from a query of the cache, says the file itself
--- is broken, rather than, say, busy.
-- The same test, and the same `set_aside`, as build.shared_verdicts',
-- kept apart so neither cache's code enters the other's identity: this
-- module is in no compile key, that one is in every test's.
local function corrupt(trouble: string): boolean
  return trouble:find("malformed", 1, true) ~= nil or
    trouble:find("not a database", 1, true) ~= nil
end

--- Moves a broken cache aside, write-ahead log and all -- the log and
--- its index first -- to `<path>.corrupt-<now_ns>`, removing any earlier
--- one set aside there, so the next build starts a fresh cache rather
--- than meeting it again. Answers where it went, or nil and why.
local function set_aside(path: string, now_ns: integer): string | nil, string
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

--- The compile kept under the shared `key`, or nil, and why when the
--- cache could not answer. A row that does not decode to what its digest
--- says -- damaged, or written by something else -- is a miss, and is
--- deleted, so a compile made here takes its place.
function shared_compiles.look(cache: shared_compiles.Cache,
                              key: string): importer.Shared.Compile | nil, string
  local rows, trouble = Sqlite.rows(cache.db,
    "SELECT lua, bytecode, refs, digest FROM " .. compiled .. " WHERE key = ?1", { text(key) })
  if rows == nil then return nil, trouble end
  local row = rows[1]
  if row == nil then return nil, "" end
  local parts: {string} = {}
  for index = 1, 3 do
    local cell = row[index]
    local packed_part = cell.blob or cell.text
    local part: string | nil = nil
    if packed_part ~= nil then
      local inflated, _ = Compress.inflate("raw", packed_part)
      part = inflated
    end
    if part == nil then break end
    parts[index] = part
  end
  local references = #parts == 3 and unpacked(parts[3]) or nil
  local stored = row[4].text
  if references == nil or stored ~= digest_of(parts[1], parts[2], parts[3]) then
    -- Only the row read, by its digest: a good one a build writes under
    -- the key meanwhile stays. Best effort: a busy file leaves it for the
    -- next build that looks, and the cache stays on.
    local _, _ = Sqlite.run(cache.db,
      "DELETE FROM " .. compiled .. " WHERE key = ?1 AND digest IS ?2",
      { text(key), stored ~= nil and text(stored) or {} })
    return nil, ""
  end
  return { lua = parts[1], bytecode = parts[2], references = references }, ""
end

--- Writes what a build owes the cache, at `now_ns`, in one transaction:
--- each compile kept where no row holds its key yet, each row used made
--- the latest, and, when anything was written, what is no longer kept
--- dropped: rows unused for thirty days, then the least lately used
--- past `bound_bytes` (by default 256 MB).
function shared_compiles.settle(cache: shared_compiles.Cache, owed: shared_compiles.Owed,
                                now_ns: integer, bound_bytes?: integer): boolean, string
  if #owed.kept == 0 and #owed.used == 0 then return true, "" end
  local db = cache.db
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    for _, kept in ipairs(owed.kept) do
      local refs = packed(kept.references)
      local ok, trouble = Sqlite.run(db,
        "INSERT OR IGNORE INTO " .. compiled .. " (key, lua, bytecode, refs, digest, size, " ..
        "used_ns) VALUES (?1, deflate(?2), deflate(?3), deflate(?4), ?5, 0, ?6)",
        { text(kept.key), { blob = kept.lua }, { blob = kept.bytecode }, { blob = refs },
          text(digest_of(kept.lua, kept.bytecode, refs)), { integer = now_ns } })
      if not ok then return false, trouble end
      ok, trouble = Sqlite.run(db, "UPDATE " .. compiled ..
        " SET size = length(key) + length(lua) + length(bytecode) + length(refs) " ..
        "WHERE key = ?1 AND size = 0", { text(kept.key) })
      if not ok then return false, trouble end
    end
    for _, key in ipairs(owed.used) do
      local ok, trouble = Sqlite.run(db, "UPDATE " .. compiled .. " SET used_ns = ?1 WHERE key = ?2",
        { { integer = now_ns }, text(key) })
      if not ok then return false, trouble end
    end
    if #owed.kept == 0 then return true, "" end
    local aged, age_trouble = Sqlite.run(db, "DELETE FROM " .. compiled .. " WHERE used_ns < ?1",
      { { integer = now_ns - kept_ns } })
    if not aged then return false, age_trouble end
    return Sqlite.run(db, "DELETE FROM " .. compiled .. " WHERE key IN (SELECT key FROM " ..
      "(SELECT key, SUM(size) OVER (ORDER BY used_ns DESC, key) AS total FROM " .. compiled ..
      ") WHERE total > ?1)", { { integer = bound_bytes or kept_bytes } })
  end
  local ok, trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, trouble
  end
  return db:exec("COMMIT")
end

--- The shared cache for one build, as `importer.compile` takes it, or
--- nil where there is none: turned off, or not to be opened, which is
--- said once, as is any later failure to read or write it, and the
--- build goes on without it. A corrupt file is moved aside
--- (`set_aside`), so the next build starts a fresh one.
function shared_compiles.for_build(environment?: {string:string}): importer.Shared | nil
  local path, trouble = location(environment)
  local cache: shared_compiles.Cache | nil = nil
  if path ~= nil then cache, trouble = shared_compiles.open(path) end
  local function drop(why: string)
    local aside = ""
    if path ~= nil and corrupt(why) then
      if cache ~= nil then
        shared_compiles.close(cache)
        cache = nil
      end
      local moved, _ = set_aside(path, Time.now_ns())
      if moved ~= nil then aside = "; moved aside to " .. moved end
    end
    if cache ~= nil then
      shared_compiles.close(cache)
      cache = nil
    end
    local _, _ = log:complain("build: shared compiles: " .. why ..
      "; building without them (" .. variable .. "=0 turns them off)" .. aside)
  end
  if cache == nil then
    if trouble ~= "" then drop(trouble) end
    return nil
  end
  local owed: shared_compiles.Owed = { kept = {}, used = {} }
  return {
    look = function(m: importer.Module, own_tree: boolean): importer.Shared.Compile | nil
      if cache == nil then return nil end
      local key = shared_compiles.key(m.key, own_tree, m.generated, m.file)
      local found, look_trouble = shared_compiles.look(cache, key)
      if found == nil then
        if look_trouble ~= "" then drop(look_trouble) end
        return nil
      end
      owed.used[#owed.used + 1] = key
      return found
    end,
    keep = function(m: importer.Module, own_tree: boolean, made: importer.Shared.Compile)
      if cache == nil then return end
      owed.kept[#owed.kept + 1] = {
        key = shared_compiles.key(m.key, own_tree, m.generated, m.file),
        lua = made.lua, bytecode = made.bytecode, references = made.references,
      }
    end,
    finish = function()
      if cache == nil then return end
      local settled, settle_trouble = shared_compiles.settle(cache, owed, Time.now_ns())
      if not settled then
        drop(settle_trouble)
        return
      end
      shared_compiles.close(cache)
      cache = nil
    end,
  }
end

return shared_compiles
