--- Where `cosmic lsp` ([`build.lsp`]) reads a project's modules from: the
--- working database of the workspace's root, `build.db` in its build
--- directory ([`build.paths`]), as a build reads them, and the documents
--- the editor holds open, whose text comes over the protocol.
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
--- ([`build.lsp.check`]). A root that is no project ([`rebuild.stage`])
--- is never staged, as a lookup never starts a tree of its own: a build
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
--- A module is served as its stub ([`build.stub`]) where it has one, as
--- cosmic serves its standard library: the stub types a `require` of it as
--- its source does, and the checker reads a fraction of it. The stub of a
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
--- database up to it. It stages again at its next check.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Template = require("cosmic.template")
local ast = require("build.ast")
local build_paths = require("build.paths")
local importer = require("build.importer")
local rebuild = require("build.rebuild")
local stub = require("build.stub")
local type compiler = require("build.compiler")

local record source
  --- A module as the working database lists it (the `inputs` view).
  record Module
    path: string
    file: string
    kind: string
    source_hash: string
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
    database_stubs: integer
    --- Served as a stub made in this process, of an open document or of
    --- a source whose `stubs` rows are not the running analyzer's.
    made_stubs: integer
    --- Served as its source: a declaration, or one that has no stub.
    sources: integer
    --- Served as a template's Teal.
    templates: integer
    --- Documents whose [`Shape.record_of`] calls were found in the copy
    --- with every function body left out, and in the whole text.
    bodiless_splices: integer
    whole_splices: integer
    --- Stages made, and times the database was found made again and
    --- opened anew.
    stages: integer
    reopened: integer
  end

  --- An open document's text, and its SHA-256.
  record Text
    text: string
    hash: string
  end

  --- The open document that is the file `file` below the root, or nil
  --- when none is open.
  type Open = function(file: string): Text | nil

  --- One session's view of the database.
  record View
    root: string
    --- A read handle on `build.db`, nil until there is one to read, and
    --- the device and inode of the file it reads.
    db: Sqlite.Handle | nil
    identity: string
    --- The database's path, once a stage has found the build directory.
    working: string | nil
    --- What the last stage found of the root, nil before the first.
    where: rebuild.Where | nil
    --- Each module by its import path, and by its file.
    modules: {string:Module}
    files: {string:Module}
    --- What each source requires, by its `source_hash` (the `requires`
    --- rows), in order.
    requires: {string:{string}}
    --- Whether the `stubs` rows are the running analyzer's, and the
    --- analyzer this session's last stage recorded, nil before one.
    stubs: boolean
    analyzer: string | nil
    --- Whether the tree is yet to be staged: before the first check, or
    --- since a stage that found the database busy.
    pending: boolean
    --- Whether the session has said the database is busy, since it last
    --- staged.
    told: boolean
    --- The stub made here of each text, by its SHA-256: "" for a text
    --- with none.
    made: {string:string}
    tally: Tally
    --- Where complaints go, without their newline.
    err: function(line: string)
  end
end

local type Module = source.Module
local type Served = source.Served
local type Tally = source.Tally

--- The most stubs kept of texts made here: an open module's every edit
--- makes one.
local MADE_HELD <const> = 64

--- The running analyzer's name, found once.
local record Analyzer
  identity: string | nil
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
function source.new(root: string, err: function(line: string)): source.View
  local tally: Tally = { database_stubs = 0, made_stubs = 0, sources = 0, templates = 0,
    bodiless_splices = 0, whole_splices = 0, stages = 0, reopened = 0 }
  return {
    root = root,
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
    told = false,
    made = {},
    tally = tally,
    err = err,
  }
end

--- Whether the root is cosmic's own tree, as the last stage found it.
function source.own_tree(src: source.View): boolean
  local where = src.where
  return where ~= nil and where.own_tree
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
--- hold up the session.
local function database(src: source.View): Sqlite.Handle | nil
  local db = src.db
  if db ~= nil then return db end
  local path = src.working
  if path == nil then return nil end
  local identity = identity_of(path)
  if identity == "" then return nil end
  local opened, trouble = Sqlite.open(path)
  if opened == nil then
    src.err("cosmic: lsp: " .. path .. ": " .. trouble)
    return nil
  end
  opened:busy_timeout(0)
  src.db, src.identity = opened, identity
  return opened
end

--- Reads whether the database's stubs are the running analyzer's: the
--- one that derived them, where this session `staged` them.
local function trusted(src: source.View, staged: boolean)
  local db = database(src)
  if db == nil then return end
  local named, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'analyzer'")
  local recorded: string | nil = nil
  if named ~= nil then
    local row = named[1]
    if row ~= nil then recorded = row:text(1) end
  end
  if staged and recorded ~= nil then src.analyzer = recorded end
  src.stubs = recorded ~= nil and recorded == (src.analyzer or analyzer_identity())
end

--- Reads the modules the database lists, what each requires, and
--- whether its stubs are the running analyzer's ([`trusted`]).
local function listed(src: source.View, staged: boolean)
  local db = database(src)
  if db == nil then return end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, file, kind, source_hash FROM inputs " ..
      "ORDER BY path, kind = 'decl' DESC, file")
  if rows == nil then
    src.err("cosmic: lsp: the staged tree: " .. trouble)
    return
  end
  local modules: {string:Module} = {}
  local files: {string:Module} = {}
  for _, row in ipairs(rows) do
    local found: Module = { path = row:text(1), file = row:text(2), kind = row:text(3),
      source_hash = row:text(4) }
    if modules[found.path] == nil then modules[found.path] = found end
    files[found.file] = found
  end
  local requires: {string:{string}} = {}
  local named_rows, _ = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM requires ORDER BY source_hash, ordinal")
  if named_rows ~= nil then
    for _, row in ipairs(named_rows) do
      local hash = row:text(1)
      local names = requires[hash]
      if names == nil then
        names = {}
        requires[hash] = names
      end
      names[#names + 1] = row:text(2)
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

--- Opens the database again where the file its path names is no longer
--- the one the handle reads, a run having made it again, and reads what
--- it lists; answers whether it did.
local function reopened(src: source.View): boolean
  local db, path = src.db, src.working
  if db == nil or path == nil then return false end
  local identity = identity_of(path)
  if identity == "" or identity == src.identity then return false end
  local _, _ = db:close()
  src.db = nil
  src.tally.reopened = src.tally.reopened + 1
  listed(src, false)
  return true
end

--- Stages the tree when it is yet to be ([`source.View`]'s `pending`),
--- then reads what the database lists; otherwise reads it again where a
--- run made the database again, and whether its stubs are the running
--- analyzer's in any case. `built` parses what is new.
function source.refresh(src: source.View, built: compiler)
  local where = src.where
  if where ~= nil and not where.project then
    local directory = where.directory
    if directory == nil then return end
    local started, _ = rebuild.started(directory)
    if started ~= true then return end
    src.pending = true
  end
  if not src.pending then
    if not reopened(src) then trusted(src, false) end
    return
  end
  reopened(src)
  local staged, trouble = rebuild.stage(src.root, built)
  if staged ~= nil then adopt(src, staged) end
  if staged ~= nil and not staged.project then
    src.pending = false
    src.modules, src.files, src.requires = {}, {}, {}
    return
  end
  if staged ~= nil and staged.busy then
    if not src.told then
      src.err("cosmic: lsp: another cosmic run holds the write lock of " ..
          tostring(src.working) .. "; not staging, answering from the tree as last committed")
      src.told = true
    end
    listed(src, false)
    return
  end
  if staged == nil then
    src.err("cosmic: lsp: not staged, answering from the tree as last staged: " .. trouble)
  else
    src.tally.stages = src.tally.stages + 1
  end
  src.pending, src.told = false, false
  listed(src, staged ~= nil)
end

--- Stages the tree again at the next [`source.refresh`]: files changed on
--- disk.
function source.stale(src: source.View)
  src.pending = true
end

--- The module the file `file` below the root is, or nil when the
--- database lists none.
function source.module(src: source.View, file: string): Module | nil
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
  return found.file .. "\0" .. found.source_hash .. "\0" .. (src.stubs and "derived" or "made")
end

--- The stub made here of `text`, the file `file` whose SHA-256 is
--- `hash`: nil for a text that does not parse or returns nothing at its
--- top level, which has none ([`build.derivation`]).
local function made_stub(src: source.View, built: compiler, file: string, text: string,
                         hash: string): string | nil
  local held = src.made[hash]
  if held == nil then
    held = ""
    local parsed, _ = ast.parse(built, text, file)
    if parsed ~= nil then
      for _, statement in ipairs(parsed.node) do
        if statement.kind == "return" then held = stub.made(parsed).text end
      end
    end
    local count = 0
    for _ in pairs(src.made) do count = count + 1 end
    if count >= MADE_HELD then src.made = {} end
    src.made[hash] = held
  end
  if held == "" then return nil end
  return held
end

--- One column of the first row `sql` answers given `value`, or nil.
local function first(db: Sqlite.Handle, sql: string, value: string): string | nil
  local rows, _ = Sqlite.text_rows(db, sql, { { text = value } })
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

--- What the checker reads for the module `name`, or nil when the
--- database lists none, or it is a template that does not compile.
--- `built` parses a text to stub here. It is counted in the tally
--- ([`source.Tally`]) unless `uncounted`: what is served, not what is
--- looked at.
function source.served(src: source.View, built: compiler, name: string,
                       open: source.Open, uncounted?: boolean): Served | nil
  local found = src.modules[name]
  if found == nil then return nil end
  local template = found.file:match("%.tmpl$") ~= nil
  -- Read under the name the module would have on disk below the root, as
  -- a build reads it ([`teal.environment_for`]), so a message that names
  -- it (a type "inferred at" it) names it as a build's does: a
  -- declaration by its `.d.tl`, and a name that ends in `tl` alone, which
  -- a template's or a generated declaration's file does not.
  local stem = src.root .. "/" .. found.path:gsub("%.", "/")
  local file = stem .. ".tl"
  if found.kind == "decl" then file = stem .. ".d.tl" end
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
      local compiled, _ = Template.compile(text, found.file)
      if compiled == nil then return nil end
      return serving_as("source", compiled, key)
    end
    if found.kind ~= "decl" then
      local stubbed = made_stub(src, built, found.file, text, hash)
      if stubbed ~= nil then return serving_as("made", stubbed, key) end
    end
    return serving_as("source", text, key)
  end
  local db = database(src)
  if db == nil then return nil end
  local key = source.key(src, name, open)
  if found.kind ~= "decl" and src.stubs then
    local stubbed = first(db, "SELECT text FROM stubs WHERE source_hash = ?1", found.source_hash)
    if stubbed ~= nil then return serving_as("database", stubbed, key) end
  end
  local held = first(db, "SELECT source FROM inputs WHERE file = ?1", found.file)
  if held == nil then return nil end
  if found.kind ~= "decl" and not src.stubs then
    local stubbed = made_stub(src, built, found.file, held, found.source_hash)
    if stubbed ~= nil then return serving_as("made", stubbed, key) end
  end
  return serving_as("source", held, key)
end

--- Lets go of the database, which is opened again when next read.
function source.close(src: source.View)
  local db = src.db
  if db ~= nil then
    local _, _ = db:close()
    src.db = nil
  end
end

return source
