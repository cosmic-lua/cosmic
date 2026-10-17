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
--- ([`build.lsp.check`]).
---
--- A module is served as its stub ([`build.stub`]) where it has one, as
--- cosmic serves its standard library: the stub types a `require` of it as
--- its source does, and the checker reads a fraction of it. The stub of a
--- file is the one the stage derived of its source (the `stubs` row of its
--- `source_hash`), while the database's rows are the running analyzer's
--- ([`importer.analyzer_identity`]); otherwise, and for an open document,
--- it is made here from the text, once a text.
---
--- Reading waits on no lock. The database is in write-ahead mode
--- ([`work.open`]), so the read handle reads the last commit at once
--- while another run holds the write lock for minutes (a `cosmic test`
--- compiling, say). Staging is a write, and waits for no other run either: where
--- another holds the write lock, the session says so, does not stage, and
--- answers from the tree as last committed; that run stages the same
--- tree, and its commit brings the database up to it. It stages again at
--- its next check. Once the lock is free it stages as a build does,
--- waiting, as [`work.open`] waits, only for a run that took the lock in
--- between.

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
    --- A read handle on `build.db`, nil until there is one to read.
    db: Sqlite.Handle | nil
    --- Each module by its import path, and by its file.
    modules: {string:Module}
    files: {string:Module}
    --- Whether the `stubs` rows are the running analyzer's.
    stubs: boolean
    --- Whether the tree is yet to be staged: before the first check, or
    --- since a stage that found the database busy or failed.
    pending: boolean
    --- Whether the session has said the database is busy, since it last
    --- staged.
    told: boolean
    --- The stub made here of each text, by its SHA-256: "" for a text
    --- with none.
    made: {string:string}
    --- Where complaints go, without their newline.
    err: function(line: string)
  end
end

local type Module = source.Module
local type Served = source.Served

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
  return {
    root = root,
    db = nil,
    modules = {},
    files = {},
    stubs = false,
    pending = true,
    told = false,
    made = {},
    err = err,
  }
end

--- The working database's path, or nil where the root has no build
--- directory.
local function working(root: string): string | nil
  local dir, _ = build_paths.optional(root)
  if dir == nil then return nil end
  return build_paths.under(dir).working
end

--- Whether another run holds the write lock of the database at `path`
--- now: asked by taking it, and letting it go, without waiting. It
--- decides only whether to stage, never whether to read.
local function busy(path: string): boolean
  local there, _ = Fs.exists(path)
  if there ~= true then return false end
  local db, _ = Sqlite.open(path, { writable = true })
  if db == nil then return false end
  db:busy_timeout(0)
  local begun = db:exec_result("BEGIN IMMEDIATE")
  if begun.code == Sqlite.OK then
    local _, _ = db:exec("ROLLBACK")
  end
  local _, _ = db:close()
  return begun.code == Sqlite.BUSY
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
  local path = working(src.root)
  if path == nil then return nil end
  local there, _ = Fs.exists(path)
  if there ~= true then return nil end
  local opened, trouble = Sqlite.open(path)
  if opened == nil then
    src.err("cosmic: lsp: " .. path .. ": " .. trouble)
    return nil
  end
  opened:busy_timeout(0)
  src.db = opened
  return opened
end

--- Reads the modules the database lists, and whether its stubs are the
--- running analyzer's.
local function listed(src: source.View)
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
  src.modules, src.files = modules, files
  local named, _ = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'analyzer'")
  src.stubs = named ~= nil and #named > 0 and named[1]:text(1) == analyzer_identity()
end

--- Stages the tree when it is yet to be ([`source.View`]'s `pending`),
--- then reads what the database lists. `built` parses what is new.
function source.refresh(src: source.View, built: compiler)
  if not src.pending then return end
  local path = working(src.root)
  if path ~= nil and busy(path) then
    if not src.told then
      src.err("cosmic: lsp: another cosmic run holds the write lock of " .. path ..
          "; not staging, answering from the tree as last committed")
      src.told = true
    end
    listed(src)
    return
  end
  local staged, trouble = rebuild.stage(src.root, built)
  if not staged then
    src.err("cosmic: lsp: not staged, answering from the tree as last staged: " .. trouble)
  end
  src.pending, src.told = false, false
  listed(src)
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
--- and its source's hash, or "" when it is not found.
function source.key(src: source.View, name: string, open: source.Open): string
  local found = src.modules[name]
  if found == nil then return "" end
  local opened = open(found.file)
  if opened ~= nil then return found.file .. "\0" .. opened.hash end
  return found.file .. "\0" .. found.source_hash
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
  if rows == nil or #rows == 0 then return nil end
  return rows[1]:text(1)
end

--- What the checker reads for the module `name`, or nil when the
--- database lists none, or it is a template that does not compile.
--- `built` parses a text to stub here.
function source.served(src: source.View, built: compiler, name: string,
                       open: source.Open): Served | nil
  local found = src.modules[name]
  if found == nil then return nil end
  local template = found.file:match("%.tmpl$") ~= nil
  -- Read under the name the module would have on disk, as a build reads
  -- it ([`teal.environment_for`]): the checker takes a declaration by its
  -- `.d.tl`, and a name that ends in `tl` alone, which a template's or a
  -- generated declaration's file does not.
  local file = found.path:gsub("%.", "/") .. ".tl"
  if found.kind == "decl" then file = found.path:gsub("%.", "/") .. ".d.tl" end
  local opened = open(found.file)
  if opened ~= nil then
    local text, hash = opened.text, opened.hash
    local key = found.file .. "\0" .. hash
    if template then
      local compiled, _ = Template.compile(text, found.file)
      if compiled == nil then return nil end
      return { file = file, text = compiled, key = key }
    end
    if found.kind ~= "decl" then
      local stubbed = made_stub(src, built, found.file, text, hash)
      if stubbed ~= nil then return { file = file, text = stubbed, key = key } end
    end
    return { file = file, text = text, key = key }
  end
  local db = database(src)
  if db == nil then return nil end
  local key = found.file .. "\0" .. found.source_hash
  if found.kind ~= "decl" and src.stubs then
    local stubbed = first(db, "SELECT text FROM stubs WHERE source_hash = ?1", found.source_hash)
    if stubbed ~= nil then return { file = file, text = stubbed, key = key } end
  end
  local held = first(db, "SELECT source FROM inputs WHERE file = ?1", found.file)
  if held == nil then return nil end
  if found.kind ~= "decl" and not src.stubs then
    local stubbed = made_stub(src, built, found.file, held, found.source_hash)
    if stubbed ~= nil then return { file = file, text = stubbed, key = key } end
  end
  return { file = file, text = held, key = key }
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
