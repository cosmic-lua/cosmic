--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction by queries
--- over rows the build already holds -- this run's plan joined to the inputs
--- and compiles it names, the
--- declarations a checker needs to build a tree against this one --
--- and produced by `VACUUM INTO`, so a second build of the same tree
--- is byte-identical.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")

local record writer
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- The signature already recorded inside the projection at `path`, or
--- `""` when there is none to trust: no file there, a file that is not
--- a database, or a database with no `projected` row. Read straight
--- from the file itself rather than from any record kept elsewhere, so
--- a file that drifted from that other record is never mistaken for
--- what it describes.
local function projected_signature(path: string): string
  local handle, _ = Sqlite.open(path, false)
  if handle == nil then
    return ""
  end
  local rows, _ = Sqlite.text_rows(handle,
    "SELECT value FROM meta WHERE key = 'projected'")
  local _, _ = handle:close()
  if rows == nil or #rows == 0 then
    return ""
  end
  return rows[1][1]
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
--- each planned module and each declaration -- `cosmic.sys`'s only
--- source is the C header it is generated from -- in module order and
--- then source order. Which of them a reader sees is `build.docs`'s
--- to decide: it answers a project only for the public standard library. `id` is left for SQLite to assign in
--- that order, so it is the same on every build of the same tree.
local insert_docs =
  "INSERT INTO out.docs (module, symbol, source_symbol, exported, kind, " ..
  "signature, text, file, line) " ..
  "SELECT m.path, d.symbol, d.source_symbol, d.exported, d.kind, " ..
  "d.signature, d.text, i.file, d.line " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs " ..
  "WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path " ..
  "JOIN docs d ON d.source_hash = i.source_hash ORDER BY m.path, d.ordinal"

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

--- The record-field uses `build.receivers` found while each planned
--- module was compiled, kept under the compile's key: `w:add_file(...)`
--- on a `Zip.ZipWriter` is a use of `ZipWriter.add_file` in `cosmic.zip`.
local insert_typed_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN typed_refs r ON r.key = p.key " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The worked examples `build.positions.examples_of` found: a
--- `<module>_example.tl`'s own `function Example.<name>()`, shipped
--- against the module its file name pairs with (the `_example` suffix
--- stripped), which is a planned module or a declaration, as
--- `cosmic.sys` is -- nothing here decides which symbol an example is FOR.
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
  "WHERE t.path IN (SELECT path FROM plan) OR t.kind = 'decl' " ..
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
--- each module's file, the declarations, fingerprints, host-independent
--- identities, the main module, and the running binary's own boot hash,
--- as one hash. The last is the writer itself: a stale tool rebuilding
--- itself writes this file with its own, older code before the new tool
--- re-enters, and the tree's fingerprints alone would let the new tool
--- take that file for its own projection.
--- When it matches the one the last write left in `meta` and the file
--- is still there, the file already is the projection of these rows,
--- and nothing is written. The catalog, docs, examples and references
--- add nothing here: an extracted row changes only with the source it
--- was parsed from, which moves that module's key. A record-field use
--- rides on a compile instead, which a change to the code finding it
--- redoes under the same key, so that code's identity (`receivers`
--- in `meta`) is signed too.
local function signature_sql(): string
  local metadata = "('boot_hash', 'image_hash', 'compiler', 'runtime_basis', 'receivers')"
  return "SELECT lower(hex(sha256(" ..
  "coalesce((SELECT group_concat(p.path || ' ' || p.key || ' ' || i.file, " ..
  "char(10) ORDER BY p.path) FROM plan p JOIN inputs i ON i.path = p.path " ..
  "WHERE i.kind <> 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || source_hash, char(10) " ..
  "ORDER BY path) FROM inputs WHERE kind = 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(key || ' ' || value, char(10) ORDER BY key) " ..
  "FROM meta WHERE key IN " .. metadata .. "), '') || char(10) || ?1 || " ..
  "char(10) || ?2 || char(10) || ?3)))"
end

--- The signature of `result`'s projection as the binary whose boot
--- hash is `binary` would write it -- see `signature_sql`.
function writer.signature(handle: work.Handle, result: importer.Result,
                          binary: string): string | nil, string
  local signed, trouble = Sqlite.text_rows(handle.db, signature_sql(),
    { text(result.main or ""), text("portable-v1"), text(binary) })
  if signed == nil then
    return nil, trouble
  end
  return signed[1][1]
end

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
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local metadata = "('boot_hash', 'image_hash', 'compiler', 'runtime_basis')"
    local carried, meta_trouble = db:exec(
      "INSERT INTO out.meta (key, value) SELECT key, value FROM meta " ..
      "WHERE key IN " .. metadata)
    if not carried then
      return false, meta_trouble
    end
    for _, statement in ipairs({ insert_catalog_extracted, insert_docs,
                                 insert_uses, insert_typed_uses, insert_examples }) do
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
    local carried_main, main_trouble = Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('main', ?1)",
      { text(result.main or "") })
    if not carried_main then
      return false, main_trouble
    end
    local signature, sign_trouble = writer.signature(handle, result, Store.meta("boot_hash") or "")
    if signature == nil then
      return false, sign_trouble
    end
    return Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('projected', ?1)",
      { text(signature) })
  end)
  if not made then
    return false, refused
  end

  local _, _ = Fs.remove(path .. ".building")
  return Sqlite.run(db, "VACUUM out INTO ?1", { text(path .. ".building") })
end

--- Writes an already-compiled result into a fresh host-independent database
--- and leaves it at `out`, unless the file there already is that projection.
--- This ends the run's transaction first: SQLite attaches and vacuums outside
--- one only.
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
  local signature, sign_trouble = writer.signature(handle, result, Store.meta("boot_hash") or "")
  if signature == nil then
    return false, sign_trouble
  end
  if projected_signature(out) == signature then
    return true, ""
  end

  local attached, attach_trouble = db:exec("ATTACH ':memory:' AS out")
  if not attached then
    return false, attach_trouble
  end
  local projected, trouble = project(handle, out, result)
  local _, _ = db:exec("DETACH out")
  if not projected then
    return false, trouble
  end
  return Fs.rename(out .. ".building", out)
end

return writer
