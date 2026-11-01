--- Where `cosmic lsp` ([`build.lsp`]) reads a project's modules from: the
--- working database of the workspace's root, `build.db` in its build
--- directory ([`build.paths`]), as a build reads them, and the documents
--- the editor holds open, whose text comes over the protocol. What the
--- build derived of a text it does not hold (an open document that was
--- edited, a file whose rows are another analyzer's) is derived here into a
--- private in-memory database that only this process reads
--- ([`source.places`]); `build.db` is never written, so nothing a `cosmic
--- test` holds it for waits on the session, and no build sees an unsaved
--- text: no unsaved text or scratch row is written to `build.db` (its
--- staging of the files on disk below is the build's own).
---
--- The database is brought up to the files on disk by the build's own
--- staging ([`rebuild.stage`]: [`work.stage`], then [`importer.derive`]),
--- before the first check and again when the editor says files changed
--- on disk (a save, or a watched file), and at no other time: nothing
--- here reads a project's file, lists a directory or stats a path, so a
--- file changed on disk with no word from the editor is read as it was
--- staged. A module is what the `inputs` view lists (a declaration ahead
--- of a source of the same import path, a directory's `init.tl`, a
--- template's Teal), and an open document stands in for the file it
--- is; a name the database does not list is not found, whatever is
--- open. The binary's own `cosmic.*` modules are the checker's
--- ([`build.lsp.check`]), and the tool's database that carries them also carries where each declares its types and
--- members ([`source.places`]), which a project's database does not list. A root that is no project
--- ([`rebuild.stage`]) is never staged, as a lookup never starts a tree of its own: a build
--- would find its modules, and this finds none, so nothing is checked
--- there ([`source.outside`]). Each refresh asks again whether a build was
--- started there, looking at the build directory's own files alone
--- ([`rebuild.started`]), and the first that finds one stages the tree.
---
--- The stage is also what tells whether the root is cosmic's own tree,
--- and where its build directory is, so nothing else here looks at the
--- root. The database is the build directory's file: a run that finds
--- its schema stale makes it again ([`work.open`]), and the handle on the
--- old one would read it forever, so each refresh compares the file the
--- path names with the one the handle reads, and opens it again when they
--- part.
---
--- A module is served as its stub ([`build.syntax_stub`]) where it has one, as
--- cosmic serves its standard library: the checker reads a fraction of
--- it, and the stub types a `require` of it as its source does but where a
--- body declares past itself ([`build.syntax_stub`]), which nothing here checks.
--- The stub of a
--- file is the one the stage derived of its source (the `stubs` row of its
--- `source_hash`), while the database's rows are the running analyzer's:
--- the one this session's own stage recorded deriving them (the `meta`
--- row `analyzer`), or before one, the binary's
--- ([`importer.analyzer_identity`]); otherwise, and for an open document,
--- it is made here from the text, once a text. Another run may derive
--- the rows again with another analyzer at any time, so the row is read
--- again at every refresh, and a module served is named by which of the
--- two it was served as ([`source.key`]).
---
--- Reading waits on no lock. The database is in write-ahead mode
--- ([`work.open`]), so the read handle reads the last commit at once
--- while another run holds the write lock for minutes (a `cosmic test`
--- compiling, say). Staging is a write, and waits for no other run
--- either ([`rebuild.stage`]): where another holds the write lock, the
--- session says so, does not stage, and answers from the tree as last
--- committed; that run stages the same tree, and its commit brings the
--- database up to it. It stages again at its next check. A database of
--- another schema, another tool's, it neither stages nor reads, and
--- finds no module in, saying so, until a run of this tool makes it
--- again: found so by a stage, or when the file is made again under the
--- session. Nor does it find a module in a database that other code
--- than its own staged last ([`work.other_code`]), a run of a newer
--- tool or an older one, saying so, until a stage of this tool's code
--- stages it again; which code staged it is read again at every
--- refresh, as the analyzer is.

-- TODO: serve a module whose body declares past itself as its source, or
-- as a stub that keeps such bodies, once [`build.syntax_stub`]'s TODO is done:
-- until then a dependent of a module whose body adds a function to an
-- outer record is told the record has no such field.

local AnalysisSchema = require("build.analysis_schema")
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Derivation = require("build.syntax_derivation")
local Driver = require("build.driver")
local Node = require("build.syntax_node")
local Places = require("build.syntax_places")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Template = require("cosmic.template")
local TreeProgram = require("build.tree_program")
local build_paths = require("build.paths")
local importer = require("build.importer")
local rebuild = require("build.rebuild")
local type tree = require("build.tree")
local syntax_read = require("build.lsp.syntax_read")
local work = require("build.work")

local record source
  --- A module as the working database lists it (the `inputs` view).
  record Module
    path: string
    file: string
    kind: string
    source_hash: string
    --- Where the source comes from: `tree` for a staged file, else the kind of generator that made it from `file`
    --- (`syscalls`, `doctest`, `template`).
    origin: string
  end

  --- What the checker is served for a module: the file name it reads it
  --- under, the text (its stub, a template's Teal, or its source), and
  --- what it was served from, which names it again exactly when the text
  --- would be the same ([`source.key`]).
  record Served
    file: string
    text: string
    key: string
  end

  --- How each module was served, and what the session did to read them:
  --- what a test reads to tell each path was taken.
  record Tally
    --- Served as the stub the stage derived (its `stubs` row).
    mut database_stubs: integer
    --- Served as a stub made in this process, of an open document or of
    --- a source whose `stubs` rows are not the running analyzer's.
    mut made_stubs: integer
    --- Served as its source: a declaration, or one that has no stub.
    mut sources: integer
    --- Served as a template's Teal.
    mut templates: integer
    --- Documents whose [`Shape.record_of`] calls were found in the whole
    --- text.
    mut whole_splices: integer
    --- Stages made, and times the database was found made again and
    --- opened anew.
    mut stages: integer
    mut reopened: integer
    --- Texts derived into the scratch database ([`source.places`]): an
    --- open document that differs from the staged file, or a file whose
    --- rows are not the running analyzer's. A text that does not parse
    --- is counted for the places of its recovered tree; one whose rows fail to
    --- write is not.
    mut derived: integer
    --- Completions of a module's members read from the `members` rows ([`source.members`]), and from the checker's
    --- declarations of its stub, where there are no rows.
    mut member_rows: integer
    mut member_declarations: integer
  end

  --- A module's text as its file holds it, not as the checker is served it (a stub, a template's Teal): where a place in
  --- the module is found for a person ([`build.lsp.definition`]).
  record Written
    --- The module's file, below the root.
    file: string
    text: string
  end

  --- Where a name is declared in a module's text: the line (from 1), the column and the length in bytes, the checker's
  --- ([`lang.lexer`]'s `y` and `x`).
  record Spot
    line: integer
    column: integer
    length: integer
  end

  --- Where a module declares its types and their members, by dotted symbol ([`build.syntax_places`]), and the text and the
  --- file they are places in.
  record Placed
    --- The module's file, below the root.
    file: string
    text: string
    --- The first place of each symbol.
    spots: {string:Spot}
    --- The SHA-256 of the text, as hex, where the module is the binary's own ([`source.places`]) and `file` is
    --- below no root ([`source.extracted`]); nil for a module of the root.
    carried?: string
  end

  --- One member of a declared type, as the `members` rows hold it ([`build.syntax_members`]), with the documentation of the
  --- same symbol in the `docs` rows of the text.
  record MemberRow
    name: string
    --- "field", "method", "function" or "value".
    kind: string
    --- "instance", "value" or "both".
    scope: string
    --- The type as written, "" for an enum's value.
    type: string
    doc: string
  end

  --- A type the `members` rows hold: "record", "class", "interface" or "enum", the interfaces it lists as written, and its
  --- members in the order the rows are in.
  record MemberOwner
    kind: string
    supers: {string}
    members: {MemberRow}
  end

  --- The types a text declares, by dotted symbol ([`build.syntax_places`]).
  type Members = {string:MemberOwner}

  --- An open document's text, and its SHA-256.
  record Text
    text: string
    hash: string
  end

  --- The open document that is the file `file` below the root, or nil
  --- when none is open.
  type Open = function(file: string): Text?

  --- One session's view of the database.
  record View
    root: string
    --- The `built_from` the tool carries, by default the binary's ([`tree.standing`]).
    carried: string?
    --- The databases the binary's own modules are read from, the last the tool's own: [`Store.databases`] when nil.
    store: {Sqlite.Handle}?
    --- A read handle on `build.db`, nil until there is one to read, and
    --- the device and inode of the file it reads.
    mut db: Sqlite.Handle?
    mut identity: string
    --- The database's path, once a stage has found the build directory.
    mut working: string?
    --- What the last stage found of the root, nil before the first.
    mut where: rebuild.Where?
    --- Each module by its import path, and by its file.
    mut modules: {string:Module}
    mut files: {string:Module}
    --- What each source requires, by its `source_hash` (the `requires`
    --- rows), in order.
    mut requires: {string:{string}}
    --- Whether the `stubs` rows are the running analyzer's, and the
    --- analyzer this session's last stage recorded, nil before one.
    mut stubs: boolean
    mut analyzer: string?
    --- Why the last stage staged nothing, "" for a stage that did. A document of a pair it refused is told of it
    --- ([`source.refusal`]).
    mut trouble: string
    --- Whether the tree is yet to be staged: before the first check, or
    --- since a stage that found the database busy.
    mut pending: boolean
    --- Whether the session has said the database is busy, since it last
    --- staged.
    mut told_busy: boolean
    --- The stub made here of each text, by its SHA-256: "" for a text
    --- with none.
    mut made: mut {string:string}
    --- The places read of the binary's own modules ([`source.places`]) by module, each as of its `carried` hash; at most
    --- `MADE_HELD`, and all go when another would pass it.
    mut carried_held: mut {string:Placed}
    mut carried_count: integer
    --- A private in-memory database of the analysis tables ([`AnalysisSchema.statements`] but the `inputs` view),
    --- made at the first text derived here; no `build.db` row is ever written to it or read from it as its own.
    mut scratch: Sqlite.Handle?
    --- The SHA-256 of the text derived (or tried) into `scratch` for each file below the root: the rows of a hash are
    --- dropped when no file holds it.
    mut scratched: mut {string:string}
    tally: Tally
    --- Where complaints go, without their newline.
    err: function(line: string)
  end
end

local type Module = source.Module
local type Served = source.Served
local type Written = source.Written
local type Spot = source.Spot
local type Tally = source.Tally

--- The most stubs kept of texts made here: an open module's every edit makes one.
local MADE_HELD <const> = 64

--- The running analyzer's name, found once.
local record Analyzer
  mut identity: string?
end

local running: Analyzer = { identity = nil }

local function analyzer_identity(): string
  local identity = running.identity
  if identity == nil then
    identity = importer.analyzer_identity()
    running.identity = identity
  end
  return identity
end

--- A source for the tree at `root`, staged at its first [`source.refresh`].
function source.new(root: string, err: function(line: string), carried?: string, store?: {Sqlite.Handle}): source.View
  local tally: Tally = { database_stubs = 0, made_stubs = 0, sources = 0, templates = 0,
    whole_splices = 0, stages = 0, reopened = 0, derived = 0, member_rows = 0,
    member_declarations = 0 }
  return {
    root = root,
    carried = carried,
    store = store,
    db = nil,
    identity = "",
    working = nil,
    where = nil,
    modules = {},
    files = {},
    requires = {},
    stubs = false,
    analyzer = nil,
    pending = true,
    told_busy = false,
    trouble = "",
    made = {},
    carried_held = {},
    carried_count = 0,
    scratch = nil,
    scratched = {},
    tally = tally,
    err = err,
  }
end

--- What the root is to the running tool, as the last stage found it; a
--- project before any stage.
function source.standing(src: source.View): tree.Standing
  local where = src.where
  if where == nil then return { own = false } end
  return where.standing
end

--- Whether the root is no project, as the last refresh found it
--- ([`rebuild.stage`]): no build was started there, so none of its
--- modules is found.
function source.outside(src: source.View): boolean
  local where = src.where
  return where ~= nil and not where.project
end

--- The device and inode of the file at `path`, or "" where there is none.
local function identity_of(path: string): string
  local st, _ = Fs.stat(path)
  if st == nil then return "" end
  return tostring(st.dev) .. ":" .. tostring(st.ino)
end

--- The read handle on the database, opened once there is one to open.
--- It waits on no lock: in write-ahead mode a read never needs to. In
--- rollback mode -- a file no run of this tool has opened since an
--- older one made it, or one on a file system with no shared memory --
--- a read a writer holds off fails at once, saying so, rather than
--- hold up the session. A file of another schema, another tool's, whose
--- rows this one's code may misread, it opens no handle on: it answers
--- nil and that schema, having read nothing of it but its schema.
local function database(src: source.View): Sqlite.Handle?, string
  local db = src.db
  if db ~= nil then return db, "" end
  local path = src.working
  if path == nil then return nil, "" end
  local identity = identity_of(path)
  if identity == "" then return nil, "" end
  local opened, trouble = Sqlite.open(path)
  if opened == nil then
    src.err("cosmic: lsp: " .. path .. ": " .. trouble)
    return nil, ""
  end
  opened:busy_timeout(0)
  local other, _ = work.other_schema(opened)
  if other ~= nil then
    local _, _ = opened:close()
    return nil, other
  end
  src.db, src.identity = opened, identity
  return opened, ""
end

--- Reads whether the database's stubs are the running analyzer's: the
--- one that derived them, where this session `staged` them.
local function trusted(src: source.View, staged: boolean)
  local db, _ = database(src)
  if db == nil then return end
  local named, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'analyzer'")
  local recorded: string? = nil
  if named ~= nil then
    local row = named[1]
    if row ~= nil then recorded = row:text(1) end
  end
  if staged and recorded ~= nil then src.analyzer = recorded end
  src.stubs = recorded ~= nil and recorded == (src.analyzer or analyzer_identity())
end

--- Reads whether other code than this session's staged the database
--- `db` ([`work.other_code`]), a read that fails counting as such, and
--- says so once a process for each code it finds, and for a read that
--- fails ([`work.first_time`]).
local function staged_by_other(src: source.View, db: Sqlite.Handle): boolean
  local other, trouble = work.other_code(db)
  local working = tostring(src.working)
  if other == nil and trouble ~= "" then
    if work.first_time("lsp other_code unread", working) then
      src.err("cosmic: lsp: " .. working .. ": reading which code staged it: " .. trouble ..
          "; finding no module in it until it is read")
    end
    return true
  end
  if other == nil then return false end
  if work.first_time("lsp other_code " .. other, working) then
    src.err("cosmic: lsp: " .. working .. " was staged by " .. work.code_name(other) ..
        ", not this tool's; finding no module in it, which this tool's code may misread, " ..
        "until a stage of this tool makes it this tool's")
  end
  return true
end

--- Reads the modules the database lists, what each requires, and
--- whether its stubs are the running analyzer's ([`trusted`]); none of
--- them where other code than this session's staged it
--- ([`staged_by_other`]).
local function listed(src: source.View, staged: boolean)
  local db, _ = database(src)
  if db == nil then return end
  -- Other code's rows are read none of: each query answers none.
  local own = 1
  if staged_by_other(src, db) then own = 0 end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, file, kind, source_hash, origin FROM inputs WHERE ?1 = 1 " ..
      "ORDER BY path, " .. AnalysisSchema.declaration("kind") .. " DESC, file", { { integer = own } })
  if rows == nil then
    src.err("cosmic: lsp: the staged tree: " .. trouble)
    return
  end
  local modules: mut {string:Module} = {}
  local files: mut {string:Module} = {}
  for _, row in ipairs(rows) do
    local found: Module = { path = row:text(1), file = row:text(2), kind = row:text(3),
      source_hash = row:text(4), origin = row:text(5) }
    if modules[found.path] == nil then modules[found.path] = found end
    files[found.file] = found
  end
  local requires: mut {string:{string}} = {}
  local named_rows, _ = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM requires WHERE ?1 = 1 ORDER BY source_hash, ordinal",
    { { integer = own } })
  if named_rows ~= nil then
    for _, row in ipairs(named_rows) do
      local hash = row:text(1)
      local names = requires[hash]
      if names == nil then
        names = {}
        requires[hash] = names
      end
      local second = row:text(2)
      names[#names + 1] = second
    end
  end
  src.modules, src.files, src.requires = modules, files, requires
  trusted(src, staged)
end

--- Takes what a stage found of the root.
local function adopt(src: source.View, where: rebuild.Where)
  src.where = where
  local directory = where.directory
  if where.project and directory ~= nil then
    src.working = build_paths.under(directory).working
  else
    src.working = nil
  end
end

--- Closes the read handle, where there is one, so the next read opens
--- the file anew.
local function let_go(src: source.View)
  local db = src.db
  if db ~= nil then
    local _, _ = db:close()
  end
  src.db = nil
end

--- What [`reopened`] did: kept the handle, the file being the one it
--- reads; read the file anew; or found it of another schema, which it
--- reads nothing of.
local enum Reopening
  "kept"
  "read"
  "other"
end

--- Opens the database again where the file its path names is no longer
--- the one the handle reads, a run having made it again, and reads what
--- it lists, unless it is now of another schema ([`database`]). Where
--- no handle is open, it opens one, and finds so too.
local function reopened(src: source.View): Reopening
  local db, path = src.db, src.working
  if path == nil then return "kept" end
  if db ~= nil then
    local identity = identity_of(path)
    if identity == "" or identity == src.identity then return "kept" end
    let_go(src)
    src.tally.reopened = src.tally.reopened + 1
  end
  local _, other = database(src)
  if other ~= "" then return "other" end
  if db == nil then return "kept" end
  listed(src, false)
  return "read"
end

--- What a session says of a tree its tool was not checked against
--- ([`rebuild.Where`]'s `unchecked`).
local unchecked_line <const> = "this tool was not checked against the tree when it started, " ..
  "since another cosmic run held the tree's build or its database was another tool's, so its " ..
  "code may be older than the tree's: until the editor starts it again it stages nothing, " ..
  "and answers from what the tree last staged, or finds no module where another tool's code " ..
  "staged it"

--- Stages the tree when it is yet to be ([`source.View`]'s `pending`),
--- then reads what the database lists; otherwise reads it again where a
--- run made the database again, and whether its stubs are the running
--- analyzer's in any case.
local function refreshed(src: source.View)
  local where = src.where
  if where ~= nil and not where.project then
    local directory = where.directory
    if directory == nil then return end
    local started, _ = rebuild.started(directory)
    if started ~= true then return end
    src.pending = true
  end
  -- A file made again under the session as another schema's goes to
  -- the stage, which finds that schema and says so.
  local again = reopened(src)
  if not src.pending and again ~= "other" then
    -- What another run staged meanwhile is read only where its code is
    -- this session's. Where it is another's, the tree is staged again
    -- here with this session's code, as a change on disk stages it, so
    -- its modules are found again at once; a session that stages
    -- nothing ([`source.unchecked`]) lets go of the modules it found.
    -- Where it is this session's, none found are looked for again (an
    -- empty tree's, or one another code staged before).
    local db = src.db
    if again ~= "kept" or db == nil then return end
    local found = next(src.modules) ~= nil
    local other = staged_by_other(src, db)
    if other and not (where ~= nil and where.unchecked) then
      -- Staged below, as a pending stage is.
    elseif other == found then
      listed(src, false)
      return
    else
      trusted(src, false)
      return
    end
  end
  local staged, trouble = rebuild.stage(src.root, src.carried)
  if staged ~= nil then adopt(src, staged) end
  -- A database of another schema is another tool's, whose rows this
  -- one's code may misread: none of it is read, and no module found in
  -- it. The stage is tried again at every check, and the file read once
  -- a run of this tool has made it again. That is said once for each
  -- stage that finds another schema than the one before it found
  -- (`where`, from before this one).
  local other: string? = nil
  if staged ~= nil then other = staged.other_schema end
  if other ~= nil then let_go(src) end
  if staged ~= nil and (not staged.project or other ~= nil) then
    src.pending = other ~= nil
    src.modules, src.files, src.requires = {}, {}, {}
    if other ~= nil and (where == nil or where.other_schema ~= other) then
      src.err("cosmic: lsp: " .. tostring(src.working) .. " is of schema " .. other ..
          ", another tool's; not staging or reading it until a `cosmic test` of this tool makes it again")
    end
    return
  end
  if staged ~= nil and staged.unchecked then
    -- Its stubs stay as last staged for the session, which says why once
    -- ([`source.unchecked`]); the stage it asks for at each check stages
    -- nothing.
    listed(src, false)
    return
  end
  if staged ~= nil and staged.busy then
    if not src.told_busy then
      src.err("cosmic: lsp: another cosmic run holds the write lock of " ..
          tostring(src.working) .. "; not staging, answering from the tree as last committed")
      src.told_busy = true
    end
    listed(src, false)
    return
  end
  if staged == nil then
    src.err("cosmic: lsp: not staged, answering from the tree as last staged: " .. trouble)
    src.trouble = trouble
  else
    src.tally.stages = src.tally.stages + 1
    src.trouble = ""
  end
  src.pending, src.told_busy = false, false
  listed(src, staged ~= nil)
end

--- Whether the last stage staged nothing.
function source.refused(src: source.View): boolean
  return src.trouble ~= ""
end

--- The complaint about the file `name` (below the root) where the last stage staged nothing and the file is one of a
--- declaration and a source of one module on disk, or nil: what a document of that file is told, at its first line. The pair
--- is found as the build finds one, by the files a module may be written in ([`build.driver.candidates`]).
function source.refusal(src: source.View, name: string): string?
  -- A fixture of a test is no part of the program, as in a build ([`build.tree_program.skipped`]).
  if src.trouble == "" or TreeProgram.skipped(name) then return nil end
  local module = Declarations.module_of(name)
  local declaration: string? = nil
  local code: string? = nil
  for _, file in ipairs(Driver.candidates(module)) do
    local there, _ = Fs.exists(src.root .. "/" .. file)
    if there == true then
      if file:match("%.d%.tl$") ~= nil then
        declaration = declaration or file
      else
        code = code or file
      end
    end
  end
  if declaration ~= nil and code ~= nil and (name == declaration or name == code) then
    return Driver.pairing(declaration, code, module)
  end
  return nil
end

--- What to say once, on stderr and to the person, where the session's
--- tool was not checked against its tree, so the stage stages nothing
--- ([`rebuild.Where`]'s `unchecked`), or nil.
function source.unchecked(src: source.View): string?
  local where = src.where
  if where ~= nil and where.unchecked then return unchecked_line end
  return nil
end

--- Stages the tree again at the next [`source.refresh`]: files changed on
--- disk.
function source.stale(src: source.View)
  src.pending = true
end

--- The module the file `file` below the root is, or nil when the
--- database lists none.
function source.module(src: source.View, file: string): Module?
  return src.files[file]
end

--- What names the text the module `name` would be served now: its file
--- and its text's hash, and, for one read from the database, whether as
--- the stub the stage derived ([`source.View`]'s `stubs`); "" when it is
--- not found.
function source.key(src: source.View, name: string, open: source.Open): string
  local found = src.modules[name]
  if found == nil then return "" end
  local opened = open(found.file)
  if opened ~= nil then return found.file .. "\0" .. opened.hash end
  return found.file .. "\0" .. found.source_hash .. "\0" .. (if src.stubs then "derived" else "made" end)
end

--- The stub made here of `text`, the file `file` whose SHA-256 is
--- `hash`: nil for a text that does not parse or returns nothing at its
--- top level, which has none ([`build.derivation`]).
local function made_stub(src: source.View, file: string, text: string, hash: string): string?
  local held = src.made[hash]
  if held == nil then
    held = syntax_read.stub_of(file, text)
    local count = 0
    for _ in pairs(src.made) do count = count + 1 end
    if count >= MADE_HELD then src.made = {} end
    src.made[hash] = held
  end
  if held == "" then return nil end
  return held
end

--- One column of the first row `sql` answers given `value`, or nil.
local function first(db: Sqlite.Handle, sql: string, value: string): string?
  local rows, _ = Sqlite.text_rows(db, sql, { { text = value } })
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

--- What the checker reads for the module `name`, or nil when the
--- database lists none, or it is a template that does not compile.
--- It is counted in the tally
--- ([`source.Tally`]) unless `uncounted`: what is served, not what is
--- looked at.
function source.served(src: source.View, name: string, open: source.Open, uncounted?: boolean): Served?
  local found = src.modules[name]
  if found == nil then return nil end
  local template = found.file:match("%.tmpl$") ~= nil
  -- Read under the name the module would have on disk below the root, as
  -- a build reads it, so a message that names it names it as a build's
  -- does: a declaration by its `.d.tl`, and a name that ends in `tl`
  -- alone, which a template's or a generated declaration's file does not.
  local stem = src.root .. "/" .. found.path:gsub("%.", "/")
  local file = stem .. ".tl"
  if AnalysisSchema.is_declaration(found.kind) then file = stem .. ".d.tl" end
  local tally = src.tally
  --- The module served as `text`, counted as `kind` is ([`source.Tally`]).
  local function serving_as(kind: string, text: string, key: string): Served
    if uncounted == true then
      return { file = file, text = text, key = key }
    elseif template then
      tally.templates = tally.templates + 1
    elseif kind == "database" then
      tally.database_stubs = tally.database_stubs + 1
    elseif kind == "made" then
      tally.made_stubs = tally.made_stubs + 1
    else
      tally.sources = tally.sources + 1
    end
    return { file = file, text = text, key = key }
  end
  local opened = open(found.file)
  if opened ~= nil then
    local text, hash = opened.text, opened.hash
    local key = found.file .. "\0" .. hash
    if template then
      local compiled, _ = Template.compile(text, found.file, { dialects = nil })
      if compiled == nil then return nil end
      return serving_as("source", compiled, key)
    end
    if not AnalysisSchema.is_declaration(found.kind) then
      local stubbed = made_stub(src, found.file, text, hash)
      if stubbed ~= nil then return serving_as("made", stubbed, key) end
    end
    return serving_as("source", text, key)
  end
  local db, _ = database(src)
  if db == nil then return nil end
  -- Another code's stage committed since the refresh is served none of.
  if staged_by_other(src, db) then return nil end
  local key = source.key(src, name, open)
  if not AnalysisSchema.is_declaration(found.kind) and src.stubs then
    local stubbed = first(db, "SELECT text FROM stubs WHERE source_hash = ?1", found.source_hash)
    if stubbed ~= nil then return serving_as("database", stubbed, key) end
  end
  local held = first(db, "SELECT source FROM inputs WHERE file = ?1", found.file)
  if held == nil then return nil end
  if not AnalysisSchema.is_declaration(found.kind) and not src.stubs then
    local stubbed = made_stub(src, found.file, held, found.source_hash)
    if stubbed ~= nil then return serving_as("made", stubbed, key) end
  end
  return serving_as("source", held, key)
end

--- The text of the module `name` as written: an open document's, else the working database's. nil where the database lists
--- none, for a template, whose file is not Teal, and where the database cannot be read as [`source.served`] cannot.
local function written_of(src: source.View, name: string, open: source.Open): Written?
  local found = src.modules[name]
  if found == nil or found.file:match("%.tmpl$") ~= nil then return nil end
  local db, _ = database(src)
  if found.origin ~= "tree" then
    -- A generated module's `file` is the one it was generated from, whose staged text is what its places are lines of;
    -- an open document of it is not read, for the places are the stage's.
    if db == nil or staged_by_other(src, db) then return nil end
    local data = first(db, "SELECT CAST(data AS TEXT) FROM files WHERE path = ?1", found.file)
    if data == nil then return nil end
    return { file = found.file, text = data }
  end
  local opened = open(found.file)
  if opened ~= nil then return { file = found.file, text = opened.text } end
  if db == nil or staged_by_other(src, db) then return nil end
  local held = first(db, "SELECT source FROM inputs WHERE file = ?1", found.file)
  if held == nil then return nil end
  return { file = found.file, text = held }
end

--- The scratch database, made at the first need: the analysis tables of [`build.analysis_schema`] without the `inputs`
--- view, which reads the `files` table that only a working database has. It is a handle of its own, so
--- [`Derivation.insert`] writes it as it writes a working database, by the unqualified names of the tables. nil, and said,
--- where it cannot be made.
local function scratch_of(src: source.View): Sqlite.Handle?
  local held = src.scratch
  if held ~= nil then return held end
  local made, trouble = Sqlite.memory()
  if made == nil then
    src.err("cosmic: lsp: the scratch database: " .. trouble)
    return nil
  end
  for _, statement in ipairs(AnalysisSchema.statements) do
    if statement:find("^%s*CREATE VIEW") == nil then
      local ok, why = made:exec(statement)
      if not ok then
        src.err("cosmic: lsp: the scratch database: " .. why)
        local _, _ = made:close()
        return nil
      end
    end
  end
  src.scratch = made
  return made
end

--- Whether a file other than `except` holds the text whose SHA-256 is `hash` in the scratch database.
local function held_by_another(src: source.View, hash: string, except: string): boolean
  for file, held in pairs(src.scratched) do
    if held == hash and file ~= except then return true end
  end
  return false
end

--- Drops the rows of the text `hash` from every analysis table of the scratch database.
local function forget_rows(scratch: Sqlite.Handle, hash: string)
  for _, name in ipairs(AnalysisSchema.tables) do
    local _, _ = Sqlite.run(scratch, "DELETE FROM " .. name .. " WHERE source_hash = ?1", { { text = hash } })
  end
end

--- Lets go of what the scratch database holds for the file `file`: a document closed, or one whose text is the staged
--- file's now, which `build.db` answers. The rows of its text stay while another file holds the same text.
function source.release(src: source.View, file: string)
  local old = src.scratched[file]
  if old == nil then return end
  src.scratched[file] = nil
  local scratch = src.scratch
  if scratch ~= nil and not held_by_another(src, old, file) then forget_rows(scratch, old) end
end

--- Derives the text `text` of the file `file`, whose SHA-256 is `hash`, into the scratch database, once a text: the rows
--- are [`Derivation.insert`]'s, as the stage writes them, the whole analysis of the text at its first read after an edit.
--- The file's earlier text goes. A text that does not parse writes its places alone, from the parser's recovered tree. A
--- text is not tried again while a file holds it.
local function derive(src: source.View, scratch: Sqlite.Handle, file: string, text: string, hash: string)
  local old = src.scratched[file]
  if old == hash then return end
  local tried = held_by_another(src, hash, file)
  src.scratched[file] = hash
  if old ~= nil and not held_by_another(src, old, file) then forget_rows(scratch, old) end
  if tried then return end
  -- Not the check's chunk, which is the parse of the text with its splices put in.
  local chunk, _ = Node.parse(text, file)
  if chunk == nil then
    -- A text being typed does not parse: the places of what the parser recovered are written, and no other row, as a
    -- partial tree says nothing safe of the rest of the analysis. It has no `parsed` row, so it is not a parse.
    local dialect: Ast.Dialect = "tl"
    if file:match("%.d%.tl$") ~= nil then dialect = "decl" end
    local recovered = Driver.parse(Driver.source(file, file, text, dialect)).chunk
    for ordinal, place in ipairs(Places.found(recovered)) do
      local ok, _ = Sqlite.run(scratch,
        "INSERT INTO places (source_hash, ordinal, symbol, kind, line, column, length) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        { { text = hash }, { integer = ordinal }, { text = place.symbol }, { text = place.kind },
          { integer = place.line }, { integer = place.column }, { integer = place.length } })
      if not ok then
        forget_rows(scratch, hash)
        return
      end
    end
    src.tally.derived = src.tally.derived + 1
    return
  end
  local ok, why = Derivation.insert(scratch, hash, file, text, chunk, false)
  if not ok then
    forget_rows(scratch, hash)
    src.err("cosmic: lsp: deriving " .. file .. ": " .. why)
    return
  end
  src.tally.derived = src.tally.derived + 1
end

--- The first place of each symbol of `rows`, whose columns are the symbol, the line, the column and the length.
local function spots_of(rows: Sqlite.Rows): {string:Spot}
  local held: mut {string:Spot} = {}
  for _, row in ipairs(rows) do
    local symbol = row:text(1)
    if held[symbol] == nil then
      held[symbol] = { line = math.tointeger(tonumber(row:text(2))) or 1,
        column = math.tointeger(tonumber(row:text(3))) or 1, length = math.tointeger(tonumber(row:text(4))) or 1 }
    end
  end
  return held
end

--- The places `db` holds of the text `hash`, by symbol (the first of each), and whether it holds a parse of it: its
--- `places` or `parsed` rows. nil where the read fails.
local function read_places(db: Sqlite.Handle, hash: string): {string:Spot}?, boolean
  local rows, _ = Sqlite.text_rows(db,
    "SELECT symbol, line, column, length FROM places WHERE source_hash = ?1 ORDER BY ordinal",
    { { text = hash } })
  if rows == nil then return nil, false end
  local derived = #rows > 0
  if not derived then
    local parsed, _ = Sqlite.text_rows(db, "SELECT 1 FROM parsed WHERE source_hash = ?1", { { text = hash } })
    if parsed == nil then return nil, false end
    derived = #parsed > 0
  end
  return spots_of(rows), derived
end

--- Where the binary's own module `name` declares its types and their members, in the text the tool carries of it: the
--- `places` of the tool's database ([`build.writer`]'s `insert_places`) and the module's `source`, in the units of the
--- file it was parsed from. nil for a name that is no `cosmic.*` module, for a module the tool carries no places of (one
--- generated from another file has none, and a module with no declaration), and where the database cannot be read: a
--- tool made before the table. The database is the last of the view's `store`, which a tool's own is.
local function carried_places(src: source.View, name: string): source.Placed?
  if name:sub(1, 7) ~= "cosmic." then return nil end
  local databases = src.store or Store.databases()
  local held = databases[#databases]
  if held == nil then return nil end
  local named, _ = Sqlite.text_rows(held, "SELECT CAST(source_hash AS TEXT) FROM modules WHERE path = ?1",
    { { text = name } })
  if named == nil then return nil end
  local first_row = named[1]
  if first_row == nil then return nil end
  local kept = src.carried_held[name]
  if kept ~= nil and kept.carried == first_row:text(1) then return kept end
  local module, _ = Sqlite.text_rows(held,
    "SELECT CAST(source_hash AS TEXT), file, CAST(inflate(source) AS TEXT) FROM modules WHERE path = ?1",
    { { text = name } })
  if module == nil then return nil end
  local row = module[1]
  if row == nil then return nil end
  local rows, _ = Sqlite.text_rows(held,
    "SELECT symbol, line, column, length FROM places WHERE module = ?1 ORDER BY ordinal", { { text = name } })
  if rows == nil or #rows == 0 then return nil end
  local placed: source.Placed = { file = row:text(2), text = row:text(3), spots = spots_of(rows), carried = row:text(1) }
  if src.carried_held[name] == nil then
    if src.carried_count >= MADE_HELD then
      src.carried_held = {}
      src.carried_count = 0
    end
    src.carried_count = src.carried_count + 1
  end
  src.carried_held[name] = placed
  return placed
end

--- Where `name` first stands on `line` of `text` as a whole word, as a byte column; 1 where it does not stand there. A word
--- right after an `@` is a tag of the annotation (`---@field`), not the name.
local function column_in(text: string, line: integer, name: string): integer, integer
  local at = 1
  for _ = 2, line do
    local newline = text:find("\n", at, true)
    if newline == nil then return 1, 0 end
    at = newline + 1
  end
  local stop = text:find("\n", at, true) or #text + 1
  local row = text:sub(at, stop - 1)
  local pattern = "%f[%w_]" .. name:gsub("%p", "%%%0") .. "%f[^%w_]"
  local search = 1
  while true do
    local from, to = row:find(pattern, search)
    if from == nil or to == nil then return 1, 0 end
    if from == 1 or row:sub(from - 1, from - 1) ~= "@" then return from, to - from + 1 end
    search = to + 1
  end
end

-- TODO: derive the places of a mapped module from an open buffer of its origin file, once the stage can generate a module from
-- an unsaved header: until then an open document of the header is ignored, so lines edited above a declaration and not yet
-- saved shift the file's lines from the staged rows.

-- TODO: answer a mapped module whose origin file is not staged (a header deleted since the stage, or a tree whose stage
-- failed), once the stage keeps the generated module's rows apart from its origin: it answers none, silently.

--- The places of a module generated from another file ([`build.syntax_derivation`]'s `origin_lines`), in that file's text
--- `written`: the stage's rows, each at the line of the file, with the column of the symbol's last name where it stands
--- on that line. The rows are the running analyzer's or none: a generated module is never derived here.
local function mapped_places(src: source.View, found: Module, written: Written): source.Placed?
  local spots: mut {string:Spot} = {}
  if src.stubs then
    local db, _ = database(src)
    if db == nil then return nil end
    local held, _ = read_places(db, found.source_hash)
    if held == nil then return nil end
    for symbol, spot in pairs(held) do
      local last = symbol:match("([^.]+)$") or symbol
      local column, length = column_in(written.text, spot.line, last)
      spots[symbol] = { line = spot.line, column = column, length = length }
    end
  end
  return { file = written.file, text = written.text, spots = spots }
end

-- TODO: keep the rows of both the text a check read and the text now in the scratch database of a file, once a file may hold
-- two texts there: a completion on the own module of an edited document that does not parse derives the text last checked,
-- which drops the rows of the text now, and the next request for its places derives that again.

-- TODO: serve the stub of an edited open document from its scratch `stubs` row, in place of the one made here ([`made_stub`],
-- [`View`]'s `made`), once the scratch database is derived for every open document rather than at the first read of its places.

-- TODO: feed an open document's `requires` from its scratch `requires` rows, in place of the ones the check reads of its
-- syntax tree, once the scratch database is derived for every open document.

-- TODO: answer without reading the module's text, once `places` rows carry whether their line is ASCII-only: the text is read
-- for every request only to count the line's characters in the protocol's units ([`build.lsp.lines`]).

--- Where the module `name` declares its types and their members ([`build.syntax_places`]), in its text as written
--- (an open document's, else the working database's), nil where that is none. The rows the stage derived of the file
--- (`places`) answer it while the text is the staged file's (not open, or open and the same) and they are the running
--- analyzer's. Any other text, an open document that was edited or a file whose rows are another analyzer's, is derived
--- into the scratch database ([`View`]'s `scratch`), once a text, and answered from the rows there; so is a file the
--- stage could not parse (it has no `parsed` row), which has none if it does not parse here either. A module generated
--- from another file (`mapped`) answers from the rows its `-- line` map gave, in the text of that file ([`mapped_places`]). A name
--- the database lists no module of is looked up among the binary's own modules ([`source.places`]).
function source.places(src: source.View, name: string, open: source.Open): source.Placed?
  local found = src.modules[name]
  if found == nil then return carried_places(src, name) end
  local written = written_of(src, name, open)
  if written == nil then return nil end
  if found.origin ~= "tree" then
    return mapped_places(src, found, written)
  end
  local opened = open(found.file)
  local hash = found.source_hash
  if opened ~= nil then hash = opened.hash end
  if hash == found.source_hash and src.stubs then
    local db, _ = database(src)
    if db == nil then return nil end
    local spots, derived = read_places(db, hash)
    if spots == nil then return nil end
    if derived then
      source.release(src, found.file)
      return { file = written.file, text = written.text, spots = spots }
    end
  end
  local scratch = scratch_of(src)
  if scratch == nil then return nil end
  derive(src, scratch, found.file, written.text, hash)
  local spots, _ = read_places(scratch, hash)
  return { file = written.file, text = written.text, spots = spots or {} }
end

-- TODO: remove the directories of `cosmic_source` ([`build.paths`]) that no module of the running tool names, once there
-- is a pass that visits the build directory beside [`build.cache_lifetime`]'s: a tool built again leaves the extracted
-- text of each module it changed, which lives until the whole build directory is pruned.

--- The path of a file holding the text of the binary's module `placed` ([`source.places`]), in the build
--- directory's `cosmic_source` ([`build.paths`]) below a directory named for the text's SHA-256, so that a path names
--- one text for good. The file is written read-only when it is not there or its bytes are not the text (a file changed since is replaced): an editor that opens it shows the module as
--- the binary has it, and a save is refused. It is written whole or not at all ([`Fs.write`]), so a reader never finds
--- part of it. nil where the root has no build directory, or the file cannot be made, which is said.
function source.extracted(src: source.View, placed: source.Placed): string?
  local hash = placed.carried
  if hash == nil or hash:find("^%x+$") == nil then return nil end
  local file = placed.file
  if file:sub(1, 1) == "/" or file:find("..", 1, true) ~= nil then return nil end
  local where = src.where
  if where == nil or where.directory == nil then return nil end
  local path = build_paths.under(where.directory).cosmic_source .. "/" .. hash .. "/" .. file
  local there, _ = Fs.read(path)
  if there ~= nil and Hash.hex_sha256(there) == hash then return path end
  local made, trouble = Fs.mkdirs(Fs.dirname(path))
  if made then made, trouble = Fs.write(path, placed.text, 0x124) end
  if not made then
    src.err("cosmic: lsp: the source of " .. file .. " of the binary: " .. trouble)
    return nil
  end
  return path
end

--- The `members` rows of a text, by owner, with the docs of the same symbols, in `db`, which holds the parse of the text
--- `hash`; nil where it holds none or cannot be read.
local function read_members(db: Sqlite.Handle, hash: string): source.Members?
  local parsed, _ = Sqlite.text_rows(db, "SELECT 1 FROM parsed WHERE source_hash = ?1", { { text = hash } })
  if parsed == nil or #parsed == 0 then return nil end
  local rows, _ = Sqlite.text_rows(db,
    "SELECT owner, name, kind, scope, type, coalesce((SELECT text FROM docs WHERE docs.source_hash = members.source_hash " ..
      "AND docs.source_symbol IN (members.owner || '.' || members.name, members.owner || ':' || members.name) " ..
      "ORDER BY length(text) DESC LIMIT 1), '') FROM members WHERE source_hash = ?1 ORDER BY ordinal",
    { { text = hash } })
  if rows == nil then return nil end
  local kinds: mut {string:string} = {}
  local supers: mut {string:mut {string}} = {}
  local members: mut {string:mut {source.MemberRow}} = {}
  for _, row in ipairs(rows) do
    local owner = row:text(1)
    local name = row:text(2)
    local interfaces = supers[owner] or {}
    supers[owner] = interfaces
    local held = members[owner] or {}
    members[owner] = held
    if name == "" then
      kinds[owner] = row:text(3)
      for each in row:text(5):gmatch("[^,]+") do
        local trimmed = each:gsub("^%s+", ""):gsub("%s+$", "")
        interfaces[#interfaces + 1] = trimmed
      end
    else
      local made: source.MemberRow = { name = name, kind = row:text(3), scope = row:text(4), type = row:text(5),
        doc = row:text(6) }
      held[#held + 1] = made
    end
  end
  local out: mut {string:source.MemberOwner} = {}
  for owner, list in pairs(members) do
    out[owner] = { kind = kinds[owner] or "", supers = supers[owner] or {}, members = list }
  end
  return out
end

--- The types the module `name` declares and their members, from the rows derived of its text: the open document's, else
--- the working database's, or `given` where that is the text the caller means (the text a check read, which is no text
--- being typed). The staged file's own rows answer while the text is the staged file's and they are the running analyzer's;
--- any other text is derived into the scratch database, once a text, as [`source.places`] does. nil where the module is
--- not listed, or the text does not parse, and a module generated from another file (`mapped`) is as the rows of its text
--- say.
function source.members(src: source.View, name: string, open: source.Open, given?: string): source.Members?
  local found = src.modules[name]
  if found == nil then return nil end
  local written = written_of(src, name, open)
  if written == nil then return nil end
  local text = written.text
  local hash = found.source_hash
  local opened = open(found.file)
  if opened ~= nil then hash = opened.hash end
  if given ~= nil and given ~= text then
    text = given
    hash = Hash.hex_sha256(given)
  end
  if hash == found.source_hash and src.stubs then
    local db, _ = database(src)
    if db == nil then return nil end
    local held = read_members(db, hash)
    if held ~= nil then return held end
  end
  local scratch = scratch_of(src)
  if scratch == nil then return nil end
  derive(src, scratch, found.file, text, hash)
  return read_members(scratch, hash)
end

--- Lets go of the scratch database in the files whose text is the staged file's now, the rows of `build.db` answering
--- for it ([`source.places`]): after a stage, a document saved.
local function settle(src: source.View)
  for file, hash in pairs(src.scratched) do
    local staged = src.files[file]
    if staged == nil then
      -- A file the tree no longer lists (deleted, renamed) has no module to answer for.
      source.release(src, file)
    elseif src.stubs and staged.source_hash == hash then
      local db, _ = database(src)
      if db == nil then return end
      local _, derived = read_places(db, hash)
      if derived then source.release(src, file) end
    end
  end
end

--- Brings the session's view of the database up to date as [`refreshed`] says, then lets go of what the scratch database
--- holds for a text the staged tree has now ([`settle`]).
function source.refresh(src: source.View)
  refreshed(src)
  settle(src)
end

--- Lets go of the databases: the working one is opened again when next read, the scratch one made again.
function source.close(src: source.View)
  local db = src.db
  if db ~= nil then
    local _, _ = db:close()
    src.db = nil
  end
  local scratch = src.scratch
  if scratch ~= nil then
    local _, _ = scratch:close()
    src.scratch = nil
  end
  src.scratched = {}
end

return source
