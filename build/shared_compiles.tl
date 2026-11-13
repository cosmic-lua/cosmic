--- The compiles and parses every checkout shares: a SQLite database
--- under the cosmic cache directory, beside the `compiled` table and the
--- parse tables each checkout keeps in `build.db`. The file is
--- `build/cache.db` in [`Fs.cache_dir`]'s `$XDG_CACHE_HOME/cosmic`
--- (`~/.cache/cosmic`) by default, or the absolute path
--- `COSMIC_BUILD_CACHE` names; `0` turns the cache off. A module's key
--- ([`build.importer`]'s) names no path: it covers the module's import
--- graph by name and content, and the compiler's identity. So a compile
--- one checkout made stands in another of the same content, and a fresh
--- worktree compiles only what no sibling has compiled already.
---
--- A row is keyed by more than the local key (`key`): also by what else
--- decides whether a compile is accepted, which a checkout's own cache
--- leaves out. That is whether the tree is cosmic's own
--- (build.syntax_contracts runs only there) and whether the module was
--- extracted from a doc, so a row never stands where a compile of the
--- module here would refuse it. The file the module is read from is in
--- the local key already. A compile refused and kept only for the run
--- that made it (an unjudged run's, `seen = -1`) is never shared.
---
--- A row holds what a local compile writes: the Lua, the bytecode and
--- the record-field uses its checker found (`typed_refs`), so a
--- projection built from shared rows is the one a compile would have
--- made. It also holds a digest of the three. A row that does not decode
--- to what its digest says is a miss, and is deleted.
---
--- A parse is shared the same way, a row per source: what one parse of
--- it wrote in every table [`build.derivation`] fills from a parse, keyed
--- by the analyzer that parsed it ([`importer.analyzer_identity`]), the
--- source's hash, and whether its docs' lines are mapped to a file it
--- was generated from ([`build.syntax_derivation`]'s `origin_lines`), with a digest of
--- the lot. [`build.importer`]'s `derive` says when a row stands in for a
--- parse.
---
--- A row's bytecode runs (a build of cosmic's own tree carries the
--- `build.*` modules' in its tool), so whoever can write the file
--- can run code as every user of it. The file and its directory are held
--- to what [`Fs.cache_dir`] holds its directories to, wherever the file
--- is: owned by this user, and writable by no one else.
---
--- Many builds share the file at once. It is in WAL mode, so a reader
--- never waits on a writer. A build reads a row at a time and writes
--- what it compiled and parsed in one short transaction as its compile
--- ends; two writers of one key write the same bytes. The file is
--- bounded: a row no build has used for `kept_ns` goes, and past
--- `kept_bytes`, the least lately used of either table go first. A
--- cache that cannot be opened, read or written is reported once and
--- done without: it never fails a build.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local Compress = require("cosmic.compress")
local Sqlite = require("cosmic.sqlite")
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")
local type importer = require("build.importer")
local type SyntaxReceivers = require("build.syntax_receivers")
local shared_sqlite = require("build.shared_sqlite")
local fanout = require("build.compile_fanout")
local plural = require("build.plural")
local Proc = require("cosmic.proc")
local cache_formats = require("build.cache_formats")

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
    references: {SyntaxReceivers.Reference}
    fact_wraps: integer
    parameter_checks: integer
  end

  --- What a parse is shared under: the analyzer that made it, the
  --- source's hash, and whether its docs' lines are mapped.
  record ParseKey
    analyzer: string
    source_hash: string
    mapped: boolean
  end

  --- One parse to keep, under its key.
  record Parsed
    key: ParseKey
    made: importer.Shared.Parse
  end

  --- What a build owes the cache when its compile ends.
  record Owed
    kept: mut {Kept}
    --- Keys the build took a compile from, which stay the longer for it.
    used: mut {string}
    --- Parses made here, none when nil.
    parses?: {Parsed}
    --- Parses the build took, which stay the longer for it; none when nil.
    parses_used?: {ParseKey}
  end
end

--- The variable that moves the cache, or turns it off with `0`.
local variable <const>: Env.Name = "COSMIC_BUILD_CACHE"

--- How many bytes of compiles the cache keeps: some twenty whole
--- states of cosmic's own tree.
local kept_bytes <const> = 256 * 1024 * 1024

--- How long a row no build uses is kept: thirty days.
local kept_ns <const> = Clock.hours(30 * 24)

--- The table rows are in, named by the format's version, which any
--- change to the table's shape or to what a row holds bumps. A later
--- format keeps a table of its own, so a binary of it sharing the file
--- never empties this one's; an earlier format's table is dropped
--- (`prepare`): only an older binary reads it, and this one's rows stand
--- in for it.
local compiled <const> = cache_formats.compiled
local parsed <const> = cache_formats.parsed
local formats <const> = cache_formats.compile_versions

local log = Log.new("cosmic")

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Where the cache is: `COSMIC_BUILD_CACHE` when it names a path, else
--- `cache.db` in `Fs.cache_dir("build")`, made if missing. Nil and ""
--- when the variable is `0`, or nil and why when there is nowhere to
--- keep it.
local function location(environment?: {string:string}): string?, string
  local value: string
  if environment ~= nil then
    value = environment[variable] or ""
  else
    value = Env.read(variable) or ""
  end
  if value == "0" then return nil, "" end
  if value ~= "" then
    if value:sub(1, 1) ~= "/" then
      return nil, variable .. " names no absolute path: " .. value
    end
    return value, ""
  end
  local dir, trouble = Fs.cache_dir("build", { environment = environment })
  if dir == nil then return nil, trouble end
  return dir .. "/cache.db", ""
end

--- Turns the cache off in `environment`, for a process that is to
--- neither read nor write it.
function shared_compiles.turn_off(environment: mut {string:string})
  environment[variable] = "0"
end

--- The key a compile is shared under: the module's own key
--- (`importer.Module.key`), what else decides whether the compile is
--- accepted (`own_tree`, `generated`), and the format's table (`format`,
--- this one's by default).
--- The file the module is read from is no salt here: the module's own
--- key holds it already (build.plans' `dependency_keys`), so a
--- compile is never taken across a moved file.
function shared_compiles.key(key: string, own_tree: boolean, generated?: boolean,
                             format?: string): string
  return Hash.hex_sha256((format or compiled) .. "\n" .. key .. "\n" ..
      (if own_tree then "own" else "project" end) .. "\n" ..
      (if generated == true then "doctest" else "tree" end))
end

local schema <const> = cache_formats.compiles

--- The record-field uses, a line each: module, member and line, by tabs, led for a checked compile by the line `#checks`
--- and the counts of the fact wraps and of the parameter checks it wrote. The line is part of what the row's digest is
--- of; a row without it is a compile of 0 checks.
local function packed(references: {SyntaxReceivers.Reference}, fact_wraps: integer, parameter_checks: integer): string
  local out: mut {string} = {}
  if fact_wraps > 0 or parameter_checks > 0 then
    out[1] = "#checks\t" .. tostring(fact_wraps) .. "\t" .. tostring(parameter_checks) .. "\n"
  end
  for _, r in ipairs(references) do
    out[#out + 1] = r.module .. "\t" .. r.member .. "\t" .. tostring(r.line) .. "\n"
  end
  return table.concat(out)
end

--- The counts `packed` led `refs` by: the fact wraps and the parameter checks, 0 and 0 for none.
local function checks_of(refs: string): integer, integer
  local wraps_text, checks_text = refs:match("^#checks\t(%d+)\t(%d+)\n")
  return math.tointeger(tonumber(wraps_text or "0")) or 0, math.tointeger(tonumber(checks_text or "0")) or 0
end

--- `packed` undone: nil for what `packed` never writes.
local function unpacked(refs: string): {SyntaxReceivers.Reference}?
  local out: mut {SyntaxReceivers.Reference} = {}
  local rest = refs:gsub("^#checks\t%d+\t%d+\n", "", 1):gsub("([^\t\n]*)\t([^\t\n]*)\t(%d+)\n", function(module: string,
                                                                                                         member: string,
                                                                                                         line: string): string
    table.insert(out, { module = module, member = member,
      line = math.tointeger(tonumber(line)) or 0 })
    return ""
  end)
  if rest ~= "" then return nil end
  return out
end

--- What a row's digest is of: its Lua, bytecode and packed uses, each
--- but the last led by its length, so no two rows' parts run together.
local function digest_of(lua: string, bytecode: string, refs: string): string
  return Hash.hex_sha256(tostring(#lua) .. "\n" .. lua .. tostring(#bytecode) .. "\n" .. bytecode .. refs)
end

--- The names a parse requires, a line each.
local function packed_requires(names: {string}): string
  local out: mut {string} = {}
  for _, name in ipairs(names) do out[#out + 1] = name .. "\n" end
  return table.concat(out)
end

--- [`packed_requires`] undone: nil for what it never writes.
local function unpacked_requires(requires: string): {string}?
  local out: mut {string} = {}
  local rest = requires:gsub("([^\n]+)\n", function(name: string): string
    out[#out + 1] = name
    return ""
  end)
  if rest ~= "" then return nil end
  return out
end

--- What a parse row's digest is of: its key, its packed requires and
--- its rows, each but the last led by its length.
local function parse_digest(key: shared_compiles.ParseKey, requires: string,
                            rows: string): string
  return Hash.hex_sha256(tostring(#key.analyzer) .. "\n" .. key.analyzer .. key.source_hash .. "\n" ..
      (if key.mapped then "mapped" else "own" end) .. "\n" .. tostring(#requires) .. "\n" .. requires .. rows)
end

--- Whether `path` is `kind` (a "dir" or a "file"), this user's and
--- writable by no one else, as [`Fs.cache_dir`] holds its directories.
--- A file is taken as it is, never through a link: SQLite writes its
--- log beside where a link leads, which the directory checked is not.
local function private(path: string, kind: sys.Kind): boolean, string
  local st, trouble: sys.Stat?, string = nil, ""
  if kind == "file" then st, trouble = sys.lstat(path) else st, trouble = sys.stat(path) end
  if st == nil then return false, path .. ": " .. trouble end
  if st.kind == "link" then return false, path .. ": a symbolic link" end
  if st.kind ~= kind then
    return false, path .. ": not a " .. (if kind == "dir" then "directory" else kind end)
  end
  if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
  if st.mode & 0x12 ~= 0 then return false, path .. ": writable by its group or others" end
  return true, ""
end

--- Makes each format's table when the file has none yet, and drops any
--- earlier format's table of either kind, in one transaction. A file
--- that has them all is only read.
local function prepare(db: Sqlite.Handle): boolean, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND " ..
      "(name GLOB 'compiled_v*' OR name GLOB 'parsed_v*')")
  if rows == nil then return false, trouble end
  local stale: mut {string} = {}
  local current = 0
  for _, row in ipairs(rows) do
    for _, format in ipairs(formats) do
      local prefix, number = format.prefix, format.number
      local found = math.tointeger(tonumber(row:text(1):match("^" .. prefix .. "(%d+)$")))
      if found == number then
        current = current + 1
      elseif found ~= nil and found < number then
        stale[#stale + 1] = row:text(1)
      end
    end
  end
  if current == #formats and #stale == 0 then return true, "" end
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local statements: mut {string} = {}
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
--- The directory is made 0700 and the file 0600, the file before SQLite
--- opens it, so no build ever meets either wider. Both must be private
--- (`private`), one that already exists included. It is opened in
--- write-ahead mode ([`shared_sqlite.open`]).
function shared_compiles.open(path: string): shared_compiles.Cache?, string
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
  local db, trouble = shared_sqlite.open(path, prepare)
  if db == nil then return nil, trouble end
  return { db = db, path = path }, ""
end

function shared_compiles.close(cache: shared_compiles.Cache)
  local _, _ = cache.db:close()
end

--- The bytes of column `index` of `row` when it holds text or a blob,
--- else nil: a damaged row can hold any type, and is a miss, not a
--- failure.
local function bytes_at(row: Sqlite.Row, index: integer): string?
  local kind = row:kind(index)
  if kind == "blob" or kind == "text" then return row:bytes(index) end
  return nil
end

--- The text of column `index` of `row`, or nil when it holds another
--- type.
local function text_at(row: Sqlite.Row, index: integer): string?
  if row:kind(index) == "text" then return row:text(index) end
  return nil
end

--- The compile kept under the shared `key`, or nil, and why when the
--- cache could not answer. A row that does not decode to what its digest
--- says -- damaged, or written by something else -- is a miss, and is
--- deleted, so a compile made here takes its place.
function shared_compiles.look(cache: shared_compiles.Cache,
                              key: string): importer.Shared.Compile?, string
  local rows, trouble = Sqlite.rows(cache.db,
    "SELECT lua, bytecode, refs, digest FROM " .. compiled .. " WHERE key = ?1", { text(key) })
  if rows == nil then return nil, trouble end
  local row = rows[1]
  if row == nil then return nil, "" end
  local function inflated_part(index: integer): string?
    local packed_part = bytes_at(row, index)
    if packed_part == nil then return nil end
    local inflated, _ = Compress.inflate("raw", packed_part)
    return inflated
  end
  -- Each part is read only when the ones before it were found.
  local lua_text = inflated_part(1)
  local bytecode_text = if lua_text ~= nil then inflated_part(2) else nil end
  local refs_text = if bytecode_text ~= nil then inflated_part(3) else nil end
  local references: {SyntaxReceivers.Reference}? = nil
  local fact_wraps, parameter_checks = 0, 0
  if refs_text ~= nil then
    references = unpacked(refs_text)
    fact_wraps, parameter_checks = checks_of(refs_text)
  end
  local stored = text_at(row, 4)
  if references == nil or lua_text == nil or bytecode_text == nil or refs_text == nil or
      stored ~= digest_of(lua_text, bytecode_text, refs_text) then
    -- Only the row read, by its digest: a good one a build writes under
    -- the key meanwhile stays. Best effort: a busy file leaves it for the
    -- next build that looks, and the cache stays on.
    local _, _ = Sqlite.run(cache.db,
      "DELETE FROM " .. compiled .. " WHERE key = ?1 AND digest IS ?2",
      { text(key), if stored ~= nil then text(stored) else {} end })
    return nil, ""
  end
  return { lua = lua_text, bytecode = bytecode_text, references = references, fact_wraps = fact_wraps,
    parameter_checks = parameter_checks }, ""
end

--- Whether a compile is kept under the shared `key`, its row not read:
--- false where there is none or the cache cannot answer, so a build that
--- asks before it compiles compiles.
local function known(cache: shared_compiles.Cache, key: string): boolean
  local rows, _ = Sqlite.rows(cache.db, "SELECT 1 FROM " .. compiled .. " WHERE key = ?1", { text(key) })
  return rows ~= nil and rows[1] ~= nil
end

--- A list of hashes, as SQLite's `json_each` reads it: each is hex.
local function json_list(hashes: {string}): string
  return '["' .. table.concat(hashes, '","') .. '"]'
end

--- The analyzers whose parses the cache holds of every one of `hashes`,
--- the most lately used first.
function shared_compiles.analyzers(cache: shared_compiles.Cache,
                                   hashes: {string}): {string}?, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT analyzer FROM " .. parsed .. " WHERE source_hash IN " ..
      "(SELECT value FROM json_each(?1)) GROUP BY analyzer " ..
      "HAVING count(DISTINCT source_hash) = ?2 ORDER BY max(used_ns) DESC, analyzer",
    { text(json_list(hashes)), { integer = #hashes } })
  if rows == nil then return nil, trouble end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do out[#out + 1] = row:text(1) end
  return out, ""
end

--- What `analyzer` found each of `hashes` requires, by hash, of those
--- the cache holds a parse of. Unchecked against a digest -- only a
--- whole row read by [`look_parse`] is -- so it is a guess, for
--- [`build.importer`]'s fixed point, and nothing it guesses is kept: a
--- source's requires are the same whether its lines are mapped or not.
function shared_compiles.requires(cache: shared_compiles.Cache, analyzer: string,
                                  hashes: {string}): {string:{string}}?, string
  local rows, trouble = Sqlite.text_rows(cache.db,
    "SELECT source_hash, requires FROM " .. parsed .. " WHERE analyzer = ?1 " ..
      "AND source_hash IN (SELECT value FROM json_each(?2))",
    { text(analyzer), text(json_list(hashes)) })
  if rows == nil then return nil, trouble end
  local out: mut {string:{string}} = {}
  for _, row in ipairs(rows) do
    local names = unpacked_requires(row:text(2))
    if names ~= nil then out[row:text(1)] = names end
  end
  return out, ""
end

--- The parse kept under `key`, or nil, and why when the cache could not
--- answer. A row that does not decode to what its digest says is a miss,
--- and is deleted, as `look` deletes a compile's.
function shared_compiles.look_parse(cache: shared_compiles.Cache,
                                    key: shared_compiles.ParseKey): importer.Shared.Parse?, string
  local where: mut {Sqlite.Value} = { text(key.analyzer), text(key.source_hash),
    { integer = if key.mapped then 1 else 0 end } }
  local rows, trouble = Sqlite.rows(cache.db,
    "SELECT requires, rows, digest FROM " .. parsed ..
      " WHERE analyzer = ?1 AND source_hash = ?2 AND mapped = ?3", where)
  if rows == nil then return nil, trouble end
  local row = rows[1]
  if row == nil then return nil, "" end
  local requires = bytes_at(row, 1)
  local packed_rows = bytes_at(row, 2)
  local inflated: string? = nil
  if packed_rows ~= nil then
    local out, _ = Compress.inflate("raw", packed_rows)
    inflated = out
  end
  local names = if requires ~= nil then unpacked_requires(requires) else nil end
  local stored = text_at(row, 3)
  if names == nil or inflated == nil or requires == nil or
      stored ~= parse_digest(key, requires, inflated) then
    local digest: Sqlite.Value = if stored ~= nil then text(stored) else {} end
    where[#where + 1] = digest
    local _, _ = Sqlite.run(cache.db, "DELETE FROM " .. parsed ..
        " WHERE analyzer = ?1 AND source_hash = ?2 AND mapped = ?3 AND digest IS ?4", where)
    return nil, ""
  end
  return { requires = names, rows = inflated }, ""
end

--- Drops what the cache no longer keeps, at `now_ns`: rows of either
--- table unused for thirty days, then, of both at once, the least
--- lately used past `bound_bytes`.
local function evict(db: Sqlite.Handle, now_ns: integer, bound_bytes: integer): boolean, string
  for _, name in ipairs({ compiled, parsed }) do
    local aged, age_trouble = Sqlite.run(db, "DELETE FROM " .. name .. " WHERE used_ns < ?1",
      { { integer = now_ns - kept_ns } })
    if not aged then return false, age_trouble end
  end
  local over, trouble = Sqlite.text_rows(db,
    "SELECT tab, id FROM (SELECT tab, id, SUM(size) OVER (ORDER BY used_ns DESC, tab, id) " ..
      "AS total FROM (SELECT 'c' AS tab, rowid AS id, size, used_ns FROM " .. compiled ..
      " UNION ALL SELECT 'p', rowid, size, used_ns FROM " .. parsed .. ")) WHERE total > ?1",
    { { integer = bound_bytes } })
  if over == nil then return false, trouble end
  local compiled_ids: mut {string} = {}
  local parsed_ids: mut {string} = {}
  for _, row in ipairs(over) do
    local tab = row:text(1)
    local second = row:text(2)
    if tab == "c" then
      compiled_ids[#compiled_ids + 1] = second
    elseif tab == "p" then
      parsed_ids[#parsed_ids + 1] = second
    else
      error("the eviction query answered the table tag " .. tab .. ", not 'c' or 'p'")
    end
  end
  local function drop(name: string, list: {string}): boolean, string
    if #list == 0 then return true, "" end
    return Sqlite.run(db, "DELETE FROM " .. name ..
        " WHERE rowid IN (SELECT value FROM json_each(?1))",
      { text("[" .. table.concat(list, ",") .. "]") })
  end
  local dropped, drop_trouble = drop(compiled, compiled_ids)
  if not dropped then return false, drop_trouble end
  dropped, drop_trouble = drop(parsed, parsed_ids)
  if not dropped then return false, drop_trouble end
  return true, ""
end

--- Writes what a build owes the cache, at `now_ns`, in one transaction:
--- each compile kept where no row holds its key yet, each parse kept
--- over any row of its key, each row used made the latest, and, when
--- anything was written, what is no longer kept dropped (`evict`),
--- bounded by `bound_bytes` (by default 256 MB). A parse replaces its
--- key's row because it is right by construction, where that row may
--- not be: a `requires` guess [`build.importer`]'s fixed point reads
--- without a digest could have led it to parse here what the row
--- holds, and would lead every later build there again.
function shared_compiles.settle(cache: shared_compiles.Cache, owed: shared_compiles.Owed,
                                now_ns: integer, bound_bytes?: integer): boolean, string
  local parses = owed.parses or {}
  local parses_used = owed.parses_used or {}
  if #owed.kept == 0 and #owed.used == 0 and #parses == 0 and #parses_used == 0 then
    return true, ""
  end
  local db = cache.db
  local begun, begin_trouble = db:exec("BEGIN IMMEDIATE")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    for _, kept in ipairs(owed.kept) do
      local refs = packed(kept.references, kept.fact_wraps, kept.parameter_checks)
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
    for _, one in ipairs(parses) do
      local key = one.key
      local analyzer_value = text(key.analyzer)
      local source_value = text(key.source_hash)
      local mapped_value: Sqlite.Value = { integer = if key.mapped then 1 else 0 end }
      local where: {Sqlite.Value} = { analyzer_value, source_value, mapped_value }
      local requires = packed_requires(one.made.requires)
      local ok, trouble = Sqlite.run(db,
        "INSERT OR REPLACE INTO " .. parsed .. " (analyzer, source_hash, mapped, requires, rows, " ..
          "digest, size, used_ns) VALUES (?1, ?2, ?3, ?4, deflate(?5), ?6, 0, ?7)",
        { analyzer_value, source_value, mapped_value, text(requires), { blob = one.made.rows },
          text(parse_digest(key, requires, one.made.rows)), { integer = now_ns } })
      if not ok then return false, trouble end
      ok, trouble = Sqlite.run(db, "UPDATE " .. parsed ..
          " SET size = length(analyzer) + length(source_hash) + length(requires) + length(rows) " ..
          "WHERE analyzer = ?1 AND source_hash = ?2 AND mapped = ?3 AND size = 0", where)
      if not ok then return false, trouble end
    end
    for _, key in ipairs(parses_used) do
      local ok, trouble = Sqlite.run(db, "UPDATE " .. parsed .. " SET used_ns = ?1 " ..
          "WHERE analyzer = ?2 AND source_hash = ?3 AND mapped = ?4",
        { { integer = now_ns }, text(key.analyzer), text(key.source_hash),
          { integer = if key.mapped then 1 else 0 end } })
      if not ok then return false, trouble end
    end
    if #owed.kept == 0 and #parses == 0 then return true, "" end
    return evict(db, now_ns, bound_bytes or kept_bytes)
  end
  local ok, trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, trouble
  end
  return db:exec("COMMIT")
end

--- What a copy that compiles cosmic's own tree holds at its most, with room to spare: 1.1 GB measured, as the build
--- itself holds compiling them all. A host is given no more copies than it has memory for
--- ([`fanout.copies`]).
local copy_bytes <const> = 1536 * 1024 * 1024

--- A size no copy's file reaches: nothing is evicted from one.
local unbounded <const> = 1 << 40

--- Says that `late` copies of the process were ended while `doing` their share, which the build then does itself.
local function said_late(late: integer, doing: string)
  if late == 0 then return end
  local _, _ = log:complain("build: " .. plural.count(late, "copy", "copies") .. " of the process still " .. doing ..
      " after " .. tostring(fanout.patience_ns // (60 * 1000000000)) .. " minutes " ..
      (if late == 1 then "was" else "were" end) .. " ended; the build does that work itself")
end

--- Compiles `due` in copies of this process ([`build.compile_fanout`]), `make` the compile of one module, `own_tree`
--- as a shared compile is keyed by: what [`importer.Shared`]'s `fan` answers. A compile of a module is a function of
--- the tree a build has read and of that module alone, and a build makes them one after another in one process: 1200
--- of them take 53 s of a cold boot on a four-core host. Each copy holds the tree as the process read it, compiles
--- every n-th module, keeps what it made in a file of its own in this module's form, and ends. `look` reads a
--- module's compile from the file of the copy that made it.
---
--- Nothing a copy does reaches the build but its file. A compile a copy could not make is not kept, and one of a
--- copy that ended badly is not read: the build makes each again itself, and says what the checker said, once. So this
--- only saves time. Nil where no copy is made: too few modules, one processor, or a host that forks no process.
local function fan(due: {importer.Module}, own_tree: boolean,
                   make: function(m: importer.Module, rest: {string:boolean}): importer.Shared.Compile?,
                   watch?: function()): importer.Shared.Fanned?
  local copies = fanout.copies(#due, Proc.cpu_count(), copy_bytes)
  if copies == 0 then return nil end
  local dir, _ = Fs.mkdtemp("cosmic-compile-")
  if dir == nil then return nil end
  local function path_of(copy: integer): string
    return dir .. "/copies/" .. tostring(copy) .. ".db"
  end
  local function key_of(m: importer.Module): string
    return shared_compiles.key(assert(m.key), own_tree, m.generated)
  end
  local ran = fanout.run(copies, function(copy: integer)
    local cache = assert(shared_compiles.open(path_of(copy)))
    local kept: mut {shared_compiles.Kept} = {}
    -- What this copy has yet to make, which `make` is told so that it forgets the rest.
    local rest: mut {string:boolean} = {}
    for index = copy, #due, copies do
      rest[assert(due[index], "an index within the list is a module").path] = true
    end
    for index = copy, #due, copies do
      local m = assert(due[index], "an index within the list is a module")
      rest[m.path] = nil
      local made = make(m, rest)
      if made ~= nil then
        kept[#kept + 1] = { key = key_of(m), lua = made.lua, bytecode = made.bytecode,
          references = made.references, fact_wraps = made.fact_wraps, parameter_checks = made.parameter_checks }
      end
    end
    assert(shared_compiles.settle(cache, { kept = kept, used = {} }, Clock.now_ns(), unbounded))
    shared_compiles.close(cache)
  end, watch)
  said_late(ran.late, "compiling")
  local ended = ran.ended
  local opened: mut {integer:shared_compiles.Cache} = {}
  for copy = 1, copies do
    if ended[copy] == true then
      local cache, _ = shared_compiles.open(path_of(copy))
      if cache ~= nil then opened[copy] = cache end
    end
  end
  local copy_of: mut {string:integer} = {}
  for index, m in ipairs(due) do copy_of[m.path] = (index - 1) % copies + 1 end
  return {
    look = function(m: importer.Module): importer.Shared.Compile?
      local copy = copy_of[m.path]
      local cache = if copy ~= nil then opened[copy] else nil end
      if cache == nil then return nil end
      local found, _ = shared_compiles.look(cache, key_of(m))
      return found
    end,
    close = function()
      for _, cache in pairs(opened) do shared_compiles.close(cache) end
      local _, _ = Fs.remove_tree(dir)
    end,
  }
end

--- The analyzer a copy's parses are kept under in its own file: no analyzer's name, since the file is read by the build
--- that made the copy and by nothing else.
local copy_analyzer <const> = "a copy of the build"

--- Parses `count` sources in copies of this process, as `fan` compiles modules in them: what [`importer.Shared`]'s
--- [`fan_parses`] answers. Each copy keeps the parses `make` answers it in a file of its own, as a shared parse is kept, and
--- `look` reads a source's from whichever copy made it. Nil where no copy is made. A copy that parses holds less than
--- one that compiles, and is counted against the host's memory as that one is.
local function fan_parses(count: integer,
                          make: function(copy: integer, copies: integer): {importer.Shared.ParseMade}):
    importer.Shared.ParsesFanned?
  local copies = fanout.copies(count, Proc.cpu_count(), copy_bytes)
  if copies == 0 then return nil end
  local dir, _ = Fs.mkdtemp("cosmic-parse-")
  if dir == nil then return nil end
  local function path_of(copy: integer): string
    return dir .. "/copies/" .. tostring(copy) .. ".db"
  end
  local ran = fanout.run(copies, function(copy: integer)
    local parses: mut {shared_compiles.Parsed} = {}
    for _, one in ipairs(make(copy, copies)) do
      parses[#parses + 1] = { key = { analyzer = copy_analyzer, source_hash = one.source_hash, mapped = one.mapped },
        made = one.parse }
    end
    local cache = assert(shared_compiles.open(path_of(copy)))
    assert(shared_compiles.settle(cache, { kept = {}, used = {}, parses = parses }, Clock.now_ns(), unbounded))
    shared_compiles.close(cache)
  end)
  said_late(ran.late, "parsing")
  local ended = ran.ended
  local opened: mut {shared_compiles.Cache} = {}
  for copy = 1, copies do
    if ended[copy] == true then
      local cache, _ = shared_compiles.open(path_of(copy))
      if cache ~= nil then opened[#opened + 1] = cache end
    end
  end
  return {
    look = function(source_hash: string, mapped: boolean): importer.Shared.Parse?
      for _, cache in ipairs(opened) do
        local found, _ = shared_compiles.look_parse(cache,
          { analyzer = copy_analyzer, source_hash = source_hash, mapped = mapped })
        if found ~= nil then return found end
      end
      return nil
    end,
    close = function()
      for _, cache in ipairs(opened) do shared_compiles.close(cache) end
      local _, _ = Fs.remove_tree(dir)
    end,
  }
end

--- The cache a build holds open, which a failure closes and drops.
local record Opened
  mut cache: shared_compiles.Cache?
end

--- The shared cache for one build, as [`importer.derive`] and
--- [`importer.compile`] take it, or nil where there is none: turned off,
--- or not to be opened. That is reported once, as is any later failure
--- to read or write it, and the build goes on without the cache.
function shared_compiles.for_build(environment?: {string:string}): importer.Shared?
  local path, trouble = location(environment)
  local open: Opened = { cache = nil }
  if path ~= nil then open.cache, trouble = shared_compiles.open(path) end
  local function drop(why: string)
    local cache = open.cache
    -- TODO: retire broken caches automatically once cache-wide lifetime
    -- ownership and identity checks can exclude concurrent users and replacements.
    if cache ~= nil then
      shared_compiles.close(cache)
      open.cache = nil
    end
    local _, _ = log:complain("build: shared compiles: " .. why ..
        "; building without them (" .. variable .. "=0 turns them off)")
  end
  if open.cache == nil then
    if trouble ~= "" then drop(trouble) end
    return nil
  end
  local owed: shared_compiles.Owed = { kept = {}, used = {}, parses = {}, parses_used = {} }
  return {
    look = function(m: importer.Module, own_tree: boolean): importer.Shared.Compile?
      local held = open.cache
      if held == nil then return nil end
      local key = shared_compiles.key(assert(m.key), own_tree, m.generated)
      local found, look_trouble = shared_compiles.look(held, key)
      if found == nil then
        if look_trouble ~= "" then drop(look_trouble) end
        return nil
      end
      owed.used[#owed.used + 1] = key
      return found
    end,
    fan = fan,
    fan_parses = fan_parses,
    known = function(m: importer.Module, own_tree: boolean): boolean
      local held = open.cache
      if held == nil then return false end
      return known(held, shared_compiles.key(assert(m.key), own_tree, m.generated))
    end,
    keep = function(m: importer.Module, own_tree: boolean, made: importer.Shared.Compile)
      if open.cache == nil then return end
      table.insert(owed.kept, {
        key = shared_compiles.key(assert(m.key), own_tree, m.generated),
        lua = made.lua, bytecode = made.bytecode, references = made.references,
        fact_wraps = made.fact_wraps, parameter_checks = made.parameter_checks,
      })
    end,
    analyzers = function(hashes: {string}): {string}
      local cache = open.cache
      if cache == nil then return {} end
      local found, found_trouble = shared_compiles.analyzers(cache, hashes)
      if found == nil then
        drop(found_trouble)
        return {}
      end
      return found
    end,
    requires = function(analyzer: string, hashes: {string}): {string:{string}}
      local cache = open.cache
      if cache == nil then return {} end
      local found, found_trouble = shared_compiles.requires(cache, analyzer, hashes)
      if found == nil then
        drop(found_trouble)
        return {}
      end
      return found
    end,
    parse = function(analyzer: string, source_hash: string,
                     mapped: boolean): importer.Shared.Parse?
      local cache = open.cache
      if cache == nil then return nil end
      local key: shared_compiles.ParseKey = {
        analyzer = analyzer, source_hash = source_hash, mapped = mapped,
      }
      local found, look_trouble = shared_compiles.look_parse(cache, key)
      if found == nil then
        if look_trouble ~= "" then drop(look_trouble) end
        return nil
      end
      table.insert(assert(owed.parses_used), key) -- checked: overload_none -- untyped: call
      return found
    end,
    offer = function(analyzer: string, source_hash: string, mapped: boolean,
                     made: importer.Shared.Parse)
      if open.cache == nil then return end
      table.insert(assert(owed.parses), { -- checked: overload_none -- untyped: call
        key = { analyzer = analyzer, source_hash = source_hash, mapped = mapped }, -- checked: arms_differ
        made = made,
      })
    end,
    finish = function()
      local held = open.cache
      if held == nil then return end
      local settled, settle_trouble = shared_compiles.settle(held, owed, Clock.now_ns())
      if not settled then
        drop(settle_trouble)
        return
      end
      shared_compiles.close(held)
      open.cache = nil
    end,
  }
end

return shared_compiles
