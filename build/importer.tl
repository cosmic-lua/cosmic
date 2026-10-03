--- The staged tree, read by position into modules.
---
--- A source's path relative to the root is its import path, so nothing
--- lists what a module is: [`cosmic/fs.tl`] is [`cosmic.fs`]. A `*.d.tl`
--- declares a module the core provides and holds no code, so it is read
--- for its type and never stored.
---
--- Nothing here reads a path: [`build.work`] has already staged every
--- input into the working database, and the tree is the rows of its
--- `files` table, which its `inputs` view reads by position. What a
--- build derives beyond that -- the test module a doc guide extracts
--- to, the declaration the syscall header generates to, and what one
--- parse of each source finds -- is written back as rows too, each
--- keyed so it is redone only when what it came from changed, and the
--- modules to compile are a query over them.
---
--- A module's key is its kind, the content hash of its source, the
--- keys of everything it imports, and the identity of the compiler
--- that compiled it -- see [`build.identity`]'s `Identities`. An unchanged
--- key is a stat; a changed one recompiles what depended on it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local identities = require("build.identity")
local analysis_schema = require("build.analysis_schema")
local positions = require("build.positions")
local receivers = require("build.receivers")
local symbols = require("build.symbols")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local type compiler = require("build.compiler")
local bind = require("build.bind")
local plural = require("build.plural")

local compilation = require("build.compilation")
local derivation = require("build.derivation")

local type Module = compilation.Module
local type Source = derivation.Source

local record importer
  Module: Module

  --- Where the code that analyzes is read from, as [`Store.requires`]
  --- and [`Store.source`] read it of the binary ([`importer.tree_code`]
  --- reads it of the tree): what a module requires among the modules a
  --- build plans, of which a declaration alone is none, sorted; and a
  --- module's source, a declaration's ahead of a module's of the same
  --- name. `compiler` is the identity of the compiler it runs beside
  --- ([`build.identity`]'s `Identities`).
  record Code
    compiler: string
    requires: function(string): {string} | nil, string
    source: function(string): string | nil, string
  end

  record Result
    modules: {Module}
    --- The compiler identity every key in `modules` carries.
    tool: string
    main: string | nil
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: {string}
    -- How many modules were compiled this run, and how many came back
    -- from `compiled` under a key that stood.
    compiled: integer
    cached: integer
    --- How many of those `cached` came from the compiles every
    --- checkout shares ([`Shared`]) rather than this one's own.
    shared: integer
    --- What the derive the compile began with parsed.
    parses: derivation.Parses
  end

  --- What a derive parsed ([`importer.derive`]): how many sources it
  --- parsed, and how many more another checkout's parse stood in for.
  Parses: derivation.Parses

  --- The compiles and parses every checkout shares
  --- ([`build.shared_compiles`]), as the caller that opened them hands
  --- them to `derive` and `compile`: looked in when a source or a
  --- module misses this checkout's own, and given every parse, and
  --- every compile that is not refused, made here.
  record Shared
    --- One compile: what a compile writes of a module.
    record Compile
      lua: string
      bytecode: string
      --- The record-field uses its checker found (`typed_refs`).
      references: {receivers.Reference}
    end
    --- One parse: what a parse writes of a source in every table
    --- `analysis_tables` names.
    Parse: derivation.Parse
    --- The analyzers another checkout parsed every one of `hashes`
    --- with, the most lately used first.
    analyzers: function(hashes: {string}): {string}
    --- What `analyzer` found each of `hashes` requires, by hash, of
    --- those it parsed: a guess, read without its row's digest.
    requires: function(analyzer: string, hashes: {string}): {string:{string}}
    --- The parse `analyzer` made of the source `hash`, its docs' lines
    --- `mapped` or not ([`build.derivation`]'s `origin_lines`), or nil.
    parse: function(analyzer: string, hash: string, mapped: boolean): derivation.Parse | nil
    --- Offers a parse `analyzer` made here to every other checkout.
    offer: function(analyzer: string, hash: string, mapped: boolean, made: derivation.Parse)
    --- The compile another checkout made of `m` in a tree that is or
    --- is not cosmic's own, or nil.
    look: function(m: Module, own_tree: boolean): Compile | nil
    --- Offers a compile of `m` made here to every other checkout.
    keep: function(m: Module, own_tree: boolean, made: Compile)
    --- Writes what was offered; `compile` calls it once, as it ends,
    --- whether or not it compiled everything, and after it nothing is
    --- looked up or offered.
    finish: function()
  end

  --- The statement that drops the record-field uses of every compile
  --- `compiled` no longer holds, run at the end of each compile.
  prune_references: string

  --- The worked examples a checker diagnostic points its reader to
  --- (`cosmic docs <name>`), by the kind of diagnostic:
  --- [`build.tree_checks`] holds the tree to answering each.
  diagnostic_queries: {string: string}
end

importer.diagnostic_queries = {
  arguments = "generics_functions_returns",
  record_key = "records_interfaces_methods",
}

-- `NOT IN (SELECT key FROM compiled)` leads SQLite to probe
-- `compiled`'s primary key once per `typed_refs` row ("USING INDEX
-- sqlite_autoindex_compiled_1 FOR IN-OPERATOR"), and that key is the
-- WITHOUT ROWID table itself, its `lua` and `bytecode` inline, so each
-- probe reads the overflow chain of every cell it compares: on
-- cosmic's own tree, about 5900 rows cost 200,000-780,000 pread64
-- calls (two measurements, by the database's layout) and 300-390 ms
-- of a warm build that otherwise takes about 200. The unary `+` makes
-- `key` an expression, which SQLite's documented rule keeps from
-- using an index, so the planner reads `compiled` once into a list
-- ("LIST SUBQUERY") and the statement takes about 2 ms. Neither `key`
-- is ever NULL (`typed_refs`' is declared so, `compiled`'s is a
-- WITHOUT ROWID primary key), so `NOT IN` meets no NULL.
importer.prune_references =
  "DELETE FROM typed_refs WHERE key NOT IN (SELECT +key FROM compiled)"

--- The derivation and the extractors, generators and parser it calls:
--- the roots of
--- [`importer.analyzer_modules`]. "The analyzer" in these names is that
--- whole set, of which the source analyzer [`build.analyzer`] is one.
--- Each is a root of the compiler's identity too ([`build.identity`]'s
--- `compiler_roots`), which the analyzer's starts from. The schema of the
--- rows a parse stores ([`build.analysis_schema`]) is among them: what a
--- source parses to is recorded in its columns.
local analyzer_roots: {string} = {
  "build.derivation", "build.analysis_schema", "build.analyzer", "build.ast", "build.bind",
  "build.compiler", "build.doctest", "build.gen_syscalls", "build.link_text",
}

--- The modules whose code decides what the analysis tables record: the
--- derivation and every module that its extractors, generators and
--- parser reach through `require`,
--- as `code` records it: the running binary's own `imports` table by
--- default. What a source parses to is a function of these and of the
--- compiler, and of nothing else in the tool. Cache coordination and
--- diagnostic presentation belong to the importer, outside this closure.
function importer.analyzer_modules(code?: importer.Code): {string} | nil, string
  -- A name at a time ([`Store.requires`]), not a query of a handle on
  -- the binary's database: under a test worker's hold on the store
  -- each lookup is held as a lookup of that module is, where a handle
  -- would read every module's rows.
  local requires = code ~= nil and code.requires or Store.requires
  local source_of = code ~= nil and code.source or Store.source
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(analyzer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do
    -- What the binary holds a module or a declaration of: what
    -- [`Store.source`] answers, of a name no hold holds.
    local source, _ = source_of(name)
    if source ~= nil then names[#names + 1] = name end
  end
  table.sort(names)
  return names, ""
end

local text = bind.text

--- The tables a parse or a generator fills ([`build.analysis_schema`]).
local analysis_tables = analysis_schema.tables

--- The code that analyzes as the tree holds it, staged in the working
--- database of `handle`: what [`importer.analyzer_modules`] and
--- [`importer.analyzer_identity`] read of the binary a boot writes, read
--- before that binary exists. A boot carries no database and runs the
--- tree's own code, so this is the code deriving in a boot. What a
--- module requires is what the last parse of its source found, and the
--- compiler's identity is taken over those finds too
--- ([`identities.compiler_identity`]): before a parse, a module whose source
--- is new has none, but its source alone already moves the identity.
function importer.tree_code(handle: work.Handle): importer.Code | nil, string
  local identity, trouble = identities.compiler_identity(handle.db)
  if identity == nil then
    return nil, trouble
  end
  local db = handle.db
  -- What the binary's `imports` holds ([`build.writer`]): the requires of
  -- each module the build plans, kept where they name a planned module.
  -- Every input but a declaration stands for a planned one here: the
  -- only others left out -- a test or an example the compile refuses,
  -- and every test and example once the tool's carried database drops
  -- them -- no analyzer module requires, so the walk from the analyzer
  -- never reaches them.
  local function requires(name: string): {string} | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
        "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
        "AND ?1 IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "AND r.name IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "ORDER BY r.name", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    local names: {string} = {}
    for _, row in ipairs(rows) do names[#names + 1] = row[1] end
    return names, ""
  end
  -- What [`Store.source`] answers: a declaration's source ahead of a
  -- module's.
  local function source(name: string): string | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT source FROM inputs WHERE path = ?1 " ..
        "ORDER BY kind = 'decl' DESC LIMIT 1", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    if #rows == 0 then
      return nil, "no module '" .. name .. "' in the tree"
    end
    return rows[1][1], ""
  end
  return { compiler = identity, requires = requires, source = source }, ""
end

--- The identity of the analyzer `code` holds: the compiler, and the
--- source of every one of [`importer.analyzer_modules`]. `code` defaults
--- to the running binary's, the code actually deriving; in a stale tool
--- rebuilding itself that is older than the tree's. A boot names the
--- tree's ([`importer.tree_code`]), the code it runs, so the tool it
--- writes finds the rows the boot derived as its own. A binary that
--- carries no source for one of them, or no record of what they import,
--- can only be named whole.
-- TODO: name the analyzer by what a parse runs alone -- the pins
-- (`runtime_basis`), build.derivation and these modules -- rather than
-- the whole compiler's identity, which build.teal, build.contracts,
-- build.receivers and build.tree move though no parse runs them, so an
-- edit to one parses every source again. Waits on a change that moves
-- every parse key at once, one of its own.
function importer.analyzer_identity(code?: importer.Code): string
  local parts: {string} = { code ~= nil and code.compiler or Store.meta("compiler") or "" }
  local modules, _ = importer.analyzer_modules(code)
  if modules == nil then
    return "binary " .. (Store.meta("boot_hash") or "")
  end
  local source_of = code ~= nil and code.source or Store.source
  for _, name in ipairs(modules) do
    local source, _ = source_of(name)
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = name .. "\n" .. source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- The identity of the analyzer that is running ([`importer.analyzer_identity`]):
--- the binary's, or in a boot, which carries no database, the tree's.
local function running_analyzer(handle: work.Handle): string | nil, string
  if Store.meta("boot_hash") ~= nil then
    return importer.analyzer_identity()
  end
  local code, trouble = importer.tree_code(handle)
  if code == nil then
    return nil, trouble
  end
  return importer.analyzer_identity(code)
end

--- Names the rows the analysis tables hold as derived by `identity`.
local function record_analyzer(db: Sqlite.Handle, identity: string): boolean, string
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
    { text(identity) })
end

--- What `meta` names the analysis tables' rows as derived by, "" for
--- none.
local function recorded_analyzer(db: Sqlite.Handle): string | nil, string
  local last, trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'analyzer'")
  if last == nil then
    return nil, trouble
  end
  return #last > 0 and last[1][1] or "", ""
end

--- Forgets every derived row: every parse, and every derivation but
--- the compiler's.
local function forget_analysis(db: Sqlite.Handle): boolean, string
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name)
    if not ok then
      return false, trouble
    end
  end
  return db:exec("DELETE FROM derived WHERE origin <> 'vendor'")
end

--- Forgets every derived row when the code that derives them has
--- changed since they were made, and answers whether it did. A row
--- keyed by its source's hash is found again for as long as that
--- source stands, which is right only while the analyzer stands too: an
--- extractor that learns to see something new, or a generator that
--- emits differently, must see every source again. The analyzer is
--- named by the code that is running it ([`running_analyzer`]), not by
--- the tree: a stale tool rebuilding itself derives and parses with its
--- own, older code before the new tool re-enters, and must not leave
--- rows the new tool takes for its own. Only a change to that code
--- reparses everything; an edit anywhere else in the tool reparses just
--- what it edited. A boot does not forget as a side effect of being one:
--- the analyzer's name is a function of the compiler, the pins and the
--- Teal sources it reaches, and of nothing else, so a change to the
--- core's C or build.zig does not move it, by design.
local function forget_stale_analysis(handle: work.Handle): boolean | nil, string
  local db = handle.db
  local identity, identity_trouble = running_analyzer(handle)
  if identity == nil then
    return nil, identity_trouble
  end
  local last, last_trouble = recorded_analyzer(db)
  if last == nil then
    return nil, last_trouble
  end
  if last == identity then
    return false, ""
  end
  local forgot, forget_trouble = forget_analysis(db)
  if not forgot then
    return nil, forget_trouble
  end
  local recorded, record_trouble = record_analyzer(db, identity)
  if not recorded then
    return nil, record_trouble
  end
  return true, ""
end

--- Forgets every compile, and the record-field uses found with it,
--- when the code that finds those uses has changed since: a compile
--- whose key stands is never checked again, so a `typed_refs` row is
--- only as right as the [`build.receivers`] that ran beside the checker.
local function forget_stale_receivers(db: Sqlite.Handle): boolean, string
  local identity, identity_trouble = compilation.receivers_identity(db)
  if identity == nil then
    return false, identity_trouble
  end
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'receivers'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1][1] == identity then
    return true, ""
  end
  for _, statement in ipairs({ "DELETE FROM compiled", "DELETE FROM typed_refs" }) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('receivers', ?1)",
    { text(identity) })
end

--- What a boot names its analyzer ([`running_analyzer`]) with `guessed`,
--- by hash, written as `requires` rows for the while, then taken back.
local function named_over(handle: work.Handle,
                          guessed: {string:{string}}): string | nil, string
  local db = handle.db
  local begun, begin_trouble = db:exec("SAVEPOINT shared_analyzer")
  if not begun then return nil, begin_trouble end
  local function named(): string | nil, string
    for hash, names in pairs(guessed) do
      for ordinal, name in ipairs(names) do
        local ok, why = Sqlite.run(db,
          "INSERT OR REPLACE INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
          { text(hash), { integer = ordinal }, text(name) })
        if not ok then return nil, why end
      end
    end
    return running_analyzer(handle)
  end
  local identity, identity_trouble = named()
  local _, _ = db:exec("ROLLBACK TO shared_analyzer")
  local _, _ = db:exec("RELEASE shared_analyzer")
  if identity == nil then return nil, identity_trouble end
  return identity, ""
end

--- The analyzer whose shared parses of `sources` are this tree's own:
--- "" for none.
---
--- A tool names the analyzer running it by what it carries
--- ([`importer.analyzer_identity`]), which no parse here moves, so its
--- name stands before the parse as after it, and its parses are the
--- ones to take. A boot names it by the tree ([`importer.tree_code`]),
--- whose `requires` rows decide which modules the name covers, so
--- before a parse it is inexact: on a fresh working database it covers
--- the roots alone. So a boot asks the cache instead, for a fixed point.
--- For each analyzer X that parsed this tree's own
--- analyzer roots (`analyzer_roots`) -- few: one
--- per state of those roots the cache keeps -- it writes the `requires`
--- rows X found of these sources, names the tree's analyzer over them,
--- and takes those rows back. When the name is X, X's parses are this
--- tree's:
---
--- - X is a digest of the compiler's identity and of each analyzer
---   module's name and source, so naming it again over this tree's
---   sources lists the same modules and sources X did, and the same
---   compiler: X's code is the code this boot runs.
--- - A parse is a function of that code and the source alone, so X's
---   parse of each of these sources, `requires` rows included, is the
---   parse this boot would make, and the rows that named X are what the
---   boot's own parse would have written -- a fixed point: parsing with
---   X yields the rows that name X.
---
--- The `requires` rows it guesses by are read without their rows'
--- digests, so they can only lead astray to a name that is not X,
--- which declines X, or to X where some row is damaged: that row's
--- digest fails when it is taken, the source is parsed here, and
--- [`importer.derive`] checks the name again after the parse, forgetting
--- every row and parsing the tree afresh if it moved. Where no X names
--- itself -- the cache holds no parse of the tree's analyzer as it is
--- here -- every source is parsed here, and its rows are offered under
--- the name the whole parse settles on.
---
--- Before that trial, which costs tens of milliseconds, X is passed over
--- where the modules its `requires` rows reach from the roots include
--- one it holds no parse of (`unguessed`): the roots change less often
--- than what they reach, so X's of several states of the rest can
--- gather. Only the trial accepts an X.
-- Nothing but the compiler, the pins and the analyzer's Teal sources is
-- in X, by design ([`forget_stale_analysis`]): the core's C, which runs
-- the parse, is not, so a branch whose C parses otherwise shares rows
-- with main under the same X, as compiles do under their keys, and as
-- one checkout switching between the two keeps its rows. The semantic
-- row encoding belongs to build.derivation, in X; the outer shared-cache
-- format is versioned by build.shared_compiles' `parsed_version`.
local function shared_analyzer(handle: work.Handle, shared: importer.Shared,
                               sources: {Source}): string | nil, string
  if Store.meta("boot_hash") ~= nil then
    return running_analyzer(handle)
  end
  local db = handle.db
  local roots: {string} = {}
  for _, name in ipairs(analyzer_roots) do roots[#roots + 1] = name end
  local found, trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT source_hash FROM inputs WHERE kind <> 'decl' " ..
      "AND path IN (SELECT value FROM json_each(?1)) ORDER BY source_hash",
    { text('["' .. table.concat(roots, '","') .. '"]') })
  if found == nil then return nil, trouble end
  if #found == 0 then return "", "" end
  local root_hashes: {string} = {}
  for _, row in ipairs(found) do root_hashes[#root_hashes + 1] = row[1] end
  local hashes: {string} = {}
  local fresh: {string:boolean} = {}
  for _, source in ipairs(sources) do
    hashes[#hashes + 1] = source.source_hash
    fresh[source.source_hash] = true
  end
  local planned, planned_trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash FROM inputs WHERE kind <> 'decl'")
  if planned == nil then return nil, planned_trouble end
  local hash_of: {string:string} = {}
  for _, row in ipairs(planned) do hash_of[row[1]] = row[2] end
  -- A module the roots reach through `guessed`, and through the rows
  -- the tables hold of what is parsed already, of which `guessed` has
  -- no parse: "" for none.
  local function unguessed(guessed: {string:{string}}): string | nil, string
    local reached: {string:boolean} = {}
    local stack: {string} = {}
    for _, name in ipairs(roots) do stack[#stack + 1] = name end
    while #stack > 0 do
      local name = table.remove(stack)
      local hash = hash_of[name]
      if not reached[name] and hash ~= nil then
        reached[name] = true
        local names = guessed[hash]
        if fresh[hash] and names == nil then return name, "" end
        if names == nil then
          local rows, rows_trouble = Sqlite.text_rows(db,
            "SELECT name FROM requires WHERE source_hash = ?1 ORDER BY ordinal", { text(hash) })
          if rows == nil then return nil, rows_trouble end
          names = {}
          for _, row in ipairs(rows) do names[#names + 1] = row[1] end
        end
        for _, next_name in ipairs(names) do stack[#stack + 1] = next_name end
      end
    end
    return "", ""
  end
  for _, candidate in ipairs(shared.analyzers(root_hashes)) do
    local guessed = shared.requires(candidate, hashes)
    local missing, missing_trouble = unguessed(guessed)
    if missing == nil then return nil, missing_trouble end
    if missing == "" then
      local identity, identity_trouble = named_over(handle, guessed)
      if identity == nil then return nil, identity_trouble end
      if identity == candidate then return candidate, "" end
    end
  end
  return "", ""
end

--- Whether `identity` names an analyzer at all: one named by a binary
--- with no boot hash ([`importer.analyzer_identity`]) is every such
--- binary's, so no parse is shared under it.
local function nameless(identity: string): boolean
  return identity == "binary "
end

--- Takes the parse another checkout made of each of `sources` from
--- `shared`, where its analyzer is this tree's ([`shared_analyzer`]), and
--- writes it as the parse would have, counting it in `tally`; the rest
--- are left to [`derivation.parse_new`]. Answers that analyzer, "" for none.
local function take_parses(handle: work.Handle, shared: importer.Shared, sources: {Source},
                           tally: importer.Parses): string | nil, string
  local identity, trouble = shared_analyzer(handle, shared, sources)
  if identity == nil then return nil, trouble end
  if identity == "" or nameless(identity) then return "", "" end
  local db = handle.db
  local widths, widths_trouble = derivation.table_widths(db)
  if widths == nil then return nil, widths_trouble end
  for _, source in ipairs(sources) do
    local found = shared.parse(identity, source.source_hash, source.mapped)
    local rows = found ~= nil and derivation.unpacked_parse(found.rows, widths) or nil
    if found ~= nil and rows ~= nil then
      -- One the tables refuse is left to the parse, which says why.
      local put, _ = derivation.put_parse(db, source.source_hash, found.requires, rows)
      if put then tally.shared = tally.shared + 1 end
    end
  end
  return identity, ""
end

--- Offers `shared` the parse of each of `made`, made here by the
--- analyzer named `identity`.
local function offer_parses(db: Sqlite.Handle, shared: importer.Shared | nil, identity: string,
                            made: {Source}): boolean, string
  if shared == nil or #made == 0 or nameless(identity) then return true, "" end
  local packed, trouble = derivation.packed_parses(db, made)
  if packed == nil then return false, trouble end
  for _, source in ipairs(made) do
    local one = packed[source.source_hash]
    if one ~= nil then shared.offer(identity, source.source_hash, source.mapped, one) end
  end
  return true, ""
end

--- Derives and parses what the staged tree holds that the tables do
--- not, and drops what no input refers to any more ([`importer.derive`]).
--- A source another checkout parsed is taken from `shared` rather than
--- parsed ([`take_parses`]). Counts what it parsed and took in `tally`,
--- lists what it parsed in `made`, and answers the analyzer whose
--- parses it took, "" for none.
local function derive_new(handle: work.Handle, built: compiler, tally: importer.Parses,
                          made: {Source}, shared: importer.Shared | nil): string | nil, string
  local db = handle.db
  local swept, sweep_trouble = db:exec(
    "DELETE FROM derived WHERE origin <> 'vendor' AND NOT EXISTS " ..
      "(SELECT 1 FROM files f WHERE f.path = derived.file " ..
      "AND f.sha256 = derived.from_hash)")
  if not swept then
    return nil, sweep_trouble
  end
  local derived, derived_trouble = derivation.inputs(db)
  if not derived then return nil, derived_trouble end
  local taken = ""
  if shared ~= nil then
    local sources, sources_trouble = derivation.unparsed(db)
    if sources == nil then
      return nil, sources_trouble
    end
    if #sources > 0 then
      local identity, take_trouble = take_parses(handle, shared, sources, tally)
      if identity == nil then
        return nil, take_trouble
      end
      taken = identity
    end
  end
  local parsed, parse_trouble = derivation.parse_new(db, built, tally, made)
  if not parsed then
    return nil, parse_trouble
  end
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name ..
        " WHERE source_hash NOT IN (SELECT source_hash FROM inputs)")
    if not ok then
      return nil, trouble
    end
  end
  return taken, ""
end

--- Brings `derived` and the parse tables up to the staged tree, inside
--- the run's transaction: a derived row whose file changed or vanished goes, and
--- only what is new is extracted, generated, or parsed. The compiler's
--- row has no file and is Lua, so it is neither dropped nor parsed
--- here; the plan carries it. What no input refers to any more is
--- dropped, so the tables describe this tree and nothing older.
--- Both compile entry points do this once before planning modules. A
--- self-build records its identities afterward, since
--- [`identities.record_identities`] closes over the parsed `requires`.
--- @param self_tree whether the tree is cosmic's own, where the
---   `cosmic.` namespace is not reserved against the tree itself
--- @param built the compiler, loaded and ready
--- @param shared the parses every checkout shares, or nil for none: a
---   source another checkout's analyzer parsed, where that analyzer is
---   this one ([`shared_analyzer`]), is taken from them rather than
---   parsed, and every parse made here is offered them. This borrows the
---   cache; a compile entry point or the caller must finish it.
--- @return what it parsed and took, or nil and why it could not
function importer.derive(handle: work.Handle, self_tree: boolean,
                         built: compiler, shared?: importer.Shared): importer.Parses | nil, string
  local db = handle.db
  if not self_tree then
    local reserved, reserved_trouble = Fs.is_dir(handle.root .. "/cosmic")
    if reserved == nil then
      return nil, reserved_trouble
    end
    if reserved then
      return nil, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree"
    end
    local claimed, trouble = Sqlite.text_rows(db,
      "SELECT path FROM files WHERE path GLOB 'cosmic/*' ORDER BY path LIMIT 1")
    if claimed == nil then
      return nil, trouble
    end
    if #claimed > 0 then
      return nil, claimed[1][1] .. ": the 'cosmic' directory is reserved to " ..
        "cosmic's own tree"
    end
  end

  local tally: importer.Parses = { parsed = 0, shared = 0 }
  local made: {Source} = {}
  local forgotten, forget_trouble = forget_stale_analysis(handle)
  if forgotten == nil then
    return nil, forget_trouble
  end
  local taken, derive_trouble = derive_new(handle, built, tally, made, shared)
  if taken == nil then
    return nil, derive_trouble
  end
  if Store.meta("boot_hash") ~= nil then
    if shared ~= nil and #made > 0 then
      local identity, identity_trouble = running_analyzer(handle)
      if identity == nil then
        return nil, identity_trouble
      end
      local offered, offer_trouble = offer_parses(db, shared, identity, made)
      if not offered then
        return nil, offer_trouble
      end
    end
    return tally, ""
  end
  -- A boot names its analyzer again now that every source is parsed:
  -- what an analyzer module whose source is new requires is found only
  -- by this parse, and the tool the boot writes walks it
  -- ([`importer.tree_code`]). A name the parse moved when nothing was
  -- forgotten can only come of rows that were not the whole of a parse
  -- (one cut short, say), and a name other than that of the analyzer
  -- whose shared parses were taken only of one of them that was not
  -- what it seemed ([`shared_analyzer`]), so the rows are forgotten and
  -- the tree parsed again, here, rather than kept under a name they do
  -- not hold to.
  local before, before_trouble = recorded_analyzer(db)
  if before == nil then
    return nil, before_trouble
  end
  local after, after_trouble = running_analyzer(handle)
  if after == nil then
    return nil, after_trouble
  end
  if (after ~= before and not forgotten) or (taken ~= "" and after ~= taken) then
    local forgot, forgot_trouble = forget_analysis(db)
    if not forgot then
      return nil, forgot_trouble
    end
    -- What this pass parses is all the derive parsed, and none of it
    -- another checkout's.
    made = {}
    tally.parsed, tally.shared = 0, 0
    local again, again_trouble = derive_new(handle, built, tally, made, nil)
    if again == nil then
      return nil, again_trouble
    end
    after, after_trouble = running_analyzer(handle)
    if after == nil then
      return nil, after_trouble
    end
  end
  local recorded, record_trouble = record_analyzer(db, after)
  if not recorded then
    return nil, record_trouble
  end
  local offered, offer_trouble = offer_parses(db, shared, after, made)
  if not offered then
    return nil, offer_trouble
  end
  return tally, ""
end

--- Adds to an unused-variable or unused-argument warning the way to
--- silence it. tl's checker treats a name starting with `_` as
--- intentionally unused (`tl.lua`'s `var_name:sub(1, 1) == "_"` check),
--- but the warning for any other name does not say so, and every
--- warning is a refused compile on cosmic's paths (see `generate`).
--- Added here, where every message is rendered, rather than by patching
--- the vendored checker's text.
local function with_unused_hint(msg: string): string
  if msg:match("^unused variable ") or msg:match("^unused argument ") then
    return msg .. " -- name it _ or _<name> to mark it intentionally unused"
  end
  return msg
end

--- The bare name tl's checker names in a message reporting that
--- nothing by that name exists: "unknown variable: NAME" (a global
--- reference -- `os.time()`, once [`build.teal`] strips `os` from the
--- checker's own environment for exactly this) or "module not found:
--- 'NAME'" (a `require` of a literal string nothing provides). `nil`
--- for any other message, since only these two name a single missing
--- word worth looking up.
local function unresolved_name(msg: string): string
  return msg:match("^unknown variable: (.+)$") or
    msg:match("^module not found: '(.+)'$")
end

--- The databases a hint looks a name up in, and whether each is read as
--- the public standard library's, asked for only when a message earns a
--- hint: a handle on the store's databases is one a test worker's hold
--- on the store refuses ([`Store.databases`]), which a build that
--- compiles clean never asks for.
local type Hints = function(): {Sqlite.Handle}, {boolean}

--- Appends a pointer at whatever `cosmic docs` already answers for the
--- name a resolution failure names, when [`symbols.named`] finds it
--- exactly -- the same rule `cosmic docs <word>` itself matches by, so
--- this can never point somewhere that command would disagree with.
--- Only the symbol's name, never its documentation: the error already
--- says where to read that in full (`cosmic docs <name>`), and a
--- compile failure is not the place to reprint it.
local function with_docs_hint(msg: string, hints: Hints): string
  local name = unresolved_name(msg)
  if name == nil then
    return msg
  end
  local databases, public = hints()
  local found = symbols.named(databases, public, name)
  if #found == 0 then
    return msg
  end
  return msg .. " -- see also in docs: " .. table.concat(found, ", ")
end

--- Checker forms that reliably identify a language topic. Argument failures
--- point to the general checked function-contract guide; a diagnostic does
--- not carry enough AST binding information here to claim a particular call.
--- Only a message [`teal.replacement`] leaves unanswered is pointed here
--- ([`with_hint`]).
local function diagnostic_docs(msg: string): string | nil
  if msg:match("^wrong number of arguments %(") or
      msg:match("^argument %d+: got .+, expected ") then
    return importer.diagnostic_queries.arguments
  elseif msg:match("^invalid key '.-' in record ") then
    return importer.diagnostic_queries.record_key
  end
  return nil
end

local function with_diagnostic_docs(msg: string, hints: Hints): string
  local query = diagnostic_docs(msg)
  if query == nil then
    return msg
  end
  local databases, public = hints()
  if not symbols.has_example_query(databases, public, query) then
    return msg
  end
  return msg .. " -- see also: cosmic docs " .. query
end

--- Every hint a checker message earns, appended once, at the one place
--- every message is rendered, rather than patched into the vendored
--- checker's own text or duplicated at each call site. A message
--- [`teal.replacement`] answers says what to write instead, which a
--- reader acts on where a pointer at the docs goes unread, so it is
--- given no such pointer.
local function with_hint(msg: string, hints: Hints, answered: boolean): string
  local said = with_docs_hint(with_unused_hint(msg), hints)
  if answered then
    return said
  end
  return with_diagnostic_docs(said, hints)
end

--- `file`'s own complaints, one line each. A removed name's replacement
--- ([`teal.replacement`]) comes straight after the checker's own words,
--- ahead of any pointer at the docs: it is the answer, they are more.
--- A hint repeated word for word in one file (one variable's every
--- field read, each unused name's) is printed on the first line that
--- earns it, with how many more lines it holds for, and those lines
--- carry the checker's words alone.
local function complain(file: string, source: string, result: compiler.Result,
                        hints: Hints): string
  local lines: {string} = {}
  local hinted: {string:integer} = {}
  local repeats: {integer:integer} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or {}) do
      local where = e.filename ~= "" and e.filename or file
      local instead = where == file and teal.replacement(e.msg, source, e.y, e.x, e.fields) or nil
      local said = with_hint(e.msg, hints, instead ~= nil)
      if instead ~= nil then
        said = e.msg .. " -- " .. instead .. said:sub(#e.msg + 1)
      end
      local hint = said:sub(#e.msg + 1)
      local seen = where .. "\0" .. hint
      local first = hint ~= "" and hinted[seen] or nil
      if first ~= nil then
        repeats[first] = (repeats[first] or 0) + 1
        said = e.msg
      elseif hint ~= "" then
        hinted[seen] = #lines + 1
      end
      lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. said
    end
  end
  for at, more in pairs(repeats) do
    lines[at] = lines[at] .. " (same for " .. more .. " more)"
  end
  return table.concat(lines, "\n")
end

--- The statements one compile pass runs, prepared once each.
local record Cache
  run: integer
  tool: string
  look: Sqlite.Statement
  put: Sqlite.Statement
  plan: Sqlite.Statement
end

local function prepare_cache(handle: work.Handle, tool: string): Cache | nil, string
  local db = handle.db
  -- A compile build.contracts refused, kept anyway by an unjudged run,
  -- is marked seen -1 and never reused: the next run compiles and
  -- judges the module again. Changing which verdict may stand is a
  -- semantic change: invalidate the stored keys or the cache schema,
  -- rather than treating it as a transport-only edit.
  local look, look_trouble = db:prepare(
    "UPDATE compiled SET seen = ?2 WHERE key = ?1 AND seen >= 0 RETURNING lua")
  if look == nil then
    return nil, look_trouble
  end
  local put, put_trouble = db:prepare(
    "INSERT OR REPLACE INTO compiled (key, tool, lua, bytecode, seen) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)")
  if put == nil then
    look:finalize()
    return nil, put_trouble
  end
  local plan, plan_trouble = db:prepare(
    "INSERT INTO plan (path, key, ordinal) VALUES (?1, ?2, ?3)")
  if plan == nil then
    look:finalize()
    put:finalize()
    return nil, plan_trouble
  end
  return { run = handle.run, tool = tool, look = look, put = put,
    plan = plan }
end

local function finish_cache(cache: Cache)
  cache.look:finalize()
  cache.put:finalize()
  cache.plan:finalize()
end

--- How many runs a compile stays cached after the last one that used
--- it.
local kept_runs = 100

local once = bind.once

--- The cached Lua under `key`, marked as used by this run, or nil
--- when nothing is cached there.
local function cached_lua(cache: Cache, key: string): string | nil, string
  local look = cache.look
  local bound, bind_trouble = look:bind_text(1, key)
  if bound then bound, bind_trouble = look:bind_integer(2, cache.run) end
  if not bound then
    return nil, bind_trouble
  end
  local state, trouble = look:step()
  if state == nil then
    return nil, trouble
  end
  local lua: string | nil = nil
  if state == "row" then
    lua = look:bytes(0)
  end
  local reset, reset_trouble = look:reset()
  if not reset then
    return nil, reset_trouble
  end
  return lua, ""
end

--- Puts one compile in the cache under its key, and the module in
--- this run's plan. A `refused` compile is kept for this run alone.
local function remember(cache: Cache, path: string, key: string, ordinal: integer,
                        lua: string | nil, bytecode: string | nil,
                        refused: boolean): boolean, string
  if lua ~= nil and bytecode ~= nil then
    local put = cache.put
    local bound, bind_trouble = put:bind_text(1, key)
    if bound then bound, bind_trouble = put:bind_text(2, cache.tool) end
    if bound then bound, bind_trouble = put:bind_text(3, lua) end
    if bound then bound, bind_trouble = put:bind_blob(4, bytecode) end
    if bound then bound, bind_trouble = put:bind_integer(5, refused and -1 or cache.run) end
    if not bound then
      return false, bind_trouble
    end
    local kept, put_trouble = once(put)
    if not kept then
      return false, put_trouble
    end
  end
  local plan = cache.plan
  local bound, bind_trouble = plan:bind_text(1, path)
  if bound then bound, bind_trouble = plan:bind_text(2, key) end
  if bound then bound, bind_trouble = plan:bind_integer(3, ordinal) end
  if not bound then
    return false, bind_trouble
  end
  return once(plan)
end

--- The vendored compiler, planned and cached like any module: its Lua
--- is its source, so only the bytecode is made, and only once per
--- compiler identity. Nothing to do when the working database holds no compiler,
--- as a project's does not. Never taken from the compiles every checkout
--- shares ([`Shared`]): loading and dumping it takes some ten milliseconds,
--- about what reading its half-megabyte row back would.
local function plan_compiler(handle: work.Handle, cache: Cache,
                             tool: string, ordinal: integer): boolean, string
  local rows, trouble = Sqlite.text_rows(handle.db,
    "SELECT source FROM inputs WHERE kind = 'vendor'")
  if rows == nil then
    return false, trouble
  end
  if #rows == 0 then
    return true, ""
  end
  if #rows > 1 then
    return false, "the working database holds " .. plural.count(#rows, "compiler") ..
      "; there is only ever one (derivation.put_compiler)"
  end
  local source = rows[1][1]
  local key = compilation.vendor_key(source, tool)
  local lua, look_trouble = cached_lua(cache, key)
  if lua ~= nil then
    return remember(cache, "vendor.tl", key, ordinal, nil, nil, false)
  end
  if look_trouble ~= "" then
    return false, look_trouble
  end
  local bytecode, dump_trouble = compilation.vendor_bytecode(source)
  if bytecode == nil then return false, dump_trouble end
  return remember(cache, "vendor.tl", key, ordinal, source, bytecode, false)
end

--- Plans and compiles an already derived tree. Only the entry points
--- below own the shared cache; every failure here returns through them.
local function compile_derived(handle: work.Handle, built: compiler, tool: string,
                               own_tree: boolean, parses: importer.Parses,
                               unjudged: boolean, shared: importer.Shared): importer.Result | nil, string
  local modules, trouble = compilation.collect(handle.db)
  if modules == nil then
    return nil, trouble
  end
  local positioned, position_trouble = positions.check(modules, own_tree)
  if not positioned then
    return nil, position_trouble
  end
  local order, why = compilation.ordered(modules)
  if order == nil then
    return nil, why
  end
  local keys, keys_trouble = compilation.dependency_keys(handle.db, modules, built, tool)
  if keys == nil then
    return nil, keys_trouble
  end
  local result: importer.Result = {
    modules = {}, tool = tool, main = nil, refused = {},
    compiled = 0, cached = 0, shared = 0, parses = parses,
  }
  local db = handle.db
  local failure = ""
  -- Made on first use, by whichever module first fails to find a
  -- cached compile below: a run that compiles nothing never pays for
  -- `new_env`'s parse and type-check of tl's own prelude and stdlib.
  local env: compiler.Env | nil = nil
  local typed: receivers.State | nil = nil

  -- Where a hint ([`with_docs_hint`]) looks up the name a refused module
  -- could not resolve, as [`docs.databases`] builds the same list for
  -- `cosmic docs`:
  -- * This tree's last projection, `o/cosmic.db`, unrestricted. It is
  --   the only place cosmic's own `build.*` symbols are documented,
  --   since the tool carries only the public standard library's
  --   ([`writer.carried`]).
  -- * Then the running binary's own, where a standard-library symbol
  --   such as one of [`cosmic.removed`]'s fields lives for any tree but
  --   cosmic's.
  -- The working database cannot stand in: its `docs` rows are keyed by
  -- source hash, with no module to name. A projection that is missing
  -- or unreadable is left out, since the hint is best effort.
  local hint_databases: {Sqlite.Handle} = nil
  local hint_public: {boolean} = nil
  local hint_projection: Sqlite.Handle = nil
  local hints: Hints = function(): {Sqlite.Handle}, {boolean}
    if hint_databases == nil then
      local databases: {Sqlite.Handle} = {}
      local public: {boolean} = {}
      local projection, _ = Sqlite.open(handle.root .. "/o/cosmic.db")
      if projection ~= nil then
        hint_projection = projection
        databases[1] = projection
        public[1] = false
      end
      for _, store_db in ipairs(Store.databases()) do
        databases[#databases + 1] = store_db
        public[#public + 1] = not own_tree
      end
      hint_databases, hint_public = databases, public
    end
    return hint_databases, hint_public
  end

  local compile_all = function(): boolean, string
    local cleared, clear_trouble = db:exec("DELETE FROM plan")
    if not cleared then
      return false, clear_trouble
    end
    local forgotten, forget_trouble = forget_stale_receivers(db)
    if not forgotten then
      return false, forget_trouble
    end
    local judged = not unjudged
    local cache, prepare_trouble = prepare_cache(handle, tool)
    if cache == nil then
      return false, prepare_trouble
    end

    for ordinal, m in ipairs(order) do
      m.key = keys[m.path].key
      m.graph_key = keys[m.path].graph

      local refusal = compilation.refusal(m)
      if refusal ~= nil then
        result.refused[#result.refused + 1] = refusal
      else
        local lua, look_trouble = cached_lua(cache, m.key)
        if lua == nil and look_trouble ~= "" then
          finish_cache(cache)
          return false, look_trouble
        end
        local bytecode: string | nil = nil
        local refused = false
        -- Another checkout's compile stands for one made here: its key
        -- and what else decides it are the same ([`build.shared_compiles`]),
        -- and it lands as a compile does, uses and all.
        local elsewhere = lua == nil and shared ~= nil and shared.look(m, own_tree) or nil
        if lua ~= nil then
          result.cached = result.cached + 1
        elseif elsewhere ~= nil then
          lua = elsewhere.lua
          bytecode = elsewhere.bytecode
          result.cached = result.cached + 1
          result.shared = result.shared + 1
          local kept_refs, refs_trouble = compilation.keep_references(db, m.key, elsewhere.references)
          if not kept_refs then
            finish_cache(cache)
            return false, m.file .. ": " .. refs_trouble
          end
        else
          if env == nil then
            local made_env, env_trouble = teal.environment_for(built, handle.db, handle.root)
            if made_env == nil then
              failure = env_trouble
              break
            end
            env = made_env
            typed = receivers.install(made_env)
          end
          local generated, generate_trouble =
            compilation.generate(m, built, env, assert(typed), own_tree, judged,
              function(file: string, source: string, checked: compiler.Result): string
                return complain(file, source, checked, hints)
              end)
          if generated == nil then
            failure = generate_trouble
            break
          end
          lua = generated.lua
          bytecode = generated.bytecode
          refused = generated.refused
          result.compiled = result.compiled + 1
          local kept_refs, refs_trouble = compilation.keep_references(db, m.key,
            generated.references)
          if not kept_refs then
            finish_cache(cache)
            return false, m.file .. ": " .. refs_trouble
          end
          -- A refused compile is this run's alone (`remember`), and
          -- never another checkout's.
          if shared ~= nil and not refused then
            shared.keep(m, own_tree, { lua = generated.lua, bytecode = generated.bytecode,
              references = generated.references })
          end
        end
        m.lua = lua
        local kept, keep_trouble = remember(cache, m.path, m.key, ordinal, lua,
          bytecode, refused)
        if not kept then
          finish_cache(cache)
          return false, m.file .. ": " .. keep_trouble
        end
        if m.kind == "main" then
          result.main = m.path
        end
        result.modules[#result.modules + 1] = m
      end
    end

    if failure == "" then
      local planned, plan_trouble = plan_compiler(handle, cache, tool,
        #order + 1)
      if not planned then
        finish_cache(cache)
        return false, plan_trouble
      end
    end
    finish_cache(cache)
    local pruned, prune_trouble = Sqlite.run(db,
      "DELETE FROM compiled WHERE tool <> ?1 OR (seen >= 0 AND seen < ?2)" ..
        (judged and " OR seen < 0" or ""),
      { text(tool), { integer = handle.run - kept_runs } })
    if not pruned then
      return false, prune_trouble
    end
    -- Run whether or not the prune above dropped anything: a run that
    -- failed between a compile's [`compilation.keep_references`] and its `remember`
    -- commits the uses without the compile (build.dispatch closes the
    -- handle, keeping what the run did), and only this sweeps them.
    return db:exec(importer.prune_references)
  end
  local made, compile_trouble = compile_all()
  -- The projection the hints opened, once a message earned one.
  if hint_projection ~= nil then
    local _, _ = hint_projection:close()
  end
  if not made then
    return nil, compile_trouble
  end
  if failure ~= "" then
    return nil, failure
  end
  return result
end

--- A self-build chooses the compiler that actually runs only after the
--- analyzer has stabilized and the complete tree identities are recorded.
local function prepare_compile(handle: work.Handle, built: compiler, tool: string,
                               unjudged: boolean, shared: importer.Shared,
                               choose: function(identities.Identities): string | nil, string): importer.Result | nil, string
  local own_tree, own_trouble = tree.is_own(handle.root)
  if own_tree == nil then return nil, own_trouble end
  local parses, derive_trouble = importer.derive(handle, own_tree, built, shared)
  if parses == nil then return nil, derive_trouble end
  if choose ~= nil then
    local recorded, record_trouble = identities.record_identities(handle.db)
    if recorded == nil then return nil, record_trouble end
    local selected, select_trouble = choose(recorded)
    if selected == nil then return nil, select_trouble end
    tool = selected
  end
  return compile_derived(handle, built, tool, own_tree, parses, unjudged, shared)
end

--- The cache belongs to the whole derive/identity/compile operation,
--- including successful rows offered before a later phase fails.
local function consuming_compile(handle: work.Handle, built: compiler, tool: string,
                                 unjudged: boolean, shared: importer.Shared,
                                 choose?: function(identities.Identities): string | nil, string): importer.Result | nil, string
  local result, trouble = prepare_compile(handle, built, tool, unjudged, shared, choose)
  if shared ~= nil then shared.finish() end
  if result == nil then return nil, trouble end
  return result, ""
end

--- Compiles every module, in import order, into Lua and bytecode --
--- or finds it already compiled under the same key. The keys and the
--- compiles land in the working database inside the run's
--- transaction, kept even when a later module refuses, so a run that
--- fails still pays for each module once; a compile another tool
--- made, or one no run has used lately, is dropped.
---
--- The checker's environment ([`build.teal`]'s `environment_for`) is made
--- on first use, right before the first module that actually needs one
--- to compile, rather than up front: `new_env` parses and type-checks
--- tl's own prelude and stdlib declarations, so a build that finds
--- every module already cached never pays for it.
--- @param handle the working database the tree is staged in
--- @param built the compiler, loaded and ready
--- @param tool the identity of the compiler doing the compiling, which
---   every key carries
--- @param unjudged whether a module [`build.contracts`] refuses is kept
---   rather than refused: a stale tool rebuilding itself ([`build.reboot`])
---   judges the tree by its own, older rules and exemptions, so it
---   leaves the last word to the tool it builds, which re-enters the
---   command. A compile the old rules refuse is kept only for this run's
---   database, never reused, so the next run compiles and judges the
---   module again; one they pass is cached as any other, since a change
---   to the rules themselves forgets every compile ([`forget_stale_receivers`]).
--- @param shared the compiles and parses every checkout shares, or nil
---   for none: a module whose key misses here is taken from them rather
---   than compiled, and every compile made here but a refused one is
---   offered them, as its derive takes and offers parses
---   ([`importer.derive`]). Finished before this returns, whatever it
---   returns, with whatever an earlier derive given them offered.
function importer.compile(handle: work.Handle, built: compiler,
                          tool: string, unjudged?: boolean,
                          shared?: importer.Shared): importer.Result | nil, string
  return consuming_compile(handle, built, tool, unjudged, shared)
end

--- Compiles a self-build after deriving its sources and recording its
--- complete identities. `choose` selects the compiler actually running:
--- the tree's for a boot, the running tool's until a rebuild settles.
--- Like [`importer.compile`], consumes `shared`, finishing it exactly once
--- on success or failure. The working database and its transaction remain
--- the caller's, as does publishing the completed projection.
function importer.compile_tree(handle: work.Handle, built: compiler,
                               choose: function(identities.Identities): string | nil, string,
                               unjudged: boolean, shared?: importer.Shared): importer.Result | nil, string
  return consuming_compile(handle, built, "", unjudged, shared, choose)
end

return importer
