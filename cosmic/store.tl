--- The databases `require` reads its modules from, for test and build
--- tooling: attach a project's database, and read a module's compiled
--- bytes, its source, its imports, or the binary's own tables. An
--- ordinary program has no use for it.

-- The raw module behind this one lives under `cosmic.internal.`, a
-- reserved namespace that never satisfies an ordinary `require` for
-- any caller: `require` caches a result under the name it was asked
-- for, and a value that must be checked on every access can never be
-- that cached value, or the first caller's access would answer for
-- every caller after it. The searcher hands it here directly instead,
-- as the second argument `require` always passes a loader -- present
-- only because this module was itself loaded, trusted, from the
-- binary's own tree. Boot mode, before any such check exists, falls
-- back to requiring it by name, which only boot's own preload answers.

local type raw_store = require("cosmic.internal.store")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local extra: any = select(2, ...)
local store: raw_store
if type(extra) == "table" then
  store = extra as raw_store
else
  store = require("cosmic.internal.store")
end

local record Store
  --- How [`Store.closure`] follows requires.
  record ClosureOptions
    --- Follows the requires a module makes only to name types
    --- (`local type t = require("x")`, which Teal erases) as well. Off by
    --- default: a program that runs never loads such a module.
    types?: boolean
  end

  --- What [`Store.seal`] is told beyond the modules to carry.
  record SealOptions
    --- The module the sealed program runs, recorded as the database's
    --- `main`. It must be one of the sealed names. Without it the database
    --- names no main.
    main?: string
    --- A module the store does not hold, carried as well and recorded as
    --- the database's `main` (so `main` is left out): a script compiled
    --- this run. Its name is none of the sealed names.
    extra?: Store.Extra
    --- Required, and `true`, with `extra`: the bytecode of `extra` is
    --- loaded as given, which nothing checks. See [`Store.attach`].
    unchecked_bytecode?: boolean
  end

  --- What [`Store.attach`] is told beyond the path.
  record AttachOptions
    --- Required, and `true`: the database's bytecode is loaded as given.
    unchecked_bytecode: boolean
  end

  --- A file the binary carries for [`cosmic.web`] to serve, from [`Store.web_asset`].
  record WebAsset
    --- The file's bytes.
    data: string
    --- Their SHA-256, in lower case hexadecimal.
    sha256: string
    --- Their SHA-384 in base64: the value after `sha384-` in an `integrity` attribute.
    sha384: string
    --- The version of the library the file belongs to.
    version: string
  end

  --- A module [`Store.seal`] is handed rather than finds: what a row of
  --- the store holds of one, its compiled chunk and its source.
  record Extra
    --- The module's name, which a `require` of it asks for.
    name: string
    --- The chunk `string.dump` writes, which the core loads for the
    --- name, and which returns the module's value, a function for a main.
    bytecode: string
    --- The text the chunk was compiled from, which an error's line is
    --- read from.
    source: string
    --- The modules it requires by a literal name, kept where they are
    --- among the sealed names, as the `imports` rows of the rest are.
    requires: {string}
  end
end

--- Opens a projected module database and searches it ahead of every other.
---
--- The database's modules are loaded as the bytecode it holds, which nothing
--- checks: Lua has no bytecode verifier, so bytecode that lies about its
--- own types runs as the program the user chose to run. `opts.unchecked_bytecode`
--- must be `true`, or this raises naming it, so each caller says it takes
--- that. A project build refuses an attach without that literal option, and
--- refuses [`Store.attach`] used as a value: that is a gate on checked code,
--- not a boundary against code that is not checked, which can call this
--- itself.
function Store.attach(path: string, opts?: Store.AttachOptions): boolean, string
  if opts == nil or opts.unchecked_bytecode ~= true then
    error("store: attach: the database's bytecode is loaded unchecked; " ..
        "pass { unchecked_bytecode = true } to say so", 2)
  end
  local ok, trouble = store.attach(path)
  if not ok then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- One module's compiled bytes, for a caller that must load the chunk in
--- an environment of its own; nil and why for none.
function Store.bytecode(name: string): string?, string
  return store.bytecode(name)
end

--- One entry of the meta table, which is where a build records what it
--- decided. Nil when no database holds that key.
function Store.meta(key: string): string?
  return store.meta(key)
end

--- One module's Teal source, or a declaration's, from the binary's own
--- database and no other: what a checker building another tree needs
--- to type a `require` of this one's modules. Stored deflated, it is
--- inflated here; nil beside why when there is no such row or it will
--- not inflate.
function Store.source(name: string): string?, string
  return store.source(name)
end

--- The names the binary's own `imports` table records the module
--- `name` requiring, sorted: none for a name it holds no row of. Nil
--- and why when the query failed.
--- This walks the binary's module graph without a handle on every
--- module's rows (`databases`).
function Store.requires(name: string): {string}?, string
  return store.requires(name)
end

--- Every database `require` searches, in search order: a project's
--- own ahead of the binary's, which is always last. Each is a handle
--- [`cosmic.sqlite`] reads through and never closes -- what a verb that
--- asks about the shipped tables (`docs`, `uses`, `catalog`) queries.
function Store.databases(): {Sqlite.Handle}
  return store.databases()
end

--- One time zone's TZif file (RFC 8536), by IANA name, from the copy
--- of the tz database the binary's own database carries: the only zone
--- rules [`cosmic.time`] reads. Nil and why when it carries no such zone
--- or the query failed; [`zone_names`] tells the two apart.
function Store.zoneinfo(name: string): string?, string
  return store.zoneinfo(name)
end

--- One file of the browser-side libraries the binary carries for
--- [`cosmic.web`] to serve (`htmx.min.js`, `htmx-ext-sse.min.js`), with its
--- hashes and version, from the binary's own database. Nil and why when it
--- carries no such file or the query failed.
function Store.web_asset(name: string): Store.WebAsset?, string
  local databases = store.databases()
  local rows, trouble = Sqlite.rows(databases[#databases],
    "SELECT data, sha256, sha384, version FROM web_assets WHERE name = ?1",
    { { text = name } })
  if rows == nil then
    return nil, trouble
  end
  local row = rows[1]
  if row == nil then
    return nil, "the binary carries no web asset " .. name
  end
  return { data = row:bytes(1),
    sha256 = row:text(2), sha384 = row:text(3), version = row:text(4) }, ""
end

--- Every time zone name the binary's own database carries, as a set,
--- or nil and why when the query failed.
function Store.zone_names(): {string:boolean}?, string
  return store.zone_names()
end

--- The paths of the files the runtime holds open for the store, and no
--- other file: each database [`Store.databases`] hands out that is a
--- file, then its write-ahead log (`-wal`) and shared-memory file
--- (`-shm`), which SQLite opens beside it whether or not they exist yet.
--- What [`Sandbox.restrict`] grants on macOS, where Seatbelt checks a path
--- at every open.
function Store.paths(): {string}
  return store.paths()
end

--- Calls `fn` searching only the binary's own database, as a process
--- that attached none would -- `require`, `meta`, `source` and
--- `databases` included -- then puts every other back where it was,
--- whether `fn` returned or raised. Nothing can be attached meanwhile.
function Store.alone(fn: function())
  store.alone(fn)
end

local type Handle = Sqlite.Handle

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Whether the searcher resolves `name` from the binary's own database
--- ahead of any other: everything under `cosmic.*`, and each wrapper of
--- a raw binding, which the searcher alone knows (it hands such a
--- module a second value when it loads). It takes the store's searcher
--- to be the last of `package.searchers`, where the core installs it.
local function reserved(name: string): boolean
  if name:sub(1, 7) == "cosmic." then
    return true
  end
  -- Only the binary's own tree has wrappers, and the searcher loads the
  -- chunk it answers with, which a name outside it need not be one.
  if name:sub(1, 6) ~= "build." then
    return false
  end
  local search = package.searchers[#package.searchers]
  local _, raw = search(name)
  return raw is table
end

--- The database whose row of `name` the search order answers with; nil
--- and why when none holds one or a query failed.
local function locate(name: string, required?: string): Handle?, string
  local databases = Store.databases()
  local count = #databases
  local binary_first = reserved(name)
  for step = 1, count do
    local db = databases[if binary_first then count + 1 - step else step end]
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT 1 FROM modules WHERE path = ?1", { text(name) })
    if rows == nil then
      return nil, trouble
    end
    if #rows > 0 then
      return db, ""
    end
  end
  return nil, "no module of that name in the store" ..
    (if required ~= nil then ", required by " .. required else "" end)
end

--- [`locate`], raising where it fails: a name no database holds is a
--- degenerate argument, naming `name` and who `required` it.
local function located(name: string, required?: string): Handle
  local db, trouble = locate(name, required)
  if db == nil then
    error("store: " .. name .. ": " .. trouble, 3)
  end
  return db
end

--- The names `name` requires according to `db`'s `imports` rows. With
--- `types` false, an edge is dropped when the importer's bytecode lacks
--- the required name as a string constant, which is what Teal leaves of
--- a type-only require: the rule build/test.tl's `erased_require` holds
--- its closures to, so a sealed program's modules are those the tests of
--- it ran against. Keep the two in step.
local function requires_of(db: Handle, name: string, types: boolean): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.requires FROM imports i WHERE i.path = ?1 AND (?2 = 1 OR " ..
      "NOT EXISTS (SELECT 1 FROM modules m WHERE m.path = i.path AND " ..
      "m.kind IN ('module', 'main') AND " ..
      "instr(m.bytecode, CAST(i.requires AS BLOB)) = 0)) ORDER BY i.requires",
    { text(name), { integer = if types then 1 else 0 end } })
  if rows == nil then
    error("store: " .. name .. ": " .. trouble, 3)
  end
  local out: mut {string} = {}
  for index, row in ipairs(rows) do
    out[index] = row:text(1)
  end
  return out
end

--- Every module `roots` name and every module they require, directly or
--- not, sorted, over the `imports` rows of the databases the store
--- searches, each module's from the database that answers for it
--- ([`Store.databases`], so a test declares `store`). A `local type`
--- require, which Teal erases and the program never loads, is left out
--- unless `opts.types` is true; the rows do not mark it, so it is told
--- by the importer's bytecode not holding the name (the rule the test
--- runner's closures follow), and a name that is also a string
--- there is followed. Only the `imports` rows are edges, and they hold
--- the literal names handed to `require` and to `pcall(require, ...)`.
--- A name computed at run time is none: the build refuses one
--- (`computed_require`), and a program that gets one past it fails when
--- it runs sealed. Raises naming a root, or a module a root requires,
--- that no searched database holds, and for a `roots` that is not a list.
---
---     local names = Store.closure({ "cosmic.json" })
---     print(#names, names[1])
function Store.closure(roots: {string}, opts?: Store.ClosureOptions): {string}
  if type(roots) ~= "table" then
    error("store: closure: roots is a list of module names, not a " .. type(roots), 2)
  end
  local types = opts ~= nil and opts.types == true
  local seen: mut {string:boolean} = {}
  local names: mut {string} = {}
  local stack: mut {string} = {}
  local required_by: mut {integer: string} = {}
  for _, root in ipairs(roots) do
    stack[#stack + 1] = root
  end
  while #stack > 0 do
    local required = required_by[#stack]
    required_by[#stack] = nil
    local name = table.remove(stack)
    if seen[name] ~= true then
      seen[name] = true
      names[#names + 1] = name
      for _, next_name in ipairs(requires_of(located(name, required), name, types)) do
        stack[#stack + 1] = next_name
        required_by[#stack] = name
      end
    end
  end
  table.sort(names)
  return names
end

--- Copies every row `query` yields from `from`, bound to `values`, into
--- `table_name` of `into`, column for column and each value as the
--- kind it was read as. `columns` names the destination's, in
--- `query`'s order. False and why when a statement fails.
local function copy_rows(from: Handle, into: Handle, table_name: string,
                         columns: {string}, query: string,
                         values?: {Sqlite.Value}): boolean, string
  local rows, trouble = Sqlite.rows(from, query, values)
  if rows == nil then
    return false, table_name .. ": " .. trouble
  end
  local slots: mut {string} = {}
  for index = 1, #columns do
    slots[index] = "?" .. tostring(index)
  end
  local insert = "INSERT OR IGNORE INTO " .. table_name .. " (" ..
    table.concat(columns, ", ") .. ") VALUES (" .. table.concat(slots, ", ") .. ")"
  for _, row in ipairs(rows) do
    local bound: mut {Sqlite.Value} = {}
    for index = 1, row:count() do
      bound[index] = row:value(index)
    end
    local ok, why = Sqlite.run(into, insert, bound)
    if not ok then
      return false, table_name .. ": " .. why
    end
  end
  return true, ""
end

--- The tables of a program database, as the core reads them
--- (core/store.c): module rows, their requires, every edge a type
--- checker follows from each (which a compile of a project reads of a
--- standard-library module it imports), declaration sources (empty here:
--- only a type checker reads one), the zones and CA roots
--- it falls back on, and what was decided at the writing. Their
--- columns are build/schema.tl's, so a database written here and one
--- written by the build answer the same queries.
local seal_schema: {string} = {
  "PRAGMA page_size = 4096",
  "PRAGMA auto_vacuum = 0",
  "PRAGMA encoding = 'UTF-8'",
  "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",
  [[CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL,
    kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL,
    bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)]],
  [[CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL,
    PRIMARY KEY (path, requires)) WITHOUT ROWID]],
  [[CREATE TABLE decl_imports (path TEXT NOT NULL, requires TEXT NOT NULL,
    PRIMARY KEY (path, requires)) WITHOUT ROWID]],
  "CREATE TABLE decls (path TEXT PRIMARY KEY, source BLOB NOT NULL) WITHOUT ROWID",
  "CREATE TABLE zoneinfo (name TEXT PRIMARY KEY, data BLOB NOT NULL)",
  [[CREATE TABLE web_assets (name TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL,
    sha256 TEXT NOT NULL, sha384 TEXT NOT NULL, version TEXT NOT NULL) WITHOUT ROWID]],
  "CREATE TABLE ca_roots (sha256 BLOB NOT NULL, label TEXT NOT NULL, der BLOB NOT NULL, " ..
    "distrust_after TEXT NOT NULL)",
  "CREATE TABLE ca_revoked (kind TEXT NOT NULL, name BLOB NOT NULL, value BLOB NOT NULL)",
}

local module_columns <const> = { "path", "file", "kind", "source_hash", "key",
  "bytecode", "tests", "source" }

--- Writes the database of `names` at `file` (see [`Store.seal`]), with
--- `identity`, the meta rows to record, and `main`. False and why on a
--- failure.
local function write_database(names: {string}, file: string, main: string?,
                              identity: {{string}}, script: Store.Extra?): boolean, string
  local binary = Store.databases()
  local binary_db = binary[#binary]
  local present: mut {string:boolean} = {}
  for _, name in ipairs(names) do
    present[name] = true
  end
  local out, open_trouble = Sqlite.open(file, { writable = true })
  if out == nil then
    return false, file .. ": " .. open_trouble
  end
  local db: Handle = out
  local function fill(): boolean, string
    for _, statement in ipairs(seal_schema) do
      local ok, why = db:exec(statement)
      if not ok then
        return false, why
      end
    end
    return Sqlite.transact(db, function(): boolean, string
      local zones, roots, web = false, false, false
      for _, name in ipairs(names) do
        local source, locate_trouble = locate(name)
        if source == nil then
          return false, name .. ": " .. locate_trouble
        end
        -- The key is the compile's, which only the tree that compiled the
        -- module can use, and `tests` names the tree's tests, which a
        -- program never runs: both left empty, so the bytes are a
        -- function of what the program runs and of its source.
        local copied, why = copy_rows(source, db, "modules", module_columns,
          "SELECT path, file, kind, source_hash, X'', bytecode, '', source " ..
            "FROM modules WHERE path = ?1", { text(name) })
        if not copied then
          return false, why
        end
        -- Every edge, within the set or not, as the database it came from
        -- holds them: a compile that resolves the module follows each. A
        -- database the core reads need not have the table (one attached
        -- by hand), and gives none.
        local has_edges, has_trouble = Sqlite.text_rows(source,
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'decl_imports'")
        if has_edges == nil then
          return false, "decl_imports: " .. has_trouble
        end
        if #has_edges > 0 then
          local edges_copied, edges_why = copy_rows(source, db, "decl_imports",
            { "path", "requires" },
            "SELECT path, requires FROM decl_imports WHERE path = ?1 ORDER BY requires",
            { text(name) })
          if not edges_copied then
            return false, edges_why
          end
        end
        -- Only edges within the set: one left out (by type alone) would
        -- dangle, and a closure of the sealed program would raise on it.
        local edges, edge_trouble = Sqlite.text_rows(source,
          "SELECT requires FROM imports WHERE path = ?1 ORDER BY requires",
          { text(name) })
        if edges == nil then
          return false, "imports: " .. edge_trouble
        end
        for _, edge in ipairs(edges) do
          if present[edge:text(1)] == true then
            local inserted, insert_trouble = Sqlite.run(db,
              "INSERT OR IGNORE INTO imports (path, requires) VALUES (?1, ?2)",
              { text(name), text(edge:text(1)) })
            if not inserted then
              return false, "imports: " .. insert_trouble
            end
          end
        end
        zones = zones or name == "cosmic.time"
        roots = roots or name == "cosmic.http"
        web = web or name == "cosmic.web.htmx"
      end
      if script ~= nil then
        -- Last, so the rows' order is the same whatever the script is.
        local added, why = Sqlite.run(db,
          "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
            "VALUES (?1, ?2, 'main', ?3, X'', ?4, '', ?5)",
          { text(script.name), text(script.name), { blob = Hash.sha256(script.source) },
            { blob = script.bytecode }, { blob = script.source } })
        if not added then
          return false, script.name .. ": " .. why
        end
        for _, edge in ipairs(script.requires or {}) do
          if present[edge] == true then
            local inserted, insert_trouble = Sqlite.run(db,
              "INSERT OR IGNORE INTO imports (path, requires) VALUES (?1, ?2)",
              { text(script.name), text(edge) })
            if not inserted then
              return false, "imports: " .. insert_trouble
            end
          end
        end
      end
      -- The zones cosmic.time falls back on where the host has none, and
      -- the roots core/http.c trusts and the files cosmic.web serves: carried
      -- only for a program that holds the module that reads them.
      if zones then
        local copied, why = copy_rows(binary_db, db, "zoneinfo", { "name", "data" },
          "SELECT name, data FROM zoneinfo ORDER BY name")
        if not copied then
          return false, why
        end
      end
      if web then
        -- A binary from before the table has none to carry.
        local has_web, has_trouble = Sqlite.text_rows(binary_db,
          "SELECT 1 FROM sqlite_master WHERE name = 'web_assets'")
        if has_web == nil then
          return false, has_trouble
        end
        if #has_web > 0 then
          local copied, why = copy_rows(binary_db, db, "web_assets",
            { "name", "data", "sha256", "sha384", "version" },
            "SELECT name, data, sha256, sha384, version FROM web_assets ORDER BY name")
          if not copied then
            return false, why
          end
        end
      end
      if roots then
        local copied, why = copy_rows(binary_db, db, "ca_roots",
          { "sha256", "label", "der", "distrust_after" },
          "SELECT sha256, label, der, distrust_after FROM ca_roots ORDER BY sha256")
        if not copied then
          return false, why
        end
        copied, why = copy_rows(binary_db, db, "ca_revoked", { "kind", "name", "value" },
          "SELECT kind, name, value FROM ca_revoked ORDER BY rowid")
        if not copied then
          return false, why
        end
      end
      -- What the program was made to run on and as.
      for _, pair in ipairs(identity) do
        local inserted, trouble = Sqlite.run(db,
          "INSERT INTO meta (key, value) VALUES (?1, ?2)", { text(pair[1]), text(pair[2]) })
        if not inserted then
          return false, trouble
        end
      end
      if main ~= nil then
        return Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('main', ?1)",
          { text(main) })
      end
      return true, ""
    end)
  end
  local ok, why = fill()
  local _, _ = db:close()
  if not ok then
    return false, why
  end
  return true, ""
end

--- Writes a database holding exactly the modules `names` and returns its
--- digest, the SHA-256 of its bytes in hex: a program's own store, which
--- a process started on it searches in place of the tree's. Each
--- module's row is the one the store's search order answers with
--- (attached databases first, but the binary's own for `cosmic.*` and
--- the wrappers of raw bindings), carried with the `imports` rows of
--- those modules, and the `meta` rows a program needs to run: its
--- `core_sha256` (the digest of the core that seals, which a core started
--- on the file refuses to run unless it is its own), `runtime_basis` and
--- `image_hash`, and `main` when `opts.main` names
--- the module to run (one of `names`). Only the `imports` rows between
--- the names given go along. Nothing else of the store goes
--- along -- no docs, tests, catalog or notices -- except the time zones,
--- only when `names` holds [`cosmic.time`], and the CA roots, only when
--- it holds [`cosmic.http`]. `names` is taken as the whole program, so it
--- is usually [`Store.closure`]'s answer: a module it requires but
--- leaves out is one the program cannot load.
---
--- The bytes depend only on the rows (written in order, then vacuumed),
--- so sealing the same names twice, in any checkout of the same tree run
--- by the same core (its SQLite version is in the file's header), writes
--- the same file. A module's `source` is among the rows -- an error's
--- line is read from it -- so an edit to a comment moves the digest; the
--- tests that name a module, and its compile key, do not. It is written whole or not at all.
--- With no `path` it goes to `<cache>/sandbox/<digest>.db` under
--- [`Fs.cache_dir`], where a file of that digest is its own content.
---
--- `opts.extra` adds one module the store does not hold, a script compiled
--- this run, as the main (kind `main`, after the others): `names` may then
--- be empty, and nothing else of the row is the store's. Its name is none
--- of the sealed names, nor a module any searched database holds, nor under
--- `cosmic.`: it raises rather than shadow one.
---
--- `opts.extra` is bytecode the caller made, which nothing checks as
--- [`Store.attach`] explains: it also needs `opts.unchecked_bytecode = true`,
--- or this raises naming it. A project build refuses `extra`.
---
--- The modules of a sealed database are the program's own, and run with
--- the trust any program the user can read runs with, raw bindings
--- included: seal only what the user chose to run. Raises when `names`
--- is not a non-empty list, names a module no searched database holds,
--- or `opts.main` is not among them; otherwise nil and why for a failure
--- to write, when the store records no `runtime_basis`, or when this process
--- has no core digest to record (one run from source, with no core of its
--- own).
---
---     local names = Store.closure({ "cosmic.json" })
---     local digest = assert(Store.seal(names, "json.db"))
function Store.seal(names: {string}, path?: string,
                    opts?: Store.SealOptions): string?, string
  local script = opts ~= nil and opts.extra or nil
  if type(names) ~= "table" or (#names == 0 and script == nil) then
    error("store: seal: names is a non-empty list of module names", 2)
  end
  local sorted: mut {string} = {}
  local present: mut {string:boolean} = {}
  for _, name in ipairs(names) do
    if present[name] ~= true then
      present[name] = true
      sorted[#sorted + 1] = name
    end
  end
  table.sort(sorted)
  local main = opts ~= nil and opts.main or nil
  if script ~= nil then
    if opts ~= nil and opts.unchecked_bytecode ~= true then
      error("store: seal: extra is bytecode loaded unchecked; " ..
          "pass unchecked_bytecode = true to say so", 2)
    end
    if main ~= nil then
      error("store: seal: main and extra are both given: the extra module is the main", 2)
    end
    if type(script.name) ~= "string" or type(script.bytecode) ~= "string" or
        type(script.source) ~= "string" then
      error("store: seal: extra holds a name, bytecode and source, all text", 2)
    end
    if present[script.name] == true then
      error("store: seal: extra " .. script.name .. " is also one of the names sealed", 2)
    end
    -- A name a program's own `require` would find in the store (or in the
    -- core's namespace) is not one to take over.
    local holder, _ = locate(script.name)
    if script.name:sub(1, 7) == "cosmic." or holder ~= nil then
      error("store: seal: extra " .. script.name .. " is a module the store holds or the " ..
          "core's namespace, which a main must not shadow", 2)
    end
    main = script.name
  elseif main ~= nil and present[main] ~= true then
    error("store: seal: main " .. main .. " is not among the modules sealed", 2)
  end
  for _, name in ipairs(sorted) do
    local _ = located(name)
  end
  local basis = Store.meta("runtime_basis")
  if basis == nil or basis == "" then
    return nil, "the store records no runtime basis"
  end
  -- The core's digest is what the core started on this file checks
  -- (`core_sha256`): the database is for the core that sealed it.
  local core = Store.meta("host_image")
  if core == nil or core == "" then
    return nil, "this process has no core digest to record"
  end
  local identity: mut {{string}} = { { "core_sha256", core }, { "runtime_basis", basis } }
  local image = Store.meta("image_hash")
  if image ~= nil then
    table.insert(identity, 1, { "image_hash", image })
  end
  local made_scratch, scratch_trouble = Fs.mkdtemp("seal-")
  if made_scratch == nil then
    return nil, scratch_trouble
  end
  local scratch: string = made_scratch
  local function build(): string?, string
    local written, write_trouble = write_database(sorted, scratch .. "/building.db",
      main, identity, script)
    if not written then
      return nil, write_trouble
    end
    local vacuumed, open_trouble = Sqlite.open(scratch .. "/building.db")
    if vacuumed == nil then
      return nil, open_trouble
    end
    local moved, why = Sqlite.run(vacuumed, "VACUUM INTO ?1", { text(scratch .. "/sealed.db") })
    local _, _ = vacuumed:close()
    if not moved then
      return nil, why
    end
    local bytes, read_trouble = Fs.read(scratch .. "/sealed.db")
    if bytes == nil then
      return nil, read_trouble
    end
    local digest = Hash.hex_sha256(bytes)
    local target = path
    if target == nil then
      -- TODO: prune this directory: nothing removes a sealed database
      -- once its run is over, so it grows with every distinct program
      -- sealed with no path (`cosmic sandbox` seals into a directory of
      -- its own, removed after the run). The test runner (build.test)
      -- should own it, deleting what no recorded run names, once it seals
      -- through this.
      local dir, dir_trouble = Fs.cache_dir("sandbox")
      if dir == nil then
        return nil, dir_trouble
      end
      target = dir .. "/" .. digest .. ".db"
    end
    local saved, save_trouble = Fs.write(target, bytes)
    if not saved then
      return nil, save_trouble
    end
    return digest, ""
  end
  local digest, trouble = build()
  local _, _ = Fs.remove_tree(scratch)
  if digest == nil then
    return nil, trouble
  end
  return digest, ""
end

return Store
