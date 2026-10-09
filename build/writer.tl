--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh schema
--- attached in memory and filled in one transaction by queries over rows
--- the build already holds, then written by `VACUUM INTO`, so a second
--- build of the same tree is byte-identical. The rows are this run's plan
--- joined to the inputs and compiles it names, the declarations a checker
--- needs to build a tree against this one, and the time zones the
--- working database holds (cosmic's own tree's only).
---
--- The store of a test module's import closure a sandboxed worker is
--- given in the projection's place is derived from the projection by
--- [`build.closure_store`], apart from this module, so an edit here that
--- leaves every store's bytes alone moves no store's address.

local build_paths = require("build.paths")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local identity = require("build.identity")
local type importer = require("build.importer")
local bom = require("build.bom")
local link_index = require("build.link_index")
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
  return rows[1][1]
end

--- The shipped modules: this run's plan joined to the inputs it named
--- of non-declaration kind and the compiles it found or made, with
--- a test or example module's own names alongside.
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
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
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
--- module ([`build.analyzer.Bound`]), kept whatever the module they
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

--- The documented symbols ([`build.analyzer.DocEntry`]) found while parsing
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

--- The uses ([`build.analyzer.Reference`]) found: each
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

--- The record-field uses [`build.receivers`] found while each planned
--- module was compiled, kept under the compile's key: `w:add_file(...)`
--- on a [`Zip.Writer`] is a use of `Writer.add_file` in [`cosmic.zip`].
local insert_typed_uses =
  "INSERT OR IGNORE INTO out.uses (module, symbol, from_module, " ..
  "from_file, line) " ..
  "SELECT r.module, r.member, p.path, i.file, r.line " ..
  "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
  "JOIN typed_refs r ON r.key = p.key " ..
  "ORDER BY r.module, r.member, p.path, r.line"

--- The worked examples ([`build.analyzer.ExampleEntry`]) found: a
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

--- The catalog entries ([`build.analyzer.CatalogEntry`]) found while parsing
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
    "char(10) ORDER BY name) FROM zoneinfo), '') || char(10) || ?1 || " ..
    "char(10) || ?2 || char(10) || ?3 || char(10) || ?4)))"
end

--- The signature of the projection of `result`, whose links are
--- `pending`, as the writer whose identity is `binary` would write it.
local function signed(handle: work.Handle, result: importer.Result, pending: link_index.Pending,
                      binary: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(handle.db, signature_sql(),
    { text(result.main or ""), text("portable-v1"), text(binary), text(pending.digest) })
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- What the links of the tree at `root` may name beside its own
--- symbols: nothing in cosmic's own tree, whose projection documents its
--- standard library itself; in a project, `given`, or the standard
--- library of the binary running.
local function library_for(root: string, given: link_index.Library | nil):
    link_index.Library | nil, string
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
local function pending_links(handle: work.Handle, given: link_index.Library | nil):
    link_index.Pending | nil, string
  local library, trouble = library_for(handle.root, given)
  if library == nil and trouble ~= "" then
    return nil, trouble
  end
  return link_index.pending(handle.db, handle.root, library)
end

--- The signature of `result`'s projection as the writer whose identity
--- is `binary` would write it -- see [`signature_sql`].
--- @param library in a project, the standard library its links may
--- name, in place of the running binary's ([`link_index.running`])
function writer.signature(handle: work.Handle, result: importer.Result,
                          binary: string, library?: link_index.Library): string | nil, string
  local pending, trouble = pending_links(handle, library)
  if pending == nil then
    return nil, trouble
  end
  return signed(handle, result, pending, binary)
end

--- Fills the attached `out` schema within the working transaction, signed
--- `signature` by the writer whose identity is `by`, and naming the
--- compiler whose identity keyed its modules (`result.tool`) as
--- `compiled_by`. Its links are `pending`'s, resolved once its docs are
--- in.
local function project(handle: work.Handle,
                       result: importer.Result, pending: link_index.Pending,
                       signature: string, by: string): boolean, string
  local db = handle.db
  for _, statement in ipairs(schema.settings("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end

  local statements: {string} = {}
  for _, statement in ipairs(schema.create("out.")) do
    statements[#statements + 1] = statement
  end
  statements[#statements + 1] = insert_modules
  statements[#statements + 1] = insert_imports
  statements[#statements + 1] = insert_decl_imports
  statements[#statements + 1] = insert_bound
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
  -- code, and the CA roots it trusts ([`build.roots`]). A change to
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
                       tree_code: boolean): string | nil, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil or tree_code then
    return identities.writer
  end
  local tree_hash, trouble = identity.recorded_boot_hash(handle.db)
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
function writer.write_result(handle: work.Handle, out: string,
                             result: importer.Result, tree_code?: boolean,
                             library?: link_index.Library): boolean, string
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
  local pending, pending_trouble = pending_links(handle, library)
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
  local projected, project_trouble = project(handle, result, pending, signature, by)
  if not projected then
    local _, _ = work.rollback(handle)
    local _, _ = db:exec("DETACH out")
    return false, project_trouble
  end
  local committed, commit_trouble = work.commit(handle)
  if not committed then
    local _, _ = db:exec("DETACH out")
    return false, commit_trouble
  end

  -- Written aside under `out`'s one fixed `.building` name, which no
  -- other run in this checkout writes meanwhile: the checkout's own
  -- projection is written holding its rebuild lock, which a `cosmic
  -- test` run and a rebuild of the tool hold already, and a boot's
  -- bridge is handed by the `bin/zig build boot` that holds it. Taken
  -- only now, with the working database's transaction ended above, so
  -- a holder waiting for that database is not waited on in turn.
  local took = false
  local held_fd: integer = nil
  if out == build_paths.required(handle.root) .. "/cosmic.db" then
    local taken, lock_trouble = rebuild_lock.hold(handle.root, "write", "o/cosmic.db")
    if taken == nil then
      local _, _ = db:exec("DETACH out")
      return false, lock_trouble
    end
    took = taken
  elseif out == handle.dir .. "/cosmic.db" then
    -- A build in a directory of its own (build/dispatch.tl's private one)
    -- has no checkout's lock; one in the directory keeps two runs from
    -- writing its one `.building` at once.
    local fd, open_trouble = sys.open(handle.dir .. "/.write.lock", sys.O_RDWR | sys.O_CREAT, 0x180)
    if fd == nil then
      local _, _ = db:exec("DETACH out")
      return false, handle.dir .. "/.write.lock: " .. open_trouble
    end
    local locked, lock_trouble = sys.flock(fd, "exclusive", -1)
    if not locked then
      local _, _ = sys.close(fd)
      local _, _ = db:exec("DETACH out")
      return false, handle.dir .. "/.write.lock: " .. lock_trouble
    end
    held_fd = fd
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
  if held_fd ~= nil then
    local _, _ = sys.close(held_fd)
  end
  if not ok then
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

--- The condition under which a doc row `d` of a `cosmic.internal.*`
--- module is a nested type -- [`sqlite.Handle`] -- or a member of one
--- ([`Handle.exec`]) that a public declaration reaches: an alias
--- (`type Handle = raw_sqlite.Handle`) or a base (`record Options is
--- raw_http.Options`), whose page lists them, through the name its
--- module binds `d`'s to ([`build.analyzer.Bound`]). [`symbols.shown_docs`]
--- still hides these rows from every public query; only that page's
--- resolution ([`build.docs`]) reads them.
local carried_internal_types =
  "(d.module LIKE 'cosmic.internal.%' AND d.symbol <> '' AND " ..
  "((d.kind IN ('record', 'interface', 'enum') AND instr(d.source_symbol, '.') > 0) OR " ..
  "(d.kind IN ('field', 'value', 'metamethod') AND instr(d.symbol, '.') > 0)) AND " ..
  "EXISTS (SELECT 1 FROM whole.docs p " ..
  "JOIN whole.bound b ON b.path = p.module AND b.requires = d.module WHERE " ..
  symbols.public_only("p.module", true) .. " AND " ..
  "(p.signature GLOB 'type * = *' OR p.signature GLOB '*record * is *' OR " ..
  "p.signature GLOB '*interface * is *') AND " ..
  "(p.signature GLOB '*[ ,]' || b.name || '.' || " .. nested_type .. " OR " ..
  "p.signature GLOB '*[ ,]' || b.name || '.' || " .. nested_type .. " || ',*')))"

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
  "INSERT INTO main.payload SELECT * FROM whole.payload ORDER BY path",
  "INSERT INTO main.zoneinfo (name, data) SELECT name, data FROM whole.zoneinfo " ..
    "ORDER BY name",
  "INSERT INTO main.components SELECT * FROM whole.components ORDER BY name",
  "INSERT INTO main.notices SELECT * FROM whole.notices ORDER BY component, ordinal",
  "INSERT INTO main.ca_roots SELECT * FROM whole.ca_roots ORDER BY sha256",
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
  dropped_modules .. "INSERT INTO main.docs (module, symbol, source_symbol, " ..
    "exported, kind, signature, text, file, line) SELECT module, symbol, " ..
    "source_symbol, exported, kind, signature, text, file, line " ..
    "FROM whole.docs d WHERE (d.symbol = '' AND " ..
    symbols.guide_module("d.module") .. ") OR (module NOT IN dropped AND (" ..
    symbols.public_only("d.module", true) ..
    " OR EXISTS (SELECT 1 FROM whole.catalog c WHERE c.module = d.module " ..
    "AND c.symbol = d.source_symbol) OR " .. carried_internal_types .. ")) ORDER BY id",
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
