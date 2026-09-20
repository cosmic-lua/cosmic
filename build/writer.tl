--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction by queries
--- over rows the build already holds -- the images a boot put there,
--- this run's plan joined to the inputs and compiles it names, the
--- declarations a checker needs to build a tree against this one --
--- and produced by `VACUUM INTO`, so a second build of the same tree
--- is byte-identical.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")

local record writer
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function integer(value: integer): Sqlite.Value
  return { integer = value }
end

--- The shipped modules: this run's plan joined to the inputs it named
--- and the compiles it found or made, with a test or example module's
--- own names alongside.
local insert_modules =
  "INSERT INTO out.modules (path, file, kind, source_hash, key, source, " ..
  "lua, bytecode, tests) " ..
  "SELECT i.path, i.file, i.kind, CAST(i.source_hash AS BLOB), " ..
  "CAST(p.key AS BLOB), i.source, c.lua, c.bytecode, " ..
  "CASE WHEN i.kind = 'test' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM tests t " ..
  "WHERE t.source_hash = i.source_hash), '') " ..
  "WHEN i.kind = 'example' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM examples e " ..
  "WHERE e.source_hash = i.source_hash), '') ELSE '' END " ..
  "FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN compiled c ON c.key = p.key ORDER BY p.path"

--- The import edges among shipped modules: what each planned module
--- requires, kept only where the name is itself a planned module.
local insert_imports =
  "INSERT OR IGNORE INTO out.imports (path, requires) " ..
  "SELECT p.path, r.name FROM plan p " ..
  "JOIN inputs i ON i.path = p.path " ..
  "JOIN requires r ON r.source_hash = i.source_hash " ..
  "WHERE r.name IN (SELECT path FROM plan) ORDER BY p.path, r.ordinal"

--- The documented symbols `build.positions.docs_of` found while parsing
--- each planned module, in module order and then source order. `id` is
--- left for SQLite to assign in that order, so it is the same on every
--- build of the same tree.
local insert_docs =
  "INSERT INTO out.docs (module, symbol, source_symbol, exported, kind, " ..
  "signature, text, file, line) " ..
  "SELECT p.path, d.symbol, d.source_symbol, d.exported, d.kind, " ..
  "d.signature, d.text, i.file, d.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN docs d ON d.source_hash = i.source_hash ORDER BY p.path, d.ordinal"

--- The uses `build.positions.references_of` found: each
--- `alias.member` resolved against the module the alias names, as the
--- canonical member path. Targets need not be in this build plan: bundled and
--- external definitions are selected from the effective database view later.
local insert_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN refs r ON r.source_hash = i.source_hash " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The worked examples `build.positions.examples_of` found: a
--- `<module>_example.tl`'s own `function Example.<name>()`, shipped
--- against the module its file name pairs with (the `_example` suffix
--- stripped) -- nothing here decides which symbol an example is FOR.
--- `build.docs` answers that at read time, by matching an example's
--- own text and source against a symbol's name through
--- `examples_fts`: an example calls the real function it demonstrates,
--- so the symbol's own name is already in its code, and a query never
--- needs `<name>` to encode an association a build-time join would
--- only have to guess at anyway once more than one example can be FOR
--- one symbol. `OR IGNORE` guards `examples`'s `UNIQUE (module, name)`
--- against a literal duplicate declaration; `<name>` is otherwise free
--- -- there is no convention left for it to hold to.
local insert_examples =
  "INSERT OR IGNORE INTO out.examples (module, name, text, file, line, " ..
  "source) " ..
  "SELECT t.path, e.name, e.text, i.file, e.line, e.source " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind = 'example' " ..
  "JOIN examples e ON e.source_hash = i.source_hash " ..
  "JOIN inputs t ON t.path = substr(p.path, 1, length(p.path) - length('_example')) " ..
  "WHERE t.path IN (SELECT path FROM plan) " ..
  "ORDER BY t.path, e.line"

--- The catalog entries `build.positions.catalog_of` found while parsing
--- each planned module: every literal `return nil, ...` under a
--- top-level function. The guidance a match prints is that function's
--- own documentation, joined from `docs` at lookup, so `text` is left
--- NULL here. `id` is left for SQLite to assign, in this SELECT's own
--- deterministic order -- the hand-authored rows below claim the low
--- ids first, so this always continues after them the same way on
--- every build.
local insert_catalog_extracted =
  "INSERT INTO out.catalog (kind, module, symbol, message, text, file, " ..
  "line) SELECT 'error', p.path, c.symbol, c.message, NULL, " ..
  "i.file, c.line FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN catalog c ON c.source_hash = i.source_hash " ..
  "ORDER BY p.path, c.ordinal"

--- One hand-authored catalog row: a `strerror()` message the catalog
--- matches on, the guidance already known for it, and where it comes
--- from.
local record CatalogSeedRow
  symbol: string
  message: string
  hint: string
  file: string
  line: integer
end

--- Hand-authored catalog rows, seeded ahead of the extracted ones:
--- guidance for the handful of `strerror()` messages cosmic's own
--- syscalls can plausibly raise -- `core/fail.h`'s `cosmic_fail`
--- returns `nil, strerror(errno), errno`, and a stdlib wrapper like
--- `cosmic/fs.tl`'s `path .. ": " .. trouble` stitches that literal
--- text straight into what a program sees, so it is exactly as
--- matchable as an authored message. Every row here has a message: the
--- catalog is matched on message text alone, so a row without one
--- could never be found. `core/surface.c`'s replacement hints for the
--- globals it removes are raised by that C code itself, not looked up.
local catalog_seed: {CatalogSeedRow} = {
  { symbol = "ENOENT",
    message = "No such file or directory",
    hint = "the path does not exist -- check it is spelled right, and " ..
           "that every parent directory already exists; cosmic.fs " ..
           "creates no parent directories on its own",
    file = "core/fail.h", line = 0 },
  { symbol = "EACCES",
    message = "Permission denied",
    hint = "the process does not have permission for this path -- " ..
           "check its ownership and mode, cosmic.fs.stat's own fields",
    file = "core/fail.h", line = 0 },
  { symbol = "EEXIST",
    message = "File exists",
    hint = "something is already at this path -- cosmic.fs.remove it " ..
           "first, or use a call that tolerates an existing target",
    file = "core/fail.h", line = 0 },
  { symbol = "ENOTDIR",
    message = "Not a directory",
    hint = "a path segment that should be a directory is a plain file " ..
           "instead -- check every component up to the last",
    file = "core/fail.h", line = 0 },
  { symbol = "EISDIR",
    message = "Is a directory",
    hint = "the path names a directory where a file was expected -- " ..
           "reading or writing needs a file path, not a directory",
    file = "core/fail.h", line = 0 },
  { symbol = "ENOSPC",
    message = "No space left on device",
    hint = "the filesystem holding this path is full",
    file = "core/fail.h", line = 0 },
  { symbol = "EMFILE",
    message = "Too many open files",
    hint = "this process already has too many files open -- close ones " ..
           "no longer needed before opening more",
    file = "core/fail.h", line = 0 },
}

--- Rebuilds each FTS5 index from its content table's current rows: the
--- documented way to bulk-load an external-content FTS5 table without
--- keeping the two in sync through triggers a read-only, write-once
--- database has no use for.
local rebuild_fts: {string} = {
  "INSERT INTO out.docs_fts(docs_fts) VALUES ('rebuild')",
  "INSERT INTO out.catalog_fts(catalog_fts) VALUES ('rebuild')",
  "INSERT INTO out.examples_fts(examples_fts) VALUES ('rebuild')",
}

--- What the shipped database is a function of: this run's plan with
--- each module's file, the declarations, the images, the fingerprints,
--- identities and host it carries, and the main module, as one hash.
--- When it matches the one the last write left in `meta` and the file
--- is still there, the file already is the projection of these rows,
--- and nothing is written. The catalog, docs, examples and references
--- add nothing here: an extracted row changes only with the source it
--- was parsed from, which moves that module's key, and the seed rows
--- change only with this module, which moves `boot_hash`.
local signature_sql =
  "SELECT lower(hex(sha256(" ..
  "coalesce((SELECT group_concat(p.path || ' ' || p.key || ' ' || i.file, " ..
  "char(10) ORDER BY p.path) FROM plan p JOIN inputs i ON i.path = p.path " ..
  "WHERE i.kind <> 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || source_hash, char(10) " ..
  "ORDER BY path) FROM inputs WHERE kind = 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(target || ' ' || hex(sha256), char(10) " ..
  "ORDER BY target) FROM images), '') || char(10) || " ..
  "coalesce((SELECT group_concat(key || ' ' || value, char(10) ORDER BY key) " ..
  "FROM meta WHERE key IN ('boot_hash', 'image_hash', 'host', 'host_image', " ..
  "'compiler', 'runtime')), '') || char(10) || ?1)))"

--- Fills the attached `out` schema and vacuums it into `path`.
local function project(handle: work.Handle, path: string,
                       result: importer.Result): boolean, string
  local db = handle.db
  for _, statement in ipairs(schema.settings("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end

  local made, refused = Sqlite.transact(db, function(): boolean, string
    local statements: {string} = {}
    for _, statement in ipairs(schema.create("out.")) do
      statements[#statements + 1] = statement
    end
    statements[#statements + 1] = insert_modules
    statements[#statements + 1] = insert_imports
    statements[#statements + 1] =
      "INSERT INTO out.decls (path, source) SELECT path, source FROM inputs " ..
      "WHERE kind = 'decl' ORDER BY path"
    statements[#statements + 1] =
      "INSERT INTO out.images (target, sha256, size, encoding, data) " ..
      "SELECT target, sha256, size, encoding, data FROM images ORDER BY target"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local carried, meta_trouble = db:exec(
      "INSERT INTO out.meta (key, value) SELECT key, value FROM meta " ..
      "WHERE key IN ('boot_hash', 'image_hash', 'host', 'host_image', " ..
      "'compiler', 'runtime')")
    if not carried then
      return false, meta_trouble
    end
    for id, row in ipairs(catalog_seed) do
      local ok, failure = Sqlite.run(db,
        "INSERT INTO out.catalog (id, kind, module, symbol, message, " ..
        "text, file, line) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        { integer(id), text("error"), text("(errno)"), text(row.symbol),
          text(row.message), text(row.hint), text(row.file),
          integer(row.line) })
      if not ok then
        return false, failure
      end
    end
    for _, statement in ipairs({ insert_catalog_extracted, insert_docs,
                                 insert_uses, insert_examples }) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    for _, statement in ipairs(rebuild_fts) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    return Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('main', ?1)",
      { text(result.main or "") })
  end)
  if not made then
    return false, refused
  end

  Fs.remove(path .. ".building")
  return Sqlite.run(db, "VACUUM out INTO ?1", { text(path .. ".building") })
end

--- Writes an already-compiled result into a fresh database and leaves
--- it at `out`, unless the file there already is that projection. This
--- ends the run's transaction first: SQLite attaches and vacuums
--- outside one only.
function writer.write_result(handle: work.Handle, out: string,
                             result: importer.Result): boolean, string
  local db = handle.db
  local committed, commit_trouble = work.commit(handle)
  if not committed then
    return false, commit_trouble
  end
  local identities, identity_trouble = work.identities(handle)
  if identities == nil then
    return false, identity_trouble
  end
  local signed, sign_trouble = Sqlite.text_rows(db, signature_sql,
    { text(result.main or "") })
  if signed == nil then
    return false, sign_trouble
  end
  local signature = signed[1][1]
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'projected'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1][1] == signature and Fs.exists(out) then
    return true, ""
  end

  local attached, attach_trouble = db:exec("ATTACH ':memory:' AS out")
  if not attached then
    return false, attach_trouble
  end
  local projected, trouble = project(handle, out, result)
  db:exec("DETACH out")
  if not projected then
    return false, trouble
  end
  local renamed, rename_trouble = Fs.rename(out .. ".building", out)
  if not renamed then
    return false, rename_trouble
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('projected', ?1)",
    { text(signature) })
end

return writer
