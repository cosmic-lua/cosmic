--- The digests of the modules the identities of the code hash ([`build.code_fingerprint`]'s `of`), read where they are
--- kept and not made again: lexing the 74 to 89 modules of the walks ([`build.code_walk`]) is some 130 ms in a plain core and
--- many times that in a sanitized one, and every process that names the code would pay it.
---
--- A digest is a function of a source alone, so it is made once, where the source is first held:
---
---  * The projection a tool is written from ([`build.writer`]) carries a `fingerprints` row, by path, for each module and
---    declaration some walk reaches, made from the source the row of `modules` or `decls` holds. A process running the
---    binary reads it ([`Fingerprints.carried`]), and a test's pure store ([`build.closure_store`]) copies the rows of the
---    modules it keeps.
---  * The working database keeps `fingerprinted`, by the SHA-256 of a source and the version of the form, so that the
---    sources a tree stages ([`Fingerprints.staged`]) are lexed once and not by each process that names the tree's code.
---
--- Both are exactly [`build.code_fingerprint`]'s `of` of the source: [`build.fingerprints_test`] holds the rows to it.

local CodeFingerprint = require("build.code_fingerprint")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local AnalysisSchema = require("build.analysis_schema")
local bind = require("build.bind")

local record Fingerprints
  --- The digest of the module or declaration `name` the running binary carries (a declaration ahead of a module, as
  --- [`Store.source`] reads them), nil and "" for a name it holds no source of, whether absent or withheld ([`Store.withheld`]),
  --- and nil and why when the query failed.
  ---
  --- A binary whose database has no `fingerprints` table is one an older tool wrote, or a database made by hand: the digest
  --- is made of its source, which is the same value, only slower. A binary that has the table and holds a source with no row
  --- in it is wrong, and raises: a half-filled table would name the code by whichever modules had a row.
  carried: function(name: string): string?, string

  --- The digest of the source the tree stages for `path` in the working database `db` (a declaration's ahead of a
  --- module's, or a module's alone with `modules_only`), kept in `fingerprinted` once made. nil and "" where the tree
  --- holds no such path, and nil and why where the query failed.
  staged: function(db: Sqlite.Handle, path: string, modules_only?: boolean): string?, string

  --- Each source of each of `paths` the working database `db` stages, as a line of `path`, a space and its digest, ordered by path and then
  --- the source's SHA-256 (a declaration and a module may share a path), as [`Fingerprints.staged`] keeps them.
  staged_lines: function(db: Sqlite.Handle, paths: {string}): {string}?, string

  --- Makes into `fingerprinted` the digest of each source `from` (an SQL query of the working database, of `source_hash`,
  --- `source` and `path`) holds that it has none of. A database that cannot be written leaves it unmade, and the digests
  --- are still given, made of the sources.
  fill: function(db: Sqlite.Handle, from: string, params?: {Sqlite.Value}): boolean, string
end

local text = bind.text

--- Whether the binary's database has the `fingerprints` table, once.
local table_held: boolean? = nil

local function binary_handle(): Sqlite.Handle?
  local databases = Store.databases()
  return databases[#databases]
end

function Fingerprints.carried(name: string): string?, string
  local binary = binary_handle()
  if binary == nil then return nil, "" end
  if table_held == nil then
    local rows, trouble = Sqlite.text_rows(binary, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'fingerprints'")
    if rows == nil then return nil, "fingerprints: " .. trouble end
    table_held = #rows > 0
  end
  if table_held ~= true then
    local source, _ = Store.source(name)
    if source == nil then return nil, "" end
    return CodeFingerprint.of(source, name), ""
  end
  local rows, trouble = Sqlite.text_rows(binary, "SELECT fingerprint FROM fingerprints WHERE path = ?1", { text(name) })
  if rows == nil then return nil, "fingerprints: " .. trouble end
  local row = rows[1]
  if row ~= nil then return row:text(1), "" end
  local source, _ = Store.source(name)
  if source ~= nil then
    return nil, "the binary carries the source of " .. name .. " but no fingerprint of it: " ..
      "it was written by a tool that did not keep one for every module the identities read; build it again (bin/zig build boot)"
  end
  return nil, ""
end

local ensure <const> =
  "CREATE TABLE IF NOT EXISTS fingerprinted (source_hash TEXT NOT NULL, form TEXT NOT NULL, fingerprint TEXT NOT NULL, " ..
  "PRIMARY KEY (source_hash, form)) WITHOUT ROWID"

--- Whether `fingerprinted` could be created or is there, so a database that cannot be written is answered without it.
local function cache(db: Sqlite.Handle): boolean
  local ok, _ = Sqlite.run(db, ensure)
  return ok
end

function Fingerprints.fill(db: Sqlite.Handle, from: string, params?: {Sqlite.Value}): boolean, string
  if not cache(db) then return false, "" end
  local missing, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, source, path FROM (" .. from .. ") s WHERE NOT EXISTS " ..
      "(SELECT 1 FROM fingerprinted f WHERE f.source_hash = s.source_hash AND f.form = '" .. CodeFingerprint.version ..
      "') GROUP BY source_hash", params)
  if missing == nil then return false, trouble end
  for _, row in ipairs(missing) do
    local ok, why = Sqlite.run(db,
      "INSERT OR IGNORE INTO fingerprinted (source_hash, form, fingerprint) VALUES (?1, ?2, ?3)",
      { text(row:text(1)), text(CodeFingerprint.version), text(CodeFingerprint.of(row:text(2), row:text(3))) })
    if not ok then return false, why end
  end
  return true, ""
end

--- The sources of `path` with the digest `fingerprinted` holds of each ("" where it holds none), by `order`.
local function held(db: Sqlite.Handle, path: string, order: string, modules_only?: boolean): {Sqlite.Row}?, string
  local only = if modules_only == true then " AND " .. AnalysisSchema.not_declaration("i.kind") else "" end
  if cache(db) then
    return Sqlite.text_rows(db,
      "SELECT i.source_hash, coalesce(f.fingerprint, '') FROM inputs i LEFT JOIN fingerprinted f " ..
        "ON f.source_hash = i.source_hash AND f.form = '" .. CodeFingerprint.version .. "' WHERE i.path = ?1" .. only .. " ORDER BY " ..
        order, { text(path) })
  end
  return Sqlite.text_rows(db, "SELECT i.source_hash, '' FROM inputs i WHERE i.path = ?1" .. only .. " ORDER BY " .. order, { text(path) })
end

--- The digest of the source of `hash`, made of it where `fingerprinted` has none, and kept if the database can be written.
local function made(db: Sqlite.Handle, path: string, hash: string, given: string): string?, string
  if given ~= "" then return given, "" end
  local rows, trouble = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE source_hash = ?1 LIMIT 1", { text(hash) })
  if rows == nil then return nil, trouble end
  local row = rows[1]
  if row == nil then return nil, "no source " .. hash .. " in the tree" end
  local digest = CodeFingerprint.of(row:text(1), path)
  local _, _ = Sqlite.run(db, "INSERT OR IGNORE INTO fingerprinted (source_hash, form, fingerprint) VALUES (?1, ?2, ?3)",
    { text(hash), text(CodeFingerprint.version), text(digest) })
  return digest, ""
end

function Fingerprints.staged(db: Sqlite.Handle, path: string, modules_only?: boolean): string?, string
  local rows, trouble = held(db, path, AnalysisSchema.declaration("i.kind") .. " DESC, i.source_hash", modules_only)
  if rows == nil then return nil, trouble end
  local first = rows[1]
  if first == nil then return nil, "" end
  return made(db, path, first:text(1), first:text(2))
end

--- One source of a path, for ordering.
local record Line
  path: string
  hash: string
  line: string
end

function Fingerprints.staged_lines(db: Sqlite.Handle, paths: {string}): {string}?, string
  local out: mut {Line} = {}
  for _, path in ipairs(paths) do
    local rows, trouble = held(db, path, "i.source_hash")
    if rows == nil then return nil, trouble end
    for _, row in ipairs(rows) do
      local digest, why = made(db, path, row:text(1), row:text(2))
      if digest == nil then return nil, why end
      out[#out + 1] = { path = path, hash = row:text(1), line = path .. " " .. digest }
    end
  end
  table.sort(out, function(a: Line, b: Line): boolean
    if a.path ~= b.path then return a.path < b.path end
    return a.hash < b.hash
  end)
  local lines: mut {string} = {}
  for _, one in ipairs(out) do lines[#lines + 1] = one.line end
  return lines, ""
end

return Fingerprints
