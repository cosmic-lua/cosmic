--- Writing the store of a test module's import closure: what a
--- sandboxed worker of a test whose module does not declare `store` is
--- given at o/cosmic.db in the projection's place ([`build.test_sandbox`]),
--- derived from the projection [`build.writer`] writes and kept by
--- `cosmic test` under o/stores by its address ([`build.test`]), so an
--- edit to a module outside the closure leaves the store as it was. A
--- test's key holds the store by the digest of its bytes
--- ([`build.declared_key`]'s `store_digest`), not by its address: the
--- address says only where a store is and whether it must be written, so
--- an edit to the code that writes it that leaves its bytes as they were
--- moves no key.
---
--- It is apart from the projection's writer because its code salts
--- every store's address ([`build.test`]'s `store_writer`), and that
--- writer's need not. What the writer writes reaches a store only
--- through rows and orderings the address digests
--- ([`closure_store.basis`]): each module's columns, the stored (deflated)
--- source's bytes among them, and each module's own imports, names
--- bound, docs, uses, catalog, examples and links in the order the
--- store takes them. The order across
--- modules is this module's (`closed`). So an edit to the writer -- a
--- query of the projection, a table only the projection fills -- moves
--- only the addresses of the stores whose rows it moves.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")
local Sqlite = require("cosmic.sqlite")
local schema = require("build.schema")
local String = require("cosmic.string")

local record closure_store
  --- What every closure store a projection yields is a function of,
  --- read once from the projection ([`closure_store.basis`]).
  ---
  --- Each module is a line naming its path, kind, file, source hash and
  --- tests, then the digests of its bytecode, of its source as stored
  --- (deflated, by [`build.writer`]), and of the rows a store carries of
  --- it: its imports, the names it binds, its docs, uses, catalog,
  --- examples and links (those it makes), each in the order the store
  --- takes them within the module (or file). Each declaration is a line
  --- naming its path and the digests of its source as stored, of its
  --- docs, of its links and of the names it binds, and it records the
  --- declarations it requires. A digest covers what
  --- every store holds alike: the `meta` rows it keeps (`closure_meta`).
  ---
  --- What the compiler made of a module is held by what it made, not by
  --- the compiler's identity ([`build.identity`]'s `Identities`). That moves
  --- with every edit to any module a compile or a parse runs, most of
  --- which change nothing it makes. An edit to the compiler that leaves
  --- every row of a closure as it was leaves its store and its address
  --- too.
  record Basis
    modules: {string:string}
    shared: string
    --- Each module's kind, by path.
    kinds: {string:string}
    --- The modules an example can be paired with -- neither tests nor
    --- examples -- sorted (see [`build.writer`]'s `insert_examples`).
    pairable: {string}
    --- Each declaration's line, by path.
    decls: {string:string}
    --- The declarations each declaration requires, by path
    --- ([`required_by`]).
    decl_requires: {string:{string}}
  end

  --- Modules a module loads by other means than `require`, by that
  --- module (`loaded_beside`).
  loaded_beside: {string:{string}}
end

--- `value`, bound as TEXT: [`build.bind`]'s `text`, restated rather than
--- required so that what salts a store's address is this module and the
--- schema alone ([`build.test`]'s `store_writer`), and an edit to the
--- binds the rest of the build shares moves no address.
local function text(value: string): Sqlite.Value
  return { text = value }
end

--- The `meta` rows of a projection a closure store keeps: none that
--- moves with a module outside the closure. `boot_hash` hashes every
--- file of the tree and `projected` signs every module; `writer` and
--- `written_by` name the projection's writer ([`build.work`]'s
--- `writer_modules`), which holds much of the standard library
--- (cosmic.json among it); `compiler` and `compiled_by` name the
--- importer's. Each left out is answered by the tool's own `meta`, the
--- next database [`Store.meta`] searches; what writes a closure store is
--- named in its address instead ([`closure_store.address`]'s `salt`), and
--- a test whose closure reads the compiler's identity is keyed by the
--- tool's ([`build.declared_key`]'s `compiler_readers`).
local closure_meta <const> = "('image_hash', 'main', 'runtime_basis')"

--- The names `source`, a declaration's, requires: each literal name
--- handed to `require` -- `local type t = require("name")`, as a
--- declaration requires another's types -- spelled `require("name")`,
--- `require "name"`, with single quotes, or as a long string
--- (`require [[name]]`). It reads more than a parse would: a name
--- written so in a comment is among them, which only makes a store
--- carry, and its address hold, one declaration more. A declaration
--- cannot require a computed name, since the checker types only a
--- literal one. A spelling it misses fails closed: the store's hold
--- ([`build.test_worker`]'s `hold_store`) refuses a held test any
--- declaration outside its closure's names, so one this leaves out of a
--- store is one no held test can read, and a test that types it fails
--- rather than standing. Scanned here rather than taken from the
--- importer's parse, which the projection does not keep of a
--- declaration: a require of build.analyzer would salt every store's
--- address with it ([`build.test`]'s `store_writer`). [`build.tree_checks`]
--- holds the tree to declarations that require only declarations
--- (`declared`).
function closure_store.required_by(source: string): {string}
  local out: {string} = {}
  for _, pattern in ipairs({ "require%s*%(?%s*[\"']([%w_%.]+)[\"']",
      "require%s*%(?%s*%[(=*)%[([%w_%.]+)%]%1%]" }) do
    for first, second in source:gmatch(pattern) do
      out[#out + 1] = second or first
    end
  end
  return out
end

--- The digest of the rows of `from`, the table of a projection `db`
--- holds, by each value of its column `of`: of each row's `columns`,
--- each quoted (`quote`) so no two rows spell one line, in `order`. A
--- text is quoted as a blob of its bytes, since quote() ends a text at
--- its first NUL, which a blob's hex does not (as [`build.declared_key`]'s
--- `carried_digest` quotes it).
local function grouped(db: Sqlite.Handle, of: string, columns: {string}, from: string,
                       order: string): {string:string} | nil, string
  local quoted: {string} = {}
  for i, column in ipairs(columns) do
    quoted[i] = "typeof(" .. column .. ") || ':' || quote(CASE WHEN typeof(" .. column ..
      ") = 'text' THEN CAST(" .. column .. " AS BLOB) ELSE " .. column .. " END)"
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. of .. ", lower(hex(sha256(group_concat(" ..
      table.concat(quoted, " || ',' || ") .. ", char(10) ORDER BY " .. order .. ")))) " ..
      "FROM " .. from .. " GROUP BY " .. of)
  if rows == nil then return nil, trouble end
  local out: {string:string} = {}
  for _, row in ipairs(rows) do out[row[1]] = row[2] end
  return out, ""
end

--- The basis of the closure stores of the projection at `whole`.
function closure_store.basis(whole: string): closure_store.Basis | nil, string
  local opened, trouble = Sqlite.open(whole)
  if opened == nil then return nil, whole .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function read(): closure_store.Basis | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT path, path || char(9) || kind || char(9) || file || char(9) || " ..
        "lower(hex(source_hash)) || char(9) || lower(hex(sha256(bytecode))) || char(9) || " ..
        "lower(hex(sha256(tests))) || char(9) || lower(hex(sha256(source))), file " ..
        "FROM modules ORDER BY path")
    if rows == nil then return nil, rows_trouble end
    -- The rows `closed` carries of each module, as it carries them: by
    -- its path, or, for its examples, by its file.
    local carried: {{string:string}} = {}
    local by_file: {boolean} = {}
    -- The links' and the names' digests, which a declaration's line
    -- takes too.
    local linked: {string:string} = {}
    local bound: {string:string} = {}
    for _, group in ipairs({
        { "path", "requires", "imports", "requires" },
        { "path", "name requires", "bound", "name" },
        { "module", "symbol source_symbol exported kind signature text file line", "docs", "id" },
        { "from_module", "module symbol from_file line", "uses", "module, symbol, line" },
        { "module", "kind symbol message text file line", "catalog", "id" },
        { "file", "module name text line source", "examples", "id" },
        { "from_module", "module symbol path anchor from_file line column kind form source text",
            "links", "module, symbol, path, anchor, from_file, line, column" },
    }) do
      local columns: {string} = {}
      for column in group[2]:gmatch("%S+") do columns[#columns + 1] = column end
      local digests, group_trouble = grouped(db, group[1], columns, group[3], group[4])
      if digests == nil then return nil, group_trouble end
      carried[#carried + 1] = digests
      if group[3] == "links" then linked = digests end
      if group[3] == "bound" then bound = digests end
      by_file[#carried] = group[1] == "file"
    end
    local shared, shared_trouble = Sqlite.text_rows(db,
      "SELECT coalesce((SELECT group_concat(key || ' ' || lower(hex(value)), char(10) " ..
        "ORDER BY key) FROM meta WHERE key IN " .. closure_meta .. "), '')")
    if shared == nil then return nil, shared_trouble end
    local decl_rows, decl_trouble = Sqlite.text_rows(db,
      "SELECT path, lower(hex(sha256(source))), CAST(inflate(source) AS TEXT) FROM decls " ..
        "ORDER BY path")
    if decl_rows == nil then return nil, decl_trouble end
    local declared, declared_trouble = grouped(db, "module",
      { "symbol", "source_symbol", "exported", "kind", "signature", "text", "file", "line" },
      "docs WHERE module IN (SELECT path FROM decls)", "id")
    if declared == nil then return nil, declared_trouble end
    local names, names_trouble = Sqlite.text_rows(db,
      "SELECT path FROM modules WHERE kind NOT IN ('test', 'example') ORDER BY path")
    if names == nil then return nil, names_trouble end
    local basis: closure_store.Basis = { modules = {}, kinds = {}, pairable = {}, decls = {},
      decl_requires = {} }
    for _, row in ipairs(rows) do
      local line: {string} = { row[2] }
      for i, digests in ipairs(carried) do
        line[#line + 1] = digests[by_file[i] and row[3] or row[1]] or ""
      end
      basis.modules[row[1]] = table.concat(line, "\t")
      basis.kinds[row[1]] = row[2]:match("^[^\t]*\t([^\t]*)")
    end
    for i, row in ipairs(names) do basis.pairable[i] = row[1] end
    for _, row in ipairs(decl_rows) do
      basis.decls[row[1]] = "decl " .. row[1] .. " " .. row[2] .. " " .. (declared[row[1]] or "") ..
        " " .. (linked[row[1]] or "") .. " " .. (bound[row[1]] or "")
      basis.decl_requires[row[1]] = closure_store.required_by(row[3])
    end
    basis.shared = Hash.hex_sha256("closure-store-6\n" .. shared[1][1])
    return basis, ""
  end
  local basis, read_trouble = read()
  local _, _ = db:close()
  if basis == nil then return nil, whole .. ": " .. read_trouble end
  return basis, ""
end

--- Modules a module loads by other means than `require`, which a
--- closure store carries beside it: build.teal loads the compiler as
--- bytecode (`Store.bytecode("vendor.tl")`), which no parse follows.
local loaded_beside: {string:{string}} = { ["build.teal"] = { "vendor.tl" } }
closure_store.loaded_beside = loaded_beside

--- The modules of `basis` a closure store for `names` -- an import
--- closure's module names ([`test_inputs.modules`]) -- holds, sorted: each
--- that the projection holds, and what each loads beside
--- (`loaded_beside`). A name only a declaration answers for is none:
--- `declared` answers those.
local function stored(basis: closure_store.Basis, names: {string}): {string}
  local seen: {string:boolean} = {}
  local out: {string} = {}
  local function add(name: string)
    if seen[name] or basis.modules[name] == nil then return end
    seen[name] = true
    out[#out + 1] = name
  end
  for _, name in ipairs(names) do
    add(name)
    for _, beside in ipairs(loaded_beside[name] or {}) do add(beside) end
  end
  table.sort(out)
  return out
end

--- The declarations of `basis` a closure store for `names` holds,
--- sorted: each that `names` holds -- an import closure holds each
--- declaration a module of it requires by value, and each a test module
--- of it requires by `require` or by `local type ... = require`; a
--- non-test module's type-only edges are not followed
--- ([`test_inputs.modules`]) -- and each that one of
--- them requires, directly or not, so a declaration the checker reads
--- to type another's is carried beside it and its edit moves the
--- address too. The core's raw modules (`cosmic.internal.*`) and
--- [`cosmic.sys`] are so carried only by the closures whose wrappers
--- require them, and an edit to one moves only those stores.
---
--- What it carries beyond the closure's names over-approximates the
--- address: the store's hold ([`build.test_worker`]'s `hold_store`)
--- refuses a held test every declaration outside its closure's names,
--- so a checker under it cannot read a declaration carried only this
--- way, and an edit to one moves an address no held test's verdict
--- turns on. The hold, not this walk, is what keeps a verdict sound; the
--- walk keeps a store whole for a worker the hold does not cover.
--- It follows declarations alone: a module of the tree one required
--- would be neither carried nor in the address, so [`build.tree_checks`]
--- (`declarations`) refuses a declaration that requires anything but
--- a declaration.
-- TODO: have [`test_inputs.modules`] follow a declaration's requires
-- too, as this does, so the store's hold lets a held test read the
-- declarations carried here beyond its closure's names
-- ([`cosmic.internal.sqlite`] beside cosmic.internal.store, which requires
-- it): today it refuses them, which fails a test that types one rather
-- than standing on it.
local function declared(basis: closure_store.Basis, names: {string}): {string}
  local seen: {string:boolean} = {}
  local out: {string} = {}
  local stack: {string} = {}
  for _, name in ipairs(names) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not seen[name] and basis.decls[name] ~= nil then
      seen[name] = true
      out[#out + 1] = name
      for _, required in ipairs(basis.decl_requires[name]) do stack[#stack + 1] = required end
    end
  end
  table.sort(out)
  return out
end

--- The modules of `basis` the example module `name` could be paired
--- with by its name ([`build.writer`]'s `insert_examples`): each that it
--- is less `_example`, or that it starts with, followed by `_`. Which
--- of them is longest names the module its examples are about.
local function candidates(basis: closure_store.Basis, name: string): {string}
  local stem = name:sub(1, #name - #"_example")
  local out: {string} = {}
  for _, path in ipairs(basis.pairable) do
    if path == stem or String.starts_with(stem, path .. "_") then out[#out + 1] = path end
  end
  return out
end

--- The address of the closure store for `names` over `basis`: the
--- digest of everything its bytes follow from -- its modules' lines,
--- the modules each example module among them could be paired with
--- (`candidates`), its declarations' lines (`declared`), the basis's
--- shared digest, and `salt`, which names the code that writes it
--- ([`build.test`] passes a digest of this module's and build.schema's
--- sources and bytecode, and nothing of the projection's writer, whose
--- edits leave a store's bytes alone). An edit to a module or a
--- declaration outside the closure moves none of these, and neither
--- does adding or removing one, except a module an example of the
--- closure could be paired with. So neither the address nor the store
--- moves. The store holds no trace of its address (`write`), so two
--- addresses of the same rows -- an edit to the writer's comments, say
--- -- name stores of the same bytes, which a key holds alike.
function closure_store.address(basis: closure_store.Basis, names: {string},
                               salt: string): string
  local lines: {string} = { basis.shared, salt }
  for _, name in ipairs(stored(basis, names)) do
    lines[#lines + 1] = basis.modules[name]
    if basis.kinds[name] == "example" then
      lines[#lines + 1] = "pairs " .. name .. " " .. table.concat(candidates(basis, name), " ")
    end
  end
  for _, name in ipairs(declared(basis, names)) do lines[#lines + 1] = basis.decls[name] end
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- Fills a closure store's fresh schema from the projection attached
--- as `whole`, for the modules `temp.wanted` names: their rows, the
--- edges among them, the names they bind, their docs, uses and links
--- (those they make), catalog, and the examples of the example files
--- among them; the declarations `temp.declared` names (`declared`), the
--- names they bind, their docs and links; and the `meta` rows `closure_meta` keeps. The zones, CA
--- roots, components and notices are left out: the core, [`cosmic.time`]
--- and [`build.bom`] read those from the tool's own database alone.
--- Each table's rows go in by what the address digests of them
--- ([`closure_store.basis`]): the docs, catalog and examples by module
--- (and file) first, then in the projection's order within one, which
--- the address digests; the projection's order across modules, which
--- the projection's writer decides and no digest holds, sets no id.
local closed: {string} = {
  "INSERT INTO main.meta SELECT * FROM whole.meta WHERE key IN " .. closure_meta ..
    " ORDER BY key",
  -- Every column but the key, which holds the compiler's identity: no
  -- worker reads a store's keys, and its address holds what the
  -- compiler made instead ([`Basis`]).
  "INSERT INTO main.modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
    "SELECT path, file, kind, source_hash, X'', bytecode, tests, source FROM whole.modules " ..
    "WHERE path IN temp.wanted ORDER BY path",
  "INSERT INTO main.imports SELECT * FROM whole.imports " ..
    "WHERE path IN temp.wanted AND requires IN temp.wanted ORDER BY path, requires",
  "INSERT INTO main.bound SELECT * FROM whole.bound " ..
    "WHERE path IN temp.wanted OR path IN temp.declared ORDER BY path, name",
  "INSERT INTO main.decls SELECT * FROM whole.decls WHERE path IN temp.declared " ..
    "ORDER BY path",
  "INSERT INTO main.docs (module, symbol, source_symbol, exported, kind, signature, " ..
    "text, file, line) SELECT module, symbol, source_symbol, exported, kind, signature, " ..
    "text, file, line FROM whole.docs WHERE module IN temp.wanted " ..
    "OR module IN temp.declared ORDER BY module, id",
  "INSERT INTO main.uses SELECT * FROM whole.uses WHERE from_module IN temp.wanted " ..
    "ORDER BY module, symbol, from_module, line",
  -- The links its modules and declarations make, as the uses: one from
  -- a Markdown, C or Zig file (from_module "") is no module's, so no
  -- closure's.
  "INSERT INTO main.links SELECT * FROM whole.links WHERE from_module IN temp.wanted " ..
    "OR from_module IN temp.declared " ..
    "ORDER BY module, symbol, path, anchor, from_file, line, column",
  "INSERT INTO main.examples (module, name, text, file, line, source) " ..
    "SELECT module, name, text, file, line, source FROM whole.examples " ..
    "WHERE file IN (SELECT file FROM whole.modules WHERE path IN temp.wanted) " ..
    "ORDER BY module, file, id",
  "INSERT INTO main.catalog (kind, module, symbol, message, text, file, line) " ..
    "SELECT kind, module, symbol, message, text, file, line FROM whole.catalog " ..
    "WHERE module IN temp.wanted ORDER BY module, id",
}

--- Flushes the file at `path` to the disk: `VACUUM INTO` leaves its
--- output unsynced, and a store cut short by a crash after its rename
--- would stand at its address for good.
local function sync(path: string): boolean, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then return false, path .. ": " .. trouble end
  local synced, sync_trouble = sys.fsync(fd)
  local _, _ = sys.close(fd)
  if not synced then return false, path .. ": " .. sync_trouble end
  return true, ""
end

--- Writes at `out` the closure store for `names` (see
--- [`closure_store.address`]) of the projection at `whole`, whose basis
--- is `basis`: what a sandboxed worker of a test whose module's import
--- closure `names` holds is given at o/cosmic.db in the projection's
--- place ([`build.test_sandbox`]), so an edit outside the closure leaves
--- it as it was. Like the projection, a function of its rows alone: a
--- fresh schema, filled in one order, vacuumed, naming neither its
--- address nor the code that wrote it, so a key holds it by its bytes
--- (build/closure_store_test.tl holds two writes of the same rows to
--- the same bytes); and synced before it is moved into place, since a
--- store is written once and read as it is from then on.
function closure_store.write(whole: string, out: string, names: {string},
                             basis: closure_store.Basis): boolean, string
  local function fill(db: Sqlite.Handle): boolean, string
    local statements: {string} = {}
    for _, statement in ipairs(schema.settings("")) do statements[#statements + 1] = statement end
    for _, statement in ipairs(schema.create("")) do statements[#statements + 1] = statement end
    statements[#statements + 1] = "CREATE TEMP TABLE wanted (path TEXT PRIMARY KEY)"
    statements[#statements + 1] = "CREATE TEMP TABLE declared (path TEXT PRIMARY KEY)"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then return false, failure end
    end
    for _, name in ipairs(stored(basis, names)) do
      local ok, failure = Sqlite.run(db, "INSERT INTO temp.wanted (path) VALUES (?1)",
        { text(name) })
      if not ok then return false, failure end
    end
    for _, name in ipairs(declared(basis, names)) do
      local ok, failure = Sqlite.run(db, "INSERT INTO temp.declared (path) VALUES (?1)",
        { text(name) })
      if not ok then return false, failure end
    end
    local attached, attach_trouble = Sqlite.run(db, "ATTACH DATABASE ?1 AS whole",
      { text(whole) })
    if not attached then return false, attach_trouble end
    local made, refused = Sqlite.transact(db, function(): boolean, string
      for _, statement in ipairs(closed) do
        local ok, failure = db:exec(statement)
        if not ok then return false, failure end
      end
      for _, statement in ipairs(schema.rebuild("main.")) do
        local ok, failure = db:exec(statement)
        if not ok then return false, failure end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH whole")
    if not made then return false, refused end
    -- Written aside under `out`'s one fixed `.building` name, which no
    -- other run writes or sweeps meanwhile: only `cosmic test` writes a
    -- checkout's stores, and one run of it at a time holds the
    -- checkout's rebuild lock (build.rebuild_lock), so a `.building`
    -- that build.test's `sweep_stores` finds is one cut short.
    local _, _ = Fs.remove(out .. ".building")
    local vacuumed, vacuum_trouble = Sqlite.run(db, "VACUUM INTO ?1", { text(out .. ".building") })
    if not vacuumed then return false, vacuum_trouble end
    local synced, sync_trouble = sync(out .. ".building")
    if not synced then return false, sync_trouble end
    return Fs.rename(out .. ".building", out)
  end
  local db, open_trouble = Sqlite.memory()
  if db == nil then return false, open_trouble end
  local ok, trouble = fill(db)
  local _, _ = db:close()
  if not ok then return false, trouble end
  return true, ""
end

return closure_store
