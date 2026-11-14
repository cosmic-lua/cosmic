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

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local GrammarMode = require("build.grammar_mode")
local Store = require("cosmic.store")
local CodeWalk = require("build.code_walk")
local Stamp = require("build.stamp")
local identities = require("build.identity")
-- The pipeline is required where a build in the new grammar asks for it: `cosmic boot` compiles what the tool requires at load
-- with the bootstrap release, whose checker reads the new checker's closure otherwise than the tree's does.
local type Pipeline = require("build.pipeline")
-- Required where a parse runs, for the same reason: it is a root of the analyzer's identity ([`CodeWalk.analyzer_roots`]),
-- which is walked from the roots and not from this module.
local type ParseDerive = require("build.parse_derive")
local analysis_schema = require("build.analysis_schema")
local positions = require("build.positions")
local type SyntaxReceivers = require("build.syntax_receivers")
local work = require("build.work")
local log = require("build.logger").log
local bind = require("build.bind")

local plans = require("build.plans")
local derivation = require("build.derivation")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): analyzer, receivers.
local _ = require("build.reads.analyzer")
local _ = require("build.reads.receivers")

local type Module = plans.Module
local type Source = derivation.Source

local record importer
  type Module = plans.Module

  --- Where the code that analyzes is read from, as [`Store.requires`]
  --- and [`Store.source`] read it of the binary ([`importer.tree_code`]
  --- reads it of the tree): what a module requires among the modules a
  --- build plans, of which a declaration alone is none, sorted; and a
  --- module's source, a declaration's ahead of a module's of the same
  --- name. `basis` is the runtime basis it runs on: Lua's pin and
  --- patches and the declarations the new checker types a program with
  --- ([`build.identity`]'s [`Identities.runtime_basis`]).
  record Code
    basis: string
    requires: function(string): {string}?, string
    source: function(string): string?, string
  end

  record Result
    modules: {Module}
    --- The compiler identity every key in `modules` carries.
    tool: string
    mut main?: string
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: mut {string}
    --- The files of the modules `refused` names for what they hold, in the
    --- order named, not those left out only for requiring one of them.
    own_refused?: mut {string}
    --- For each file the run left out as refused, whether for what it holds or for requiring a module that was, the
    --- positions in `refused` of the refusals that hold it out: its own, or those of every refused module it rests on.
    --- A run that named a file uses it to show why that file did not compile.
    refusal_roots?: mut {string:{integer}}
    --- One line per module a file run ([`importer.compile_for`]) left
    --- out, since it does not parse or compile and the file does not
    --- reach it. A module left out only because it requires one of
    --- these has no line, nor is it in `modules`.
    left_out: mut {string}
    -- How many modules were compiled this run, and how many came back
    -- from `compiled` under a key that stood.
    mut compiled: integer
    mut cached: integer
    --- How many reads of a narrowed place and how many typed parameters the Lua of the modules checks, summed over
    --- the modules compiled and those a cache answered (the counts are kept with a compile): what a checked compile
    --- wrote, 0 for an unchecked one.
    mut fact_wraps: integer
    mut parameter_checks: integer
    --- How many of those `cached` came from the compiles every
    --- checkout shares ([`Shared`]) rather than this one's own.
    mut shared: integer
    --- What the derive the compile began with parsed.
    parses: derivation.Parses
    --- Writes the rows the checker that compiled adds to the shipped catalog (`catalog` of the attached schema `schema`,
    --- "" for the main one), after the extracted ones: the rule behind each code the new checker emits
    --- ([`build.error_catalog`]). nil where the compile adds none.
    catalog?: Catalog
  end

  --- Writes rows to the `catalog` table of `db` (of the attached schema `schema`, "" for the main one): how many, or nil and
  --- why.
  type Catalog = function(db: Sqlite.Handle, schema: string): integer?, string

  --- What a derive parsed ([`importer.derive`]): how many sources it
  --- parsed, and how many more another checkout's parse stood in for.
  type Parses = derivation.Parses

  --- The databases a hint looks a name up in, and whether each is read
  --- as the public standard library's (importer.said).
  type Hints = function(): {Sqlite.Handle}, {boolean}

  --- Whether a compile that answered nothing stopped on a refusal of the source -- a file the run needs that does not parse
  --- or that the checker refuses -- and not on a trouble of the host (a database, a missing tool). A caller that takes one
  --- hands it to [`importer.compile_for`], which sets `refused`.
  ---
  --- With `tell`, a compile over a tree that goes on past the first module it refuses says so through it, once, ahead of
  --- its report ([`importer.due`]), `patience_ns` after the refusal, two seconds where that is nil. The verbs that build
  --- on purpose hand one in ([`importer.telling`]); a lookup, which says a refusal in a line of its own, does not.
  record Outcome
    mut refused: boolean
    tell?: function(string)
    patience_ns?: integer
  end

  --- The first module a compile over a tree refused for what it holds, which the compile goes on past: its file, what
  --- the checker said of it, when, and whether the run has said so yet ([`importer.due`]).
  record Early
    file: string
    trouble: string
    at_ns: integer
    mut told: boolean
  end

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
      references: {SyntaxReceivers.Reference}
      --- How many reads of a narrowed place and how many typed parameters the Lua checks: 0 and 0 for an
      --- unchecked compile.
      fact_wraps: integer
      parameter_checks: integer
    end
    --- One parse: what a parse writes of a source in every table
    --- `analysis_tables` names.
    type Parse = derivation.Parse
    --- The analyzers another checkout parsed every one of `hashes`
    --- with, the most lately used first.
    analyzers: function(hashes: {string}): {string}
    --- What `analyzer` found each of `hashes` requires, by hash, of
    --- those it parsed: a guess, read without its row's digest.
    requires: function(analyzer: string, hashes: {string}): {string:{string}}
    --- The parse `analyzer` made of the source `hash`, its docs' lines
    --- `mapped` or not ([`build.syntax_derivation`]'s `origin_lines`), or nil.
    parse: function(analyzer: string, hash: string, mapped: boolean): derivation.Parse?
    --- Offers a parse `analyzer` made here to every other checkout.
    offer: function(analyzer: string, hash: string, mapped: boolean, made: derivation.Parse)
    --- The compile another checkout made of `m` in a tree that is or
    --- is not cosmic's own, or nil.
    look: function(m: Module, own_tree: boolean): Compile?
    --- Whether another checkout made a compile of `m`, its Lua not
    --- read: what a build asks before it compiles many modules at once
    --- ([`build.compile_fanout`]). A cache that does not say is taken to
    --- hold none.
    known?: function(m: Module, own_tree: boolean): boolean
    --- The compiles of many modules, made at once.
    record Fanned
      --- The compile made of `m`, or nil where none was.
      look: function(m: Module): Compile?
      --- Drops what was made. Nothing is looked up after it.
      close: function()
    end
    --- Compiles `due` in copies of this process, `make` the compile of
    --- one module (nil where it makes none), or nil where no copy is
    --- made: too few modules, or one processor
    --- ([`build.compile_fanout`]). `make` is told, with a module, the
    --- paths its copy has yet to make after it. `watch` is called in
    --- this process while the copies run.
    fan?: function(due: {Module}, own_tree: boolean,
                   make: function(m: Module, rest: {string:boolean}): Compile?, watch?: function()): Fanned?
    --- Offers a compile of `m` made here to every other checkout.
    keep: function(m: Module, own_tree: boolean, made: Compile)
    --- A parse a copy of this process made, and of which source.
    record ParseMade
      source_hash: string
      mapped: boolean
      parse: Parse
    end
    --- The parses of many sources, made at once.
    record ParsesFanned
      --- The parse made of the source `source_hash`, or nil where none was.
      look: function(source_hash: string, mapped: boolean): Parse?
      --- Drops what was made. Nothing is looked up after it.
      close: function()
    end
    --- Parses `count` sources in copies of this process, or nil where no
    --- copy is made, as [`fan`] makes none. `make` answers the parses of
    --- the sources that are its copy's, each `copies`-th from `copy`.
    fan_parses?: function(count: integer, make: function(copy: integer, copies: integer): {ParseMade}): ParsesFanned?
    --- Writes what was offered; `compile` calls it once, as it ends,
    --- whether or not it compiled everything, and after it nothing is
    --- looked up or offered.
    finish: function()
  end

  --- The statement that drops the record-field uses of every compile
  --- `compiled` no longer holds, run at the end of each compile.
  mut prune_references: string
end

local type Hints = importer.Hints

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

--- The derivation, the parse and the extractors, generators and parser they call: the roots of
--- [`importer.analyzer_modules`] ([`build.code_walk`]'s `analyzer_roots`). "The analyzer" in these names is that
--- whole set, of which the source analyzer [`build.syntax_analyzer`] is one.
local analyzer_roots: {string} = CodeWalk.analyzer_roots

--- The modules whose code decides what the analysis tables record: the
--- derivation, the parse ([`build.parse_derive`]) and every module that
--- their extractors, generators, lexer and parser reach through `require`,
--- as `code` records it: the running binary's own `imports` table by
--- default. What a source parses to is a function of these and of the
--- runtime basis, and of nothing else in the tool: the checker is not
--- among them, since no module of the walk requires it. Cache coordination and
--- diagnostic presentation belong to the importer, outside this closure.
local record Walk
  names: {string}?
  trouble: string
  --- Whether the walk stopped at a module held without its source ([`Store.withheld`]), not at one it could not read.
  withheld: boolean
end

local function walk_analyzer(code?: importer.Code): Walk
  -- A name at a time ([`Store.requires`]), not a query of a handle on
  -- the binary's database, which would read every module's rows.
  local requires = if code ~= nil then code.requires else Store.requires end
  local source_of = if code ~= nil then code.source else Store.source end
  local reached, reach_trouble = CodeWalk.reach(CodeWalk.analyzer, requires)
  if reached == nil then return { names = nil, trouble = reach_trouble, withheld = false } end
  local names: mut {string} = {}
  for _, name in ipairs(reached) do
    -- What the binary holds a module or a declaration of: what
    -- [`Store.source`] answers, of a name no hold holds.
    local source, _ = source_of(name)
    if source ~= nil then
      names[#names + 1] = name
    elseif code == nil then
      -- A module the binary holds without its source (a pure test store)
      -- is held, not absent: its absence would shorten the set quietly.
      local withheld, withheld_trouble = Store.withheld(name)
      if withheld_trouble ~= "" then
        return { names = nil, trouble = withheld_trouble, withheld = false }
      end
      if withheld ~= nil then return { names = nil, trouble = withheld, withheld = true } end
    end
  end
  table.sort(names)
  return { names = names, trouble = "", withheld = false }
end

function importer.analyzer_modules(code?: importer.Code): {string}?, string
  local walk = walk_analyzer(code)
  local names = walk.names
  if names == nil then return nil, walk.trouble end
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
--- module requires is what the last parse of its source found: before a
--- parse, a module whose source is new has none, but its source alone
--- already moves the identity. The runtime basis is the tree's pins
--- ([`identities.runtime_basis`]).
function importer.tree_code(handle: work.Handle): importer.Code?, string
  local basis, trouble = identities.runtime_basis(handle.db)
  if basis == nil then
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
  local function requires(name: string): {string}?, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
        "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
        "AND ?1 IN (SELECT path FROM inputs WHERE " .. analysis_schema.not_declaration("kind") .. ") " ..
        "AND r.name IN (SELECT path FROM inputs WHERE " .. analysis_schema.not_declaration("kind") .. ") " ..
        "ORDER BY r.name", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    local names: mut {string} = {}
    for _, row in ipairs(rows) do names[#names + 1] = row:text(1) end
    return names, ""
  end
  -- What [`Store.source`] answers: a declaration's source ahead of a
  -- module's.
  local function source(name: string): string?, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT source FROM inputs WHERE path = ?1 " ..
        "ORDER BY " .. analysis_schema.declaration("kind") .. " DESC LIMIT 1", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    if #rows == 0 then
      return nil, "no module '" .. name .. "' in the tree"
    end
    return rows[1]:text(1), ""
  end
  return { basis = basis, requires = requires, source = source }, ""
end

--- The identity of the analyzer `code` holds: the runtime basis it runs
--- on, and the source of every one of [`importer.analyzer_modules`].
--- `code` defaults to the running binary's, the code actually deriving;
--- in a stale tool rebuilding itself that is older than the tree's. A
--- boot names the tree's ([`importer.tree_code`]), the code it runs, so
--- the tool it writes finds the rows the boot derived as its own. A
--- binary that carries no source for one of them, or no record of what
--- they import, can only be named whole. What a parse runs is these
--- modules and the Lua and declarations of the basis, and nothing else of
--- the compiler's identity or of the code that checks ([`build.pipeline`]'s
--- `coded`): an edit to build.plans, build.tree or the checker (lang/check.tl,
--- build.driver, build.pipeline) compiles again and parses nothing again. An
--- edit to the lexer, the parser or a reader of the syntax tree parses
--- everything again.
local function analyzer_named(code?: importer.Code): string?, string
  if code == nil then
    -- The running binary's own, which the build that wrote its database
    -- worked out from the same rows ([`build.stamps`]).
    local stamped = Stamp.read("stamp_analyzer")
    if stamped ~= nil then return stamped, "" end
  end
  local parts: mut {string} = { (if code ~= nil then code.basis else Store.meta("runtime_basis") end) or "" }
  local walk = walk_analyzer(code)
  local modules = walk.names
  if modules == nil then
    -- A module the binary holds without its source is no binary that carries none of it: say so.
    if walk.withheld then return nil, walk.trouble end
    return "binary " .. (Store.meta("boot_hash") or ""), ""
  end
  local source_of = if code ~= nil then code.source else Store.source end
  for _, name in ipairs(modules) do
    local source, _ = source_of(name)
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or ""), ""
    end
    parts[#parts + 1] = name .. "\n" .. source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n")), ""
end

--- [`analyzer_named`] for a caller with no place to carry a refusal: it raises the reason a module's
--- source is withheld.
function importer.analyzer_identity(code?: importer.Code): string
  local identity, trouble = analyzer_named(code)
  if identity == nil then error(trouble, 0) end
  return identity
end

--- Whether `identity` names an analyzer at all: one named by a binary
--- with no boot hash ([`importer.analyzer_identity`]) is every such
--- binary's, so no parse is shared under it.
local function nameless(identity: string): boolean
  return identity == "binary "
end

--- The identity of the analyzer that is running ([`importer.analyzer_identity`]):
--- the binary's, or in a boot, which carries no database, the tree's.
local function running_analyzer(handle: work.Handle): string?, string
  local identity = ""
  if Store.meta("boot_hash") ~= nil then
    local named, named_trouble = analyzer_named()
    if named == nil then return nil, named_trouble end
    identity = named
  else
    local code, trouble = importer.tree_code(handle)
    if code == nil then
      return nil, trouble
    end
    local named, named_trouble = analyzer_named(code)
    if named == nil then return nil, named_trouble end
    identity = named
  end
  return identity, ""
end

--- Names the rows the analysis tables hold as derived by `identity`.
local function record_analyzer(db: Sqlite.Handle, identity: string): boolean, string
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
    { text(identity) })
end

--- What `meta` names the analysis tables' rows as derived by, "" for
--- none.
local function recorded_analyzer(db: Sqlite.Handle): string?, string
  local last, trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'analyzer'")
  if last == nil then
    return nil, trouble
  end
  return if #last > 0 then last[1]:text(1) else "" end, ""
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
local function forget_stale_analysis(handle: work.Handle): boolean?, string
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

--- The identity of the code that finds the record-field uses and judges the discipline beside the checker
--- ([`build.syntax_receivers`], [`build.syntax_contracts`]): a boot names them by the tree's source, a built tool by the
--- source it carries.
local function receivers_identity(db: Sqlite.Handle): string?, string
  local booting = Store.meta("boot_hash") == nil
  local parts: mut {string} = {}
  for _, name in ipairs(CodeWalk.receivers_modules) do
    local source: string? = nil
    if booting then
      local rows, trouble = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE path = ?1", { text(name) })
      if rows == nil then
        return nil, trouble
      end
      local first = rows[1]
      if first ~= nil then
        source = first:text(1)
      end
    else
      local carried, _ = Store.source(name)
      source = carried
    end
    if source == nil then
      if not booting then
        -- Held without its source is no binary that lacks the module.
        local withheld, withheld_trouble = Store.withheld(name)
        if withheld_trouble ~= "" then return nil, withheld_trouble end
        if withheld ~= nil then return nil, withheld end
      end
      return "binary " .. (Store.meta("boot_hash") or ""), ""
    end
    parts[#parts + 1] = source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n")), ""
end

--- Forgets every compile, and the record-field uses found with it, when the code that finds those uses has changed since:
--- a compile whose key stands is never checked again, so a `typed_refs` row is only as right as the readers that ran
--- beside the checker.
local function forget_stale_receivers(db: Sqlite.Handle): boolean, string
  local identity, identity_trouble = receivers_identity(db)
  if identity == nil then
    return false, identity_trouble
  end
  local last, last_trouble = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'receivers'")
  if last == nil then
    return false, last_trouble
  end
  local recorded = last[1]
  if recorded ~= nil and recorded:text(1) == identity then
    return true, ""
  end
  for _, statement in ipairs({ "DELETE FROM compiled", "DELETE FROM typed_refs" }) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return Sqlite.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('receivers', ?1)", { text(identity) })
end

--- What a boot names its analyzer ([`running_analyzer`]) with `guessed`,
--- by hash, written as `requires` rows for the while, then taken back.
local function named_over(handle: work.Handle, guessed: {string:{string}}): string?, string
  local db = handle.db
  local begun, begin_trouble = db:exec("SAVEPOINT shared_analyzer")
  if not begun then return nil, begin_trouble end
  local function named(): string?, string
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
--- - X is a digest of the runtime basis and of each analyzer module's name
---   and source, so naming it again over
---   this tree's sources lists the same modules and sources X did, on the
---   same basis: X's code is the code this boot runs.
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
-- Nothing but the pins and the analyzer's Teal sources is
-- in X, by design ([`forget_stale_analysis`]): the core's C, which runs
-- the parse, is not, so a branch whose C parses otherwise shares rows
-- with main under the same X, as compiles do under their keys, and as
-- one checkout switching between the two keeps its rows. The semantic
-- row encoding belongs to build.derivation, in X; the outer shared-cache
-- format is versioned by build.shared_compiles' `parsed_version`.
local function shared_analyzer(handle: work.Handle, shared: importer.Shared,
                               sources: {Source}): string?, string
  if Store.meta("boot_hash") ~= nil then
    return running_analyzer(handle)
  end
  local db = handle.db
  local roots: mut {string} = {}
  for _, name in ipairs(analyzer_roots) do roots[#roots + 1] = name end
  local found, trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT source_hash FROM inputs WHERE " .. analysis_schema.not_declaration("kind") .. " " ..
      "AND path IN (SELECT value FROM json_each(?1)) ORDER BY source_hash",
    { text('["' .. table.concat(roots, '","') .. '"]') })
  if found == nil then return nil, trouble end
  if #found == 0 then return "", "" end
  local root_hashes: mut {string} = {}
  for _, row in ipairs(found) do root_hashes[#root_hashes + 1] = row:text(1) end
  local hashes: mut {string} = {}
  local fresh: mut {string:boolean} = {}
  for _, source in ipairs(sources) do
    hashes[#hashes + 1] = source.source_hash
    fresh[source.source_hash] = true
  end
  local planned, planned_trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash FROM inputs WHERE " .. analysis_schema.not_declaration("kind"))
  if planned == nil then return nil, planned_trouble end
  local hash_of: mut {string:string} = {}
  for _, row in ipairs(planned) do hash_of[row:text(1)] = row:text(2) end
  -- A module the roots reach through `guessed`, and through the rows
  -- the tables hold of what is parsed already, of which `guessed` has
  -- no parse: "" for none.
  local function unguessed(guessed: {string:{string}}): string?, string
    local reached: mut {string:boolean} = {}
    local stack: mut {string} = {}
    for _, name in ipairs(roots) do stack[#stack + 1] = name end
    while #stack > 0 do
      local name = table.remove(stack)
      local hash = if name ~= nil then hash_of[name] else nil end
      if name ~= nil and reached[name] ~= true and hash ~= nil then
        reached[name] = true
        local names = guessed[hash]
        if fresh[hash] == true and names == nil then return name, "" end
        if names == nil then
          local rows, rows_trouble = Sqlite.text_rows(db,
            "SELECT name FROM requires WHERE source_hash = ?1 ORDER BY ordinal", { text(hash) })
          if rows == nil then return nil, rows_trouble end
          names = {}
          for _, row in ipairs(rows) do
            local first = row:text(1)
            names[#names + 1] = first -- checked: view_written
          end
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

--- Takes the parse another checkout made of each of `sources` from
--- `shared`, where its analyzer is this tree's ([`shared_analyzer`]), and
--- writes it as the parse would have, counting it in `tally`; the rest
--- are left to [`parse_new`]. Answers that analyzer, "" for none.
local function take_parses(handle: work.Handle, shared: importer.Shared, sources: {Source},
                           tally: importer.Parses): string?, string
  local identity, trouble = shared_analyzer(handle, shared, sources)
  if identity == nil then return nil, trouble end
  if identity == "" or nameless(identity) then return "", "" end
  local db = handle.db
  local widths, widths_trouble = derivation.table_widths(db)
  if widths == nil then return nil, widths_trouble end
  for _, source in ipairs(sources) do
    local found = shared.parse(identity, source.source_hash, source.mapped)
    local rows = if found ~= nil then derivation.unpacked_parse(found.rows, widths) else nil end
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
local function offer_parses(db: Sqlite.Handle, shared: importer.Shared?, identity: string,
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

--- Parses every source no parse has seen, with the new checker's syntax tree ([`build.parse_derive`]), in this
--- process. Nothing here decides a row: which sources are fresh is [`build.derivation`]'s answer and what each parses to
--- is [`build.parse_derive`]'s, both roots of the analyzer's identity. The rows land in hash order. `broken`, when given, lists what does not parse rather than stopping there.
local function parse_new(handle: work.Handle, tally: importer.Parses, made: mut {Source},
                         broken: mut {derivation.Broken}?, outcome: importer.Outcome?): boolean, string
  local db = handle.db
  local fresh, trouble = derivation.fresh(db)
  if fresh == nil then
    return false, trouble
  end
  local parse_derive = require("build.parse_derive")
  local refusal: ParseDerive.Refusal = { refused = false }
  local parsed, parse_trouble = parse_derive.derive(db, work.standing(handle).own, fresh, tally, made, broken, refusal)
  if not parsed then
    if refusal.refused and outcome ~= nil then outcome.refused = true end
    return false, parse_trouble
  end
  return true, ""
end

--- Parses the sources no parse has seen in copies of this process, where there are many and `shared` makes copies
--- ([`importer.Shared`]'s `fan_parses`): a parse of a source is a function of the tree as staged and of that source.
--- Each copy parses its sources into a database of its own, in memory, with the tables a parse writes and nothing else, by the same
--- [`build.parse_derive`] a build parses with, and hands back each as a shared parse holds one; they land here as a
--- parse taken from another checkout does ([`take_parses`]). A source a copy could not parse it hands back nothing of, and
--- [`parse_new`] parses it here and says why. Nothing is made at once where the tree cannot be read: that is
--- [`parse_new`]'s to say too.
local function parse_at_once(handle: work.Handle, tally: importer.Parses, made: mut {Source}, shared: importer.Shared)
  local fan_parses = shared.fan_parses
  if fan_parses == nil then return end
  local db = handle.db
  local fresh, _ = derivation.fresh(db)
  if fresh == nil or #fresh == 0 then return end
  local parse_derive = require("build.parse_derive")
  local own = work.standing(handle).own
  local staged, _ = parse_derive.entries(db, own)
  if staged == nil then return end
  local fanned = fan_parses(#fresh, function(copy: integer, copies: integer): {importer.Shared.ParseMade}
    local own_db = assert(Sqlite.memory())
    for _, statement in ipairs(analysis_schema.statements) do assert(own_db:exec(statement)) end
    local mine: mut {derivation.Fresh} = {}
    for index = copy, #fresh, copies do
      mine[#mine + 1] = assert(fresh[index], "an index within the list is a source")
    end
    local counted: importer.Parses = { parsed = 0, shared = 0 }
    local parsed: mut {Source} = {}
    local unparsed: mut {derivation.Broken} = {}
    assert(parse_derive.derive(own_db, own, mine, counted, parsed, unparsed, nil, staged))
    local packed = assert(derivation.packed_parses(own_db, parsed))
    local out: mut {importer.Shared.ParseMade} = {}
    for _, source in ipairs(parsed) do
      local one = packed[source.source_hash]
      if one ~= nil then
        out[#out + 1] = { source_hash = source.source_hash, mapped = source.mapped, parse = one }
      end
    end
    return out
  end)
  if fanned == nil then return end
  local widths, _ = derivation.table_widths(db)
  for _, one in ipairs(fresh) do
    local found = if widths ~= nil then fanned.look(one.source_hash, one.mapped) else nil end
    local rows = if found ~= nil and widths ~= nil then derivation.unpacked_parse(found.rows, widths) else nil end
    if found ~= nil and rows ~= nil then
      local put, _ = derivation.put_parse(db, one.source_hash, found.requires, rows)
      if put then
        tally.parsed = tally.parsed + 1
        made[#made + 1] = { source_hash = one.source_hash, mapped = one.mapped }
      end
    end
  end
  fanned.close()
end

--- Derives and parses what the staged tree holds that the tables do
--- not, and drops what no input refers to any more ([`importer.derive`]).
--- A source another checkout parsed is taken from `shared` rather than
--- parsed ([`take_parses`]). Counts what it parsed and took in `tally`,
--- lists what it parsed in `made`, and what does not parse in `broken`
--- when given ([`parse_new`]), and answers the analyzer whose parses it
--- took, "" for none.
local function derive_new(handle: work.Handle, tally: importer.Parses,
                          made: mut {Source}, shared: importer.Shared?,
                          broken: mut {derivation.Broken}?, outcome: importer.Outcome?): string?, string
  local db = handle.db
  local swept, sweep_trouble = db:exec(
    "DELETE FROM derived WHERE origin <> 'vendor' AND NOT EXISTS " ..
      "(SELECT 1 FROM files f WHERE f.path = derived.file " ..
      "AND f.sha256 = derived.from_hash)")
  if not swept then
    return nil, sweep_trouble
  end
  local refusal: derivation.Refusal = { refused = false }
  local derived, derived_trouble = derivation.inputs(db, refusal)
  if not derived then
    if refusal.refused and outcome ~= nil then outcome.refused = true end
    return nil, derived_trouble
  end
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
  if shared ~= nil then parse_at_once(handle, tally, made, shared) end
  local parsed, parse_trouble = parse_new(handle, tally, made, broken, outcome)
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
--- @param shared the parses every checkout shares, or nil for none: a
---   source another checkout's analyzer parsed, where that analyzer is
---   this one ([`shared_analyzer`]), is taken from them rather than
---   parsed, and every parse made here is offered them. This borrows the
---   cache; a compile entry point or the caller must finish it.
--- @param broken where a source that does not parse is listed, rather
---   than stopping the derive, or nil to stop
--- @param outcome set to `refused` where the derive stops on a source the tree holds that cannot be derived (a template
---   that does not compile, two files of one import path)
--- @return what it parsed and took, or nil and why it could not
function importer.derive(handle: work.Handle, shared?: importer.Shared,
                         broken?: mut {derivation.Broken}, outcome?: importer.Outcome): importer.Parses?, string
  local db = handle.db
  if not work.standing(handle).own then
    local reserved, reserved_trouble = Fs.is_dir(handle.root .. "/cosmic")
    if reserved == nil then
      return nil, reserved_trouble
    end
    if reserved then
      return nil, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree, which only the tool built from it reads; " ..
        "run bin/cosmic, which runs that tool"
    end
    local claimed, trouble = Sqlite.text_rows(db,
      "SELECT path FROM files WHERE path GLOB 'cosmic/*' ORDER BY path LIMIT 1")
    if claimed == nil then
      return nil, trouble
    end
    if #claimed > 0 then
      return nil, claimed[1]:text(1) .. ": the 'cosmic' directory is reserved to " ..
        "cosmic's own tree, which only the tool built from it reads; run bin/cosmic, which runs that tool"
    end
  end

  local tally: importer.Parses = { parsed = 0, shared = 0 }
  local made: mut {Source} = {}
  local forgotten, forget_trouble = forget_stale_analysis(handle)
  if forgotten == nil then
    return nil, forget_trouble
  end
  local taken, derive_trouble = derive_new(handle, tally, made, shared, broken, outcome)
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
    if broken ~= nil then
      while #broken > 0 do table.remove(broken) end
    end
    local again, again_trouble = derive_new(handle, tally, made, nil, broken, outcome)
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

--- The statements one compile pass runs, prepared once each.
local record Cache
  run: integer
  tool: string
  look: Sqlite.Statement
  touch: Sqlite.Statement
  put: Sqlite.Statement
  plan: Sqlite.Statement
  --- The counts of the checks the compile that [`cached_stands`] found last wrote (0 and 0 for none).
  mut wraps: integer
  mut checks: integer
end

local function prepare_cache(handle: work.Handle, tool: string): Cache?, string
  local db = handle.db
  -- A compile build.syntax_contracts refused, kept anyway by an unjudged run,
  -- is marked seen -1 and never reused: the next run compiles and
  -- judges the module again. Changing which verdict may stand is a
  -- semantic change: invalidate the stored keys or the cache schema,
  -- rather than treating it as a transport-only edit.
  -- By the index that holds `seen` and the counts of the checks beside the key
  -- (`compiled_by_checks`, [`build.work`]): a row holds the module's Lua and
  -- bytecode before them, and SQLite reaches a column by reading through every
  -- page of the ones before it, 27 MB a run for a tree's modules.
  local look, look_trouble = db:prepare(
    "SELECT seen, fact_wraps, parameter_checks FROM compiled INDEXED BY compiled_by_checks " ..
      "WHERE key = ?1 AND seen >= 0")
  if look == nil then
    return nil, look_trouble
  end
  local touch, touch_trouble = db:prepare(
    "UPDATE compiled SET seen = ?2 WHERE key = ?1 AND seen >= 0")
  if touch == nil then
    look:finalize()
    return nil, touch_trouble
  end
  local put, put_trouble = db:prepare(
    "INSERT OR REPLACE INTO compiled (key, tool, lua, bytecode, seen, fact_wraps, parameter_checks) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
  if put == nil then
    look:finalize()
    touch:finalize()
    return nil, put_trouble
  end
  local plan, plan_trouble = db:prepare(
    "INSERT INTO plan (path, key, ordinal) VALUES (?1, ?2, ?3)")
  if plan == nil then
    look:finalize()
    touch:finalize()
    put:finalize()
    return nil, plan_trouble
  end
  return { run = handle.run, tool = tool, look = look, touch = touch,
    put = put, plan = plan, wraps = 0, checks = 0 }, ""
end

local function finish_cache(cache: Cache)
  cache.look:finalize()
  cache.touch:finalize()
  cache.put:finalize()
  cache.plan:finalize()
end

--- How many runs a compile stays cached after the last one that used
--- it. [`cached_stands`] writes a compile's `seen` only once it is
--- `refresh_after` runs old, so one goes between `kept_runs` and
--- `kept_runs + refresh_after` runs after its last use.
local kept_runs = 100

--- How stale a cached compile's `seen` may be before a run that uses it
--- writes it again. A row holds the module's Lua and bytecode, so a write
--- of `seen` alone rewrites all of it: marking each of a tree's modules
--- on every run cost most of an idle run.
local refresh_after = 10

local once = bind.once

--- Whether a compile stands under `key`, marked as used by this run (see
--- `refresh_after`). Its Lua is not read: no caller of a compile asked
--- for that of a module it did not make ([`build.module`]'s `lua`).
local function cached_stands(cache: Cache, key: string): boolean, string
  local look = cache.look
  local bound, bind_trouble = look:bind_text(1, key)
  if not bound then
    return false, bind_trouble
  end
  local state, trouble = look:step()
  if state == nil then
    return false, trouble
  end
  local stands = false
  local stale = false
  cache.wraps, cache.checks = 0, 0
  if state == "row" then
    stands = true
    stale = look:integer(0) < cache.run - refresh_after
    cache.wraps, cache.checks = look:integer(1), look:integer(2)
  end
  local reset, reset_trouble = look:reset()
  if not reset then
    return false, reset_trouble
  end
  if stale then
    local touch = cache.touch
    bound, bind_trouble = touch:bind_text(1, key)
    if bound then bound, bind_trouble = touch:bind_integer(2, cache.run) end
    if not bound then
      return false, bind_trouble
    end
    local touched, touch_trouble = once(touch)
    if not touched then
      return false, touch_trouble
    end
  end
  return stands, ""
end

--- Puts one compile in the cache under its key, and the module in
--- this run's plan. A `refused` compile is kept for this run alone.
local function remember(cache: Cache, path: string, key: string, ordinal: integer,
                        lua: string?, bytecode: string?,
                        refused: boolean, fact_wraps: integer, parameter_checks: integer): boolean, string
  if lua ~= nil and bytecode ~= nil then
    local put = cache.put
    local bound, bind_trouble = put:bind_text(1, key)
    if bound then bound, bind_trouble = put:bind_text(2, cache.tool) end
    if bound then bound, bind_trouble = put:bind_text(3, lua) end
    if bound then bound, bind_trouble = put:bind_blob(4, bytecode) end
    if bound then
      bound, bind_trouble = put:bind_integer(5, if refused then -1 else cache.run end)
    end
    if bound then bound, bind_trouble = put:bind_integer(6, fact_wraps) end
    if bound then bound, bind_trouble = put:bind_integer(7, parameter_checks) end
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

--- What [`compile_derived`] keeps as it compiles, for the closure
--- that compiles every module to write and its caller to read.
local record Progress
  --- Why the compile stopped, "" while it has not.
  mut failure: string
end

--- What a compile with the new checker reads ([`build.pipeline`]): the options, and the program, made when the first module
--- that no cache answers needs it.
local record Reading
  mut options: Pipeline.Options?
  mut built: Pipeline.Built?
end

--- The databases a hint looks the name of a refused module up in, found
--- when the first refusal asks, and the projection among them that the
--- end of the compile closes.
local record Hinting
  mut databases?: {Sqlite.Handle}
  mut public?: {boolean}
  mut projection?: Sqlite.Handle
end

--- A file that does not parse, with the text the checker reads in its place ([`derivation.Broken`]'s `repaired`), and the
--- position among the refusals of the message that refuses it.
local record Mended
  path: string
  file: string
  kind: string
  text: string
  position: integer
end

--- Every module path `target` reaches through what each source at a
--- path requires, itself included. A name no source of the tree is (a
--- standard-library module), or one whose only source does not parse,
--- reaches no further.
local function reach(db: Sqlite.Handle, target: string): {string:boolean}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, r.name FROM inputs i JOIN requires r ON r.source_hash = i.source_hash " ..
      "WHERE i.kind <> 'vendor' ORDER BY i.path, r.ordinal")
  if rows == nil then
    return nil, trouble
  end
  local requires: mut {string:mut {string}} = {}
  for _, row in ipairs(rows) do
    local list = requires[row:text(1)] or {}
    requires[row:text(1)] = list
    local second = row:text(2)
    list[#list + 1] = second
  end
  local reached: mut {string:boolean} = { [target] = true }
  local pending: mut {string} = { target }
  while #pending > 0 do
    for _, name in ipairs(requires[assert(table.remove(pending))] or {}) do
      if reached[name] ~= true then
        reached[name] = true
        pending[#pending + 1] = name
      end
    end
  end
  return reached, ""
end

--- Whether `m` requires a module the run left out (`failed`).
local function leans_on(m: Module, failed: {string:boolean}): boolean
  for _, name in ipairs(m.requires) do
    if failed[name] == true then
      return true
    end
  end
  return false
end

--- The line [`importer.Result`]'s `left_out` holds for `file`, refused
--- with `trouble`, which names `named` -- `file`, or another file of the
--- same source -- at the start of its lines: why, from its first line
--- (`named: named:y:x: why`, a parse's), or from the line after it where
--- the first only says the checker refused it (`named: the compiler
--- refused it`, then a line per error), with `named` there read as `file`.
local function left_out(file: string, named: string, trouble: string): string
  local first = trouble:match("^[^\n]*") or trouble
  local why = first
  if first == named .. ": the compiler refused it" then
    why = trouble:match("^[^\n]*\n([^\n]*)") or first
  elseif first:sub(1, #named + 2) == named .. ": " then
    why = first:sub(#named + 3)
  end
  if why:sub(1, #named + 1) == named .. ":" then
    why = file .. why:sub(#named + 1)
  end
  return file .. " is left out of this run, which does not require it: " .. why
end

--- How long a compile goes on past the first module it refused before it says so, where the caller names no other
--- ([`importer.Outcome`]'s `patience_ns`): a run that ends sooner has said it in its report by then.
local patience_ns <const> = Clock.seconds(2)

--- What a compile that has gone on for `patience` past the first module it refused says of it, once, at `now_ns`:
--- the file and the first finding against it, ahead of the report that tells every refusal when the rest of the tree is
--- checked. A change to the checker compiles every module again, some minutes of them, and the module refused is most
--- often the one just edited. Nil before then, and after it is said. Exported for build/importer_test.tl, which holds
--- it to times it chooses.
function importer.due(early: importer.Early?, now_ns: integer, patience: integer): string?
  if early == nil or early.told or now_ns - early.at_ns < patience then return nil end
  early.told = true
  -- The checker's refusal opens with a line that only says so; any other opens with its first finding.
  local finding = early.trouble:match("^[^\n]*") or ""
  if finding:sub(-#": the compiler refused it") == ": the compiler refused it" then
    finding = early.trouble:match("^[^\n]*\n([^\n]+)") or finding
  end
  return early.file .. " is refused, and the rest of the tree is still being checked; this is the first finding, and " ..
    "the report that follows repeats it\n" .. finding
end

--- An [`importer.Outcome`] that says a refusal ahead of the report on standard error, as the run's other lines are said:
--- what a verb that builds the tree on purpose hands its compile.
function importer.telling(): importer.Outcome
  return { refused = false, tell = function(line: string) log:complain(line) end }
end

--- Plans and compiles an already derived tree. Only the entry points
--- below own the shared cache; every failure here returns through them.
local function compile_derived(handle: work.Handle, tool: string,
                               parses: importer.Parses,
                               unjudged: boolean?, shared: importer.Shared?,
                               checks: boolean, target: string?,
                               broken: {derivation.Broken}?, outcome: importer.Outcome?): importer.Result?, string
  local standing = work.standing(handle)
  local modules, trouble = plans.collect(handle.db)
  if modules == nil then
    return nil, trouble
  end
  -- For a file run, what `target` reaches is `needed`; a module outside
  -- it that does not parse or compile is left out (`failed`), and so is
  -- each module that requires one, rather than stopping the run.
  local needed: {string:boolean}? = nil
  local failed: mut {string:boolean} = {}
  local left: mut {string} = {}
  -- A run with the new checker reads every module and goes on past one it refuses, so that one refusal does not hide the
  -- rest of the tree: a refused module, a module that does not parse and each module that requires one are named in the
  -- result's `refused`, run no tests, and fail the run ([`build.test`]).
  local lenient = target == nil
  local refusals: mut {string} = {}
  local own_refused: mut {string} = {}
  -- The positions in `refusals` of what holds each refused module out, by path and by file ([`importer.Result`]'s
  -- `refusal_roots`).
  local roots_of: mut {string:{integer}} = {}
  local roots_by_file: mut {string:{integer}} = {}
  -- The files that do not parse and have a repaired text ([`derivation.Broken`]'s `repaired`), which the checker reads once
  -- the modules are compiled.
  local mended: mut {Mended} = {}
  -- The first module this run refuses for what it holds, where the caller asked to be told of it ahead of the report.
  -- TODO: say a file that does not parse while the tree is still being derived, once [`importer.derive`] hands each
  -- `broken` to its caller as it is found: the list is read here, when every source is parsed, 40 seconds into a boot
  -- after a change to the checker.
  local tell: function(string)? = nil
  local patience = patience_ns
  if lenient and outcome ~= nil then
    tell = outcome.tell
    patience = outcome.patience_ns or patience_ns
  end
  local noted: mut {importer.Early} = {}
  local function note(file: string, why: string)
    if tell ~= nil and #noted == 0 then
      noted[1] = { file = file, trouble = why, at_ns = Clock.monotonic_ns(), told = false }
    end
  end
  if lenient then
    for _, one in ipairs(broken or {}) do
      local holders, holders_trouble = Sqlite.text_rows(handle.db,
        "SELECT path, file, kind FROM inputs WHERE source_hash = ?1 ORDER BY file", { text(one.source_hash) })
      if holders == nil then
        return nil, holders_trouble
      end
      refusals[#refusals + 1] = one.message
      for _, row in ipairs(holders) do
        failed[row:text(1)] = true
        local held_file = row:text(2)
        note(held_file, one.message)
        own_refused[#own_refused + 1] = held_file
        roots_of[row:text(1)] = { #refusals }
        roots_by_file[held_file] = { #refusals }
        local repaired = one.repaired
        if repaired ~= nil then
          local one_mended: Mended = { path = row:text(1), file = held_file, kind = row:text(3), text = repaired, position = #refusals }
          mended[#mended + 1] = one_mended
        end
      end
    end
  end
  if target ~= nil then
    local reached, reach_trouble = reach(handle.db, target)
    if reached == nil then
      return nil, reach_trouble
    end
    needed = reached
    for _, one in ipairs(broken or {}) do
      -- Each file holding the broken source: files alike are one source.
      local holders, holders_trouble = Sqlite.text_rows(handle.db,
        "SELECT path, file FROM inputs WHERE source_hash = ?1 ORDER BY file", { text(one.source_hash) })
      if holders == nil then
        return nil, holders_trouble
      end
      for _, row in ipairs(holders) do
        if reached[row:text(1)] == true then
          if outcome ~= nil then outcome.refused = true end
          -- TODO: tell what the checker says of a repaired text ([`derivation.Broken`]'s `repaired`) here too, as a run
          -- over the tree does below, once a run that names a file goes on past the first module it cannot build: it
          -- stops here, before any module is read.
          return nil, one.message
        end
      end
      for _, row in ipairs(holders) do
        failed[row:text(1)] = true
        left[#left + 1] = left_out(row:text(2), one.file, one.message)
      end
    end
  end
  local carries = function(name: string): boolean
    -- A declaration has a source but no bytecode.
    local bytecode, _ = Store.bytecode(name)
    return bytecode ~= nil
  end
  -- The modules a run holds out for what they do, not for what they hold: a position rule they break, a `global`
  -- they declare. A run that names a file stops at the first, as it always did; one over the tree refuses the modules
  -- alone ([`importer.Result`]'s `refused`) and goes on, so that a module that breaks none still builds.
  local held_out: mut {string:boolean} = {}
  --- Holds `path` out with `message` among the refusals.
  local function hold(path: string, file: string, message: string)
    refusals[#refusals + 1] = message
    note(file, message)
    if held_out[path] ~= true then own_refused[#own_refused + 1] = file end
    held_out[path] = true
    failed[path] = true
    local resting: mut {integer} = {}
    for _, position in ipairs(roots_of[path] or {}) do resting[#resting + 1] = position end
    resting[#resting + 1] = #refusals
    roots_of[path] = resting
    roots_by_file[file] = resting
  end
  if lenient then
    for _, one in ipairs(positions.violations(modules, standing, carries)) do
      hold(one.module.path, one.module.file, one.message)
    end
  else
    local positioned, position_trouble = positions.check(modules, standing, carries)
    if not positioned then
      if outcome ~= nil then outcome.refused = true end
      return nil, position_trouble
    end
  end
  local order, why = plans.ordered(modules)
  if order == nil then
    if outcome ~= nil then outcome.refused = true end
    return nil, why
  end
  local globals, globals_trouble = plans.global_refusals(handle.db)
  if globals == nil then
    return nil, globals_trouble
  end
  if #globals > 0 then
    -- A `global` of a module is refused by the parser as that module's own (`global_in_program`), so one that reaches
    -- here is a declaration file's, which no one module owns: it stops the tree.
    local lines: mut {string} = {}
    for _, one in ipairs(globals) do lines[#lines + 1] = one.message end
    if outcome ~= nil then outcome.refused = true end
    return nil, table.concat(lines, "\n")
  end
  local keys, keys_trouble = plans.dependency_keys(handle.db, modules, tool)
  if keys == nil then
    return nil, keys_trouble
  end
  -- What the new checker's compile is made over ([`build.pipeline`]), read once the first module needs it. A module is
  -- keyed by its text, which holds its markers.
  local reading: Reading = { options = nil, built = nil }
  local pipeline = require("build.pipeline")
  local made_options, options_trouble = pipeline.options(handle.root, standing.own)
  if made_options == nil then
    return nil, options_trouble
  end
  reading.options = made_options
  local result: importer.Result = {
    modules = {}, tool = tool, main = nil, refused = refusals, own_refused = own_refused,
    refusal_roots = roots_by_file,
    left_out = left, compiled = 0, cached = 0, shared = 0, parses = parses, fact_wraps = 0, parameter_checks = 0,
    catalog = pipeline.catalog,
  }
  local db = handle.db
  local progress: Progress = { failure = "" }

  -- Where a hint (with_docs_hint) looks up the name a refused module
  -- could not resolve, as [`docs.databases`] builds the same list for
  -- `cosmic docs`:
  -- * This tree's last projection, `cosmic.db`, unrestricted. It is
  --   the only place cosmic's own `build.*` symbols are documented,
  --   since the tool carries only the public standard library's
  --   ([`writer.carried`]).
  -- * Then the running binary's own, where a standard-library symbol
  --   such as one of [`cosmic.removed`]'s fields lives for any tree but
  --   cosmic's.
  -- The working database cannot stand in: its `docs` rows are keyed by
  -- source hash, with no module to name. A projection that is missing
  -- or unreadable is left out, since the hint is best effort.
  local hinting: Hinting = {}
  local hints: Hints = function(): {Sqlite.Handle}, {boolean}
    local held_databases, held_public = hinting.databases, hinting.public
    if held_databases == nil or held_public == nil then
      local databases: mut {Sqlite.Handle} = {}
      local public: mut {boolean} = {}
      local projection, _ = Sqlite.open(handle.dir .. "/cosmic.db")
      if projection ~= nil then
        hinting.projection = projection
        databases[1] = projection
        public[1] = false
      end
      for _, store_db in ipairs(Store.databases()) do
        databases[#databases + 1] = store_db
        public[#public + 1] = not standing.own
      end
      hinting.databases, hinting.public = databases, public
      held_databases, held_public = databases, public
    end
    return held_databases, held_public
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
    local judged = unjudged ~= true
    local cache, prepare_trouble = prepare_cache(handle, tool)
    if cache == nil then
      return false, prepare_trouble
    end

    -- The modules this run is to compile itself, made in copies of this process where there are many
    -- ([`build.compile_fanout`]): each neither held out, nor standing here, nor made by another checkout. A module one
    -- of them requires may yet fail, and the loop below then leaves it out as it does: its compile is made for nothing.
    local fanned: importer.Shared.Fanned? = nil
    local function finish_all()
      local made_at_once = fanned
      if made_at_once ~= nil then made_at_once.close() end
      finish_cache(cache)
    end
    local fan = if shared ~= nil then shared.fan else nil end
    if fan ~= nil and shared ~= nil then
      local due: mut {Module} = {}
      local by_path: mut {string:Module} = {}
      for _, m in ipairs(order) do
        local planned = assert(keys[m.path], "every module of the order was keyed")
        m.key = planned.key
        m.graph_key = planned.graph
        by_path[m.path] = m
        if held_out[m.path] ~= true and plans.refusal(m) == nil then
          local stands, _ = cached_stands(cache, planned.key)
          local known = shared.known
          if not stands and not (known ~= nil and known(m, standing.own)) then due[#due + 1] = m end
        end
      end
      -- The tree is read before the copies are made, so each holds it: the first module the loop compiles would read it
      -- anyway. One that cannot be read is the loop's to say, and nothing is made at once.
      if #due > 0 then
        local made_built, _ = pipeline.build(handle.db, assert(reading.options))
        if made_built ~= nil then
          reading.built = made_built
          -- What a copy makes of each module it says at once, in a file every copy and this process read as they go, a
          -- line a module: that it compiled, or that it could not and why. A copy compiles no module that requires one
          -- that could not be, as the loop below leaves each out. This process tells of the first such module while
          -- the copies still run ([`importer.due`]), once every module it requires is said to have compiled: a copy
          -- reaches a module before another reaches what it requires, and fails it for what is wrong there, so a
          -- module is told of only when the fault is its own. Each process takes up the file where it left it.
          local said_dir, _ = Fs.mkdtemp("cosmic-refused-")
          local said_path = if said_dir ~= nil then said_dir .. "/said" else nil end
          local read_to = 0
          --- The lines said since this process last asked: for each, whether its module compiled, the module's path,
          --- its file and why it did not.
          local function heard(): {{string}}
            local out: mut {{string}} = {}
            local data: string? = nil
            if said_path ~= nil then data, _ = Fs.read(said_path) end
            if data == nil then return out end
            local whole = data:sub(read_to + 1):match("^(.*\n)") or ""
            read_to = read_to + #whole
            for kind, path, file, why_text in whole:gmatch("([^\t\n]*)\t([^\t\n]*)\t([^\t\n]*)\t([^\t\n]*)\n") do
              out[#out + 1] = { kind, path, file, (why_text:gsub("%%(%x%x)", function(hex: string): string
                return string.char(math.tointeger(tonumber(hex, 16)) or 0)
              end)) }
            end
            return out
          end
          --- Says of the module `m` that it compiled, or with `reason` that it could not be.
          local function say(m: Module, reason?: string)
            if said_path == nil then return end
            local escaped = (reason or ""):gsub("[%%\t\n]", function(c: string): string
              return string.format("%%%02x", c:byte() or 0)
            end)
            local _, _ = Fs.append(said_path, (if reason == nil then "ok" else "no" end) .. "\t" .. m.path .. "\t" .. m.file ..
                "\t" .. escaped .. "\n")
          end
          local refused_now: mut {string:boolean} = {}
          -- Whether the copies are told to make no more (a line "stop"): a run of a file stops at the first module
          -- it needs that does not build, so what a copy would compile after it is made for nothing. A copy keeps
          -- what it made only as it ends, so the copies are told and left to end rather than ended.
          local stopped = false
          -- Where each module the copies are to compile comes among them.
          local place: mut {string:integer} = {}
          for index, m in ipairs(due) do place[m.path] = index end
          local leaning: mut {string:boolean} = {}
          --- Whether the module at `path` requires, directly or not, one that does not build.
          local function leans(path: string): boolean
            local known = leaning[path]
            if known ~= nil then return known end
            leaning[path] = false
            local m = by_path[path]
            local found = false
            local required: {string} = if m ~= nil then m.requires else {} end
            for _, name in ipairs(required) do
              if not found and (failed[name] == true or refused_now[name] == true or leans(name)) then
                found = true
              end
            end
            leaning[path] = found
            return found
          end
          -- In this process: the modules the copies are to compile, those said to have compiled, and those said not to,
          -- in the order they were said, each with its file and why.
          local awaited: mut {string:boolean} = {}
          for _, m in ipairs(due) do awaited[m.path] = true end
          local compiled_now: mut {string:boolean} = {}
          -- Those a copy said it left uncompiled, since each requires one that did not compile.
          local left_now: mut {string:boolean} = {}
          local unsettled: mut {{string}} = {}
          --- Whether every module `path` requires, directly or not, that the copies are to compile is said to have
          --- compiled ("yes"), one is said not to have ("no"), or it is not known yet ("wait").
          local function requires_settled(path: string, seen: mut {string:boolean}): string
            local m = by_path[path]
            local required: {string} = if m ~= nil then m.requires else {} end
            local answer = "yes"
            for _, name in ipairs(required) do
              if seen[name] ~= true then
                seen[name] = true
                if failed[name] == true or refused_now[name] == true then return "no" end
                local below = requires_settled(name, seen)
                if below == "no" then return "no" end
                if below == "wait" or (awaited[name] == true and compiled_now[name] ~= true) then
                  answer = "wait"
                end
              end
            end
            return answer
          end
          fanned = fan(due, standing.own, function(m: Module, rest: {string:boolean}): importer.Shared.Compile?
            for _, one in ipairs(heard()) do
              if one[1] == "no" then
                refused_now[assert(one[2])] = true
                leaning = {}
              elseif one[1] == "stop" then
                stopped = true
              end
            end
            if stopped then return nil end
            if leans(m.path) then
              -- Said, so that the process knows the module is not still to come.
              if said_path ~= nil then
                local _, _ = Fs.append(said_path, "left\t" .. m.path .. "\t" .. m.file .. "\t\n")
              end
              return nil
            end
            -- No hints: what a copy is refused it does not keep, and the build says it with them.
            local made, make_trouble = pipeline.generate(m, made_built, checks, judged)
            -- A copy lowers the modules its own require, most of them another copy's to compile, which nothing here
            -- would retire: it forgets each but those it has yet to compile, and holds what the build does alone.
            pipeline.forget(made_built, rest)
            if made == nil then say(m, make_trouble) else say(m) end
            if made == nil or made.refused then return nil end
            return { lua = made.lua, bytecode = made.bytecode, references = made.references,
              fact_wraps = made.fact_wraps, parameter_checks = made.parameter_checks }
          end, function()
            for _, one in ipairs(heard()) do
              local path = assert(one[2])
              if one[1] == "ok" then
                compiled_now[path] = true
              elseif one[1] == "no" then
                refused_now[path] = true
                unsettled[#unsettled + 1] = one
              elseif one[1] == "left" then
                left_now[path] = true
              end
            end
            local waiting: mut {{string}} = {}
            for _, one in ipairs(unsettled) do
              local settled = requires_settled(assert(one[2]), {})
              if settled == "yes" then
                note(assert(one[3]), assert(one[4]))
              elseif settled == "wait" then
                waiting[#waiting + 1] = one
              end
            end
            unsettled = waiting
            if not stopped and needed ~= nil and said_path ~= nil then
              -- The loop below stops at the first module the file needs that does not build: once one is said not
              -- to, and every module before it is said either way, nothing a copy has yet to make is read.
              local first: integer? = nil
              for path in pairs(refused_now) do
                local at = place[path]
                if at ~= nil and needed[path] == true and (first == nil or at < first) then
                  first = at
                end
              end
              local settled = first ~= nil
              if first ~= nil then
                for index = 1, first - 1 do
                  local before = assert(due[index], "an index within the list is a module").path
                  if compiled_now[before] ~= true and refused_now[before] ~= true and left_now[before] ~= true then
                    settled = false
                  end
                end
              end
              if settled then
                stopped = true
                local _, _ = Fs.append(said_path, "stop\t\t\t\n")
              end
            end
            if tell ~= nil then
              local said = importer.due(noted[1], Clock.monotonic_ns(), patience)
              if said ~= nil then tell(said) end
            end
          end)
          if said_dir ~= nil then local _, _ = Fs.remove_tree(said_dir) end
        end
      end
    end

    for ordinal, m in ipairs(order) do
      if tell ~= nil then
        local said = importer.due(noted[1], Clock.monotonic_ns(), patience)
        if said ~= nil then tell(said) end
      end
      local planned = assert(keys[m.path], "every module of the order was keyed")
      local key = planned.key
      m.key = key
      m.graph_key = planned.graph

      local refusal = plans.refusal(m)
      if held_out[m.path] == true then
        -- Told of already, with the rule it breaks.
        failed[m.path] = true
      elseif needed ~= nil and needed[m.path] ~= true and leans_on(m, failed) then
        -- Left out quietly: the module it requires was told of.
        failed[m.path] = true
      elseif lenient and leans_on(m, failed) then
        local lacking = ""
        local resting: mut {integer} = {}
        local seen: mut {integer:boolean} = {}
        for _, name in ipairs(m.requires) do
          if failed[name] == true then
            if lacking == "" then
              lacking = name
            end
            for _, position in ipairs(roots_of[name] or {}) do
              if seen[position] ~= true then
                seen[position] = true
                resting[#resting + 1] = position
              end
            end
          end
        end
        table.sort(resting)
        failed[m.path] = true
        -- The module cannot be built, and is checked all the same where the declarations of every refused module it
        -- requires stand: its own findings are told in this run, and nothing of it is written, kept or run.
        local examined = reading.built
        local checked = examined ~= nil
        for _, name in ipairs(m.requires) do
          if failed[name] == true and (examined == nil or examined.standing[name] ~= true) then
            checked = false
          end
        end
        local own_trouble = ""
        if refusal ~= nil then
          checked = false
          own_trouble = refusal
        elseif checked and examined ~= nil then
          own_trouble = pipeline.examine(m, examined, judged, hints)
        end
        if own_trouble ~= "" then
          if checked then
            -- A finding here holds of the declarations as they are written, which the fix of the other module may change:
            -- the line says so, since the tree as written does disagree and either side may be the one to change.
            own_trouble = own_trouble .. "\n" .. m.file .. ": checked against the declarations of " .. lacking ..
              " as they are written, though it did not build: a fix there that changes a declaration may settle a finding here"
          end
          result.refused[#result.refused + 1] = own_trouble
          own_refused[#own_refused + 1] = m.file
          resting[#resting + 1] = #result.refused
        else
          -- [`build.refusals`] reads the end of the line to say which files were checked.
          result.refused[#result.refused + 1] = m.file .. ": not compiled: it requires " .. lacking ..
            ", which did not build" .. (if checked then "; checked all the same, it has no finding of its own" else "" end)
        end
        roots_of[m.path] = resting
        roots_by_file[m.file] = resting
      elseif refusal ~= nil then
        note(m.file, refusal)
        result.refused[#result.refused + 1] = refusal
        own_refused[#own_refused + 1] = m.file
        roots_of[m.path] = { #result.refused }
        roots_by_file[m.file] = { #result.refused }
      else
        local stands, look_trouble = cached_stands(cache, key)
        if not stands and look_trouble ~= "" then
          finish_all()
          return false, look_trouble
        end
        -- The Lua of a compile made or copied here, not of one that stands.
        local lua: string? = nil
        local bytecode: string? = nil
        local refused = false
        -- What the Lua of the module checks: the counts of the compile that stands or was copied, or made here.
        local fact_wraps, parameter_checks = cache.wraps, cache.checks
        -- Another checkout's compile stands for one made here: its key
        -- and what else decides it are the same ([`build.shared_compiles`]),
        -- and it lands as a compile does, uses and all.
        local elsewhere: importer.Shared.Compile? = nil
        if not stands and shared ~= nil then
          elsewhere = shared.look(m, standing.own)
        end
        if stands then
          result.cached = result.cached + 1
        elseif elsewhere ~= nil then
          lua = elsewhere.lua
          bytecode = elsewhere.bytecode
          fact_wraps, parameter_checks = elsewhere.fact_wraps, elsewhere.parameter_checks
          result.cached = result.cached + 1
          result.shared = result.shared + 1
          local kept_refs, refs_trouble = plans.keep_references(db, key, elsewhere.references)
          if not kept_refs then
            finish_all()
            return false, m.file .. ": " .. refs_trouble
          end
        else
          local generated: plans.Generated? = nil
          -- Read the tree once, when the first module that is not cached asks.
          if reading.built == nil then
            local tree_refusal: pipeline.Refusal = { refused = false }
            local made_built, built_trouble = pipeline.build(handle.db, assert(reading.options), tree_refusal)
            if made_built == nil then
              if tree_refusal.refused and outcome ~= nil then outcome.refused = true end
              progress.failure = built_trouble
              break
            end
            reading.built = made_built
          end
          local made_generated, generate_trouble: plans.Generated?, string = nil, ""
          local taken = if fanned ~= nil then fanned.look(m) else nil end
          if taken ~= nil then
            -- A copy of this process made it: the build has written the module, as if it had made it here.
            pipeline.took(m, assert(reading.built))
            made_generated = { lua = taken.lua, bytecode = taken.bytecode, references = taken.references, refused = false,
              fact_wraps = taken.fact_wraps, parameter_checks = taken.parameter_checks }
          else
            made_generated, generate_trouble = pipeline.generate(m, assert(reading.built), checks, judged, hints)
          end
          if made_generated == nil then
            if lenient then
              note(m.file, generate_trouble)
              result.refused[#result.refused + 1] = generate_trouble
              own_refused[#own_refused + 1] = m.file
              roots_of[m.path] = { #result.refused }
              roots_by_file[m.file] = { #result.refused }
              failed[m.path] = true
            elseif needed == nil or needed[m.path] == true then
              progress.failure = generate_trouble
              if outcome ~= nil then outcome.refused = true end
              break
            end
            table.insert(result.left_out, left_out(m.file, m.file, generate_trouble))
            failed[m.path] = true
          end
          generated = made_generated
          if generated ~= nil then
            lua = generated.lua
            bytecode = generated.bytecode
            refused = generated.refused
            fact_wraps, parameter_checks = generated.fact_wraps, generated.parameter_checks
            result.compiled = result.compiled + 1
            local kept_refs, refs_trouble = plans.keep_references(db, key,
              generated.references)
            if not kept_refs then
              finish_all()
              return false, m.file .. ": " .. refs_trouble
            end
            -- A refused compile is this run's alone (`remember`), and
            -- never another checkout's.
            if shared ~= nil and not refused then
              shared.keep(m, standing.own, { lua = generated.lua, bytecode = generated.bytecode,
                references = generated.references, fact_wraps = generated.fact_wraps,
                parameter_checks = generated.parameter_checks })
            end
          end
        end
        -- Nothing stands, and nothing is made, only for a module left out
        -- above, of which nothing is kept.
        if stands or lua ~= nil then
          m.lua = lua
          result.fact_wraps = result.fact_wraps + fact_wraps
          result.parameter_checks = result.parameter_checks + parameter_checks
          local kept, keep_trouble = remember(cache, m.path, key, ordinal, lua,
            bytecode, refused, fact_wraps, parameter_checks)
          if not kept then
            finish_all()
            return false, m.file .. ": " .. keep_trouble
          end
          if m.kind == "main" then
            result.main = m.path
          end
          result.modules[#result.modules + 1] = m -- checked: view_written
        end
      end
    end

    -- A file refused for a `global` alone is read with `local` in its place, and what the checker says of that text is
    -- told under the parser's line: the findings the next run would tell once the fix is made. Nothing is said where it
    -- requires a module whose declarations do not stand, which would be told as its own fault.
    --
    -- TODO: check the modules that require such a file against its repaired text too, once a source that does not parse
    -- has a place in the order the modules are compiled in ([`plans.ordered`] plans only what was derived): they are met
    -- before it here, and keep the line of a file not checked.
    for _, one in ipairs(mended) do
      local examined = reading.built
      if examined == nil then
        local made_built, _ = pipeline.build(handle.db, assert(reading.options))
        reading.built = made_built
        examined = made_built
      end
      local required, _ = pipeline.requires(one.file, one.text)
      local sound = examined ~= nil and required ~= nil
      for _, name in ipairs(required or {}) do
        if failed[name] == true and (examined == nil or examined.standing[name] ~= true) then
          sound = false
        end
      end
      if sound and examined ~= nil then
        local module: Module = {
          path = one.path, file = one.file, kind = one.kind, source = one.text, source_hash = "", requires = {}, tests = {},
          inputs = nil,
        }
        local more = pipeline.examine(module, examined, judged, hints, one.text)
        local head = one.file .. ": the compiler refused it\n"
        if more:sub(1, #head) == head then
          more = more:sub(#head + 1)
        end
        if more ~= "" then
          local told = assert(table.remove(result.refused, one.position), "the refusal of a file that does not parse is kept")
          table.insert(result.refused, one.position, told .. "\n" .. one.file .. ": with `local` written for `global`, " ..
              "as the fix says, the checker refuses this too\n" .. more)
        end
      end
    end

    finish_all()
    local pruned, prune_trouble = Sqlite.run(db,
      "DELETE FROM compiled WHERE tool <> ?1 OR (seen >= 0 AND seen < ?2)" ..
        (if judged then " OR seen < 0" else "" end),
      { text(tool), { integer = handle.run - kept_runs - refresh_after } })
    if not pruned then
      return false, prune_trouble
    end
    -- Run whether or not the prune above dropped anything: a run that
    -- failed between a compile's [`plans.keep_references`] and its `remember`
    -- commits the uses without the compile (build.dispatch closes the
    -- handle, keeping what the run did), and only this sweeps them.
    return db:exec(importer.prune_references)
  end
  local made, compile_trouble = compile_all()
  local hinting_projection = hinting.projection
  -- The projection the hints opened, once a message earned one.
  if hinting_projection ~= nil then
    local _, _ = hinting_projection:close()
  end
  if not made then
    return nil, compile_trouble
  end
  if progress.failure ~= "" then
    return nil, progress.failure
  end
  return result, ""
end

--- The compiler a self-build runs, chosen once the tree's identities are
--- recorded.
local type Choose = function(identities.Identities): string?, string

--- A self-build chooses the compiler that actually runs only after the
--- analyzer has stabilized and the complete tree identities are recorded.
local function prepare_compile(handle: work.Handle, tool: string,
                               unjudged: boolean?, shared: importer.Shared?,
                               choose: Choose?,
                               checks: boolean, target: string?,
                               outcome: importer.Outcome?): importer.Result?, string
  local broken: {derivation.Broken} = {}
  local parses, derive_trouble = importer.derive(handle, shared, broken, outcome) -- checked: not_assignable
  if parses == nil then return nil, derive_trouble end
  if choose ~= nil then
    local recorded, record_trouble = identities.record_identities(handle.db)
    if recorded == nil then return nil, record_trouble end
    local selected, select_trouble = choose(recorded)
    if selected == nil then return nil, select_trouble end
    tool = selected
    -- What it is made by is the code that reads: the checker and the readers. A boot runs the tree's own, which the
    -- tool it stands in for does not carry yet, so the tree says what it is; a rebuild runs the tool's.
    local pipeline = require("build.pipeline")
    if Store.meta("boot_hash") == nil then
      local coded, coded_trouble = pipeline.coded_of(tool, handle.db)
      if coded == nil then return nil, coded_trouble end
      tool = coded
    else
      tool = pipeline.coded(tool)
    end
  end
  return compile_derived(handle, tool, parses, unjudged, shared, checks, target, broken, outcome)
end

--- The cache belongs to the whole derive/identity/compile operation,
--- including successful rows offered before a later phase fails.
local function consuming_compile(handle: work.Handle, tool: string,
                                 unjudged: boolean?, shared: importer.Shared?,
                                 choose?: function(identities.Identities): string?, string,
                                 checks?: boolean, target?: string,
                                 outcome?: importer.Outcome): importer.Result?, string
  local result, trouble = prepare_compile(handle, tool, unjudged, shared, choose, checks == true, target, outcome)
  if shared ~= nil then shared.finish() end
  if result == nil then return nil, trouble end
  return result, ""
end

--- The identity of the compiler `tool` names when it writes the run-time
--- checks of a typed boundary into what it compiles ([`importer.compile`]'s
--- `checks`). Every key carries it in `tool`'s place, so a module compiled
--- with checks and one without share no row of the working database and no
--- entry of the compiles every checkout shares, and the verdict of a test
--- keyed by it is kept apart from a test run without.
---
--- `wraps` says the checks are the calls of `__fact` that the new checker's code
--- generator writes at the reads a test narrowed ([`lang.fact_wraps`]) and the calls of
--- `__cosmic_tc` at the typed parameters of a function ([`lang.boundary_checks`]), and not
--- the fork's `__cosmic_tc`: the Lua of the two differs, so their keys do. The key holds
--- what the compile adds, so a list of checks that grows (the returns and the fields written,
--- later) moves it and no entry compiled with fewer is the answer. A
--- compile cached with the one is never the answer to a request for the other,
--- nor for none.
function importer.checked_tool(tool: string, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (if wraps == true then "\0fact-wraps\0parameter-checks\0counted" else "\0run-time-checks" end))
end

--- What a compile that asked to be reused stood on, and what it made.
local record Standing
  root: string
  tool: string
  unjudged: boolean
  checks: boolean
  --- [`tree_state`] as the compile left it.
  state: string
  result: importer.Result
end

--- What this process holds of it, if anything.
local record Held
  mut standing: Standing?
end

local kept: Held = { standing = nil }

--- A digest of what a compile reads of the working database and leaves in
--- it: each staged file by its hash, each derived source, and the plan of
--- modules and keys it wrote. Nil where the database will not say.
local function tree_state(db: Sqlite.Handle): string?
  local rows, _ = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(" ..
      "coalesce((SELECT group_concat(path || char(0) || sha256, char(10)) FROM " ..
      "(SELECT path, sha256 FROM files ORDER BY path)), '') || char(1) || " ..
      "coalesce((SELECT group_concat(file || char(0) || path || char(0) || kind || char(0) || source_hash, " ..
      "char(10)) FROM (SELECT file, path, kind, source_hash FROM derived ORDER BY file, path)), '') || char(1) || " ..
      "coalesce((SELECT group_concat(path || char(0) || key || char(0) || ordinal, char(10)) FROM " ..
      "(SELECT path, key, ordinal FROM plan ORDER BY path)), ''))))")
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

--- Compiles every module, in import order, into Lua and bytecode --
--- or finds it already compiled under the same key. The keys and the
--- compiles land in the working database inside the run's
--- transaction, kept even when a later module refuses, so a run that
--- fails still pays for each module once; a compile another tool
--- made, or one no run has used lately, is dropped.
---
--- The tree is read, checked and written by the new checker ([`build.pipeline`]) in this process: `tool` is the one
--- [`build.grammar_mode`] chose, and the keys hold the code that reads as well ([`build.pipeline`]'s `coded`).
--- @param handle the working database the tree is staged in
--- @param tool the identity of the compiler doing the compiling, which
---   every key carries
--- @param unjudged whether a module build.syntax_contracts refuses is kept
---   rather than refused: a stale tool rebuilding itself ([`build.reboot`])
---   judges the tree by its own, older rules and exemptions, so it
---   leaves the last word to the tool it builds, which re-enters the
---   command. A compile the old rules refuse is kept only for this run's
---   database, never reused, so the next run compiles and judges the
---   module again; one they pass is cached as any other, since a change
---   to the rules themselves moves the tool's identity, and with it every key.
--- @param shared the compiles and parses every checkout shares, or nil
---   for none: a module whose key misses here is taken from them rather
---   than compiled, and every compile made here but a refused one is
---   offered them, as its derive takes and offers parses
---   ([`importer.derive`]). Finished before this returns, whatever it
---   returns, with whatever an earlier derive given them offered.
--- @param outcome set to `refused` where the compile answers nothing for a refusal of the source: an import cycle, a
---   global, a misplaced [`Test.policy`]; not for a trouble of the host
--- @param checks whether the compiled Lua checks a value against its declared
---   kind: each read of a place a test narrowed is wrapped in a call of `__fact` ([`lang.fact_wraps`]), and each function
---   with typed parameters checks them ([`lang.boundary_checks`]). It keys every
---   compile by [`importer.checked_tool`], so no cache shares an entry between the two.
function importer.compile(handle: work.Handle, tool: string, unjudged?: boolean,
                          shared?: importer.Shared, checks?: boolean, again?: boolean,
                          outcome?: importer.Outcome): importer.Result?, string
  -- What it is made by is the code that reads: the checker and the readers.
  local pipeline = require("build.pipeline")
  tool = pipeline.coded(tool)
  if checks == true then
    tool = importer.checked_tool(tool, true)
  end
  if again ~= true then
    return consuming_compile(handle, tool, unjudged, shared, nil, checks, nil, outcome)
  end
  -- The caller built this tree already, in this process, and asks for that
  -- build where nothing it stands on has moved.
  local before = kept.standing
  if before ~= nil and before.root == handle.root and before.tool == tool and before.unjudged == (unjudged == true) and
      before.checks == (checks == true) and before.state == tree_state(handle.db) then
    if shared ~= nil then shared.finish() end
    local was = before.result
    local again_result: importer.Result = {
      modules = was.modules, tool = was.tool, main = was.main, refused = was.refused, own_refused = was.own_refused,
      refusal_roots = was.refusal_roots,
      left_out = was.left_out,
      compiled = 0, cached = #was.modules, shared = 0, parses = was.parses, catalog = was.catalog,
      fact_wraps = was.fact_wraps, parameter_checks = was.parameter_checks,
    }
    return again_result, ""
  end
  local result, trouble = consuming_compile(handle, tool, unjudged, shared, nil, checks, nil, outcome)
  kept.standing = nil
  if result == nil then return nil, trouble end
  local state = tree_state(handle.db)
  if state ~= nil then
    kept.standing = { root = handle.root, tool = tool, unjudged = unjudged == true, checks = checks == true,
      state = state, result = result }
  end
  return result, ""
end

--- The tool string a compile of this binary's own compiler is keyed by
--- ([`build.grammar_mode`]'s `tool`): the compiler's
--- identity the build that made this binary recorded (its `meta`'s
--- `compiler`), so a project's rows made by another compiler are compiled
--- again. A worker's read of it is answered by the running tool
--- ([`build.key_parts`]' `meta_readers` names this module for it).
function importer.own_tool(): string
  return GrammarMode.tool(Store.meta("compiler") or "")
end

--- Compiles every module as [`importer.compile`] does, for a file run
--- whose file is the module `target`: a source that does not parse, or a
--- module that does not compile, stops the build only where `target`
--- reaches it through what it requires. One it does not reach is left out,
--- with a line in the result's `left_out`, and so is each module that
--- requires it, so a broken file beside the one run does not stop it.
--- Where `target` reaches one, it fails as [`importer.compile`] does, with
--- the same message, and sets `outcome`'s `refused`. Consumes `shared` as that does.
--
-- TODO: leave out a module outside `target`'s reach that a tree-wide check
-- refuses too -- a misplaced [`Test.policy`], a cycle of imports, a global, a
-- position breach (a private module required from outside its directory), an
-- unknown `cosmic.*` require -- once those checks name the modules they
-- refuse rather than answering one message for the tree: today any of them
-- stops a file run whatever the file reaches.
function importer.compile_for(handle: work.Handle, tool: string, target: string,
                              shared?: importer.Shared, outcome?: importer.Outcome): importer.Result?, string
  return consuming_compile(handle, require("build.pipeline").coded(tool), false, shared, nil, false, target, outcome)
end

--- Compiles a self-build after deriving its sources and recording its
--- complete identities. `choose` selects the compiler actually running:
--- the tree's for a boot, the running tool's until a rebuild settles.
--- Like [`importer.compile`], consumes `shared`, finishing
--- it exactly once on success or failure. The working database and its
--- transaction remain the caller's, as does publishing the completed
--- projection. `choose` answers the tool string [`build.grammar_mode`] makes of the compiler's identity.
function importer.compile_tree(handle: work.Handle, choose: function(identities.Identities): string?, string,
                               unjudged: boolean, shared?: importer.Shared,
                               outcome?: importer.Outcome): importer.Result?, string
  return consuming_compile(handle, "", unjudged, shared, choose, false, nil, outcome)
end

return importer
