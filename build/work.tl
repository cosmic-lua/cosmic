--- The working database, `build.db` in the build directory: where a build stages the tree
--- and keeps everything it learns about it on this host.
---
--- Two databases, two promises. `cosmic.db` is a pure function of
--- the tree, byte-identical from any build of it, and ships. This one
--- is a log of what happened on one host -- the tree as it was last
--- read, what a stat said about each file, test verdicts, coverage --
--- and is allowed, expected even, to differ the next time. It never
--- ships and is never copied into the tree's own database.
---
--- Staging comes first: every input the build consumes is read off
--- disk into the `files` table before anything transforms it, so the
--- rest of the build reads rows, never paths. An unchanged file is a
--- stat: when its size, modification and change times, inode and device all match the row,
--- the bytes and the hash on the row are still right and the file is
--- not read again.

local build_paths = require("build.paths")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local CodeWalk = require("build.code_walk")
local sys = require("cosmic.sys")
local identity = require("build.identity")
local type tree = require("build.tree")
local analysis_schema = require("build.analysis_schema")
local work_schema = require("build.work_schema")
local type Database = work_schema.Database
local todo_scan = require("build.todo_scan")
local gen_syscalls = require("build.gen_syscalls")
local bind = require("build.bind")
local link_files = require("build.link_files")
local rebuild_lock = require("build.rebuild_lock")
local log = require("build.logger").log
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): links.
local _ = require("build.reads.links")

local record work
  --- How the tool stands against the working database of `root` read
  --- without writing it ([`work.tool_read_unwritten`]).
  enum Unwritten
    --- Its recorded files and discovery directories stand as recorded, and
    --- the boot hash the last stage recorded is the one asked about.
    "fresh"
    --- Anything else: something moved, the hash differs or none is
    --- recorded, or the database is missing or cannot be read. Only a stage
    --- can tell more.
    "unknown"
  end

  --- A file by its device, as a stat gives it, and its inode.
  record Place
    dev: integer
    ino: integer
  end

  --- What [`work.holding`] reads of a host to name the holder of a write
  --- lock ([`work.holder_line`]): the text of /proc/locks, the `-shm` file
  --- and the database file, the text of the holder file and its age, and
  --- this process's pid. A field is nil where it could not be read.
  record Seen
    locks?: string
    mut shm?: Place
    mut file?: Place
    mut named?: string
    mut age_ns?: integer
    own: integer
  end

  --- One file of `web_assets`: its name in the table, its bytes, their
  --- SHA-256 as hex, their SHA-384 as base64 and the vendored version.
  record WebAsset
    name: string
    data: string
    sha256: string
    sha384: string
    version: string
  end
  --- An open working database, for one run. A run is one transaction
  --- from `open` to `commit`: staging, deriving and compiling all land
  --- together with the in-memory projection. Its vacuum and publication
  --- follow the commit; the test runner's records are their own phase.
  record Handle
    db: Database
    root: string
    --- The directory the build writes into: `root`'s build directory, or another
    --- [`open`] was given.
    dir: string
    --- This run's number: one more than the last run over this file.
    run: integer
    --- Whether the run's transaction is open.
    mut inside: boolean
    --- What `root` is to the running tool, as [`work.stage`] was told: what
    --- the compile and the writer after it hold the tree to. Nil before the stage.
    mut standing: tree.Standing?
  end

  --- What [`work.try_open`] or [`work.try_open_remaking`] opened: the
  --- run's handle, or nil where another run held the write lock, which it
  --- waited for no more than to find it held, or where the file was of
  --- another schema that it did not make again: [`work.try_open`] makes
  --- none, and [`work.try_open_remaking`] none another run may be using.
  record Opening
    handle: Handle?
    --- The schema the file was found of, where it was not this module's:
    --- the open read nothing else of it and left it where it was.
    other_schema: string?
  end

  --- What one staging pass found and what it had to read.
  record Staged
    mut files: integer
    mut read: integer
    --- One line for each file under `static/` newly staged whose name
    --- says it was meant as a module (`.tl`, `.tmpl`): it is carried as an
    --- asset. Also complained of as it is found.
    notes: mut {string}
  end

  --- [`work_schema.statements`]: what creates the database, in order.
  mut schema: mut {string}
end

--- The shape of the schema. A file of another shape holds nothing the
--- tree cannot produce again, so it is thrown away.
local version <const> = "35"

work.schema = work_schema.statements

local text = bind.text

local integer = bind.integer

--- How long a run waits for another run of the same tree to end its
--- transaction on `build.db`. That run holds it from staging through
--- its compile: a cold compile, a boot, or a stale tool's whole rebuild
--- of itself (build.reboot), each of which takes minutes on a loaded
--- host. That is past the 60 s every handle waits by default
--- (core/sqlite.c), which a waiting run would otherwise meet as
--- "database is locked". It is as long as build.reboot waits for
--- another run's rebuild lock.
local wait_ns <const> = Clock.minutes(30)

--- How long a run waits for that transaction before it says so.
local notice_ns <const> = Clock.seconds(1)

--- How long a waiting run waits in one go before it says it still is,
--- as a run waiting for the rebuild lock does.
local reminder_ns <const> = Clock.seconds(15)

--- Where SQLite's unix VFS puts a run's write lock on the working
--- database, an fcntl lock of one byte: byte 120 of the `-shm` file in
--- write-ahead mode (the first lock past the index header), and byte
--- 2^30 + 1 of the file itself in rollback mode (its RESERVED lock).
local wal_write_byte <const> = 120
local reserved_byte <const> = 1073741825

--- The pid that `locks`, the text of Linux's /proc/locks, says holds a
--- POSIX write lock over byte `byte` of the file at `place`. Nil where
--- none does, and where the holder is in a pid namespace this process
--- cannot see, which the file shows as pid 0. A line of a process
--- blocked waiting for the lock (`N: -> POSIX ...`) names a waiter, not
--- the holder, and is passed over. A lock is a range, `EOF` ending one
--- that runs to the file's end: Linux merges the adjacent locks of one
--- owner, as SQLite's PENDING, RESERVED and SHARED bytes are at a
--- commit in rollback mode.
function work.lock_holder_in(locks: string, place: work.Place, byte: integer): integer?
  -- The file names a device by its major and minor numbers in hex, as
  -- the kernel splits `st_dev`.
  local dev = place.dev
  local major = ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfff)
  local minor = (dev & 0xff) | ((dev >> 12) & ~0xff)
  for line in locks:gmatch("[^\n]+") do
    local pid, maj, min, at, from, to = line:match(
      "^%d+: POSIX%s+%u+%s+WRITE%s+(%d+)%s+(%x+):(%x+):(%d+)%s+(%d+)%s+(%w+)")
    local first = math.tointeger(tonumber(from))
    local last = if to == "EOF" then math.maxinteger else math.tointeger(tonumber(to)) end
    if pid ~= nil and math.tointeger(tonumber(at)) == place.ino and first ~= nil and last ~= nil and
        first <= byte and byte <= last and
        math.tointeger(tonumber(maj, 16)) == major and math.tointeger(tonumber(min, 16)) == minor then
      local holder = math.tointeger(tonumber(pid))
      if holder ~= nil and holder > 0 then return holder end
    end
  end
  return nil
end

--- The file beside the working database at `path` that names the last
--- process of this tool to take its write lock, by its pid, written the
--- moment it took it, so its age is how long that process has held the
--- lock ([`work.holder_line`]) while it still does.
local function holder_file(path: string): string
  return path .. ".pid"
end

--- Records that this process has just taken the write lock of the
--- working database at `path` ([`holder_file`]). Written aside and moved
--- into place, so a waiting run reads a whole one or the one before. A
--- file that cannot be written leaves a waiting run unable to say how
--- long the lock has been held, and nothing else.
local function mark_holder(path: string)
  local file = holder_file(path)
  local aside = file .. "." .. tostring(sys.getpid())
  local written, _ = Fs.write(aside, tostring(sys.getpid()) .. "\n")
  if written then
    local _, _ = Fs.rename(aside, file)
  end
end

--- Another process holding the write lock of the working database at
--- `path`, as a run that waits for it, or reads past it, says it, from
--- what [`work.holding`] read (`seen`). Its pid is the one /proc/locks
--- says holds the lock, and no other. It is named a cosmic run, and how
--- long it has held the lock is said, only where [`holder_file`] names
--- that pid: this tool writes the file as it takes the lock. Where the
--- system names no holder, or names this process, none is named.
function work.holder_line(path: string, seen: work.Seen): string
  local locks = seen.locks
  local pid: integer? = nil
  if locks ~= nil then
    local shm, file = seen.shm, seen.file
    if shm ~= nil then pid = work.lock_holder_in(locks, shm, wal_write_byte) end
    if pid == nil and file ~= nil then pid = work.lock_holder_in(locks, file, reserved_byte) end
  end
  if pid == nil or pid == seen.own then
    return "another cosmic run holds the write lock of " .. path
  end
  local named, age_ns = seen.named, seen.age_ns
  if named ~= nil and named:match("^(%d+)\n") == tostring(pid) and age_ns ~= nil and age_ns >= 0 then
    return "another cosmic run (pid " .. tostring(pid) .. ") has held the write lock of " .. path .. " for " ..
      rebuild_lock.elapsed(age_ns)
  end
  return "another process (pid " .. tostring(pid) .. ") holds the write lock of " .. path
end

--- Another process holding the write lock of the working database at
--- `path`, as [`work.holder_line`] says it of what this host shows:
--- Linux's /proc/locks, the database's files and [`holder_file`].
function work.holding(path: string): string
  -- TODO: name the holder on macOS and the BSDs too, which have no
  -- /proc/locks, by asking `fcntl(F_GETLK)` of the lock's byte, once
  -- cosmic.sys carries F_GETLK.
  local locks, _ = Fs.read("/proc/locks")
  local seen: work.Seen = { locks = locks, own = sys.getpid() }
  if locks ~= nil then
    local shm, _ = sys.stat(path .. "-shm")
    if shm ~= nil then seen.shm = { dev = shm.dev, ino = shm.ino } end
    local file, _ = sys.stat(path)
    if file ~= nil then seen.file = { dev = file.dev, ino = file.ino } end
    local named, _ = Fs.read(holder_file(path))
    seen.named = named
    local marked, _ = sys.stat(holder_file(path))
    if marked ~= nil then
      seen.age_ns = Clock.now_ns() - (marked.mtime * Clock.seconds(1) + marked.mtime_ns)
    end
  end
  return work.holder_line(path, seen)
end

--- What a run says as it starts to wait for `holding`, the run that holds
--- the write lock of the working database ([`work.holding`]): where it is
--- told what it is `doing` (a verb, "running hello.tl"), that first, and
--- why it waits, since a verb that only reads does not.
function work.waiting_line(holding: string, doing?: string): string
  if doing == nil then return holding .. "; waiting for it" end
  return string.format("%s: %s; waiting for it, since one run at a time writes the tree's build in that file " ..
      "(docs, uses and todos read its last build and do not wait)", doing, holding)
end

--- What a step that takes the write lock did: took it and went on
--- ("done"), or, waiting for no other run ([`work.try_open`]), found
--- another holding it ("busy").
local enum Took
  "done"
  "busy"
end

--- Begins the run's transaction on `db`, the working database at `path`,
--- waiting up to `wait_ns` for another run that holds it, saying so,
--- naming that run where it can ([`work.holding`]), after `notice_ns`,
--- and that it still waits every `reminder_ns`. The handle keeps the long
--- wait for every statement after ([`work.begin`]'s transactions among
--- them). Unless `wait`, it waits for no other run: where one holds the
--- lock it returns "busy". The line that says it waits names what the
--- run is `doing`, where given ([`work.waiting_line`]). A transaction begun is recorded
--- ([`mark_holder`]).
local function begin_waiting(db: Sqlite.Handle, path: string, wait: boolean, doing?: string): Took?, string
  if not wait then
    db:busy_timeout(0)
    local tried, tried_why = db:exec("BEGIN IMMEDIATE")
    db:busy_timeout(wait_ns)
    if tried then
      mark_holder(path)
      return "done", ""
    end
    if tried_why.code == Sqlite.BUSY then return "busy", "" end
    return nil, tried_why.message
  end
  db:busy_timeout(notice_ns)
  local begun, begun_why = db:exec("BEGIN IMMEDIATE")
  if not begun and begun_why.kind == "cancelled" then
    db:busy_timeout(wait_ns)
    return nil, "interrupted while waiting for the write lock"
  end
  if begun or begun_why.code ~= Sqlite.BUSY then
    db:busy_timeout(wait_ns)
    if not begun then return nil, begun_why.message end
    mark_holder(path)
    return "done", ""
  end
  log:complain(work.waiting_line(work.holding(path), doing))
  local started_ns = Clock.monotonic_ns() - notice_ns
  while true do
    local step = math.max(math.min(reminder_ns, wait_ns - (Clock.monotonic_ns() - started_ns)), 0)
    db:busy_timeout(step)
    local waited, waited_why = db:exec("BEGIN IMMEDIATE")
    local waited_ns = Clock.monotonic_ns() - started_ns
    if not waited and waited_why.kind == "cancelled" then
      db:busy_timeout(wait_ns)
      return nil, "interrupted while waiting for the write lock"
    end
    if waited or waited_why.code ~= Sqlite.BUSY or waited_ns >= wait_ns then
      db:busy_timeout(wait_ns)
      if not waited then return nil, waited_why.message end
      mark_holder(path)
      return "done", ""
    end
    log:complain("still waiting, " .. rebuild_lock.elapsed(waited_ns) .. " on: " .. work.holding(path))
  end
end

--- Puts `db`, the working database at `path`, in write-ahead mode, so a
--- reader -- `cosmic lsp`'s ([`build.lsp.source`]), `cosmic docs`,
--- `cosmic sql --build` -- reads the last commit while a run holds its
--- write transaction open for minutes, and never waits on it. In the
--- rollback mode a file is made in, a writer whose cache spills, or that
--- commits, holds the file whole, and every reader waits or fails
--- "database is locked". A file already in write-ahead mode reports so
--- from its header. Switching one that is not writes the header, and
--- where another run holds the write lock SQLite returns "database is
--- locked" at once, calling no busy handler: the run waits for that
--- lock as for its own transaction ([`begin_waiting`]), lets it go, and
--- asks again. Any mode returned but "wal" is kept: a file system with
--- no shared memory, which write-ahead mode needs, leaves the file in
--- rollback mode, where its readers wait on a writer as they always
--- did. Unless `wait`, it waits for no other run, returning "busy".
local function to_wal(db: Sqlite.Handle, path: string, wait: boolean, doing?: string): Took?, string
  while true do
    local rows, why = db:rows("PRAGMA journal_mode = WAL")
    if rows ~= nil then return "done", "" end
    if why.kind == "cancelled" then return nil, "interrupted while waiting for the write lock" end
    if why.code ~= Sqlite.BUSY and why.code ~= Sqlite.LOCKED then
      return nil, tostring(why)
    end
    local begun, begin_trouble = begin_waiting(db, path, wait, doing)
    if begun == nil then return nil, begin_trouble end
    if begun == "busy" then return "busy", "" end
    local rolled_back, roll_trouble = db:exec("ROLLBACK")
    if not rolled_back then return nil, tostring(roll_trouble) end
  end
end

--- Whether the `SELECT count(*)` in `counting` counted none. It gives
--- one row; a database that gives none is in trouble.
local function counted_none(db: Sqlite.Handle, counting: string): boolean?, string
  local row, trouble = db:one(counting)
  if row == nil then
    if trouble ~= nil then return nil, tostring(trouble) end
    return nil, "`" .. counting .. "` answered no row"
  end
  return row:integer(1) == 0, ""
end

--- Creates every table the schema names, in order, in the working
--- database `db` at `path`. A fresh file's go in in one transaction,
--- which commits, and syncs, once rather than once a statement: about
--- 6 ms where a transaction a statement takes 40 or more. That one is
--- begun as the run's is ([`begin_waiting`]), so a run that meets another
--- holding the file says so while it waits. A file that has tables keeps
--- a transaction a statement, each a no-op, and waits, if it must, at the
--- run's own [`begin_waiting`]. Unless `wait`, it waits for no other
--- run, returning "busy".
local function create(db: Sqlite.Handle, path: string, wait: boolean, doing?: string): Took?, string
  local fresh, count_trouble = counted_none(db, "SELECT count(*) FROM sqlite_master")
  if fresh == nil then
    return nil, count_trouble
  end
  if not fresh then
    -- A file of an older tool has `compiled` without the counts of the checks a compile wrote: a row of it is an
    -- unchecked compile, of 0 checks, which the default says. The index that holds them is made after.
    -- Each column is added if it is missing; a run that opens the file at the same moment may add it first, which
    -- shows as a duplicate column, and the table is read again before that is taken for a failure. The index the
    -- file may hold of the old layout, which nothing reads, goes.
    for _, name in ipairs({ "fact_wraps", "parameter_checks" }) do
      local columns, columns_trouble = db:rows("PRAGMA table_info(compiled)")
      if columns == nil then return nil, tostring(columns_trouble) end
      local present = #columns == 0
      for _, column in ipairs(columns) do
        if column:text(2) == name then present = true end
      end
      if not present then
        local added, add_trouble = db:exec("ALTER TABLE compiled ADD COLUMN " .. name .. " INTEGER NOT NULL DEFAULT 0")
        if not added then
          local again, again_trouble = db:rows("PRAGMA table_info(compiled)")
          if again == nil then return nil, tostring(again_trouble) end
          local now_present = false
          for _, column in ipairs(again) do
            if column:text(2) == name then now_present = true end
          end
          if not now_present then return nil, tostring(add_trouble) end
        end
      end
    end
    local dropped, drop_trouble = db:exec("DROP INDEX IF EXISTS compiled_by_seen")
    if not dropped then return nil, tostring(drop_trouble) end
    -- A table an older tool made, of each compile's bytecode deflated, which no projection carries. Left
    -- where another run holds the database: it is dead weight and no more, and the next open takes it out.
    local _, _ = db:exec("DROP TABLE IF EXISTS deflated_bytecode")
    -- A view whose stored text is not the schema's is made again, dropped and created in one transaction, so a run
    -- reading it meets one definition or the other and never none: `CREATE VIEW IF NOT EXISTS` alone would keep the
    -- other for good. The transaction is begun as the run's is ([`begin_waiting`]), so an open that waits for no
    -- other run returns "busy" where one holds the file.
    for _, statement in ipairs(work.schema) do
      local name = statement:match("^CREATE VIEW IF NOT EXISTS (%S+) AS")
      if name ~= nil then
        local row, stored_trouble = db:one(
          "SELECT sql FROM sqlite_master WHERE type = 'view' AND name = ?1", { text(name) })
        if stored_trouble ~= nil then return nil, tostring(stored_trouble) end
        local now = (statement:gsub("^CREATE VIEW IF NOT EXISTS ", "CREATE VIEW ", 1))
        if row ~= nil and row:text(1) ~= now then
          local begun, begin_trouble = begin_waiting(db, path, wait, doing)
          if begun == nil then return nil, begin_trouble end
          if begun == "busy" then return "busy", "" end
          local remade, remade_trouble = db:exec("DROP VIEW " .. name .. "; " .. statement .. "; COMMIT")
          if not remade then
            local _, _ = db:exec("ROLLBACK")
            return nil, tostring(remade_trouble)
          end
        end
      end
    end
  end
  if fresh then
    local begun, begin_trouble = begin_waiting(db, path, wait, doing)
    if begun == nil then return nil, begin_trouble end
    if begun == "busy" then return "busy", "" end
  end
  for _, statement in ipairs(work.schema) do
    local ok, trouble = db:exec(statement)
    if not ok then
      if fresh then
        local _, _ = db:exec("ROLLBACK")
      end
      return nil, tostring(trouble)
    end
  end
  if fresh then
    local committed, commit_trouble = db:exec("COMMIT")
    if not committed then return nil, tostring(commit_trouble) end
  end
  return "done", ""
end

--- The device and inode of the file at `path`, or "" where there is none.
local function identity_of(path: string): string
  local st, _ = Fs.stat(path)
  if st == nil then return "" end
  return tostring(st.dev) .. ":" .. tostring(st.ino)
end

--- The schema `db` records in `meta`, or nil where it records none: a
--- fresh file, or one whose run never stamped it.
local function schema_of(db: Sqlite.Handle): string?, string
  local meta, table_trouble = db:one(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
  if table_trouble ~= nil then return nil, tostring(table_trouble) end
  if meta == nil then return nil, "" end
  local row, version_trouble = db:one("SELECT value FROM meta WHERE key = 'schema'")
  if version_trouble ~= nil then return nil, tostring(version_trouble) end
  if row == nil then return nil, "" end
  -- A file of another tool is read here, before its tables are held to the schema: its version may be of any type.
  return row:as_text(1) or "", ""
end

--- With the write lock held on `db`, a file of another schema whose
--- device and inode are `file`: removes the file at `path` where it is
--- still that one, and closes `db`. Another run that waited for the lock
--- as this one did may have removed the file and made it again
--- meanwhile: the file at `path` is then that run's, and is kept. False
--- and why where the removal fails.
local function let_go_of_another_schema(db: Sqlite.Handle, path: string, file: string): boolean, string
  if identity_of(path) == file then
    local removed, remove_trouble = Fs.remove(path)
    if not removed then
      local _, _ = db:close()
      return false, tostring(remove_trouble)
    end
  end
  local _, _ = db:close()
  return true, ""
end

--- How the schema `found` is ordered against this module's, which are
--- plain counts: "older" or "newer", and "" for one that is no count, which is
--- neither.
local function order_of(found: string): string
  if found:match("^%d+$") == nil then return "" end
  local theirs, ours = math.tointeger(tonumber(found)), math.tointeger(tonumber(version))
  if theirs == nil or ours == nil or theirs == ours then return "" end
  return if theirs < ours then "older" else "newer" end
end

--- Whether a file of the schema `found` is one that an open in the mode
--- `remake` ([`opened`]) may remove. Only "older" asks the schemas'
--- order: a file of a newer schema was made by a newer tool, which an
--- older tool must leave to it.
local function removable(remake: string, found: string): boolean
  if remake == "any" then return true end
  return remake == "older" and order_of(found) == "older"
end

--- Opens `build.db` in `dir`, or where nil in `root`'s build directory,
--- which [`build.paths`] names and makes. It creates the database and
--- its tables when new, puts it in write-ahead mode ([`to_wal`]), and
--- counts this run. A file whose schema is not this module's holds
--- nothing the tree cannot produce: where `remake` is "any", the open removes it,
--- and where "older", only one of an older schema than this module's, which
--- this tool is the newer writer of ([`removable`]),
--- holding the checkout's rebuild lock ([`build.rebuild_lock`]) and the
--- file's write lock, and makes it again. Its write-ahead log is left,
--- where another process reading the old file keeps one: SQLite deletes
--- a log it finds beside an empty file. Otherwise it removes no file: it
--- returns one of another schema with no handle, having read nothing
--- else of it. Unless `wait`, it waits for no other run, for neither
--- lock ([`work.try_open`]). `locked` says the rebuild lock is held for
--- the open already: by this process, or a parent that handed it on.
--- A wait names what the run is `doing`, where given ([`work.waiting_line`]).
local function opened(root: string, dir: string?, wait: boolean,
                      remake: string, locked: boolean, doing?: string): work.Opening?, string
  local out: string
  if dir == nil then
    local found, directory_trouble = build_paths.prepare(root)
    if found == nil then return nil, directory_trouble end
    out = found
  else
    local made, mkdir_trouble = Fs.mkdirs(dir)
    if not made then
      return nil, tostring(mkdir_trouble)
    end
    out = dir
  end
  local path = build_paths.under(out).working
  -- Before the open, and once it has written: a file put at the path
  -- between the two is opened anew.
  local before = identity_of(path)
  local db, open_trouble = Sqlite.open(path, { writable = true })
  if db == nil then
    return nil, path .. ": " .. tostring(open_trouble)
  end
  -- Before the schema is made: a run meeting a fresh file another is
  -- making its tables in waits for that run's lock here. One that waits
  -- for no run waits a moment at most for a read, which in write-ahead
  -- mode no writer holds off.
  local timeout = notice_ns
  if wait then timeout = wait_ns end
  db:busy_timeout(timeout)
  local encoded, encode_trouble = db:exec("PRAGMA encoding = 'UTF-8'")
  if not encoded then
    local _, _ = db:close()
    return nil, path .. ": " .. tostring(encode_trouble)
  end
  -- After the encoding: on a fresh file the switch is the first write,
  -- which fixes the encoding.
  local logged, log_trouble = to_wal(db, path, wait, doing)
  -- Whatever the switch returned, a file put at the path since the open,
  -- or removed, as another run may while this one waits for its lock, is
  -- opened anew. SQLite refuses to write to the file it opened once
  -- moved ("attempt to write a readonly database"), and a file removed
  -- under a run is one it would build in unlinked.
  local file = identity_of(path)
  if file == "" or (before ~= "" and file ~= before) then
    local _, _ = db:close()
    return opened(root, dir, wait, remake, locked, doing)
  end
  if logged ~= "done" then
    local _, _ = db:close()
    if logged == "busy" then return { handle = nil, other_schema = nil }, "" end
    return nil, path .. ": " .. log_trouble
  end

  -- Before the tables are made, which would write this module's into a
  -- file of another schema.
  local found, schema_trouble = schema_of(db)
  if found == nil and schema_trouble ~= "" then
    local _, _ = db:close()
    return nil, path .. ": " .. schema_trouble
  end
  if found ~= nil and found ~= version then
    -- An open that does not remake ([`work.try_open`]: `cosmic lsp`'s
    -- stage) may be of an older tool than the run building in the file,
    -- which a newer tool made; so it never removes one, holding the lock
    -- or not, and a writer of this tool's (`cosmic test`, `cosmic fix`)
    -- makes it again. A lookup's build ([`work.try_open_older`]) removes
    -- only a file of an older schema, which no newer tool made.
    if not removable(remake, found) then
      local _, _ = db:close()
      return { handle = nil, other_schema = found }, ""
    end
    -- The rebuild lock first. A run that keeps a handle on the file
    -- between its own transactions holds it throughout: `cosmic test`,
    -- whose records follow its compile's commit, a rebuild, a boot. The
    -- file's write lock is free between that run's transactions, and a
    -- file removed then is one it goes on writing to, unlinked, and
    -- loses. Taken holding no transaction, which its holder may wait for.
    if not locked and not rebuild_lock.holds(root) then
      local _, _ = db:close()
      local took: boolean
      if wait then
        local held, hold_trouble = rebuild_lock.hold(root, "remake",
          path .. " (of schema " .. found .. ", to be made again)")
        if held == nil then return nil, hold_trouble end
        took = held
      else
        local taken, take_trouble = rebuild_lock.take(root, 0, "remake")
        if taken == nil then return nil, take_trouble end
        if taken == "busy" then return { handle = nil, other_schema = found }, "" end
        took = true
      end
      local again, again_trouble = opened(root, dir, wait, remake, true, doing)
      if took then rebuild_lock.release() end
      if again == nil then return nil, again_trouble end
      return again, ""
    end
    -- The write lock next: a run building in the file holds it till its
    -- commit.
    local begun, begin_trouble = begin_waiting(db, path, wait, doing)
    if begun ~= "done" then
      local _, _ = db:close()
      if begun == "busy" then return { handle = nil, other_schema = found }, "" end
      return nil, path .. ": " .. begin_trouble
    end
    local gone, gone_trouble = let_go_of_another_schema(db, path, file)
    if not gone then return nil, gone_trouble end
    return opened(root, dir, wait, remake, locked, doing)
  end

  local created, create_trouble = create(db, path, wait, doing)
  if created ~= "done" then
    local _, _ = db:close()
    if created == "busy" then return { handle = nil, other_schema = nil }, "" end
    return nil, path .. ": " .. create_trouble
  end

  -- IMMEDIATE takes the write lock before reading, so a second build of
  -- the same tree waits for the first ([`begin_waiting`]) instead of both
  -- reading and then one failing to upgrade.
  local begun, begin_trouble = begin_waiting(db, path, wait, doing)
  if begun ~= "done" then
    local _, _ = db:close()
    if begun == "busy" then return { handle = nil, other_schema = nil }, "" end
    return nil, path .. ": " .. begin_trouble
  end
  -- The lock held, what was read before it is read again. A run that
  -- held it meanwhile may have removed the file, which this run would
  -- then build in unlinked and lose; or stamped a fresh one with another
  -- schema, which the stamp below would keep.
  if identity_of(path) ~= file then
    local _, _ = db:close()
    return opened(root, dir, wait, remake, locked, doing)
  end
  local stamped, stamped_trouble = schema_of(db)
  if stamped == nil and stamped_trouble ~= "" then
    local _, _ = db:close()
    return nil, path .. ": " .. stamped_trouble
  end
  if stamped ~= nil and stamped ~= version then
    local _, _ = db:close()
    if not removable(remake, stamped) then
      return { handle = nil, other_schema = stamped }, ""
    end
    -- Opened again, it is removed as any file of another schema is,
    -- holding both locks, which are taken in that order.
    return opened(root, dir, wait, remake, locked, doing)
  end
  -- Every table as [`work_schema.Database`] declares it. A file of this version whose tables differ (one made by a tool whose
  -- schema moved without its version) is a file of another schema, whose rows are not read: a column out of place would
  -- give wrong ones. Where this open may remove one, it is stamped so and opened again, which removes it; an open that
  -- may not leaves it as it was. A failure to read the tables is no verdict on them: the open fails, naming it.
  local typed, hold_trouble = Sqlite.hold(db, work_schema.Database)
  if typed == nil then
    if hold_trouble.code ~= nil then
      local _, _ = db:close()
      return nil, path .. ": " .. tostring(hold_trouble)
    end
    local shape = version .. " of another shape"
    if not removable(remake, shape) then
      local _, _ = db:close()
      return { handle = nil, other_schema = shape }, ""
    end
    local marked, mark_trouble = db:run("INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
        "ON CONFLICT (key) DO UPDATE SET value = excluded.value", { text(shape) })
    if marked then marked, mark_trouble = db:exec("COMMIT") end
    local _, _ = db:close()
    if not marked then return nil, path .. ": " .. tostring(mark_trouble) end
    return opened(root, dir, wait, remake, locked, doing)
  end
  local stamp, stamp_trouble = db:run(
    "INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
      "ON CONFLICT (key) DO NOTHING", { text(version) })
  if not stamp then
    local _, _ = db:close()
    return nil, path .. ": " .. tostring(stamp_trouble)
  end
  local counted, count_trouble = typed:one(
    "INSERT INTO meta (key, value) VALUES ('run', 1) " ..
      "ON CONFLICT (key) DO UPDATE SET value = value + 1 RETURNING value")
  if counted == nil then
    local _, _ = db:close()
    return nil, path .. ": " .. tostring(count_trouble)
  end
  return { handle = { db = typed, root = root, dir = out, run = counted:integer(1), inside = true, standing = nil },
    other_schema = nil }, ""
end

--- Opens `build.db` in `dir`, or where nil in `root`'s build directory,
--- which [`build.paths`] names and makes, waiting for another run that
--- holds its write lock, as a build does ([`opened`]). The line that says
--- it waits names what the run is `doing`, where given: its verb, or what
--- else it is ([`work.waiting_line`]).
function work.open(root: string, dir?: string, doing?: string): work.Handle?, string
  local found, trouble = opened(root, dir, true, "any", false, doing)
  if found == nil then return nil, trouble end
  local handle = found.handle
  if handle == nil then return nil, "another cosmic run holds the write lock" end
  return handle, ""
end

--- Opens `root`'s working database as [`work.open`] does, but waits for
--- no other run: where another holds its write lock it returns an
--- opening with no handle. A verb that only reads ([`rebuild.here`]) or
--- `cosmic lsp`'s stage ([`rebuild.stage`]) opens it so: the run
--- holding the lock builds the same tree, and what it last committed is
--- read meanwhile, never waited for. A file of another schema it neither
--- reads nor removes, whoever holds the lock: it returns no handle, and
--- the schema it found (`other_schema`). `doing` names the run while it
--- holds the lock, as [`work.open`]'s does.
function work.try_open(root: string, doing?: string): work.Opening?, string
  return opened(root, nil, false, "never", false, doing)
end

--- Opens `root`'s working database as [`work.try_open`] does, waiting for
--- no other run, but a file of another schema it removes and makes again
--- as [`work.open`] does, where no run holds the checkout's rebuild lock
--- ([`build.rebuild_lock`]) or the file's write lock. Where one does, it
--- returns no handle and the schema it found. The check a verb that only
--- reads makes of the tool ([`reboot.stale_exit`]) opens it so: where the
--- locks are free it is a writer's.
function work.try_open_remaking(root: string): work.Opening?, string
  return opened(root, nil, false, "any", false)
end

--- Opens `root`'s working database as [`work.try_open_remaking`] does, but
--- removes only a file of an older schema than this tool's: a lookup's
--- build ([`rebuild.here`]) is a newer writer than the tool that made
--- that file, which holds nothing the tree cannot produce, and would
--- otherwise say so ([`work.tell_other_schema`]) on every call. A file of
--- a newer schema is left where it is, returned with no handle and the
--- schema found, as is any file a run holds a lock on, which may be that
--- of an older tool still at work in it ([`opened`]).
function work.try_open_older(root: string): work.Opening?, string
  return opened(root, nil, false, "older", false)
end

--- What the process has said of the working database at a path, by
--- what it said and the path ([`work.first_time`]).
local told: mut {string:boolean} = {}

--- Whether this process is yet to say a `kind` of line of the database
--- at `path`, which it is taken to say now: true once a process for each.
function work.first_time(kind: string, path: string): boolean
  local key = kind .. "\0" .. path
  if told[key] == true then return false end
  told[key] = true
  return true
end

--- Says `line` on stderr, once a process for each `kind` of line said of
--- the database at `path` ([`work.first_time`]).
local function tell_once(kind: string, path: string, line: string)
  if work.first_time(kind, path) then log:complain(line) end
end

--- Says once a process, on stderr, that `verb` does not wait for the
--- other run that holds the working database at `path`, and reads what
--- that run last committed.
function work.tell_busy(verb: string, path: string)
  tell_once("busy", path, verb .. ": " .. work.holding(path) .. "; not waiting for it, reading what it last committed")
end

--- What a build of the project at `root`, by this tool, does to a database
--- it left unread, as the line that says so ends: where `root` is known, the
--- command to run, and where it is not, the project it is run in.
local function remedy(root: string?): string
  if root == nil then return "`cosmic test` in the project writes it again" end
  return "`cd " .. root .. " && cosmic test` writes it again"
end

--- Says once a process, on stderr, that `verb` reads none of the working
--- database at `path`, of the project at `root` where that is known, found of
--- the schema `schema`, another than this tool's ([`work.try_open`]), and
--- leaves it where it is. A verb that says so reads none of it, and so stages
--- nothing in it: the rows of another tool's schema are ones its code may
--- misread. A lookup removes one of an older schema itself
--- ([`work.try_open_older`]), so this is said of a newer one, or one a run holds.
function work.tell_other_schema(verb: string, path: string, schema: string, root?: string)
  -- A newer tool's file is not one to advise making again: that removes it.
  local advice = if order_of(schema) == "newer" then
    "a newer tool wrote it" .. (if root ~= nil then "; use that tool in " .. root else "" end) else
    remedy(root) end
  tell_once("other_schema", path, verb .. ": " .. path .. " is of schema " .. schema ..
      ", not this tool's " .. version .. "; reading none of it and leaving it where it is: " ..
      advice)
end

--- The schema the working database `db` records, where it records one
--- other than this module's; nil where it records this module's, or none.
--- It reads `meta` alone. Nil and why where that read fails.
function work.other_schema(db: Sqlite.Handle): string?, string
  local found, trouble = schema_of(db)
  if found == nil or found == version then return nil, trouble end
  return found, ""
end

--- Copies the commits in `db`'s write-ahead log into the file itself
--- and empties the log, so the file alone holds the last commit. A
--- reader that opens the file immutable reads the file alone and never
--- its log: [`Store.attach`], which a test that declares `o/build.db`
--- attaches it through, opens every database so. And a
--- test's verdict is keyed by the bytes of the files it declares
--- ([`build.declared_key`]), which name `build.db` and not its log. A run
--- commits its build and keeps its handle open while its tests run, so
--- no close checkpoints first: with the commits left in the log, such a
--- test reads a file with no tables yet ("no such table: main.meta"),
--- and two checkouts whose files hold the same bytes, their logs
--- differing, share a verdict. It waits on a reader still reading an
--- older commit for `notice_ns` at most, never as a run waits for the
--- write lock: one left short keeps the rest in the log, which SQLite
--- reads, and only a reader of the file alone reads an older commit. A
--- file in rollback mode has no log, and nothing is done.
local function checkpoint(db: Database)
  db:busy_timeout(notice_ns)
  local _, _ = db:rows("PRAGMA wal_checkpoint(TRUNCATE)")
  db:busy_timeout(wait_ns)
end

--- Ends the run's transaction, keeping everything it did, and copies it
--- into the file ([`checkpoint`]). Nothing to do when it has already
--- ended.
function work.commit(handle: work.Handle): boolean, string
  if not handle.inside then
    return true, ""
  end
  local committed, trouble = handle.db:exec("COMMIT")
  if not committed then
    -- A failed COMMIT leaves SQLite's transaction open. Roll it back so
    -- close cannot keep a partial phase and `inside` stays truthful even
    -- when the database reports a deferred error here. The COMMIT's own
    -- trouble is the one reported.
    local rolled_back, _ = handle.db:exec("ROLLBACK")
    if rolled_back then
      handle.inside = false
    end
    return false, tostring(trouble)
  end
  handle.inside = false
  checkpoint(handle.db)
  return true, ""
end

--- Ends the run's transaction, discarding everything it did. Nothing to
--- do when it has already ended.
function work.rollback(handle: work.Handle): boolean, string
  if not handle.inside then
    return true, ""
  end
  local rolled_back, trouble = handle.db:exec("ROLLBACK")
  if not rolled_back then
    return false, tostring(trouble)
  end
  handle.inside = false
  return true, ""
end

--- Opens another transaction on the run, for a phase that comes after
--- the projection: the test runner's records, written together.
function work.begin(handle: work.Handle): boolean, string
  local begun, begun_why = handle.db:exec("BEGIN IMMEDIATE")
  if not begun and begun_why.kind == "cancelled" then
    return false, "interrupted while waiting for " .. handle.dir .. "/build.db"
  end
  if not begun then return false, begun_why.message end
  handle.inside = true
  mark_holder(build_paths.under(handle.dir).working)
  return true, ""
end

--- The source policy, plus the headers whose declarations this stage generates.
local function is_input(file: string, own_tree: boolean): boolean
  if identity.is_input(file, own_tree) then
    return true
  end
  if own_tree then
    for _, derivation in ipairs(gen_syscalls.targets) do
      if file == derivation.target.header then
        return true
      end
    end
  end
  return false
end

--- What a stat said about a file the last time it was staged, read
--- once per table into memory, so an unchanged file costs a stat and
--- a comparison and never a query.
local record Known
  size: integer
  --- nil for a row staged before its file settled, which no stat matches.
  mtime_ns: integer?
  ctime_ns: integer?
  ino: integer
  dev: integer
end

local function known_in(db: Sqlite.Handle,
                        table_name: string): {string:Known}?, string
  local rows, trouble = db:query(
    -- A NULL reads as 0, as SQLite's own integer of one does.
    "SELECT path, ifnull(size, 0), ifnull(mtime_ns, 0), ifnull(ino, 0), ifnull(dev, 0), mtime_ns IS NULL, " ..
      "ifnull(ctime_ns, 0), ctime_ns IS NULL FROM " .. table_name)
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {string:Known} = {}
  for row in rows:each() do
    out[row:bytes(1)] = {
      size = row:integer(2),
      mtime_ns = if row:integer(6) == 0 then row:integer(3) else nil end,
      ctime_ns = if row:integer(8) == 0 then row:integer(7) else nil end,
      ino = row:integer(4),
      dev = row:integer(5),
    }
  end
  local failure = rows:failure()
  if failure ~= nil then
    return nil, tostring(failure)
  end
  return out, ""
end

--- `files` keeps the bytes; `tool` and `scanned` keep only what a stat
--- and a hash say about them. The put for each takes the bytes as its
--- sixth parameter and their hash, made once per read, as its seventh;
--- `todo` is one TODO's row, and `miss` one near miss's.
local puts: {string:string} = {
  files = "INSERT OR REPLACE INTO files (path, size, mtime_ns, ino, dev, " ..
    "sha256, data, ctime_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?6, ?9)",
  tool = "INSERT OR REPLACE INTO tool (path, size, mtime_ns, ino, dev, " ..
    "sha256, ctime_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?9)",
  scanned = "INSERT OR REPLACE INTO scanned (path, size, mtime_ns, ino, dev, " ..
    "sha256, ctime_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?9)",
  linked = "INSERT OR REPLACE INTO linked (path, size, mtime_ns, ino, dev, " ..
    "sha256, kind, ctime_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?8, ?9)",
  todo = "INSERT OR IGNORE INTO todos (sha256, line, last, text) " ..
    "VALUES (?1, ?2, ?3, ?4)",
  miss = "INSERT OR IGNORE INTO todo_misses (sha256, line, spelling) VALUES (?1, ?2, ?3)",
}

--- The largest file `scanned` reads for TODOs.
local scanned_limit = 1024 * 1024

--- How long a file's modification and change times must be in the past before
--- a stat is trusted to stand for its bytes.
local settle_ns = Clock.seconds(2)

--- Whether a file now stated as `st` differs from the row `was` recorded
--- for it: there is no row, or its size, time, inode or device moved.
local function differs(was: Known?, st: sys.Stat, mtime_ns: integer): boolean
  local was_mtime_ns = was and was.mtime_ns
  local ctime_ns = was and was.ctime_ns
  return was == nil or was.size ~= st.size or was_mtime_ns == nil or
    was_mtime_ns ~= mtime_ns or ctime_ns == nil or
    st.ctime_ns == nil or ctime_ns ~= Clock.seconds(st.ctime) + st.ctime_ns or -- checked: compare_disjoint
    was.ino ~= st.ino or was.dev ~= st.dev
end

--- Whether a file's row no longer stands for it, consuming the row
--- from `known` either way, so what is left in `known` at the end is
--- what the walk no longer finds.
local function moved(known: mut {string:Known}, file: string, st: sys.Stat,
                     mtime_ns: integer): boolean
  local was = known[file]
  known[file] = nil
  return differs(was, st, mtime_ns)
end

--- Whether the tool's recorded files or discovery directories moved. The
--- same walk that stages inputs records its directories, so a new input
--- invalidates the fast path without listing an unchanged tree again.
local function tool_moved_in(db: Sqlite.Handle, root: string): boolean?, string
  for _, table_name in ipairs({ "tool", "tool_discovery" }) do
    local known, trouble = known_in(db, table_name)
    if known == nil then return nil, trouble end
    if table_name == "tool_discovery" and known[""] == nil then return true, "" end
    for path in pairs(known) do
      local st, _ = Fs.stat(root .. "/" .. path)
      if st == nil then return true, "" end
      local mtime_ns = Clock.seconds(st.mtime) + st.mtime_ns
      if moved(known, path, st, mtime_ns) then return true, "" end -- checked: view_as_mut
    end
  end
  return false, ""
end

function work.tool_moved(handle: work.Handle): boolean?, string
  return tool_moved_in(handle.db, handle.root)
end

--- The staged inputs whose files moved since [`work.stage`] read them,
--- sorted: changed, replaced or gone. A run checks the tree as staged,
--- so a failure in a tree edited during the run names these files and
--- says to run it again ([`work.moved_line`]). A file whose stat moved,
--- or whose row was staged unsettled and keeps no time, is hashed again
--- and held to the staged digest. A file added after the stage is not among them. Nil and the
--- trouble where the table cannot be read.
function work.moved_since_stage(handle: work.Handle): {string}?, string
  local known, trouble = known_in(handle.db, "files")
  if known == nil then return nil, trouble end
  local digests, digest_trouble = handle.db:rows("SELECT path, sha256 FROM files")
  if digests == nil then return nil, tostring(digest_trouble) end
  local staged_sha: mut {string:string} = {}
  for _, row in ipairs(digests) do staged_sha[row:text(1)] = row:text(2) end
  local paths: mut {string} = {}
  for path in pairs(known) do paths[#paths + 1] = path end
  table.sort(paths)
  local out: mut {string} = {}
  for _, path in ipairs(paths) do
    local full = handle.root .. "/" .. path
    local was = known[path]!
    local st, _ = Fs.stat(full)
    -- A stat that moved is held to the staged digest, so a chmod or a
    -- touch with the bytes unchanged is not named.
    local changed = st == nil
    if st ~= nil and (was.mtime_ns == nil or differs(was, st, Clock.seconds(st.mtime) + st.mtime_ns)) then
      local now, _ = Hash.hex_file("sha256", full)
      changed = st.size ~= was.size or now ~= staged_sha[path]
    end
    if changed then out[#out + 1] = path end
  end
  return out, ""
end

--- The line a failed run adds when files moved under it: at most five
--- named, then how many more. Empty for none.
function work.moved_line(paths: {string}): string
  if #paths == 0 then return "" end
  local named: mut {string} = {}
  for i = 1, math.min(#paths, 5) do named[i] = paths[i] end
  local list = table.concat(named, ", ")
  if #paths > 5 then list = list .. (" and %d more"):format(#paths - 5) end
  return list .. " changed during the run, which checked the tree as staged; run it again"
end

--- Whether the tool's recorded inputs in the working database of `root`
--- stand as [`work.tool_moved`] would find them, and the boot hash its
--- last stage recorded is `boot_hash`, read without writing anything
--- there: no run is counted and nothing is committed, so a run holding
--- the tree to a boundary (CI's, which hashes the file and its
--- write-ahead log across steps) sees them as they were. With no log
--- beside it the file is opened immutable, which makes none; with one,
--- another connection has it open, and it is read through the log
--- read-only, which writes neither. What a run outside the tree asks of
--- the checkout its tool was built from ([`build.reboot.stale_exit`]).
function work.tool_read_unwritten(root: string, boot_hash: string): work.Unwritten
  local directory, _ = build_paths.optional(root)
  if directory == nil then return "unknown" end
  local path = build_paths.under(directory).working
  local present_status, _ = Fs.status(path)
  local present = present_status ~= nil and present_status.exists
  if present ~= true then return "unknown" end
  local logged_status, _ = Fs.status(path .. "-wal")
  local logged = logged_status ~= nil and logged_status.exists
  local db, _ = Sqlite.open(path, { immutable = logged ~= true })
  if db == nil then return "unknown" end
  local schema, _ = schema_of(db)
  local answer: work.Unwritten = "unknown"
  if schema == version then
    local moved_now, _ = tool_moved_in(db, root)
    if moved_now == false then
      local recorded, _ = identity.recorded_boot_hash(db)
      if recorded ~= nil and recorded == boot_hash then answer = "fresh" end
    end
  end
  local _, _ = db:close()
  return answer
end

--- Writes one file's row: its stat, with the modification time kept
--- only once it has settled, its bytes, and their hash.
local function put_row(put: Sqlite.Statement, file: string, st: sys.Stat,
                       mtime_ns: integer, settled: boolean,
                       data: string, sha256: string, kind?: string): boolean, string
  local changed: Sqlite.Param = Sqlite.NULL
  if settled and st.ctime_ns ~= nil then -- checked: compare_disjoint
    changed = Clock.seconds(st.ctime) + st.ctime_ns
  end
  local tag: Sqlite.Param = Sqlite.NULL
  if kind ~= nil then tag = kind end
  local ok, trouble = put:run({ file, st.size, if settled then mtime_ns else Sqlite.NULL end, st.ino, st.dev,
    Sqlite.blob(data), sha256, tag, changed })
  if not ok then
    return false, file .. ": " .. tostring(trouble)
  end
  return true, ""
end

--- Whether a file is a patch record ([`build/patch.tl`]): a `.txt` in
--- `patch/<name>/`.
local function is_record(file: string): boolean
  return file:match("^patch/[^/]+/[^/]+%.txt$") ~= nil
end

--- Whether a file holds TODOs of the tree's own: a vendored tree and
--- its pin are upstream's, and so is everything under `patch/` but a
--- record, whose find blocks are too ([`build.todo_scan.scan_record`]).
local function holds_own_todos(file: string): boolean
  local first = identity.first_of(file)
  return first ~= "vendor" and (first ~= "patch" or is_record(file)) and
    not identity.is_static(file)
end

--- Records the TODOs in one file's bytes under their hash, and the
--- comments that open with a near miss of the spelling (`miss`), unless a
--- file with the same bytes already has: text that parses as a patch
--- record is scanned as one wherever it sits, since the rows are keyed
--- by the bytes alone, and its near misses are not looked for. Text holding
--- neither `TODO` nor `FIXME`, or holding a NUL, is not scanned.
local function put_todos(put: Sqlite.Statement, miss: Sqlite.Statement, data: string,
                         sha256: string): boolean, string
  if (data:find("TODO", 1, true) == nil and data:find("FIXME", 1, true) == nil) or
      data:find("\0", 1, true) ~= nil then
    return true, ""
  end
  local record = todo_scan.scan_record(data)
  if record == nil then
    for _, near in ipairs(todo_scan.misses(data)) do
      local ok, trouble = miss:run({ sha256, near.line, near.spelling })
      if not ok then
        return false, tostring(trouble)
      end
    end
  end
  local scanned = record or todo_scan.scan(data)
  for _, found in ipairs(scanned) do
    local ok, trouble = put:run({ sha256, found.line, found.last, found.text })
    if not ok then
      return false, tostring(trouble)
    end
  end
  return true, ""
end

--- Finalizes every statement `stage` prepared, by the `puts` key.
local function finish(put: {string:Sqlite.Statement})
  for _, statement in pairs(put) do
    statement:close()
  end
end

--- Deletes the rows `known` still holds, which the walk did not find.
local function forget(db: Database, table_name: string,
                      known: {string:Known}): boolean, string
  for path in pairs(known) do
    local ok, why = db:run(
      "DELETE FROM " .. table_name .. " WHERE path = ?1", { text(path) })
    if not ok then
      return false, path .. ": " .. tostring(why)
    end
  end
  return true, ""
end

--- Why the static asset `file` of `root` (whose real path is `real_root`)
--- cannot be carried, or nil: what [`identity.static_refusal`] refuses by
--- name and size, a path as an asset that differs only in case from that of
--- an asset staged before it which a program would carry beside it (a tree
--- must build the same on a case-insensitive disk), and a link that leads
--- out of the project, which would make the executable depend on files
--- outside the checkout. `seen` maps each lowercase path as an asset to the
--- file staged at it for each program ("" for a shared one). Two programs'
--- own assets never meet, and one of a program's own at the path of a
--- shared one is laid over it.
local function static_refusal(root: string, real_root: string, file: string, size: integer,
                              seen: mut {string: mut {string:string}}): string?
  local refusal = identity.static_refusal(file, size)
  if refusal ~= nil then return refusal end
  local asset = analysis_schema.static_asset(file)
  if asset == nil then return nil end
  local program = asset.program
  local lowered = asset.path:lower()
  local held: mut {string:string} = seen[lowered] or {}
  seen[lowered] = held
  local programs: mut {string} = {}
  for other in pairs(held) do programs[#programs + 1] = other end
  table.sort(programs)
  for _, other in ipairs(programs) do
    local earlier = assert(held[other], "a program listed holds a file")
    local spelled = analysis_schema.static_asset(earlier)
    if (spelled == nil or spelled.path ~= asset.path) and (other == program or other == "" or program == "") then
      return ("%s: differs from %s only in case; rename one, so the tree builds the same on a " ..
        "case-insensitive disk"):format(file, earlier)
    end
  end
  held[program] = file
  local real, trouble = Fs.absolute(root .. "/" .. file)
  if real == nil then return tostring(trouble) end
  if real:sub(1, #real_root + 1) ~= real_root .. "/" then
    return ("%s: a link to %s, outside the project; the executable would depend on a file " ..
      "the checkout does not hold"):format(file, real)
  end
  return nil
end

--- The boot hash of the code this process runs: the running binary's,
--- or, in a boot, which runs the tree's own code and carries no
--- database, the one of the tool it writes, over the `tool` rows the
--- stage wrote ([`identity.record_fingerprint`]'s `boot`). A stage
--- records it as `staged_by` ([`work.other_code`]).
local function running_tool(db: Sqlite.Handle): string?, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash ~= nil then
    return boot_hash, ""
  end
  return identity.hash_over(db, "1")
end

--- Reads the links of the files of `linked` not yet read (see its
--- definition, which needs [`identity.hash_over`]).
local find_links: function(handle: work.Handle, texts: {string:string}): boolean, string

--- What the links a walk meets teach it: the ancestors of the root, found
--- when the first link asks, and the first link that leads above the root.
local record Walking
  mut ancestors: mut {string:boolean}?
  mut above: string
end

--- Whether `file` of `root`, whose stat differs from its rows, still holds the bytes each of the tables `wanted`
--- names has for it, at most `size` of them as a stage reads it: a file written again with what it held, or one
--- whose stat had not settled when it was staged, which a stage only writes again with its new stat. `link_kind` is
--- the kind its `linked` row has. A stage's dry run ([`staging`]) goes on past such a file; false and why where it
--- would write a row of other bytes, or a row the table lacks.
local function same_bytes(db: Database, root: string, file: string, size: integer, wanted: {string:boolean},
                          link_kind?: string): boolean, string
  local data, read_trouble = Fs.read(root .. "/" .. file, size)
  if data == nil then return false, tostring(read_trouble) end
  local sha256 = Hash.hex_sha256(data)
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    if wanted[table_name] == true then
      local sql = "SELECT sha256 FROM " .. table_name .. " WHERE path = ?1"
      local params: {Sqlite.Param} = { text(file) }
      if table_name == "linked" then
        sql = sql .. " AND kind = ?2"
        params = { text(file), text(link_kind or "") }
      end
      local row, trouble = db:one(sql, params)
      if trouble ~= nil then return false, tostring(trouble) end
      if row == nil or row:text(1) ~= sha256 then
        return false, file .. " moved since the last stage"
      end
    end
  end
  return true, ""
end

--- The rest of a dry run of a stage ([`staging`]) once its walk found no file moved: whether the stage would delete
--- a row of a file the walk no longer finds (`known` holds what it did not find), find links again (the code finding
--- them is another, or a staged file's text is not read for links yet, or a row of what one found has no file), or
--- prune a TODO row, or record another code as having staged the tree. Nil and the first it found where it would;
--- else what it staged.
local function dry_rest(db: Database, known: {string:{string:Known}}): work.Staged?, string
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local gone = next((assert(known[table_name], "every table was read by the walk")))
    if gone ~= nil then return nil, gone .. " is gone since the last stage" end
  end
  -- The code a stage records ([`running_tool`]), and the one finding links it keeps ([`links_finder`]): a process
  -- that carries no boot hash takes the tree's for both.
  local by, by_trouble = running_tool(db)
  if by == nil then return nil, by_trouble end
  local finder = if Store.meta("boot_hash") == nil then "IS ?1" else "IS NOT NULL" end
  local row, trouble = db:one("SELECT " ..
      "(SELECT value FROM meta WHERE key = 'staged_by') IS ?1 AND " ..
      "(SELECT value FROM meta WHERE key = 'links_boot') IS ?1 AND " ..
      "(SELECT value FROM meta WHERE key = 'links_by') " .. finder .. " AND " ..
      "NOT EXISTS (SELECT 1 FROM linked l WHERE NOT EXISTS (SELECT 1 FROM linked_texts t " ..
      "WHERE t.sha256 = l.sha256 AND t.kind = l.kind)) AND " ..
      "NOT EXISTS (SELECT 1 FROM linked_found f WHERE NOT EXISTS (SELECT 1 FROM linked l " ..
      "WHERE l.sha256 = f.sha256 AND l.kind = f.kind)) AND " ..
      "NOT EXISTS (SELECT 1 FROM linked_texts f WHERE NOT EXISTS (SELECT 1 FROM linked l " ..
      "WHERE l.sha256 = f.sha256 AND l.kind = f.kind)) AND " ..
      "NOT EXISTS (SELECT 1 FROM todos WHERE sha256 NOT IN " ..
      "(SELECT sha256 FROM files UNION SELECT sha256 FROM tool UNION SELECT sha256 FROM scanned)) AND " ..
      "NOT EXISTS (SELECT 1 FROM todo_misses WHERE sha256 NOT IN " ..
      "(SELECT sha256 FROM files UNION SELECT sha256 FROM tool UNION SELECT sha256 FROM scanned))",
    { text(by) })
  if row == nil then return nil, tostring(trouble) end
  if row:integer(1) ~= 1 then return nil, "the stage would record its code or find links again" end
  return { files = 0, read = 0, notes = {} }, ""
end

--- What [`work.stage`] told `handle` its root is. Raises on a handle that was not staged: every compile and write
--- reads a staged tree.
function work.standing(handle: work.Handle): tree.Standing
  return (assert(handle.standing, "the tree was not staged: work.stage tells a handle what its root is"))
end

--- [`work.stage`] of `db`, the working database of `root`, where `handle` is the run's that holds it. Without one it
--- is the stage's dry run, which writes nothing: it answers nil, and the first thing it found the stage would write,
--- where the stage would write any row or the code that staged it was another than this process's.
local function staging(db: Database, root: string, own_tree: boolean, handle?: work.Handle): work.Staged?, string -- checked: not_assigned
  local dry = handle == nil
  -- A link is taken for what it leads to, so a project whose modules
  -- or tests are reached through one (`lib -> ../shared/lib`) builds
  -- them. A loop of links ends its branch rather than the stage.
  -- A link to a directory above the root is refused: the walk would
  -- stage everything under that directory but the root, where `skip`,
  -- asked only about paths under the root, stops nothing. The root's
  -- ancestors are known by device and inode, as the walk knows a loop,
  -- so a differing spelling of one (another case, a bind mount) is
  -- still one. A link to the root itself is a loop and ends there; a
  -- link to a tree beside the root, or to an unrelated one
  -- (`sys -> /usr`), is staged whole, by design. Only a link is
  -- stat'd, so a tree with none costs nothing more.
  -- Capture before listing: a concurrent addition after the list must not
  -- be hidden by a newer directory stat recorded after the walk.
  local discovery: mut {string:sys.Stat} = {}
  if own_tree then
    local st, trouble = Fs.stat(root)
    if st == nil then return nil, tostring(trouble) end
    discovery[""] = st
  end
  local skip_path = if own_tree then identity.skip_in_own_tree else identity.skip_input end
  -- Each entry only the walk for links reaches.
  local links_only: mut {string:boolean} = {}
  local link_skip = link_files.skipper(root)
  local function for_links(entry: string): boolean
    return not link_skip(entry) and not (own_tree and identity.is_foreign_tree(identity.first_of(entry)))
  end
  local walking: Walking = { ancestors = nil, above = "" }
  local function skip(entry: string, name: string, kind: string): boolean
    local parent = entry:match("^(.*)/[^/]*$")
    if (parent ~= nil and links_only[parent] == true) or skip_path(entry, name) then
      if not for_links(entry) then
        return true
      end
      links_only[entry] = true
    end
    if own_tree and links_only[entry] ~= true and
        not identity.is_foreign_tree(identity.first_of(entry)) and
        (kind == "dir" or kind == "link") then
      local st, _ = Fs.stat(root .. "/" .. entry)
      if st == nil then
        local link, _ = sys.lstat(root .. "/" .. entry)
        st = link
      end
      if st ~= nil then discovery[entry] = st end
    end
    if kind ~= "link" then
      return false
    end
    local known: mut {string:boolean} = walking.ancestors or {}
    if walking.ancestors == nil then
      walking.ancestors = known
      local path = root
      local last = ""
      while true do
        local st, _ = Fs.stat(path)
        if st == nil then
          break
        end
        local key = tostring(st.dev) .. ":" .. tostring(st.ino)
        if key == last then
          break
        end
        if last ~= "" then
          known[key] = true
        end
        last = key
        path = path .. "/.."
      end
    end
    -- One that leads nowhere is not walked, so it is let be.
    local st, _ = Fs.stat(root .. "/" .. entry)
    if st ~= nil and known[tostring(st.dev) .. ":" .. tostring(st.ino)] == true then
      if walking.above == "" then
        local target, _ = Fs.absolute(root .. "/" .. entry)
        walking.above = root .. "/" .. entry .. ": a link to " .. (target or "a directory") ..
          ", above the root, whose whole tree would be staged"
      end
      return true
    end
    return false
  end
  local walked, walk_trouble = Fs.walk(root, { follow = true, skip = skip })
  if walked == nil then
    return nil, tostring(walk_trouble)
  end
  if walking.above ~= "" then
    return nil, walking.above
  end
  local files: {string} = walked
  local known: mut {string:{string:Known}} = {}
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local rows, trouble = known_in(db, table_name)
    if rows == nil then
      return nil, trouble
    end
    known[table_name] = rows
  end
  local put: mut {string:Sqlite.Statement} = {}
  for _, name in ipairs({ "files", "tool", "scanned", "linked", "todo", "miss" }) do
    local statement, trouble = db:prepare((assert(puts[name], "every name listed has its put")))
    if statement == nil then
      finish(put)
      return nil, tostring(trouble)
    end
    put[name] = statement
  end
  -- Prepared by the loop above, one for each name it lists.
  local put_files = assert(put["files"], "every put was prepared")
  local put_tool = assert(put["tool"], "every put was prepared")
  local put_scanned = assert(put["scanned"], "every put was prepared")
  local put_linked = assert(put["linked"], "every put was prepared")
  local put_todo = assert(put["todo"], "every put was prepared")
  local put_miss = assert(put["miss"], "every put was prepared")
  local now = Clock.now_ns()
  local staged: work.Staged = { files = 0, read = 0, notes = {} }
  -- The real path of `root`, once a static asset asks for it, and the
  -- static paths seen by their lowercase spelling.
  local real_root: string? = nil
  local static_seen: mut {string: mut {string:string}} = {}
  -- The text of each file of `linked` read here, by path.
  local texts: mut {string:string} = {}

  for _, file in ipairs(files) do
    local only = links_only[file] == true
    local input = not only and is_input(file, own_tree)
    local tool = not only and identity.is_tool(file, own_tree)
    local scan = not only and not input and not tool and holds_own_todos(file)
    local link_kind = if for_links(file) then link_files.checked(file, own_tree) else nil end
    local st, stat_trouble = Fs.stat(root .. "/" .. file)
    if st == nil then
      finish(put)
      return nil, tostring(stat_trouble)
    end
    if scan and st.size > scanned_limit then
      scan = false
    end
    if input and identity.is_static(file) then
      local static_root: string
      if real_root ~= nil then
        static_root = real_root
      else
        local resolved, resolve_trouble = Fs.absolute(root)
        if resolved == nil then
          finish(put)
          return nil, tostring(resolve_trouble)
        end
        static_root = resolved
        real_root = resolved
      end
      local refusal = static_refusal(root, static_root, file, st.size, static_seen)
      if refusal ~= nil then
        finish(put)
        return nil, refusal
      end
    end
    if input or tool or scan or link_kind ~= nil then
      local mtime_ns = Clock.seconds(st.mtime) + st.mtime_ns
      local settled = st.ctime_ns ~= nil and -- checked: compare_disjoint
        math.max(mtime_ns, Clock.seconds(st.ctime) + st.ctime_ns) < now - settle_ns
      if input or tool then
        staged.files = staged.files + 1
      end
      local write_files = input and moved(known.files, file, st, mtime_ns) -- checked: map_field
      local write_tool = tool and moved(known.tool, file, st, mtime_ns) -- checked: map_field
      local write_scanned = scan and moved(known.scanned, file, st, mtime_ns) -- checked: map_field
      local write_linked = link_kind ~= nil and moved(known.linked, file, st, mtime_ns) -- checked: map_field
      if dry and (write_files or write_tool or write_scanned or write_linked) then
        local same, why = same_bytes(db, root, file, st.size, { files = write_files, tool = write_tool,
          scanned = write_scanned, linked = write_linked }, link_kind)
        if not same then
          finish(put)
          return nil, why
        end
        write_files, write_tool, write_scanned, write_linked = false, false, false, false
      end
      if write_files or write_tool or write_scanned or write_linked then
        -- At most the size the stat saw: a file that grows while it is
        -- read (a strace log in the tree, written as this run reads)
        -- is staged as it stood at the stat, not read without end.
        local data, read_trouble = Fs.read(root .. "/" .. file, st.size)
        if data == nil then
          finish(put)
          return nil, tostring(read_trouble)
        end
        staged.read = staged.read + 1
        if write_files and identity.is_static(file) and
            (file:match("%.tl$") ~= nil or file:match("%.tmpl$") ~= nil) then
          local note = file .. ": a static asset, so it is carried as an asset and is no module"
          staged.notes[#staged.notes + 1] = note
          log:complain(note)
        end
        local sha256 = Hash.hex_sha256(data)
        if (input or tool or scan) and holds_own_todos(file) then
          local ok, why = put_todos(put_todo, put_miss, data, sha256)
          if not ok then
            finish(put)
            return nil, file .. ": " .. why
          end
        end
        local stat, content: sys.Stat, string = st, data
        local function write(wanted: boolean, statement: Sqlite.Statement, kind?: string): boolean, string
          if not wanted then
            return true, ""
          end
          return put_row(statement, file, stat, mtime_ns, settled, content, sha256, kind)
        end
        local ok, why = write(write_files, put_files)
        if ok then
          ok, why = write(write_tool, put_tool)
        end
        if ok then
          ok, why = write(write_scanned, put_scanned)
        end
        if ok and write_linked and link_kind ~= nil then
          texts[file] = data
          ok, why = write(true, put_linked, link_kind)
        end
        if not ok then
          finish(put)
          return nil, file .. ": " .. why
        end
      end
    end
  end
  -- The directories' stats only tell a later run that the tool may have moved without its walk ([`work.tool_moved`]);
  -- the dry run walked every directory itself.
  if own_tree and not dry then
    local cleared, trouble = db:exec("DELETE FROM tool_discovery")
    if not cleared then
      finish(put)
      return nil, tostring(trouble)
    end
    local discovery_put, prepare_trouble = db:prepare(
      "INSERT INTO tool_discovery (path, size, mtime_ns, ctime_ns, ino, dev) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    if discovery_put == nil then
      finish(put)
      return nil, tostring(prepare_trouble)
    end
    for path, st in pairs(discovery) do
      local mtime_ns = Clock.seconds(st.mtime) + st.mtime_ns
      local ctime_ns = if st.ctime_ns ~= nil then Clock.seconds(st.ctime) + st.ctime_ns else nil end -- checked: compare_disjoint
      local settled = ctime_ns ~= nil and math.max(mtime_ns, ctime_ns) < now - settle_ns
      local saved, why = discovery_put:run({ path, st.size, if settled then mtime_ns else Sqlite.NULL end,
        if settled then ctime_ns or 0 else Sqlite.NULL end, st.ino, st.dev })
      if not saved then
        discovery_put:close()
        finish(put)
        return nil, tostring(why)
      end
    end
    discovery_put:close()
  end
  finish(put)
  if dry then
    return dry_rest(db, known)
  end
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local forgot, forget_trouble = forget(db, table_name,
      (assert(known[table_name], "every table forgotten was read above")))
    if not forgot then
      return nil, forget_trouble
    end
  end
  local found, found_trouble = find_links(assert(handle, "a stage that writes holds the database"), texts)
  if not found then
    return nil, found_trouble
  end
  for _, table_name in ipairs({ "todos", "todo_misses" }) do
    local pruned, prune_trouble = db:exec(
      "DELETE FROM " .. table_name .. " WHERE sha256 NOT IN " ..
        "(SELECT sha256 FROM files UNION SELECT sha256 FROM tool " ..
        "UNION SELECT sha256 FROM scanned)")
    if not pruned then
      return nil, tostring(prune_trouble)
    end
  end
  local by, by_trouble = running_tool(db)
  if by == nil then
    return nil, by_trouble
  end
  local recorded, record_trouble = db:run(
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('staged_by', ?1)", { text(by) })
  if not recorded then
    return nil, tostring(record_trouble)
  end
  return staged, ""
end

--- Reads the tree into `files` and, in cosmic's own tree, fingerprints
--- what the tool is made of into `tool`, everything else the walk
--- finds into `scanned`, and each file whose links are checked into
--- `linked`, in one pass: a file is stat'd once and read at most once,
--- and scanned for TODOs and read for links in the same moment. A file
--- whose stat matches its row is not read; one that differs, or is
--- new, is read, hashed and written; one the walk no longer finds is
--- deleted. Only a change reaches the database.
---
--- The walk goes where `cosmic fix` looks for links, too
--- ([`link_files.skipper`]): what only that walk reaches (doc/'s prose,
--- `.claude/`) is staged into `linked` alone.
--- @param standing what `root` is to the running tool, which the handle
---   keeps. Whether it is cosmic's own tree decides which files are the
---   tool's sources, and so is a part of what a stage reads.
function work.stage(handle: work.Handle, standing: tree.Standing): work.Staged?, string
  handle.standing = standing
  return staging(handle.db, handle.root, standing.own, handle)
end

--- The working database of `root`, opened read-only and holding no lock, where a stage would write nothing in it: no
--- file moved, came or went since the last stage, the code that staged it and found its links is this process's, and
--- every file it holds has had its links read ([`staging`]'s dry run). What a file run reads where another run holds
--- the write lock ([`build.dispatch`]): what that run last committed, where it stands as the tree does, is what a
--- stage of its own would leave, so the run need not wait for the lock to know whether its projection holds. The
--- database is opened as [`work.tool_read_unwritten`] opens it. Nil and why where it is missing, of another
--- schema, or a stage would write any row; the caller closes the database.
--- @param standing what `root` is to the running tool ([`work.stage`])
function work.settled_read(root: string, standing: tree.Standing): Database?, string
  local directory, _ = build_paths.optional(root)
  if directory == nil then return nil, "no build directory" end
  local path = build_paths.under(directory).working
  local present_status, _ = Fs.status(path)
  if present_status == nil or not present_status.exists then return nil, "no working database" end
  local logged_status, _ = Fs.status(path .. "-wal")
  local logged = logged_status ~= nil and logged_status.exists
  local db, open_trouble = Sqlite.open(path, { immutable = not logged })
  if db == nil then return nil, tostring(open_trouble) end
  local schema, _ = schema_of(db)
  if schema ~= version then
    local _, _ = db:close()
    return nil, "the working database is of another schema"
  end
  local typed, hold_trouble = Sqlite.hold(db, work_schema.Database)
  if typed == nil then
    local _, _ = db:close()
    return nil, tostring(hold_trouble)
  end
  -- One read transaction, left open for the caller: the dry stage and what the caller reads after it (the boot
  -- fingerprint, the run's stamp key) see one commit of the run that holds the lock, not one each. The close ends it.
  local begun, begun_why = typed:exec("BEGIN")
  if not begun then
    local _, _ = typed:close()
    return nil, tostring(begun_why)
  end
  local staged, trouble = staging(typed, root, standing.own, nil)
  if staged == nil then
    local _, _ = typed:close()
    return nil, trouble
  end
  return typed, ""
end

--- The code the working database `db` records staging it (`meta`'s
--- `staged_by`, [`work.stage`]), where that is other than the code this
--- process runs ([`running_tool`]): the boot hash it records, or "" where
--- it records none, as one an older tool staged does. Nil where it is
--- this process's own. A process that carries no boot hash runs the
--- tree's own code, as a boot does, so it takes the tree's code as that
--- database last staged it for its own.
--- A reader that reads rows it did not stage itself -- another run
--- holding the database, or the check before the verb having gone on
--- without holding the tool to the tree ([`reboot.unchecked`]) -- reads
--- none of a database another code staged: what that code wrote, and
--- what its parses and compiles keyed, may mean other than this code
--- takes it to. Nil and why where the read fails.
function work.other_code(db: Sqlite.Handle): string?, string
  local row, trouble = db:one("SELECT value FROM meta WHERE key = 'staged_by'")
  if row == nil then
    if trouble ~= nil then return nil, tostring(trouble) end
    return "", ""
  end
  -- Read on a file another code staged, whose tables are not held to the schema: the value may be of any type.
  local recorded = row:as_text(1) or ""
  local own, own_trouble = running_tool(db)
  if own == nil then
    return nil, own_trouble
  end
  if recorded == own then
    return nil, ""
  end
  return recorded, ""
end

--- How what is said names `code`, the boot hash a database records of
--- the tool that wrote it ([`work.other_code`]), "" where it records none.
function work.code_name(code: string): string
  if code == "" then return "a tool that recorded no code of its own" end
  return "the tool of boot hash " .. code:sub(1, 12)
end

--- Says once a process, on stderr, that `verb` reads none of the working
--- database at `path`, of the project at `root` where that is known, which
--- records being staged by `code`, other code than this tool's
--- ([`work.other_code`]).
function work.tell_other_code(verb: string, path: string, code: string, root?: string)
  tell_once("other_code " .. code, path, verb .. ": " .. path .. " was staged by " ..
      work.code_name(code) .. ", not this tool's; reading none of it, which this tool's " ..
      "code may misread: " .. remedy(root))
end

--- The code finding links as this process runs it, and the boot hash
--- of the tool that runs it, kept in `meta` as `links_by` and
--- `links_boot`. A tool whose boot hash is `links_boot` runs the code
--- `links_by` names. Any other tool names it by a hash of each module
--- `require` reaches from [`build.link_files`], by name and source as
--- the binary holds it, so that only an edit to that code reads every
--- file's links again. A boot runs the tree's own code and carries no
--- database: it names its code by the boot hash of the tool it writes
--- ([`identity.record_fingerprint`]'s `boot`), which it keeps as
--- `links_boot` too, so that tool goes on from the boot's rows.
local function links_finder(db: Database): string?, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil then
    local fingerprint, trouble = identity.hash_over(db, "1")
    if fingerprint == nil then
      return nil, trouble
    end
    local ok, record_trouble = db:run(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_boot', ?1)", { text(fingerprint) })
    if not ok then
      return nil, tostring(record_trouble)
    end
    return fingerprint, ""
  end
  local last, last_trouble = db:rows(
    "SELECT key, value FROM meta WHERE key IN ('links_boot', 'links_by')")
  if last == nil then
    return nil, tostring(last_trouble)
  end
  local recorded: mut {string:string} = {}
  for _, row in ipairs(last) do recorded[row:text(1)] = row:text(2) end
  if recorded["links_boot"] == boot_hash and recorded["links_by"] ~= nil then
    return recorded["links_by"], ""
  end
  local names, reach_trouble = CodeWalk.reach(CodeWalk.links, function(name: string): {string}?, string
    local required, why = Store.requires(name)
    if required == nil then return nil, tostring(why) end
    return required, ""
  end)
  if names == nil then
    return nil, reach_trouble
  end
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local source, _ = Store.source(name)
    if source == nil then
      -- A module held without its source is not one that is absent: it would hash as empty.
      local withheld, withheld_trouble = Store.withheld(name)
      if withheld == nil then return nil, tostring(withheld_trouble) end
      if withheld is string then return nil, withheld end
    end
    parts[#parts + 1] = name .. "\n" .. (source or "")
  end
  local finder = Hash.hex_sha256(table.concat(parts, "\n\0\n"))
  local ok, trouble = db:run(
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_boot', ?1)", { text(boot_hash) })
  if not ok then
    return nil, tostring(trouble)
  end
  return finder, ""
end

--- Reads the links of each file of `linked` whose text no row of
--- `linked_texts` holds yet ([`link_files.found`]): from `texts`, where
--- the stage read it, or else from the file, which is then written
--- again if it has changed since it was staged, so that it is staged
--- again next time. Every row goes first when the code finding them is
--- not the code that found them, and what no file holds goes after.
find_links = function(handle: work.Handle, texts: {string:string}): boolean, string
  local db = handle.db
  local finder, finder_trouble = links_finder(db)
  if finder == nil then
    return false, finder_trouble
  end
  local last, last_trouble = db:one("SELECT value FROM meta WHERE key = 'links_by'")
  if last_trouble ~= nil then
    return false, tostring(last_trouble)
  end
  if last == nil or last:text(1) ~= finder then
    for _, statement in ipairs({ "DELETE FROM linked_found", "DELETE FROM linked_texts" }) do
      local ok, trouble = db:exec(statement)
      if not ok then
        return false, tostring(trouble)
      end
    end
    local ok, trouble = db:run(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_by', ?1)", { text(finder) })
    if not ok then
      return false, tostring(trouble)
    end
  end
  local unread, unread_trouble = db:rows(
    "SELECT path, kind, sha256, size FROM linked l WHERE NOT EXISTS (SELECT 1 FROM linked_texts t " ..
      "WHERE t.sha256 = l.sha256 AND t.kind = l.kind) ORDER BY path")
  if unread == nil then
    return false, tostring(unread_trouble)
  end
  for _, row in ipairs(unread) do
    local path, kind, sha256 = row:text(1), row:text(2), row:text(3)
    local data = texts[path]
    if data == nil then
      -- At most the staged size, as staging reads: a file that grows
      -- meanwhile then fails the digest below, not the read.
      local read, read_trouble = Fs.read(handle.root .. "/" .. path, row:integer(4))
      if read == nil then
        return false, tostring(read_trouble)
      end
      data = read
      local now_hash = Hash.hex_sha256(data)
      if now_hash ~= sha256 then
        sha256 = now_hash
        local ok, trouble = db:run(
          "UPDATE linked SET sha256 = ?2, mtime_ns = NULL WHERE path = ?1",
          { text(path), text(sha256) })
        if not ok then
          return false, tostring(trouble)
        end
      end
    end
    local fresh, fresh_trouble = db:one(
      "INSERT OR IGNORE INTO linked_texts (sha256, kind) VALUES (?1, ?2) RETURNING 1",
      { text(sha256), text(kind) })
    if fresh_trouble ~= nil then
      return false, tostring(fresh_trouble)
    end
    if fresh ~= nil then
      for ordinal, entry in ipairs(link_files.found(kind, data)) do
        local link = entry.link
        local ok, trouble = db:run(
          "INSERT INTO linked_found (sha256, kind, ordinal, line, column, form, text, " ..
            "target, own) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
          { text(sha256), text(kind), { integer = ordinal }, { integer = link.line },
            { integer = link.column }, text(link.form), text(link.text), text(link.target),
            { integer = if entry.own then 1 else 0 end } })
        if not ok then
          return false, path .. ": " .. tostring(trouble)
        end
      end
    end
  end
  for _, name in ipairs({ "linked_found", "linked_texts" }) do
    local ok, trouble = db:exec("DELETE FROM " .. name .. " WHERE NOT EXISTS " ..
        "(SELECT 1 FROM linked l WHERE l.sha256 = " .. name .. ".sha256 AND l.kind = " ..
        name .. ".kind)")
    if not ok then
      return false, tostring(trouble)
    end
  end
  return true, ""
end

--- Every TZif file under `dir`, a `zoneinfo` tree as `vendor/tzdata`
--- holds it, by zone name: its path under `dir`. A zone that is a link
--- to another (as a system zoneinfo's aliases are) is read as the zone
--- it leads to, under its own name.
function work.read_zoneinfo(dir: string): {string:string}?, string
  local names, trouble = Fs.walk(dir, { follow = true })
  if names == nil then
    return nil, tostring(trouble)
  end
  local zones: mut {string:string} = {}
  for _, name in ipairs(names) do
    local data, read_trouble = Fs.read(dir .. "/" .. name)
    if data == nil then
      return nil, tostring(read_trouble)
    end
    zones[name] = data
  end
  return zones, ""
end

--- Every zone the database `db` carries in its `zoneinfo` table, by
--- name: none when it has no such table.
function work.zoneinfo_of(db: Sqlite.Handle): {string:string}?, string
  local absent, trouble = counted_none(db,
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = 'zoneinfo'")
  if absent == nil then
    return nil, trouble
  end
  local zones: mut {string:string} = {}
  if absent then
    return zones, ""
  end
  local rows, rows_trouble = db:rows("SELECT name, data FROM zoneinfo")
  if rows == nil then
    return nil, tostring(rows_trouble)
  end
  for _, row in ipairs(rows) do
    zones[row:text(1)] = row:bytes(2)
  end
  return zones, ""
end

--- Replaces every row of the `zoneinfo` table `db` holds with `zones`,
--- by name, written in name order so the table's rowids are a function
--- of them: a boot writes the tree's zones this way, and `cosmic
--- refresh` a fetched release's, so the same zones make the same table.
function work.write_zones(db: Sqlite.Handle, zones: {string:string}): boolean, string
  local cleared, trouble = db:exec("DELETE FROM zoneinfo")
  if not cleared then
    return false, tostring(trouble)
  end
  local names: mut {string} = {}
  for name in pairs(zones) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, why = db:run(
      "INSERT INTO zoneinfo (name, data) VALUES (?1, ?2)",
      { text(name), { blob = zones[name] } })
    if not ok then
      return false, tostring(why)
    end
  end
  return true, ""
end

--- Replaces the zones the binary will carry with `zones`, by name.
function work.put_zoneinfo(handle: work.Handle, zones: {string:string}): boolean, string
  return work.write_zones(handle.db, zones)
end

--- A file `web_assets` carries, as the vendored trees hold it: the table
--- `name`, the `tree` directory under `vendor/` and the `path` in it.
local record WebFile
  name: string
  tree: string
  path: string
end

--- The files `web_assets` carries.
local web_files: {WebFile} = {
  { name = "htmx.min.js", tree = "htmx", path = "dist/htmx.min.js" },
  { name = "htmx-ext-sse.min.js", tree = "htmx-ext-sse", path = "dist/sse.min.js" },
}

--- The files of `web_assets` read from the trees under `vendor` (a
--- checkout's `vendor/` directory), each hashed here, in name order.
function work.read_web_assets(vendor: string): {work.WebAsset}?, string
  local assets: mut {work.WebAsset} = {}
  for _, file in ipairs(web_files) do
    local pin, pin_trouble = Fs.read(vendor .. "/" .. file.tree .. "/PIN")
    if pin == nil then
      return nil, tostring(pin_trouble)
    end
    local pinned = pin:match("^version%s+(%S+)") or pin:match("\nversion%s+(%S+)")
    if pinned == nil then
      return nil, vendor .. "/" .. file.tree .. "/PIN names no version"
    end
    local data, read_trouble = Fs.read(vendor .. "/" .. file.tree .. "/" .. file.path)
    if data == nil then
      return nil, tostring(read_trouble)
    end
    assets[#assets + 1] = { name = file.name, data = data,
      sha256 = Hash.hex_sha256(data), sha384 = Codec.base64(Hash.digest("sha384", data)),
      version = pinned }
  end
  table.sort(assets, function(a: work.WebAsset, b: work.WebAsset): boolean
    return a.name < b.name
  end)
  return assets, ""
end

--- Every row of the `web_assets` table `db` holds, by name: none when it
--- has no such table.
function work.web_assets_of(db: Sqlite.Handle): {work.WebAsset}?, string
  local absent, trouble = counted_none(db,
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = 'web_assets'")
  if absent == nil then
    return nil, trouble
  end
  local assets: mut {work.WebAsset} = {}
  if absent then
    return assets, ""
  end
  local rows, rows_trouble = db:rows(
    "SELECT name, data, sha256, sha384, version FROM web_assets ORDER BY name")
  if rows == nil then
    return nil, tostring(rows_trouble)
  end
  for _, row in ipairs(rows) do
    assets[#assets + 1] = { name = row:text(1), data = row:bytes(2),
      sha256 = row:text(3), sha384 = row:text(4), version = row:text(5) }
  end
  return assets, ""
end

--- Replaces the files the binary will carry under `/_web/` with `assets`.
function work.put_web_assets(handle: work.Handle, assets: {work.WebAsset}): boolean, string
  local cleared, trouble = handle.db:exec("DELETE FROM web_assets")
  if not cleared then
    return false, tostring(trouble)
  end
  for _, asset in ipairs(assets) do
    local ok, why = handle.db:run(
      "INSERT INTO web_assets (name, data, sha256, sha384, version) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(asset.name), { blob = asset.data }, text(asset.sha256), text(asset.sha384),
        text(asset.version) })
    if not ok then
      return false, tostring(why)
    end
  end
  return true, ""
end

--- Writes this run's row into `builds`.
function work.record(handle: work.Handle, ms: integer, staged: work.Staged,
                     compiled: integer, cached: integer,
                     verdict: string): boolean, string
  local answered, answer_why = handle.db:run(
    "INSERT OR REPLACE INTO builds (run, ms, files, read, compiled, cached, " ..
      "verdict) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    { integer(handle.run), integer(ms), integer(staged.files),
      integer(staged.read), integer(compiled), integer(cached), text(verdict) })
  if not answered then return false, tostring(answer_why) end
  return answered, ""
end

--- Closes the database, keeping whatever a still-open transaction
--- did. The handle is finished after this.
function work.close(handle: work.Handle): boolean, string
  local committed, trouble = work.commit(handle)
  if not committed then
    local _, _ = handle.db:close()
    return false, trouble
  end
  local done, done_why = handle.db:close()
  if not done then return false, tostring(done_why) end
  return true, ""
end

--- Closes the database, discarding whatever a still-open transaction did.
--- The handle is finished after this.
function work.abort(handle: work.Handle): boolean, string
  local rolled_back, trouble = work.rollback(handle)
  local closed, close_trouble = handle.db:close()
  if not rolled_back then
    return false, trouble
  end
  if not closed then
    return false, tostring(close_trouble)
  end
  return true, ""
end

return work
