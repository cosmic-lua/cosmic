--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction by queries
--- over rows the build already holds -- this run's plan joined to the inputs
--- and compiles it names, the
--- declarations a checker needs to build a tree against this one, the
--- time zones the working database holds (cosmic's own tree's only) --
--- and produced by `VACUUM INTO`, so a second build of the same tree
--- is byte-identical.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local bom = require("build.bom")
local roots = require("build.roots")
local schema = require("build.schema")
local symbols = require("build.symbols")
local tree = require("build.tree")
local work = require("build.work")
local bind = require("build.bind")

local record writer
end

local text = bind.text

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
  "bytecode, tests) " ..
  "SELECT i.path, i.file, i.kind, CAST(i.source_hash AS BLOB), " ..
  "CAST(p.key AS BLOB), deflate(i.source), c.bytecode, " ..
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

--- The documented symbols (`build.analyzer.DocEntry`) found while parsing
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

--- The uses (`build.analyzer.Reference`) found: each
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
--- on a `Zip.Writer` is a use of `Writer.add_file` in `cosmic.zip`.
local insert_typed_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN typed_refs r ON r.key = p.key " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The worked examples (`build.analyzer.ExampleEntry`) found: a
--- `<module>_example.tl`'s own `function Example.<name>()`, shipped
--- against the module its file name pairs with, which is a planned
--- module or a declaration, as `cosmic.sys` is, but never a test or
--- another example. The name less `_example` pairs with the longest
--- such module it is or starts with followed by `_`, so a module's examples can be split by topic into files of their
--- own: `cosmic/json_yaml_example.tl` pairs with `cosmic.json` beside
--- `cosmic/json_example.tl` -- or with `cosmic.json_yaml`, were there
--- one -- and `cosmic/jsonx_example.tl` with neither. Nothing here
--- decides which symbol an example is FOR.
--- `build.docs` answers that at read time, by matching an example's
--- own text and source against a symbol's name through
--- `examples_fts`: an example calls the real function it demonstrates,
--- so the symbol's own name is already in its code, and a query never
--- needs `<name>` to encode an association a build-time join would
--- only have to guess at anyway once more than one example can be FOR
--- one symbol. `OR IGNORE` guards `examples`'s `UNIQUE (file, name)`
--- against a literal duplicate declaration; `<name>` is otherwise free
--- -- there is no convention left for it to hold to, and two topics'
--- files may each use one. `k` and `c` are materialized once, since
--- `inputs` is an unindexed view each example's lookup would scan again.
local insert_examples =
  "WITH k AS MATERIALIZED (SELECT path, kind, file, source_hash FROM inputs " ..
  "WHERE path IN (SELECT path FROM plan) OR kind = 'decl'), " ..
  "c(path) AS MATERIALIZED (SELECT DISTINCT path FROM k " ..
  "WHERE kind NOT IN ('test', 'example')) " ..
  "INSERT OR IGNORE INTO out.examples (module, name, text, file, line, " ..
  "source) " ..
  "SELECT x.module, e.name, e.text, x.file, e.line, e.source " ..
  "FROM (SELECT s.file, s.source_hash, " ..
  "(SELECT c.path FROM c WHERE c.path = s.stem " ..
  "OR substr(s.stem, 1, length(c.path) + 1) = c.path || '_' " ..
  "ORDER BY length(c.path) DESC LIMIT 1) AS module " ..
  "FROM (SELECT file, source_hash, " ..
  "substr(path, 1, length(path) - length('_example')) AS stem " ..
  "FROM k WHERE kind = 'example') s) x " ..
  "JOIN examples e ON e.source_hash = x.source_hash " ..
  "WHERE x.module IS NOT NULL " ..
  "ORDER BY x.module, x.file, e.line"

--- The catalog entries (`build.analyzer.CatalogEntry`) found while parsing
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
--- identities, the zones it carries, the main module, and the identity
--- of the writer writing it (`running`), as one hash. The last is
--- the writer itself: a stale tool rebuilding itself writes this file
--- with its own code before the new tool re-enters, and the tree's
--- fingerprints alone would let the new tool take that file for its
--- own projection when its writer is not the same code. A writer that is
--- the same code signs the same bytes, so a self-rebuild whose writer did
--- not move lands on the tool a boot writes.
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
  "FROM meta WHERE key IN " .. metadata .. "), '') || char(10) || " ..
  "coalesce((SELECT group_concat(name || ' ' || lower(hex(sha256(data))), " ..
  "char(10) ORDER BY name) FROM zoneinfo), '') || char(10) || ?1 || " ..
  "char(10) || ?2 || char(10) || ?3)))"
end

--- The signature of `result`'s projection as the writer whose identity
--- is `binary` would write it -- see `signature_sql`.
function writer.signature(handle: work.Handle, result: importer.Result,
                          binary: string): string | nil, string
  local signed, trouble = Sqlite.text_rows(handle.db, signature_sql(),
    { text(result.main or ""), text("portable-v1"), text(binary) })
  if signed == nil then
    return nil, trouble
  end
  return signed[1][1]
end

--- Fills the attached `out` schema and vacuums it into `path`, signed
--- `signature` by the writer whose identity is `by`, and naming the
--- compiler whose identity keyed its modules (`result.tool`) as
--- `compiled_by`.
local function project(handle: work.Handle, path: string,
                       result: importer.Result, signature: string,
                       by: string): boolean, string
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
      "INSERT INTO out.decls (path, source) SELECT path, deflate(source) FROM inputs " ..
      "WHERE kind = 'decl' ORDER BY path"
    statements[#statements + 1] =
      "INSERT INTO out.zoneinfo (name, data) SELECT name, data FROM zoneinfo " ..
      "ORDER BY name"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local metadata = "('boot_hash', 'image_hash', 'compiler', 'runtime_basis', 'writer')"
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
    -- cosmic's own tree describes the binary it builds: its bill of
    -- materials (`build.bom`), read from the pins and records beside the
    -- code, and the CA roots it trusts (`build.roots`). A change to
    -- either comes with a pin's, a tool file, so `boot_hash`, which the
    -- signature covers, moves when one does. A project's tables stay
    -- empty.
    local own, own_trouble = tree.is_own(handle.root)
    if own == nil then
      return false, own_trouble
    end
    if own then
      local filled, fill_trouble = bom.fill(db, handle.root, "out.")
      if not filled then
        return false, fill_trouble
      end
      local trusted, trust_trouble = roots.fill(db, handle.root, "out.")
      if not trusted then
        return false, trust_trouble
      end
    end
    local carried_main, main_trouble = Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('main', ?1)",
      { text(result.main or "") })
    if not carried_main then
      return false, main_trouble
    end
    return Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('projected', ?1), " ..
      "('written_by', ?2), ('compiled_by', ?3)",
      { text(signature), text(by), text(result.tool) })
  end)
  if not made then
    return false, refused
  end

  local _, _ = Fs.remove(path .. ".building")
  return Sqlite.run(db, "VACUUM out INTO ?1", { text(path .. ".building") })
end

--- The identity of the writer this process runs, which signs what it
--- writes (`signature_sql`) and is recorded beside it as `written_by`.
--- A boot, which carries no database, and a tool fresh against the tree
--- in `handle` both run the tree's own code, so it is the tree's
--- (`identities.writer`). Any other binary names the `writer` it
--- carries, or, from before binaries carried one, its whole boot hash,
--- so a tool it rebuilt is never taken for one the tree's writer wrote
--- (`build.reboot`).
local function running(handle: work.Handle,
                       identities: work.Identities): string | nil, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil then
    return identities.writer
  end
  local tree_hash, trouble = work.recorded_boot_hash(handle)
  if tree_hash == nil and trouble ~= "" then
    return nil, trouble
  end
  if tree_hash == boot_hash then
    return identities.writer
  end
  return Store.meta("writer") or ("boot " .. boot_hash)
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
  local identities, identity_trouble = work.record_identities(handle)
  if identities == nil then
    return false, identity_trouble
  end
  local by, by_trouble = running(handle, identities)
  if by == nil then
    return false, by_trouble
  end
  local signature, sign_trouble = writer.signature(handle, result, by)
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
  local projected, trouble = project(handle, out, result, signature, by)
  local _, _ = db:exec("DETACH out")
  if not projected then
    return false, trouble
  end
  return Fs.rename(out .. ".building", out)
end

--- The modules a projection holds that the tool built from it does
--- not carry: its tests and examples. One a carried module requires is
--- carried anyway, since the tool could not load without it; a
--- module's kind is only its file name. Each statement below names
--- `dropped` from this, so a row is left out only for being about one.
local dropped_modules <const> =
  "WITH RECURSIVE carried(path) AS (" ..
  "SELECT path FROM whole.modules WHERE kind NOT IN ('test', 'example') " ..
  "UNION SELECT i.requires FROM whole.imports i " ..
  "JOIN carried c ON i.path = c.path), " ..
  "dropped(path) AS (SELECT path FROM whole.modules " ..
  "EXCEPT SELECT path FROM carried) "

--- Copies a projection's rows into a fresh schema of the same shape --
--- both come from `build.schema`, so `*` names the same columns in the
--- same order -- leaving out each row `dropped_modules` names. A
--- rowid table's `id` is assigned again, in the projection's own order.
local carry: {string} = {
  "INSERT INTO main.meta SELECT * FROM whole.meta ORDER BY key",
  dropped_modules .. "INSERT INTO main.modules SELECT * FROM whole.modules " ..
    "WHERE path NOT IN dropped ORDER BY path",
  dropped_modules .. "INSERT INTO main.imports SELECT * FROM whole.imports " ..
    "WHERE path NOT IN dropped AND requires NOT IN dropped " ..
    "ORDER BY path, requires",
  "INSERT INTO main.decls SELECT * FROM whole.decls ORDER BY path",
  "INSERT INTO main.payload SELECT * FROM whole.payload ORDER BY path",
  "INSERT INTO main.zoneinfo (name, data) SELECT name, data FROM whole.zoneinfo " ..
    "ORDER BY name",
  "INSERT INTO main.components SELECT * FROM whole.components ORDER BY name",
  "INSERT INTO main.notices SELECT * FROM whole.notices ORDER BY component, ordinal",
  "INSERT INTO main.ca_roots SELECT * FROM whole.ca_roots ORDER BY sha256",
  -- Outside cosmic's own tree, `cosmic docs`, `cosmic uses` and a
  -- compile's hints read the tool's rows only for the public standard
  -- library (`symbols.public_only`), and inside it they read the tree's
  -- own projection first (and find nothing for `build.*` until a build
  -- has written one): so a doc row about any other module is
  -- carried only for the catalog, whose guidance is the doc comment of
  -- the function an error came from (core/main.c, `build.embed`).
  dropped_modules .. "INSERT INTO main.docs (module, symbol, source_symbol, " ..
    "exported, kind, signature, text, file, line) SELECT module, symbol, " ..
    "source_symbol, exported, kind, signature, text, file, line " ..
    "FROM whole.docs d WHERE module NOT IN dropped AND (" ..
    symbols.public_only("d.module", true) ..
    " OR EXISTS (SELECT 1 FROM whole.catalog c WHERE c.module = d.module " ..
    "AND c.symbol = d.source_symbol)) ORDER BY id",
  dropped_modules .. "INSERT INTO main.uses SELECT * FROM whole.uses u " ..
    "WHERE module NOT IN dropped AND from_module NOT IN dropped AND " ..
    symbols.public_only("u.module", true) .. " AND " ..
    symbols.public_only("u.from_module", true) ..
    " ORDER BY module, symbol, from_module, line",
  dropped_modules .. "INSERT INTO main.examples (module, name, text, file, " ..
    "line, source) SELECT module, name, text, file, line, source " ..
    "FROM whole.examples e WHERE module NOT IN dropped AND " ..
    symbols.public_only("e.module", true) .. " ORDER BY id",
  dropped_modules .. "INSERT INTO main.catalog (kind, module, symbol, " ..
    "message, text, file, line) SELECT kind, module, symbol, message, " ..
    "text, file, line FROM whole.catalog WHERE module NOT IN dropped " ..
    "ORDER BY id",
}

--- Writes at `out` the database the tool built from the projection at
--- `whole` carries: the projection without the tree's own tests and
--- examples, which `cosmic test` loads from the projection itself and a
--- release has no use for, and with only the public standard library's
--- docs, uses and examples, the only ones a reader asks the tool for
--- (see `carry`). Like the projection, it is a function of
--- its input alone: a fresh schema, filled in one order, vacuumed.
--- Its `meta` is the projection's, `projected` included: that signs the
--- projection it came from, not these rows.
function writer.carried(whole: string, out: string): boolean, string
  local function fill(db: Sqlite.Handle): boolean, string
    local statements: {string} = {}
    for _, statement in ipairs(schema.settings("")) do
      statements[#statements + 1] = statement
    end
    for _, statement in ipairs(schema.create("")) do
      statements[#statements + 1] = statement
    end
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local attached, attach_trouble = Sqlite.run(db,
      "ATTACH DATABASE ?1 AS whole", { text(whole) })
    if not attached then
      return false, attach_trouble
    end
    local made, refused = Sqlite.transact(db, function(): boolean, string
      for _, statement in ipairs(carry) do
        local ok, failure = db:exec(statement)
        if not ok then
          return false, failure
        end
      end
      for _, statement in ipairs(rebuild_fts) do
        local ok, failure = db:exec((statement:gsub("out%.", "main.")))
        if not ok then
          return false, failure
        end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH whole")
    if not made then
      return false, refused
    end
    local _, _ = Fs.remove(out .. ".building")
    local vacuumed, vacuum_trouble = Sqlite.run(db, "VACUUM INTO ?1",
      { text(out .. ".building") })
    if not vacuumed then
      return false, vacuum_trouble
    end
    return Fs.rename(out .. ".building", out)
  end
  local db, open_trouble = Sqlite.memory()
  if db == nil then
    return false, open_trouble
  end
  local ok, trouble = fill(db)
  local _, _ = db:close()
  if not ok then
    return false, trouble
  end
  return true, ""
end

return writer
