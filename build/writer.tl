--- Writing a compiled tree out as the shipped database.
---
--- `cosmic.db` is a projection of the working database: a fresh schema
--- attached in memory and filled in one transaction by queries over rows
--- the build already holds, then written by `VACUUM INTO`, so a second
--- build of the same tree is byte-identical. The rows are this run's plan
--- joined to the inputs and compiles it names, the declarations a checker
--- needs to build a tree against this one, the time zones the
--- working database holds (cosmic's own tree's only) and a project's static
--- assets.
---
--- The store of a test module's import closure a sandboxed worker is
--- given in the projection's place is derived from the projection by
--- [`build.closure_store`], apart from this module, so an edit here that
--- leaves every store's bytes alone moves no store's address.

local build_paths = require("build.paths")
local CheckerDeclarations = require("build.checker_declarations")
local clock = require("build.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Mime = require("cosmic.mime")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local identity = require("build.identity")
local type importer = require("build.importer")
local bom = require("build.bom")
local link_index = require("build.link_index")
local onecrl = require("build.onecrl")
local roots = require("build.roots")
local schema = require("build.schema")
local symbols = require("build.symbols")
local tree = require("build.tree")
local work = require("build.work")
local bind = require("build.bind")
local rebuild_lock = require("build.rebuild_lock")

local record writer
end

local text = bind.text
local blob = bind.blob

--- `yes` where `flag` holds, else `no`.
local function choose(flag: boolean, yes: string, no: string): string
  if flag then
    return yes
  end
  return no
end

--- The signature recorded inside the projection at `path`, or `""` when
--- there is none to trust: no file there, a file that is not a database,
--- or a database with no `projected` row. It is read from the file
--- itself, not from a record kept elsewhere, so a file that drifted from
--- that record is never mistaken for what it describes.
local function projected_signature(path: string): string
  local handle, _ = Sqlite.open(path)
  if handle == nil then
    return ""
  end
  local rows, _ = Sqlite.text_rows(handle,
    "SELECT value FROM meta WHERE key = 'projected'")
  local _, _ = handle:close()
  if rows == nil or #rows == 0 then
    return ""
  end
  return rows[1]:text(1)
end

--- What names the core whose `deflate` made a row of `deflated`: its image
--- ([`build.identity`]'s `image_hash`), which holds the zlib it links, so a
--- core whose compressor moved never serves another's bytes.
local deflating_core <const> =
  "coalesce((SELECT lower(hex(value)) FROM meta WHERE key = 'image_hash'), '')"

--- Fills `deflated` with the compressed text of each source a projection
--- carries that it does not yet hold, and drops what no input names, or
--- another core compressed. A source is named by its SHA-256, so a row
--- is never stale: an edited file is another source and is compressed
--- once, where a projection used to compress all of them, some 0.6 s of
--- every write for cosmic's own tree.
local fill_deflated <const> =
  "INSERT OR IGNORE INTO deflated (source_hash, core, data) " ..
  "SELECT i.source_hash, " .. deflating_core .. ", deflate(i.source) FROM inputs i " ..
  "WHERE (i.kind = 'decl' OR i.path IN (SELECT path FROM plan)) AND NOT EXISTS " ..
  "(SELECT 1 FROM deflated d WHERE d.source_hash = i.source_hash AND d.core = " ..
  deflating_core .. ") GROUP BY i.source_hash"

local prune_deflated <const> =
  "DELETE FROM deflated WHERE core <> " .. deflating_core ..
  " OR source_hash NOT IN (SELECT source_hash FROM inputs)"

--- The shipped modules: this run's plan joined to the inputs it named
--- of non-declaration kind and the compiles it found or made, with
--- a test or example module's own names alongside.
local insert_modules =
  "INSERT INTO out.modules (path, file, kind, source_hash, key, source, " ..
  "bytecode, tests) " ..
  "SELECT i.path, i.file, i.kind, CAST(i.source_hash AS BLOB), " ..
  "CAST(p.key AS BLOB), d.data, c.bytecode, " ..
  "CASE WHEN i.kind = 'test' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM tests t " ..
  "WHERE t.source_hash = i.source_hash), '') " ..
  "WHEN i.kind = 'example' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM examples e " ..
  "WHERE e.source_hash = i.source_hash), '') ELSE '' END " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN deflated d ON d.source_hash = i.source_hash AND d.core = " .. deflating_core .. " " ..
  "JOIN compiled c ON c.key = p.key ORDER BY p.path"

--- The import edges among shipped modules: what each planned module
--- requires, kept only where the name is itself a planned module.
local insert_imports =
  "INSERT OR IGNORE INTO out.imports (path, requires) " ..
  "SELECT p.path, r.name FROM plan p " ..
  "JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN requires r ON r.source_hash = i.source_hash " ..
  "WHERE r.name IN (SELECT path FROM plan) ORDER BY p.path, r.ordinal"

--- Every edge of the source the checker reads for a planned module or a
--- declaration ([`build.schema`]'s `decl_imports`): the declaration's
--- where there is one, as in [`insert_bound`], so the edges include those
--- to names the plan does not hold. Each path also has the row with the
--- empty name, so that a path with no edge is told from one the table
--- knows nothing of.
local insert_decl_imports =
  "INSERT OR IGNORE INTO out.decl_imports (path, requires) " ..
  "SELECT m.path, '' FROM (SELECT path FROM plan UNION SELECT path " ..
  "FROM inputs WHERE kind = 'decl') m " ..
  "UNION ALL " ..
  "SELECT m.path, r.name FROM (SELECT path FROM plan UNION SELECT path " ..
  "FROM inputs WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path " ..
  "AND (i.kind = 'decl' OR NOT EXISTS (SELECT 1 FROM inputs d " ..
  "WHERE d.path = i.path AND d.kind = 'decl')) " ..
  "JOIN requires r ON r.source_hash = i.source_hash " ..
  "ORDER BY 1, 2"

--- A paired declaration supplies the documented interface and its aliases,
--- just as it supplies the types a caller checks against. The implementation
--- alone supplies executable rows, import edges, uses and errors.
---
--- The names each planned module and each declaration binds to a
--- module ([`build.syntax_analyzer`]'s `Bound`), kept whatever the module they
--- name: a project's binds the standard library's.
local insert_bound =
  "INSERT OR IGNORE INTO out.bound (path, name, requires) " ..
  "SELECT m.path, b.name, b.module " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs " ..
  "WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path " ..
  "AND (i.kind = 'decl' OR NOT EXISTS (SELECT 1 FROM inputs d " ..
  "WHERE d.path = i.path AND d.kind = 'decl')) " ..
  "JOIN bound b ON b.source_hash = i.source_hash ORDER BY m.path, b.name"

--- The documented symbols ([`build.syntax_analyzer`]'s `DocEntry`) found while parsing
--- each planned module and each declaration ([`cosmic.sys`]'s only source
--- is the C header it is generated from), in module order and then
--- source order. Which of them a reader sees is [`build.docs`]'s to
--- decide: it answers a project only for the public standard library.
--- A declaration wins over a paired implementation, as the checker does.
--- `id` is left for SQLite to assign in that order, so it is the same on
--- every build of the same tree.
local insert_docs =
  "INSERT INTO out.docs (module, symbol, source_symbol, exported, kind, " ..
  "signature, text, file, line) " ..
  "SELECT m.path, d.symbol, d.source_symbol, d.exported, d.kind, " ..
  "d.signature, d.text, i.file, d.line " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs " ..
  "WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path " ..
  "AND (i.kind = 'decl' OR NOT EXISTS (SELECT 1 FROM inputs d " ..
  "WHERE d.path = i.path AND d.kind = 'decl')) " ..
  "JOIN docs d ON d.source_hash = i.source_hash ORDER BY m.path, d.ordinal"

--- The uses ([`build.syntax_analyzer`]'s `Reference`) found: each
--- `alias.member` resolved against the module the alias names, as the
--- canonical member path. Targets need not be in this build plan: bundled and
--- external definitions are selected from the effective database view later.
local insert_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN refs r ON r.source_hash = i.source_hash " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The record-field uses build.receivers found while each planned
--- module was compiled, kept under the compile's key: `w:add_file(...)`
--- on a [`Zip.Writer`] is a use of `Writer.add_file` in [`cosmic.zip`].
local insert_typed_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN typed_refs r ON r.key = p.key " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The worked examples ([`build.syntax_analyzer`]'s `ExampleEntry`) found: a
--- `<module>_example.tl`'s own `function Example.<name>()`, shipped
--- against the module its file name pairs with. That is a planned module
--- or a declaration (as [`cosmic.sys`] is), never a test or another
--- example.
---
--- The file name less `_example` pairs with the longest such module it
--- equals or starts with followed by `_`, so a module's examples can be
--- split by topic: `cosmic/json_yaml_example.tl` pairs with `cosmic.json`
--- beside [`cosmic/json_example.tl`] (or with `cosmic.json_yaml`, were
--- there one), and `cosmic/jsonx_example.tl` with neither.
---
--- Nothing here decides which symbol an example is for. [`build.docs`]
--- decides at read time, by matching an example's text and source
--- against a symbol's name through `examples_fts`: an example calls the
--- real function it demonstrates, so the symbol's name is already in its
--- code. `<name>` is therefore free, and two topics' files may each use
--- one; `OR IGNORE` guards `examples`'s `UNIQUE (file, name)` against a
--- literal duplicate declaration. `k` and `c` are materialized once,
--- since `inputs` is an unindexed view that each example's lookup would
--- scan again.
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

--- The stub (build.stub) of each planned `cosmic.*` module, in
--- cosmic's own tree, where the planned modules are its standard library;
--- a project's `cosmic.*` module, were it to have one, is no binary's.
--- [`build.pipeline`]'s `generate` has held each to its source's type.
local insert_stubs =
  "INSERT INTO out.stubs (path, source) " ..
  "SELECT p.path, deflate(s.text) FROM plan p " ..
  "JOIN inputs i ON i.path = p.path AND i.kind = 'module' " ..
  "JOIN main.stubs s ON s.source_hash = i.source_hash " ..
  "WHERE p.path GLOB 'cosmic.*' ORDER BY p.path"

--- Each planned `cosmic.*` module `insert_stubs` found no stub of.
local unstubbed_modules =
  "SELECT p.path FROM plan p JOIN inputs i ON i.path = p.path AND i.kind = 'module' " ..
  "WHERE p.path GLOB 'cosmic.*' AND p.path NOT IN (SELECT path FROM out.stubs) " ..
  "ORDER BY p.path"

--- The catalog entries ([`build.syntax_analyzer`]'s `CatalogEntry`) found while parsing
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
  "i.file, c.line FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN catalog c ON c.source_hash = i.source_hash " ..
  "ORDER BY p.path, c.ordinal"

--- A write that starts from the projection already at `out` ([`usable_base`])
--- takes a module's rows from it where the module stands as it was, and
--- fills the rest from the working database as a write of nothing does.
--- `reused` is the temporary table of the modules that stand: those whose
--- file, kind, source and key are the base's, and that no declaration
--- stands in for. A row it carries is the row the full statement would
--- write, since each is a function of what the table's test holds equal and
--- of the identities [`usable_base`] holds equal. Each statement below is
--- the full one beside it, with the base's rows for those modules in
--- its place and the order `ORDER BY` gave them: SQLite assigns the ids
--- of `docs` as it inserts, so they are the ones a full write assigns.
local reused_modules <const> = "(SELECT path FROM temp.reused)"

local make_reused <const> = {
  "DROP TABLE IF EXISTS temp.reused",
  "CREATE TEMP TABLE reused (path TEXT PRIMARY KEY) WITHOUT ROWID",
  "INSERT INTO temp.reused (path) SELECT p.path FROM plan p " ..
    "JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
    "JOIN prev.modules r ON r.path = p.path AND r.file = i.file AND r.kind = i.kind " ..
    "AND r.source_hash = CAST(i.source_hash AS BLOB) AND r.key = CAST(p.key AS BLOB) " ..
    "WHERE NOT EXISTS (SELECT 1 FROM inputs d WHERE d.path = p.path AND d.kind = 'decl')",
}

--- The modules of a write that starts from a base. The rows a module that
--- stands does not take from the base are looked up by subquery, where
--- a join would look up every module's: a search of `compiled` by key reads
--- each row it compares whole, the Lua and the bytecode among it, some
--- 0.2 s for cosmic's own tree.
local insert_modules_reusing <const> =
  "INSERT INTO out.modules (path, file, kind, source_hash, key, source, " ..
  "bytecode, tests) " ..
  "SELECT i.path, i.file, i.kind, CAST(i.source_hash AS BLOB), CAST(p.key AS BLOB), " ..
  "coalesce(r.source, (SELECT d.data FROM deflated d WHERE d.source_hash = i.source_hash " ..
  "AND d.core = " .. deflating_core .. ")), " ..
  "coalesce(r.bytecode, (SELECT c.bytecode FROM compiled c WHERE c.key = p.key)), " ..
  "CASE WHEN r.path IS NOT NULL THEN r.tests " ..
  "WHEN i.kind = 'test' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM tests t " ..
  "WHERE t.source_hash = i.source_hash), '') " ..
  "WHEN i.kind = 'example' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM examples e " ..
  "WHERE e.source_hash = i.source_hash), '') ELSE '' END " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "LEFT JOIN temp.reused u ON u.path = p.path " ..
  "LEFT JOIN prev.modules r ON r.path = u.path " ..
  "WHERE u.path IS NOT NULL OR (EXISTS (SELECT 1 FROM deflated d " ..
  "WHERE d.source_hash = i.source_hash AND d.core = " .. deflating_core ..
  ") AND EXISTS (SELECT 1 FROM compiled c WHERE c.key = p.key)) " ..
  "ORDER BY p.path"

local insert_docs_reusing <const> =
  "INSERT INTO out.docs (module, symbol, source_symbol, exported, kind, " ..
  "signature, text, file, line) " ..
  "SELECT module, symbol, source_symbol, exported, kind, signature, text, file, line FROM (" ..
  "SELECT d.module AS module, d.id AS ordinal, d.symbol AS symbol, " ..
  "d.source_symbol AS source_symbol, d.exported AS exported, d.kind AS kind, " ..
  "d.signature AS signature, d.text AS text, d.file AS file, d.line AS line " ..
  "FROM prev.docs d WHERE d.module IN " .. reused_modules .. " " ..
  "UNION ALL " ..
  "SELECT m.path, d.ordinal, d.symbol, d.source_symbol, d.exported, d.kind, " ..
  "d.signature, d.text, i.file, d.line " ..
  "FROM (SELECT path FROM plan WHERE path NOT IN " .. reused_modules .. " " ..
  "UNION SELECT path FROM inputs WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path " ..
  "AND (i.kind = 'decl' OR NOT EXISTS (SELECT 1 FROM inputs d " ..
  "WHERE d.path = i.path AND d.kind = 'decl')) " ..
  "JOIN docs d ON d.source_hash = i.source_hash) ORDER BY module, ordinal"

local insert_uses_reusing <const> =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN refs r ON r.source_hash = i.source_hash " ..
  "WHERE p.path NOT IN " .. reused_modules .. " " ..
  "ORDER BY r.module, r.member, p.path, r.line"

local insert_typed_uses_reusing <const> =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN typed_refs r ON r.key = p.key " ..
  "WHERE p.path NOT IN " .. reused_modules .. " " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The uses of the modules that stand, which both statements above
--- left out: each is a row of the base, whichever of the two wrote it.
local carry_uses <const> =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, from_file, line) " ..
  "SELECT module, symbol, from_module, from_file, line FROM prev.uses " ..
  "WHERE from_module IN " .. reused_modules

--- What the shipped database is a function of, as one hash: this run's
--- plan with each module's file, the declarations, fingerprints,
--- host-independent identities, the zones it carries, the main module,
--- and the identity of the writer writing it (`running`). When the hash
--- matches the one the last write left in `meta` and the file is still
--- there, the file already is the projection of these rows, and nothing
--- is written.
---
--- The writer is included because a stale tool rebuilding itself writes
--- this file with its own code before the new tool re-enters. The tree's
--- fingerprints alone would let the new tool take that file for its own
--- projection though its writer is not the same code. A writer that is
--- the same code signs the same bytes, so a self-rebuild whose writer did
--- not move lands on the tool a boot writes.
---
--- The catalog, docs, examples and references add nothing: an extracted
--- row changes only with the source it was parsed from, which moves that
--- module's key. A record-field use rides on a compile instead, which a
--- change to the code finding it redoes under the same key, so that
--- code's identity (`receivers` in `meta`) is signed too. A link's row
--- is also a function of the files of the tree it names, which no key
--- holds, so what they said is signed (`?4`, [`build.link_index`]), and
--- in a project what determines the standard library's docs they may
--- name ([`link_index.running`]).
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
    "char(10) ORDER BY name) FROM zoneinfo), '') || char(10) || " ..
    "coalesce((SELECT group_concat(name || ' ' || sha256, char(10) ORDER BY name) " ..
    "FROM web_assets), '') || char(10) || " ..
    "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) ORDER BY path) " ..
    "FROM files WHERE path GLOB 'static/*'), '') || char(10) || ?1 || " ..
    "char(10) || ?2 || char(10) || ?3 || char(10) || ?4)))"
end

-- TODO: digest the source of cosmic.mime in place of its bytecode, so that a
-- process whose modules carry run-time checks (`cosmic test --check-types`)
-- signs a projection as the tool does:
-- build/rebuild_lock_tool_test.tl's test_a_waiting_projection_keeps_its_compiled_snapshot
-- fails in a checked run for it. It waits on the change to every signature,
-- which writes every projection again once.

--- The digest of the [`cosmic.mime`] this writer runs, which the `type` and
--- `gzip` of a `payload` row come from: the signature holds it, so an edit
--- to that module writes the rows again.
local function mime_digest(): string
  local bytecode, _ = Store.bytecode("cosmic.mime")
  return Hash.hex_sha256(bytecode or "")
end

--- The signature of the projection of `result`, whose links are
--- `pending`, as the writer whose identity is `binary` would write it.
local function signed(handle: work.Handle, result: importer.Result, pending: link_index.Pending,
                      binary: string): string?, string
  local rows, trouble = Sqlite.text_rows(handle.db, signature_sql(),
    { text(result.main or ""), text("portable-v1"), text(binary .. "\n" .. mime_digest()),
      text(pending.digest) })
  if rows == nil then
    return nil, trouble
  end
  return rows[1]:text(1), ""
end

--- What the links of the tree at `root` may name beside its own
--- symbols: nothing in cosmic's own tree, whose projection documents its
--- standard library itself; in a project, `given`, or the standard
--- library of the binary running.
local function library_for(root: string, given: link_index.Library?):
    link_index.Library?, string
  local own, trouble = tree.is_own(root)
  if own == nil then
    return nil, trouble
  end
  if own then
    return nil, ""
  end
  if given ~= nil then
    return given, ""
  end
  return link_index.running(), ""
end

--- The links of the tree `handle` holds, waiting for its symbols
--- ([`link_index.pending`]), with what they may name beside its own.
local function pending_links(handle: work.Handle, given: link_index.Library?, by: string):
    link_index.Pending?, string
  local library, trouble = library_for(handle.root, given)
  if library == nil and trouble ~= "" then
    return nil, trouble
  end
  return link_index.pending(handle.db, handle.root, library, by)
end

--- The signature of `result`'s projection as the writer whose identity
--- is `binary` would write it -- see [`signature_sql`].
--- @param library in a project, the standard library its links may
--- name, in place of the running binary's ([`link_index.running`])
function writer.signature(handle: work.Handle, result: importer.Result,
                          binary: string, library?: link_index.Library): string?, string
  local pending, trouble = pending_links(handle, library, binary)
  if pending == nil then
    return nil, trouble
  end
  return signed(handle, result, pending, binary)
end

--- Writes the files under `static/` as the `payload` rows a program reads
--- them from: the path below `static/`, the bytes, their SHA-256 as staged,
--- the type [`Mime.of`] gives, and the gzip [`Mime.gzip`] finds worth
--- keeping. Both are functions of the path and bytes alone, so the
--- projection stays a function of the tree.
-- TODO: keep the gzip of a file in the working database by its hash and
-- [`mime_digest`], so an edit elsewhere in the tree does not compress every
-- asset again; the cache needs a table in [`build/schema.tl`].
local function fill_payload(db: Sqlite.Handle): boolean, string
  local files, trouble = Sqlite.text_rows(db,
    "SELECT substr(path, 8), data, sha256 FROM files WHERE path GLOB 'static/*' ORDER BY path")
  if files == nil then
    return false, trouble
  end
  for _, row in ipairs(files) do
    local path, data, sha256 = row:text(1), row:text(2), row:text(3)
    local packed = Mime.gzip(path, data)
    local ok, failure = Sqlite.run(db,
      "INSERT INTO out.payload (path, data, sha256, type, gzip) VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(path), blob(data), text(sha256), text(Mime.of(path)),
        packed ~= nil and blob(packed) or {} })
    if not ok then
      return false, "static/" .. path .. ": " .. failure
    end
  end
  return true, ""
end

--- Carries the text of a declaration of the new checker's under `module` in the `decls` of the projection being written.
local function put_declaration(db: Sqlite.Handle, module: string, source: string): boolean, string
  return Sqlite.run(db, "INSERT INTO out.decls (path, source) VALUES (?1, deflate(?2))", { text(module), text(source) })
end

--- The row of the working database's `meta` that names the projection last
--- signed and the record-field identity ([`build.importer`]'s `receivers`)
--- it was signed with: a projection does not carry that identity, though its
--- uses depend on it.
local base_key <const> = "projection_base"

--- The row of the working database's `meta` that names the projection last
--- signed and the digest of the two files its `ca_roots` and `ca_revoked`
--- were parsed from ([`vendored_digest`]).
local vendored_key <const> = "projection_vendored"

--- The digest of the files [`build.roots`] and [`build.onecrl`] parse in the
--- tree at `root`, each by its bytes or `-` where it is not there: the
--- tables they fill are a function of these and of those modules' code, which
--- the writer's identity holds. Nil where a file is there and cannot be read.
local function vendored_digest(root: string): string?
  local function digest_of(path: string): string?
    local there, _ = Fs.exists(path)
    if there == nil then
      return nil
    end
    if not there then
      return "-"
    end
    local bytes, _ = Fs.read(path)
    if bytes == nil then
      return nil
    end
    return Hash.hex_sha256(bytes)
  end
  local bundle = digest_of(roots.source(root))
  local snapshot = digest_of(onecrl.source(root))
  if bundle == nil or snapshot == nil then
    return nil
  end
  return bundle .. " " .. snapshot
end

--- Whether the first column of the first row of `rows` is `answer`.
local function says(rows: Sqlite.Rows?, answer: string): boolean
  if rows == nil then
    return false
  end
  local row = rows[1]
  return row ~= nil and row:text(1) == answer
end

--- Whether the first column of the first row of `rows` is `1`: the answer
--- of a `SELECT` of a condition, false where there was none.
local function holds(rows: Sqlite.Rows?): boolean
  return says(rows, "1")
end

--- Whether the base's CA tables were made of the files `digest` names: the
--- projection it was signed as is the one the working database recorded
--- them under ([`vendored_key`]).
local function vendored_stands(db: Sqlite.Handle, digest: string): boolean
  local rows, _ = Sqlite.text_rows(db,
    "SELECT count(*) FROM main.meta m, prev.meta p WHERE m.key = '" .. vendored_key ..
      "' AND p.key = 'projected' AND m.value = p.value || char(10) || ?1",
    { text(digest) })
  return holds(rows)
end

--- The CA tables of the base, in the order of its rows, for the rows
--- [`build.roots`] and [`build.onecrl`] would make of the same files.
local carry_vendored <const> = {
  "INSERT INTO out.ca_roots (sha256, label, der, distrust_after) " ..
    "SELECT sha256, label, der, distrust_after FROM prev.ca_roots ORDER BY rowid",
  "INSERT INTO out.ca_revoked (kind, name, value) " ..
    "SELECT kind, name, value FROM prev.ca_revoked ORDER BY rowid",
}

--- The `meta` rows a projection and the working database must hold alike for
--- a base's rows to be the rows this write would make.
local base_meta <const> = "('image_hash', 'compiler', 'runtime_basis', 'writer')"

--- Whether the projection attached as `prev` may stand in for the rows a
--- write would fill: it was signed by the writer and the compiler this
--- write runs as (`by`, `tool`), on the core image and with the
--- record-field identity this write has, under the schema it creates in
--- `out`, and it holds the same declarations by path, but for the two
--- the checker is given ([`build.checker_declarations`]). Each of those decides
--- some row a module's own inputs do not, so where any differs, or cannot
--- be read, the answer is false and the projection is written whole.
local function usable_base(db: Sqlite.Handle, by: string, tool: string): boolean
  local function schema_rows(from: string, other: string): string
    return "(SELECT count(*) FROM (SELECT type, name, tbl_name, sql FROM " .. from ..
      ".sqlite_master EXCEPT SELECT type, name, tbl_name, sql FROM " .. other .. ".sqlite_master))"
  end
  local function meta_rows(from: string, other: string): string
    return "(SELECT count(*) FROM (SELECT key, value FROM " .. from .. ".meta WHERE key IN " ..
      base_meta .. " EXCEPT SELECT key, value FROM " .. other .. ".meta WHERE key IN " ..
      base_meta .. "))"
  end
  local function named(key: string, parameter: string): string
    return "(SELECT count(*) FROM prev.meta WHERE key = '" .. key .. "' AND value = " ..
      parameter .. ") = 1"
  end
  local rows, _ = Sqlite.text_rows(db,
    "SELECT " .. schema_rows("out", "prev") .. " + " .. schema_rows("prev", "out") .. " = 0 AND " ..
      meta_rows("prev", "main") .. " + " .. meta_rows("main", "prev") .. " = 0 AND " ..
      "(SELECT count(*) FROM main.meta WHERE key IN ('compiler', 'runtime_basis', 'writer')) = 3 AND " ..
      named("written_by", "?1") .. " AND " .. named("compiled_by", "?2") .. " AND " ..
      "(SELECT count(*) FROM main.meta WHERE key = '" .. base_key .. "' AND value = " ..
      "(SELECT p.value || char(10) || r.value FROM prev.meta p, main.meta r " ..
      "WHERE p.key = 'projected' AND r.key = 'receivers')) = 1 AND " ..
      "(SELECT coalesce(group_concat(path, char(10)), '') FROM " ..
      "(SELECT path FROM prev.decls WHERE path NOT IN (?3, ?4) ORDER BY path)) = " ..
      "(SELECT coalesce(group_concat(path, char(10)), '') FROM " ..
      "(SELECT path FROM inputs WHERE kind = 'decl' ORDER BY path))",
    { text(by), text(tool), text(CheckerDeclarations.prelude_module()),
      text(CheckerDeclarations.stdlib_module()) })
  return holds(rows)
end

--- The statements that fill the rows extracted from the sources, in the
--- order they run: those that carry the base's rows for the modules that
--- stand where `reusing`.
local function extraction(reusing: boolean): {string}
  if reusing then
    return { insert_catalog_extracted, insert_docs_reusing, insert_uses_reusing,
      insert_typed_uses_reusing, carry_uses, insert_examples }
  end
  return { insert_catalog_extracted, insert_docs, insert_uses, insert_typed_uses, insert_examples }
end

--- Fills `temp.reused` ([`make_reused`]) from the base, and answers
--- whether it did; a failure leaves the write whole.
local function find_reused(db: Sqlite.Handle): boolean
  for _, statement in ipairs(make_reused) do
    local ok, _ = db:exec(statement)
    if not ok then
      return false
    end
  end
  return true
end

--- Fills the attached `out` schema within the working transaction, signed
--- `signature` by the writer whose identity is `by`, and naming the
--- compiler whose identity keyed its modules (`result.tool`) as
--- `compiled_by`. Its links are `pending`'s, resolved once its docs are
--- in.
local function project(handle: work.Handle,
                       result: importer.Result, pending: link_index.Pending,
                       signature: string, by: string, based: boolean): boolean, string
  local db = handle.db
  for _, statement in ipairs(schema.settings("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end
  for _, statement in ipairs(schema.create("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end
  local usable = based and usable_base(db, by, result.tool)
  local reusing = usable and find_reused(db)
  local statements: mut {string} = {}
  statements[#statements + 1] = prune_deflated
  statements[#statements + 1] = fill_deflated
  statements[#statements + 1] = choose(reusing, insert_modules_reusing, insert_modules)
  statements[#statements + 1] = insert_imports
  statements[#statements + 1] = insert_decl_imports
  statements[#statements + 1] = insert_bound
  statements[#statements + 1] =
    "INSERT INTO out.decls (path, source) SELECT i.path, d.data FROM inputs i " ..
    "JOIN deflated d ON d.source_hash = i.source_hash AND d.core = " .. deflating_core .. " " ..
    "WHERE i.kind = 'decl' ORDER BY i.path"
  statements[#statements + 1] =
    "INSERT INTO out.zoneinfo (name, data) SELECT name, data FROM zoneinfo " ..
    "ORDER BY name"
  statements[#statements + 1] =
    "INSERT INTO out.web_assets (name, data, sha256, sha384, version) " ..
    "SELECT name, data, sha256, sha384, version FROM web_assets ORDER BY name"
  for _, statement in ipairs(statements) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end
  -- The declarations the new checker types a project against ([`build.checker_declarations`]), which only cosmic's own tree
  -- holds: a tool carries them, a project's projection does not.
  local declared, declared_trouble = CheckerDeclarations.staged(db, handle.root)
  if declared == nil and declared_trouble ~= "" then
    return false, declared_trouble
  end
  if declared ~= nil then
    local put, put_trouble = put_declaration(db, CheckerDeclarations.prelude_module(), declared.prelude)
    if put then
      put, put_trouble = put_declaration(db, CheckerDeclarations.stdlib_module(), declared.stdlib)
    end
    if not put then
      return false, put_trouble
    end
  end
  local stored, store_trouble = fill_payload(db)
  if not stored then
    return false, store_trouble
  end
  local metadata = "('boot_hash', 'image_hash', 'compiler', 'runtime_basis', 'writer')"
  local carried, meta_trouble = db:exec(
    "INSERT INTO out.meta (key, value) SELECT key, value FROM meta " ..
      "WHERE key IN " .. metadata)
  if not carried then
    return false, meta_trouble
  end
  -- The identity the uses of this projection were found under, kept for the next write's [`usable_base`].
  local based_on, base_trouble = Sqlite.run(db,
    "INSERT OR REPLACE INTO main.meta (key, value) SELECT '" .. base_key .. "', " ..
      "?1 || char(10) || value FROM main.meta WHERE key = 'receivers'", { text(signature) })
  if not based_on then
    return false, base_trouble
  end
  for _, statement in ipairs(extraction(reusing)) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end
  -- The rule behind each code of the checker that compiled, after the rows extracted from the sources: the new checker's.
  local catalog = result.catalog
  if catalog ~= nil then
    local written, catalog_trouble = catalog(db, "out.")
    if written == nil then
      return false, catalog_trouble
    end
  end
  local linked, link_trouble = link_index.fill(db, pending, "out.")
  if not linked then
    return false, link_trouble
  end
  for _, statement in ipairs(schema.rebuild("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end
  -- cosmic's own tree describes the binary it builds: its bill of
  -- materials ([`build.bom`]), read from the pins and records beside the
  -- code, the CA roots it trusts ([`build.roots`]) and the certificates
  -- OneCRL revokes ([`build.onecrl`]). A change to any comes with a
  -- pin's, a tool file, so `boot_hash`, which the signature covers,
  -- moves when one does. It also carries its standard
  -- library's stubs (`insert_stubs`): a stub is a function of its
  -- module's source, which the module's key holds, and of build.stub,
  -- which the compiler's identity in `meta` holds. A project's tables
  -- stay empty.
  local own, own_trouble = tree.is_own(handle.root)
  if own == nil then
    return false, own_trouble
  end
  if own then
    local filled, fill_trouble = bom.fill(db, handle.root, "out.")
    if not filled then
      return false, fill_trouble
    end
    local digest = vendored_digest(handle.root)
    local kept = reusing and digest ~= nil and vendored_stands(db, digest)
    if kept then
      for _, statement in ipairs(carry_vendored) do
        local carried_roots, carry_trouble = db:exec(statement)
        if not carried_roots then
          return false, carry_trouble
        end
      end
    else
      local trusted, trust_trouble = roots.fill(db, handle.root, "out.")
      if not trusted then
        return false, trust_trouble
      end
      local revoked, revoke_trouble = onecrl.fill(db, handle.root, "out.")
      if not revoked then
        return false, revoke_trouble
      end
    end
    local noted, note_trouble = Sqlite.run(db,
      "DELETE FROM main.meta WHERE key = '" .. vendored_key .. "'", {})
    if noted and digest ~= nil then
      noted, note_trouble = Sqlite.run(db,
        "INSERT INTO main.meta (key, value) VALUES ('" .. vendored_key .. "', ?1 || char(10) || ?2)",
        { text(signature), text(digest) })
    end
    if not noted then
      return false, note_trouble
    end
    local stubbed, stub_trouble = db:exec(insert_stubs)
    if not stubbed then
      return false, stub_trouble
    end
    -- A module the binary carried no stub of would be typed from its
    -- source, slower and with nothing to say so.
    local unstubbed, unstubbed_trouble = Sqlite.text_rows(db, unstubbed_modules)
    if unstubbed == nil then
      return false, unstubbed_trouble
    end
    if #unstubbed > 0 then
      return false, unstubbed[1]:text(1) .. ": the projection holds no stub of it (build/stub.tl)"
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
end

--- The identity of the writer this process runs, which signs what it
--- writes ([`signature_sql`]) and is recorded beside it as `written_by`.
--- A boot (which carries no database) and a tool fresh against the tree
--- in `handle` both run the tree's own code, so it is the tree's
--- (`identities.writer`); so is a binary its caller has found to carry
--- the tree's code though it is stale by its own (`tree_code`, from
--- [`build.reboot`]'s `carries_tree_code`). Any other binary names the
--- `writer` it carries or, when it carries none, its whole boot hash, so
--- a tool it rebuilt is never taken for one the tree's writer wrote
--- ([`build.reboot`]).
local function running(handle: work.Handle, identities: identity.Identities,
                       tree_code: boolean): string?, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil or tree_code then
    return identities.writer, ""
  end
  local tree_hash, trouble = identity.recorded_boot_hash(handle.db)
  if tree_hash == nil and trouble ~= "" then
    return nil, trouble
  end
  if tree_hash == boot_hash then
    return identities.writer, ""
  end
  return Store.meta("writer") or ("boot " .. boot_hash), ""
end

--- An identity a projection records, as what is said names it: its
--- first twelve characters, or "none recorded" for "", none.
local function named(recorded: string): string
  if recorded == "" then return "none recorded" end
  return recorded:sub(1, 12)
end

--- What the projection `db` records of the code that wrote it, where
--- that is other than the code this process runs: its writer
--- (`written_by`) and the compiler that compiled and parsed what it
--- holds (`compiled_by`). This process names its writer as [`running`]
--- does: one that carries no boot hash, as a boot does, or carries the
--- one the projection records being made from (`boot_hash`), runs that
--- tree's code, so its writer is that tree's, which the projection
--- records beside it (`writer`); any other names the `writer` it
--- carries, or its whole boot hash. Answers the one that differs, as
--- what is said names it; nil where both are this process's own.
---
--- These name the code, not the whole tool's boot hash as the working
--- database does ([`work.other_code`]): a projection is the database of
--- the tool built from it, and holds the bytes a boot writes, which a
--- rebuild by a stale tool lands on only while it records the writer
--- and the compiler, never the tool, that wrote it. Nil and why where
--- the read fails.
--- @param compiler the compiler identity a build in this process
--- compiles under ([`rebuild.compiled_by`])
function writer.other_code(db: Sqlite.Handle, compiler: string): string?, string
  -- "" for a row it lacks, a value no identity is.
  local function value(key: string): string
    return "coalesce((SELECT value FROM meta WHERE key = '" .. key .. "'), '')"
  end
  local rows, trouble = Sqlite.text_rows(db, "SELECT " .. value("written_by") .. ", " ..
      value("compiled_by") .. ", " .. value("writer") .. ", " .. value("boot_hash"))
  if rows == nil then
    return nil, trouble
  end
  local row = rows[1]
  if row == nil then
    return nil, "the projection's meta answered no row"
  end
  local written_by, compiled_by = row:text(1), row:text(2)
  local own_writer = row:text(3)
  local boot_hash = Store.meta("boot_hash")
  if boot_hash ~= nil and boot_hash ~= row:text(4) then
    own_writer = Store.meta("writer") or ("boot " .. boot_hash)
  end
  if written_by == "" or written_by ~= own_writer then
    return "a writer other than this tool's (" .. named(written_by) .. ", not " ..
      named(own_writer) .. ")", ""
  end
  if compiled_by ~= compiler then
    return "a compiler other than this tool's (" .. named(compiled_by) .. ", not " ..
      named(compiler) .. ")", ""
  end
  return nil, ""
end

--- Writes an already-compiled result into a fresh host-independent database
--- and leaves it at `out`, unless the file there already is that projection.
--- The attached in-memory projection is filled before the working transaction
--- ends, so a later build cannot change the rows this result publishes. Only
--- vacuuming and publication wait for the rebuild lock, with no transaction
--- held that its holder may need. The caller keeps the compile transaction
--- open until this call; a repeat write of an ended run is valid only while
--- its result still matches the working rows. `tree_code` says this process
--- runs the tree's own code
--- though its fingerprint is not the tree's (`running`).
--- @param library in a project, the standard library its links may
--- name, in place of the running binary's ([`link_index.running`])
--- @param reader the verb of a lookup's build ([`rebuild.here`]), which
--- waits for no run holding the rebuild lock: where one does, it leaves
--- the projection there as it is, says so once
--- ([`rebuild_lock.try_hold`]), and answers true
function writer.write_result(handle: work.Handle, out: string,
                             result: importer.Result, tree_code?: boolean,
                             library?: link_index.Library, reader?: string): boolean, string
  local db = handle.db
  if not handle.inside then
    local begun, begin_trouble = work.begin(handle)
    if not begun then return false, begin_trouble end
  end
  local identities, identity_trouble = identity.record_identities(handle.db)
  if identities == nil then
    return false, identity_trouble
  end
  local by, by_trouble = running(handle, identities, tree_code == true)
  if by == nil then
    return false, by_trouble
  end
  local pending, pending_trouble = pending_links(handle, library, by)
  if pending == nil then
    return false, pending_trouble
  end
  local signature, sign_trouble = signed(handle, result, pending, by)
  if signature == nil then
    return false, sign_trouble
  end
  if projected_signature(out) == signature then
    return work.commit(handle)
  end
  local attached, attach_trouble = db:exec("ATTACH ':memory:' AS out")
  if not attached then return false, attach_trouble end
  -- The file there, if it is a projection, is the base of the write ([`usable_base`]).
  local based = false
  local there, _ = Fs.exists(out)
  if there == true then
    local joined, _ = Sqlite.run(db, "ATTACH DATABASE ?1 AS prev", { text(out) })
    based = joined
  end
  local projected, project_trouble = project(handle, result, pending, signature, by, based)
  if not projected then
    local _, _ = work.rollback(handle)
    local _, _ = db:exec("DETACH out")
    if based then
      -- A base that passed [`usable_base`] yet cannot be read to its end (a page of it damaged) would fail every
      -- write after this one the same way, since only a write that fills the rows whole replaces it.
      local checked, _ = Sqlite.text_rows(db, "PRAGMA prev.quick_check(1)")
      local intact = says(checked, "ok")
      local _, _ = db:exec("DETACH prev")
      if not intact then
        local _, _ = Fs.remove(out)
      end
    end
    return false, project_trouble
  end
  local committed, commit_trouble = work.commit(handle)
  if based then
    local _, _ = db:exec("DETACH prev")
  end
  if not committed then
    local _, _ = db:exec("DETACH out")
    return false, commit_trouble
  end

  -- Written aside under `out`'s one fixed `.building` name, which no
  -- other run writes meanwhile: a projection in the build directory --
  -- the project's own, or the checked boot's beneath it -- is written
  -- holding the project's rebuild lock, the one lock of that directory,
  -- which a `cosmic test` run and a rebuild of the tool hold already,
  -- and a boot's bridge is handed by the `bin/zig build` that holds it.
  -- Taken only now, with the working database's transaction ended
  -- above, so a holder waiting for that database is not waited on in
  -- turn. A reader takes it only where it is free: the run holding it
  -- writes a projection of its own.
  local took = false
  local directory = build_paths.resolve(handle.root).directory
  if Fs.within(out, directory) then
    local taken, lock_trouble: boolean?, string
    if reader ~= nil then
      taken, lock_trouble = rebuild_lock.try_hold(handle.root, "write", reader)
      if taken == nil and lock_trouble == "" then
        local _, _ = db:exec("DETACH out")
        return true, ""
      end
    else
      taken, lock_trouble = rebuild_lock.hold(handle.root, "write", out)
    end
    if taken == nil then
      local _, _ = db:exec("DETACH out")
      return false, lock_trouble
    end
    took = taken
  end
  local _, _ = Fs.remove(out .. ".building")
  local ok, trouble = Sqlite.run(db, "VACUUM out INTO ?1", { text(out .. ".building") })
  local _, _ = db:exec("DETACH out")
  if ok then
    ok, trouble = Fs.rename(out .. ".building", out)
  end
  if took then
    rebuild_lock.release()
  end
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Writes `result` to `out` as [`writer.write_result`] does, for a build
--- that holds no rebuild lock, begun at `started` (monotonic ns), that
--- staged `staged`. Its row in `builds` ([`work.record`]) goes in with
--- the commit, timed to it, so the build writes nothing to the working
--- database after: a run of another schema that removes the file once
--- the locks are free ([`work.try_open_remaking`]) takes none of the
--- build's rows with it but what it means to. Only a write that fails
--- once committed records so after. `reader` is as
--- [`writer.write_result`] takes it.
function writer.write_recorded(handle: work.Handle, out: string, result: importer.Result,
                               started: integer, staged: work.Staged,
                               reader?: string): boolean, string
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, "PASS")
  local written, trouble = writer.write_result(handle, out, result, nil, nil, reader)
  if not written then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
      result.cached, "FAIL")
    return false, trouble
  end
  return true, ""
end

--- The modules a projection holds that the tool built from it does not
--- carry: its tests and examples. A module a carried one requires is
--- carried anyway, since the tool could not load without it. A module's
--- kind is only its file name. Each statement below names `dropped` from
--- this, so a row is left out only for being about one.
local dropped_modules <const> =
  "WITH RECURSIVE carried(path) AS (" ..
  "SELECT path FROM whole.modules WHERE kind NOT IN ('test', 'example') " ..
  "UNION SELECT i.requires FROM whole.imports i " ..
  "JOIN carried c ON i.path = c.path), " ..
  "dropped(path) AS (SELECT path FROM whole.modules " ..
  "EXCEPT SELECT path FROM carried) "

--- The type a doc row `d` of a `cosmic.internal.*` module is or is
--- under, as a public declaration spells it after the name its module
--- binds the internal one to: `Handle` of [`sqlite.Handle`] and of
--- [`Handle.exec`].
local nested_type <const> =
  "(CASE WHEN d.kind IN ('record', 'interface', 'enum') " ..
  "THEN substr(d.source_symbol, instr(d.source_symbol, '.') + 1) " ..
  "ELSE substr(d.symbol, 1, instr(d.symbol, '.') - 1) END)"

--- The public declarations that can name an internal type through a
--- module binding: the `signature` of each public alias (`type Handle =
--- raw_sqlite.Handle`) or declaration with bases (`record Options is
--- raw_http.Options`), beside each module `requires` its module binds,
--- and the `name` it binds it to ([`build.syntax_analyzer`]'s `Bound`). It follows
--- `dropped` as one more common table expression, materialized so that
--- it is computed once, not for each internal doc row
--- [`carried_internal_types`] asks about.
local carried_alias_signatures <const> =
  ", alias_signatures AS MATERIALIZED (" ..
  "SELECT b.requires, b.name, p.signature FROM whole.docs p " ..
  "JOIN whole.bound b ON b.path = p.module WHERE " ..
  symbols.public_only("p.module", true) .. " AND " ..
  "(p.signature GLOB 'type * = *' OR p.signature GLOB '*record * is *' OR " ..
  "p.signature GLOB '*interface * is *')) "

--- The condition under which a doc row `d` of a `cosmic.internal.*`
--- module is a nested type -- [`sqlite.Handle`] -- or a member of one
--- ([`Handle.exec`]) that a public declaration reaches: an alias
--- (`type Handle = raw_sqlite.Handle`) or a base (`record Options is
--- raw_http.Options`), whose page lists them, through the name its
--- module binds `d`'s to ([`build.syntax_analyzer`]'s `Bound`). [`symbols.shown_docs`]
--- still hides these rows from every public query; only that page's
--- resolution ([`build.docs`]) reads them. Written as a join, which
--- looks each doc row's module up among the aliases once: an `EXISTS` that
--- scans them for each of the several hundred internal rows took most of a
--- second of every tool rebuild.
local carried_internal_types =
  "d.id IN (SELECT d.id FROM whole.docs d " ..
  "JOIN alias_signatures a ON a.requires = d.module WHERE " ..
  "d.module LIKE 'cosmic.internal.%' AND d.symbol <> '' AND " ..
  "((d.kind IN ('record', 'interface', 'enum') AND instr(d.source_symbol, '.') > 0) OR " ..
  "(d.kind IN ('field', 'value', 'metamethod') AND instr(d.symbol, '.') > 0)) AND " ..
  "(a.signature GLOB '*[ ,]' || a.name || '.' || " .. nested_type .. " OR " ..
  "a.signature GLOB '*[ ,]' || a.name || '.' || " .. nested_type .. " || ',*'))"

--- Copies a projection's rows into a fresh schema of the same shape,
--- leaving out each row `dropped_modules` names. Both schemas come from
--- [`build.schema`], so `*` names the same columns in the same order. A
--- rowid table's `id` is assigned again, in the projection's order.
local carry: {string} = {
  -- Every row of the projection's `meta` but `projected`, which signs
  -- the whole projection, tests and examples among it: carried, it would
  -- move the tool's bytes with an edit to a test, which the tool does not
  -- carry (see [`writer.carried`]).
  "INSERT INTO main.meta SELECT * FROM whole.meta WHERE key <> 'projected' " ..
    "ORDER BY key",
  dropped_modules .. "INSERT INTO main.modules SELECT * FROM whole.modules " ..
    "WHERE path NOT IN dropped ORDER BY path",
  dropped_modules .. "INSERT INTO main.imports SELECT * FROM whole.imports " ..
    "WHERE path NOT IN dropped AND requires NOT IN dropped " ..
    "ORDER BY path, requires",
  dropped_modules .. "INSERT INTO main.decl_imports SELECT * FROM whole.decl_imports " ..
    "WHERE path NOT IN dropped ORDER BY path, requires",
  dropped_modules .. "INSERT INTO main.bound SELECT * FROM whole.bound " ..
    "WHERE path NOT IN dropped ORDER BY path, name",
  "INSERT INTO main.decls SELECT * FROM whole.decls ORDER BY path",
  "INSERT INTO main.stubs SELECT * FROM whole.stubs ORDER BY path",
  "INSERT INTO main.payload SELECT * FROM whole.payload ORDER BY path",
  "INSERT INTO main.zoneinfo (name, data) SELECT name, data FROM whole.zoneinfo " ..
    "ORDER BY name",
  "INSERT INTO main.web_assets SELECT * FROM whole.web_assets ORDER BY name",
  "INSERT INTO main.components SELECT * FROM whole.components ORDER BY name",
  "INSERT INTO main.notices SELECT * FROM whole.notices ORDER BY component, ordinal",
  "INSERT INTO main.ca_roots SELECT * FROM whole.ca_roots ORDER BY sha256",
  "INSERT INTO main.ca_revoked SELECT * FROM whole.ca_revoked ORDER BY rowid",
  -- Outside cosmic's own tree, `cosmic docs`, `cosmic uses` and a
  -- compile's hints read the tool's rows only for the public standard
  -- library ([`symbols.public_only`]). Inside it they read the tree's own
  -- projection first, and find nothing for `build.*` until a build has
  -- written one. So a doc row about any other module is carried only for
  -- the catalog, whose guidance is the doc comment of the function an
  -- error came from (core/main.c, [`build.embed`]).
  --
  -- A user guide ([`symbols.guide_module`]) is a generated test module, so
  -- `dropped` names it, but its own row -- the guide's prose -- is what
  -- `cosmic docs quickstart` answers with.
  --
  -- The catalog's rows are looked up as a set (`IN`), not by a correlated
  -- `EXISTS`, which SQLite answers here by scanning the catalog for each of
  -- the thirty thousand doc rows: most of a second of every tool rebuild.
  dropped_modules .. carried_alias_signatures ..
    "INSERT INTO main.docs (module, symbol, source_symbol, exported, " ..
    "kind, signature, text, file, line) SELECT module, symbol, " ..
    "source_symbol, exported, kind, signature, text, file, line " ..
    "FROM whole.docs d WHERE (d.symbol = '' AND " ..
    symbols.guide_module("d.module") .. ") OR (module NOT IN dropped AND (" ..
    symbols.public_only("d.module", true) ..
    " OR (d.module, d.source_symbol) IN (SELECT module, symbol FROM whole.catalog) OR " ..
    carried_internal_types .. ")) ORDER BY id",
  dropped_modules .. "INSERT INTO main.uses SELECT * FROM whole.uses u " ..
    "WHERE module NOT IN dropped AND from_module NOT IN dropped AND " ..
    symbols.public_only("u.module", true) .. " AND " ..
    symbols.public_only("u.from_module", true) ..
    " ORDER BY module, symbol, from_module, line",
  -- A link to a symbol, where both ends are the public standard
  -- library's, as a use is; a link to a file names one of cosmic's own
  -- tree, which a project does not have.
  dropped_modules .. "INSERT INTO main.links SELECT * FROM whole.links l " ..
    "WHERE kind = 'symbol' AND module NOT IN dropped AND from_module NOT IN dropped AND " ..
    symbols.public_only("l.module", true) .. " AND " ..
    symbols.public_only("l.from_module", true) ..
    " ORDER BY module, symbol, path, anchor, from_file, line, column",
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
--- docs, uses, links and examples, the only ones a reader asks the tool for
--- (see `carry`). Like the projection, it is a function of
--- its input alone: a fresh schema, filled in one order, vacuumed.
--- Its `meta` is the projection's but for `projected`, which signs the
--- whole projection it came from, not these rows: a tool that carried it
--- would move with an edit to a test or an example, which it leaves out,
--- and so would everything keyed by its bytes (CI's fixtures, keyed by
--- the product they run). Nothing needs it from a tool: build.writer
--- reads it from a projection it wrote, and build.reboot's `replaced`
--- tells a rebuilt tool apart by `boot_hash`, `written_by` and
--- `compiled_by`, one of which every rebuild moves.
function writer.carried(whole: string, out: string): boolean, string
  local function fill(db: Sqlite.Handle): boolean, string
    local statements: mut {string} = {}
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
      for _, statement in ipairs(schema.rebuild("main.")) do
        local ok, failure = db:exec(statement)
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
