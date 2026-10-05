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
    types: boolean
  end

  --- What [`Store.seal`] is told beyond the modules to carry.
  record SealOptions
    --- The module the sealed program runs, recorded as the database's
    --- `main`. It must be one of the sealed names. Without it the database
    --- names no main.
    main: string
  end
end

--- Opens a projected module database and searches it ahead of every other.
function Store.attach(path: string): boolean, string
  local ok, trouble = store.attach(path)
  if not ok then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- One module's compiled bytes, for a caller that must load the chunk in
--- an environment of its own; nil and why for none.
function Store.bytecode(name: string): string | nil, string
  return store.bytecode(name)
end

--- One entry of the meta table, which is where a build records what it
--- decided. Nil when no database holds that key.
function Store.meta(key: string): string | nil
  return store.meta(key)
end

--- One module's Teal source, or a declaration's, from the binary's own
--- database and no other: what a checker building another tree needs
--- to type a `require` of this one's modules. Stored deflated, it is
--- inflated here; nil beside why when there is no such row or it will
--- not inflate.
function Store.source(name: string): string | nil, string
  return store.source(name)
end

--- The names the binary's own `imports` table records the module
--- `name` requiring, sorted: none for a name it holds no row of. Nil
--- and why when the query failed.
--- This walks the binary's module graph without a handle on every
--- module's rows (`databases`).
function Store.requires(name: string): {string} | nil, string
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
function Store.zoneinfo(name: string): string | nil, string
  return store.zoneinfo(name)
end

--- Every time zone name the binary's own database carries, as a set,
--- or nil and why when the query failed.
function Store.zone_names(): {string:boolean} | nil, string
  return store.zone_names()
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
local function locate(name: string, required?: string): Handle | nil, string
  local databases = Store.databases()
  local count = #databases
  local binary_first = reserved(name)
  for step = 1, count do
    local db = databases[binary_first and count + 1 - step or step]
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
    (required ~= nil and ", required by " .. required or "")
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
    { text(name), { integer = types and 1 or 0 } })
  if rows == nil then
    error("store: " .. name .. ": " .. trouble, 3)
  end
  local out: {string} = {}
  for index, row in ipairs(rows) do
    out[index] = row[1]
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
--- the literal names handed to `require`: a `pcall(require, ...)` or a
--- computed name is none, so a program that loads one so fails when it
--- runs sealed. Raises naming a root, or a module a root requires, that
--- no searched database holds, and for a `roots` that is not a list.
---
---     local names = Store.closure({ "cosmic.json" })
---     print(#names, names[1])
-- TODO: follow `pcall(require, ...)` too, once build.ast.requires sees
-- it (the TODO in build/embed.tl): until then such a require is no edge.
function Store.closure(roots: {string}, opts?: Store.ClosureOptions): {string}
  if type(roots) ~= "table" then
    error("store: closure: roots is a list of module names, not a " .. type(roots), 2)
  end
  local types = opts ~= nil and opts.types == true
  local seen: {string:boolean} = {}
  local names: {string} = {}
  local stack: {string} = {}
  local required_by: {string} = {}
  for _, root in ipairs(roots) do
    stack[#stack + 1] = root
  end
  while #stack > 0 do
    local required = required_by[#stack]
    required_by[#stack] = nil
    local name = table.remove(stack)
    if not seen[name] then
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

local function value_of(cell: Sqlite.Cell): Sqlite.Value
  if cell.kind == "null" then
    return {}
  end
  if cell.kind == "blob" then
    return { blob = cell.blob }
  end
  if cell.kind == "integer" then
    return { integer = cell.integer }
  end
  if cell.kind == "number" then
    return { number = cell.number }
  end
  return text(cell.text)
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
  local slots: {string} = {}
  for index = 1, #columns do
    slots[index] = "?" .. index
  end
  local insert = "INSERT OR IGNORE INTO " .. table_name .. " (" ..
    table.concat(columns, ", ") .. ") VALUES (" .. table.concat(slots, ", ") .. ")"
  for _, row in ipairs(rows) do
    local bound: {Sqlite.Value} = {}
    for index, cell in ipairs(row) do
      bound[index] = value_of(cell)
    end
    local ok, why = Sqlite.run(into, insert, bound)
    if not ok then
      return false, table_name .. ": " .. why
    end
  end
  return true, ""
end

--- The tables of a program database, as the core reads them
--- (core/store.c): module rows, their requires, declaration sources
--- (empty here: only a type checker reads one), the zones and CA roots
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
  "CREATE TABLE decls (path TEXT PRIMARY KEY, source BLOB NOT NULL) WITHOUT ROWID",
  "CREATE TABLE zoneinfo (name TEXT PRIMARY KEY, data BLOB NOT NULL)",
  "CREATE TABLE ca_roots (sha256 BLOB NOT NULL, label TEXT NOT NULL, der BLOB NOT NULL)",
}

local module_columns <const> = { "path", "file", "kind", "source_hash", "key",
  "bytecode", "tests", "source" }

--- Writes the database of `names` at `file` (see [`Store.seal`]), with
--- `identity`, the meta rows to record, and `main`. False and why on a
--- failure.
local function write_database(names: {string}, file: string, main: string | nil,
                              identity: {{string}}): boolean, string
  local binary = Store.databases()
  local binary_db = binary[#binary]
  local present: {string:boolean} = {}
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
      local zones, roots = false, false
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
        -- Only edges within the set: one left out (by type alone) would
        -- dangle, and a closure of the sealed program would raise on it.
        local edges, edge_trouble = Sqlite.text_rows(source,
          "SELECT requires FROM imports WHERE path = ?1 ORDER BY requires",
          { text(name) })
        if edges == nil then
          return false, "imports: " .. edge_trouble
        end
        for _, edge in ipairs(edges) do
          if present[edge[1]] then
            local inserted, insert_trouble = Sqlite.run(db,
              "INSERT OR IGNORE INTO imports (path, requires) VALUES (?1, ?2)",
              { text(name), text(edge[1]) })
            if not inserted then
              return false, "imports: " .. insert_trouble
            end
          end
        end
        zones = zones or name == "cosmic.time"
        roots = roots or name == "cosmic.http"
      end
      -- The zones cosmic.time falls back on where the host has none, and
      -- the roots core/http.c trusts: carried only for a program that
      -- holds the module that reads them.
      if zones then
        local copied, why = copy_rows(binary_db, db, "zoneinfo", { "name", "data" },
          "SELECT name, data FROM zoneinfo ORDER BY name")
        if not copied then
          return false, why
        end
      end
      if roots then
        local copied, why = copy_rows(binary_db, db, "ca_roots",
          { "sha256", "label", "der" },
          "SELECT sha256, label, der FROM ca_roots ORDER BY sha256")
        if not copied then
          return false, why
        end
      end
      -- What the program was made to run on and as. No identity of the
      -- core is recorded yet.
      -- TODO: record the core's digest here, once the core's --database
      -- start (PR for claude/core-database) names its meta key; the core
      -- refuses a database written for another.
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
--- `runtime_basis` and `image_hash`, and `main` when `opts.main` names
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
--- The modules of a sealed database are the program's own, and run with
--- the trust any program the user can read runs with, raw bindings
--- included: seal only what the user chose to run. Raises when `names`
--- is not a non-empty list, names a module no searched database holds,
--- or `opts.main` is not among them; otherwise nil and why for a failure
--- to write, or when the store records no `runtime_basis`.
---
---     local names = Store.closure({ "cosmic.json" })
---     local digest = assert(Store.seal(names, "json.db"))
function Store.seal(names: {string}, path?: string,
                    opts?: Store.SealOptions): string | nil, string
  if type(names) ~= "table" or #names == 0 then
    error("store: seal: names is a non-empty list of module names", 2)
  end
  local sorted: {string} = {}
  local present: {string:boolean} = {}
  for _, name in ipairs(names) do
    if not present[name] then
      present[name] = true
      sorted[#sorted + 1] = name
    end
  end
  table.sort(sorted)
  -- TODO: test that a process boots on a sealed database once the
  -- core's --database start (PR for claude/core-database) lands; until
  -- then no test runs one.
  local main = opts ~= nil and opts.main or nil
  if main ~= nil and not present[main] then
    error("store: seal: main " .. main .. " is not among the modules sealed", 2)
  end
  for _, name in ipairs(sorted) do
    local _ = located(name)
  end
  local basis = Store.meta("runtime_basis")
  if basis == nil or basis == "" then
    return nil, "the store records no runtime basis"
  end
  local identity: {{string}} = { { "runtime_basis", basis } }
  local image = Store.meta("image_hash")
  if image ~= nil then
    table.insert(identity, 1, { "image_hash", image })
  end
  local scratch, scratch_trouble = Fs.mkdtemp("seal-")
  if scratch == nil then
    return nil, scratch_trouble
  end
  local function build(): string | nil, string
    local written, write_trouble = write_database(sorted, scratch .. "/building.db",
      main, identity)
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
      -- once its run is over, so it grows with every distinct program.
      -- The test runner (build.test) should own it, deleting what no
      -- recorded run names, once it seals through this.
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
