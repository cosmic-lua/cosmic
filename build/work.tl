--- The working database, `o/build.db`: where a build stages the tree
--- and keeps everything it learns about it on this host.
---
--- Two databases, two promises. `o/cosmic.db` is a pure function of
--- the tree, byte-identical from any build of it, and ships. This one
--- is a log of what happened on one host -- the tree as it was last
--- read, what a stat said about each file, test verdicts, coverage --
--- and is allowed, expected even, to differ the next time. It never
--- ships and is never copied into the tree's own database.
---
--- Staging comes first: every input the build consumes is read off
--- disk into the `files` table before anything transforms it, so the
--- rest of the build reads rows, never paths. An unchanged file is a
--- stat: when its size, modification time and inode all match the row,
--- the bytes and the hash on the row are still right and the file is
--- not read again.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local analysis_schema = require("build.analysis_schema")
local todo_scan = require("build.todo_scan")
local gen_syscalls = require("build.gen_syscalls")
local bind = require("build.bind")
local link_files = require("build.link_files")
local log = require("build.verdict").log

local record work
  --- An open working database, for one run. A run is one transaction
  --- from `open` to `commit`: staging, deriving and compiling all land
  --- together, and what happens after -- the projection, which SQLite
  --- refuses inside a transaction, and the records -- is its own.
  record Handle
    db: Sqlite.Handle
    root: string
    --- This run's number: one more than the last run over this file.
    run: integer
    --- Whether the run's transaction is open.
    inside: boolean
  end

  --- What one staging pass found and what it had to read.
  record Staged
    files: integer
    read: integer
  end

  --- What the tool is made of, as two hashes: everything (`boot`), and
  --- the part the C core is built from (`image`). A binary carries both.
  --- A tree whose `boot` differs but whose `image` matches needs only a
  --- new database combined with the exact portable prefix the binary
  --- carries, which the tool can do to itself.
  record Fingerprint
    boot: string
    image: string
  end

  --- What a compile and a verdict are functions of, beyond their own
  --- inputs. All three are computed over the tree being built and carried
  --- by its portable projection, so a tool always names what it actually
  --- is.
  ---
  --- `compiler` is what turns source into bytecode: the build's own
  --- modules a compile or a parse runs to decide what it stores
  --- ([`work.compiler_identity`]), among them [`build.teal`], which names
  --- the globals the checker is stripped of, and the Teal compiler's and
  --- Lua's pins and patches.
  --- The rest of the standard library the importer runs on is plumbing,
  --- not transformation (a bug there breaks the build loudly rather than
  --- changing bytecode quietly), and is left out, as is the rest of the
  --- build. That keeps an edit to either from recompiling everything.
  ---
  --- `runtime_basis` is the host-independent hash of the Teal and Lua pins
  --- and patches. Portable startup combines it with the validated target,
  --- configuration and exact raw-core digest.
  ---
  --- `writer` is what turns compiled rows into a projection: build.writer,
  --- this module and what they require ([`work.writer_modules`], less
  --- `writer_left_out`, the standard library's included), and the core
  --- image, down to the SQLite that vacuums it and the codec that decodes
  --- the CA roots into it. A projection is signed with the identity of the
  --- writer that wrote it ([`build.writer`]), so a tool whose writer has not
  --- moved writes the same bytes as the tree's own, and one whose writer
  --- has is told apart.
  record Identities
    compiler: string
    runtime_basis: string
    writer: string
  end

  --- The statements that create the database, in order. `IF NOT
  --- EXISTS` because this file is opened again and again across runs
  --- rather than built fresh every time.
  schema: {string}
end

--- The shape of the schema. A file of another shape holds nothing the
--- tree cannot produce again, so it is thrown away.
local version <const> = "27"

--- `files` is the staged tree, one row per file the build consumes,
--- holding the bytes exactly as they were on disk. A file gone from
--- the tree is a row gone from the table. A file written within the
--- last two seconds of being staged is recorded with a NULL modification
--- time, which no stat matches, not even the epoch a tool normalizing
--- times writes. The next run reads it again rather than trusting a
--- stat that a second write inside one timestamp tick could leave
--- unchanged: the rule zig's cache applies to its own inputs.
---
--- `tool` is what the tool itself is made of, fingerprinted the same
--- way but without the bytes: every source input to the embedded
--- binary, its standard library and tests included, since `cosmic.*`
--- resolves from the binary rather than the tree. A vendored tree is
--- a function of its `PIN` and the records under `patch/`, and is
--- never edited in place, so the pin and the records are its inputs
--- and the tree itself is not walked. Its hash is the boot hash, and
--- a self-tree command refuses a mismatch.
---
--- `scanned` is every other file the walk finds -- a script, a README,
--- in cosmic's own tree everything under `ci/` -- fingerprinted like
--- `tool`, without the bytes, and read only to find the TODOs it holds
--- (see `todos`): the build consumes none of it. A file over
--- `scanned_limit` is left out, as data rather than text.
---
--- `linked` is every file whose links `cosmic fix` checks that is not
--- Teal ([`link_files.checked`]): its Markdown, its Zig and, in cosmic's
--- own tree, its C, but for a tree of its own inside it (`ci/`).
--- Fingerprinted like `tool`, with the kind of file it is, and read to
--- find its links: `linked_found` holds each link as [`link_files.found`]
--- reads it, and `linked_texts` each text so read, whether or not it
--- holds a link, both keyed by the text's hash and kind as a parse's
--- rows are by their source's, for the projection's index of links
--- ([`build.link_index`]). They hold what the code `meta`'s `links_by`
--- names found, and go when other code stages.
---
--- `inputs` is every module source the compiler and checker see, as
--- a view: each staged `.tl` or `.d.tl` as it is, with the import path
--- and kind its position gives it, together with every row of
--- `derived` -- the test module a doc guide extracts to, the
--- declaration the syscall header generates to, the compiler a boot
--- puts in. A derived row's `file` names where it came from and
--- `from_hash` what that file hashed to, so it is stale exactly when
--- its file's row no longer matches, and a derivation is redone only
--- then. A tree source is never copied: the view reads it from
--- `files`.
---
--- `parsed`, `requires` and `tests` are one parse of one source, keyed
--- by its content hash rather than its path: what a parse finds is a
--- function of the bytes alone, so a rename costs nothing and a row
--- can never be wrong. A row whose source no longer hashes among the
--- inputs is pruned, and every row goes when the analyzer changes.
--- `test_inputs` is the same parse's reading of a test module's
--- `needs` declaration ([`cosmic.test`]), one row per value a field
--- lists (`true` for a flag, `*` for any network host, and the line
--- the declaration starts on under `line`).
--- `links` is each link its comments hold ([`build.link_text`]), as
--- written: what it names is resolved only once every module is
--- known, as a projection is written ([`build.link_index`]).
---
--- `executable` is [`build.coverage.lines.executable`]'s answer for one
--- source, keyed by content hash the same way as `parsed`: which lines
--- could ever be hit is a function of the bytes and of that module's rule
--- for what counts as executable. A change to the rule bumps `version`,
--- as a change to what a parse records does for `parsed`. Unlike
--- `parsed`, a row is never pruned. `lines` is every executable line
--- number in ascending order, joined by single spaces (e.g. "1 3 4 9"),
--- rather than one row per line, since a caller always wants the whole
--- set back at once.
---
--- `todos` is every `TODO:` comment [`build.todo_scan`] finds in one
--- staged file, keyed by the file's content hash like `parsed`: staging
--- scans a file in the same moment it reads it, so an unchanged file
--- costs nothing, and a row is a function of the bytes and the scan's
--- rule alone -- a change to the rule bumps `version`. A row no
--- staged file hashes to any more is dropped at the end of the stage.
--- `todos_fts` indexes their text for `cosmic todos <words>`, in FTS5's
--- external-content mode over `todos` -- which is why `todos` has a
--- rowid, `id`, where every other table here is WITHOUT ROWID -- and
--- three triggers keep it in step with every insert, delete and update.
--- `blames` is what `git blame` said about one TODO's first line, kept
--- while the file hashes the same and `HEAD` names the same commit
--- (`head`), which is all blame is a function of -- or a later one, when
--- the commits between them leave the file alone, which moves `head`
--- on. `cosmic todos` fills it, since a build has no business running
--- git.
---
--- Raw cores are build outputs under `o/core`; they are never copied into
--- this working database. The compiler lives in `derived`, the one row
--- there with no file behind it.
---
--- `zoneinfo` is the IANA time zone database the binary carries, one
--- TZif file per zone name (`vendor/tzdata`), for [`cosmic.time`] to fall
--- back on where the host has no zone files. Like the compiler, it has
--- no staged file behind it: a boot reads the vendored tree, and a
--- Teal-only rebuild copies the running binary's rows back in. It
--- keeps a rowid, unlike the tables around it: a WITHOUT ROWID table
--- keeps a row inside an index page, where a zone file past about a
--- kilobyte spills into overflow pages, and rows are only ever written
--- in name order, so the rowid never varies.
---
--- `compiled` is one compile of one module, keyed by the module's key
--- -- the hash of its kind, its source, its import closure's keys and
--- the tool -- so a module whose key stands is never compiled again,
--- and `plan` is this run's key for every module it built, in build
--- order. `tool` is the hash of the tool that made a compile, and
--- `seen` the last run that used it: a compile another tool made is
--- dropped the moment this one runs, and one no run has used in the
--- last hundred goes too, so an edit undone is still free and the
--- cache stays bounded.
---
--- `typed_refs` is what one compile's checker found a record's field
--- used through ([`build.receivers`]): keyed by the compile's own key,
--- since a value's type depends on everything its module imports, and
--- dropped with the compile it rode on.
---
--- `builds` is one row per run: what was staged, what was read, what
--- was compiled and what came from the cache, and how the run ended.
---
--- `runs` is one row per test, keyed by the module and the test's own
--- name inside it, so a later run of the same test replaces its row
--- rather than piling up a history the runner has no use for yet.
--- `key` is what the verdict is a function of, the digest of the
--- test's declared inputs ([`build.declared_key`]), and, after a space,
--- the key it is shared under; `run_at_ns` the `cosmic test`
--- invocation whose coverage rows credit the verdict.
--- `elapsed_ns` is how long the test function itself took to run, by
--- [`cosmic.time`]'s monotonic clock: wall time, not CPU time. For a test
--- answered from a standing verdict it is the elapsed time of the run
--- that produced that verdict, so `runs` always answers "how long does
--- this test take", even when most tests are cached.
---
--- `verdicts` is one row per key ever seen, with its verdict and the
--- invocation that produced it, and `seen` the last run that relied on
--- it: while a key stands and its verdict passed, the test is not run
--- again, and an edit undone finds its old key again. One no run has
--- relied on in the last ten ([`build.test`]'s `kept_runs`) is dropped,
--- and with it the `coverage_by_test` rows no verdict credits any
--- more. `elapsed_ns` carries the duration of the run that reached this
--- verdict, which `runs` reports for a test answered from it.
---
--- `digests` is the hash of each file a sandboxed run's keys looked
--- at ([`build.declared_key`]) -- declared inputs beyond what the stage
--- hashes, o/bin/cosmic and vendor/ among them -- by absolute path,
--- with what `lstat` said of it then: a later run whose `lstat` says
--- the same reads none of them again. A sandboxed run that read one
--- writes what it looked at: a run of the whole tree in place of the
--- rest, so a file no test declares any more goes.
---
--- `test_runs`/`coverage`/`coverage_by_test` are real history instead:
--- one snapshot per `cosmic test` invocation, each run identified by
--- its own start time in nanoseconds (`ran_at_ns`), the convention
--- `runs.ran_at_ns` uses. This database never ships, but its growth is
--- still bounded: [`build.test`]'s `prune_history`
--- runs in the same transaction as every write here and keeps
--- `coverage` to the newest `kept_snapshots` runs, `coverage_by_test`
--- to what a standing verdict still credits, and `test_runs` to what
--- either of those still references.
---
--- `test_runs` holds one row per `cosmic test` invocation, so a run's
--- own `ran_at_ns` can be confirmed to exist (or listed, or joined
--- against) without inspecting `coverage` itself.
---
--- `coverage` holds one row per executable line of one module per run,
--- not one row per module: a run's total is `COUNT(*) GROUP BY path
--- WHERE ran_at_ns = ?` and its hit count is the same query with `AND
--- hit = 1`, and a specific never-hit line in a specific run can be
--- pointed at directly rather than only counted. A new run adds rows
--- rather than replacing the last run's, so a file's coverage trend
--- over the kept window of runs is a plain query away.
---
--- `coverage_by_test` answers a narrower question `coverage` cannot:
--- which lines a given test hit in a given run. It is one row per test
--- per run, its `hits` every line the test hit, as [`build.test`]'s
--- `encode_hits` writes them: one row per line hit would be millions a
--- run, and writing them, then deleting the last run's, cost a full run
--- most of its time.
---
--- The statements of `derived`, `inputs` and the tables a parse fills
--- are [`build.analysis_schema`]'s, which this places between the
--- stage's and the records': what a parse's rows are shaped by is kept
--- apart from the rest of this module, which the compiler's identity
--- does not hold ([`work.compiler_identity`]).
work.schema = {
  [[CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,
                                     value BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY,
                                      size INTEGER NOT NULL,
                                      mtime_ns INTEGER,
                                      ino INTEGER NOT NULL,
                                      dev INTEGER NOT NULL,
                                      sha256 TEXT NOT NULL,
                                      data BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tool (path TEXT PRIMARY KEY,
                                     size INTEGER NOT NULL,
                                     mtime_ns INTEGER,
                                     ino INTEGER NOT NULL,
                                     dev INTEGER NOT NULL,
                                     sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS scanned (path TEXT PRIMARY KEY,
                                        size INTEGER NOT NULL,
                                        mtime_ns INTEGER,
                                        ino INTEGER NOT NULL,
                                        dev INTEGER NOT NULL,
                                        sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS linked (path TEXT PRIMARY KEY,
                                       size INTEGER NOT NULL,
                                       mtime_ns INTEGER,
                                       ino INTEGER NOT NULL,
                                       dev INTEGER NOT NULL,
                                       sha256 TEXT NOT NULL,
                                       kind TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS linked_texts (sha256 TEXT NOT NULL,
                                             kind TEXT NOT NULL,
                                             PRIMARY KEY (sha256, kind)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS linked_found (sha256 TEXT NOT NULL,
                                             kind TEXT NOT NULL,
                                             ordinal INTEGER NOT NULL,
                                             line INTEGER NOT NULL,
                                             column INTEGER NOT NULL,
                                             form TEXT NOT NULL,
                                             text TEXT NOT NULL,
                                             target TEXT NOT NULL,
                                             own INTEGER NOT NULL,
                                             PRIMARY KEY (sha256, kind, ordinal)) WITHOUT ROWID]],
}
for _, statement in ipairs(analysis_schema.statements) do
  work.schema[#work.schema + 1] = statement
end
for _, statement in ipairs({
  [[CREATE TABLE IF NOT EXISTS executable (source_hash TEXT PRIMARY KEY,
                                           lines TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY,
                                      sha256 TEXT NOT NULL,
                                      line INTEGER NOT NULL,
                                      last INTEGER NOT NULL,
                                      text TEXT NOT NULL,
                                      UNIQUE (sha256, line))]],
  [[CREATE VIRTUAL TABLE IF NOT EXISTS todos_fts
      USING fts5(text, content=todos, content_rowid=id)]],
  [[CREATE TRIGGER IF NOT EXISTS todos_inserted AFTER INSERT ON todos BEGIN
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text);
    END]],
  [[CREATE TRIGGER IF NOT EXISTS todos_deleted AFTER DELETE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END]],
  [[CREATE TRIGGER IF NOT EXISTS todos_updated AFTER UPDATE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text);
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text);
    END]],
  [[CREATE TABLE IF NOT EXISTS blames (path TEXT NOT NULL,
                                       line INTEGER NOT NULL,
                                       sha256 TEXT NOT NULL,
                                       head TEXT NOT NULL,
                                       commit_id TEXT NOT NULL,
                                       author_time INTEGER NOT NULL,
                                       summary TEXT NOT NULL,
                                       boundary INTEGER NOT NULL,
                                       PRIMARY KEY (path, line)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS zoneinfo (name TEXT PRIMARY KEY,
                                         data BLOB NOT NULL)]],
  [[CREATE TABLE IF NOT EXISTS compiled (key TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         lua TEXT NOT NULL,
                                         bytecode BLOB NOT NULL,
                                         seen INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS typed_refs (key TEXT NOT NULL,
                                           ordinal INTEGER NOT NULL,
                                           module TEXT NOT NULL,
                                           member TEXT NOT NULL,
                                           line INTEGER NOT NULL,
                                           PRIMARY KEY (key, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS plan (path TEXT PRIMARY KEY,
                                     key TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS builds (run INTEGER PRIMARY KEY,
                                       ms INTEGER NOT NULL,
                                       files INTEGER NOT NULL,
                                       read INTEGER NOT NULL,
                                       compiled INTEGER NOT NULL,
                                       cached INTEGER NOT NULL,
                                       verdict TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS runs (path TEXT NOT NULL,
                                     test TEXT NOT NULL,
                                     passed INTEGER NOT NULL,
                                     message TEXT NOT NULL,
                                     ran_at_ns INTEGER NOT NULL,
                                     key TEXT NOT NULL,
                                     run_at_ns INTEGER NOT NULL,
                                     elapsed_ns INTEGER NOT NULL,
                                     PRIMARY KEY (path, test)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS verdicts (key TEXT PRIMARY KEY,
                                         passed INTEGER NOT NULL,
                                         run_at_ns INTEGER NOT NULL,
                                         seen INTEGER NOT NULL,
                                         elapsed_ns INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS digests (path TEXT PRIMARY KEY,
                                        signature TEXT NOT NULL,
                                        sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS test_runs (ran_at_ns INTEGER NOT NULL
                                          PRIMARY KEY)]],
  [[CREATE TABLE IF NOT EXISTS coverage (ran_at_ns INTEGER NOT NULL,
                                         path TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         hit INTEGER NOT NULL,
                                         PRIMARY KEY (ran_at_ns, path, line))
                                        WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS coverage_by_test (ran_at_ns INTEGER NOT NULL,
                                                 test TEXT NOT NULL,
                                                 hits TEXT NOT NULL,
                                                 PRIMARY KEY (ran_at_ns, test))]],
}) do
  work.schema[#work.schema + 1] = statement
end

local text = bind.text

local integer = bind.integer

--- One column of one row, read as the integer it was written as.
local function integer_of(rows: {{string}}): integer
  if #rows == 0 then
    return 0
  end
  return math.tointeger(tonumber(rows[1][1]) or 0) or 0
end

--- Creates every table the schema names, in order.
local function create(db: Sqlite.Handle): boolean, string
  for _, statement in ipairs(work.schema) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return true, ""
end

--- How long a run waits for another run of the same tree to end its
--- transaction on `o/build.db`. That run holds it from staging through
--- its compile: a cold compile, a boot, or a stale tool's whole rebuild
--- of itself (build.reboot), each of which takes minutes on a loaded
--- host. That is past the 60 s every handle waits by default
--- (core/sqlite.c), which a waiting run would otherwise meet as
--- "database is locked". It is as long as build.reboot waits for
--- another run's rebuild lock.
local wait_ms <const> = 30 * 60 * 1000

--- How long a run waits for that transaction before it says so.
local notice_ms <const> = 1000

--- Whether `trouble`, from beginning a transaction, says another
--- connection holds the write lock rather than something wrong with the
--- file. SQLite gives its reason only as text, which build.shared_compiles'
--- `busy` reads the same way.
-- TODO: tell SQLITE_BUSY by its code once cosmic.sqlite answers a
-- failure's result code beside its message, here and in
-- build.shared_compiles' `busy`.
local function locked(trouble: string): boolean
  return trouble:find("locked", 1, true) ~= nil
end

--- Begins the run's transaction on `db`, the working database at `path`,
--- waiting up to `wait_ms` for another run that holds it and saying so
--- after `notice_ms`. The handle keeps the long wait for every statement
--- after ([`work.begin`]'s transactions among them).
local function begin_waiting(db: Sqlite.Handle, path: string): boolean, string
  local noticed, notice_trouble = db:exec("PRAGMA busy_timeout = " ..
    tostring(notice_ms))
  if not noticed then
    return false, notice_trouble
  end
  local begun, trouble = db:exec("BEGIN IMMEDIATE")
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " ..
    tostring(wait_ms))
  if not timed then
    return false, time_trouble
  end
  if begun then
    return true, ""
  end
  if not locked(trouble) then
    return false, trouble
  end
  log:complain("another cosmic run holds " .. path .. "; waiting for it")
  local waited, wait_trouble = db:exec("BEGIN IMMEDIATE")
  if not waited then
    return false, wait_trouble
  end
  return true, ""
end

--- Opens `<root>/o/build.db`, creating it and its tables when new, and
--- counts this run. A file whose schema is not this module's is
--- removed and made again: it holds nothing the tree cannot produce.
function work.open(root: string): work.Handle | nil, string
  local made, mkdir_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    return nil, mkdir_trouble
  end
  local path = root .. "/o/build.db"
  local db, open_trouble = Sqlite.open(path, true)
  if db == nil then
    return nil, path .. ": " .. open_trouble
  end
  -- Before the schema is made: a run meeting a fresh file another is
  -- making its tables in waits for that run's lock here.
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " ..
    tostring(wait_ms))
  if not timed then
    local _, _ = db:close()
    return nil, path .. ": " .. time_trouble
  end
  local encoded, encode_trouble = db:exec("PRAGMA encoding = 'UTF-8'")
  if not encoded then
    local _, _ = db:close()
    return nil, path .. ": " .. encode_trouble
  end
  local created, create_trouble = create(db)
  if not created then
    local _, _ = db:close()
    return nil, path .. ": " .. create_trouble
  end

  local versions, version_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'schema'")
  if versions == nil then
    local _, _ = db:close()
    return nil, path .. ": " .. version_trouble
  end
  if #versions > 0 and versions[1][1] ~= version then
    local _, _ = db:close()
    local removed, remove_trouble = Fs.remove(path)
    if not removed then
      return nil, remove_trouble
    end
    return work.open(root)
  end

  -- IMMEDIATE takes the write lock before reading, so a second build of
  -- the same tree waits for the first ([`begin_waiting`]) instead of both
  -- reading and then one failing to upgrade.
  local begun, begin_trouble = begin_waiting(db, path)
  if not begun then
    local _, _ = db:close()
    return nil, path .. ": " .. begin_trouble
  end
  local stamped, stamp_trouble = Sqlite.run(db,
    "INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
    "ON CONFLICT (key) DO NOTHING", { text(version) })
  if not stamped then
    local _, _ = db:close()
    return nil, path .. ": " .. stamp_trouble
  end
  local counted, count_trouble = Sqlite.run(db,
    "INSERT INTO meta (key, value) VALUES ('run', 1) " ..
    "ON CONFLICT (key) DO UPDATE SET value = value + 1")
  if not counted then
    local _, _ = db:close()
    return nil, path .. ": " .. count_trouble
  end
  local runs, run_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'run'")
  if runs == nil then
    local _, _ = db:close()
    return nil, path .. ": " .. run_trouble
  end
  return { db = db, root = root, run = integer_of(runs), inside = true }
end

--- Ends the run's transaction, keeping everything it did. Nothing to
--- do when it has already ended.
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
    return false, trouble
  end
  handle.inside = false
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
    return false, trouble
  end
  handle.inside = false
  return true, ""
end

--- Opens another transaction on the run, for a phase that comes after
--- the projection: the test runner's records, written together.
function work.begin(handle: work.Handle): boolean, string
  local begun, trouble = handle.db:exec("BEGIN IMMEDIATE")
  if not begun then
    return false, trouble
  end
  handle.inside = true
  return true, ""
end

--- What is never an input: the build's own output, the upstream
--- sources and the records that patch them, prose, and anything
--- hidden. `doc` is handled on its own: almost all of it is prose with
--- no examples, but `doc/guides/*.md` is the one place doc/meta.md's
--- grammar applies, and the build has to see those files to run
--- [`build.doctest`] over them. In cosmic's own tree the patches, the
--- vendor pins and the zig wrapper are walked after all, as inputs to
--- the tool rather than to the build, and `.github/` for the TODOs
--- alone, never as an input even where it holds Teal.
local not_input: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["bin"] = true,
  [".github"] = true,
}

--- The trees and files the tool is made of, in cosmic's own tree,
--- beside the Teal it carries from anywhere else in the tree
--- ([`carried_teal`]).
local tool_trees: {string:boolean} = {
  ["build"] = true,
  ["core"] = true,
  ["cosmic"] = true,
  ["cmd"] = true,
  ["patch"] = true,
}
local tool_files: {string:boolean} = {
  ["build.zig"] = true,
  ["build.zig.zon"] = true,
  ["bin/zig"] = true,
  ["bin/zig.pin"] = true,
}
--- The directory the `bin/` files above sit in, walked for them and,
--- one level deep, for the TODOs its other scripts hold.
local tool_dirs: {string:boolean} = {
  ["bin"] = true,
}

--- Trees of their own that sit inside cosmic's: `ci/` is the project
--- the pinned CI driver runs from, with its own `o/`, so this tree's
--- build never reads its modules or tests. It walks it, all but that
--- `o/`, only for the TODOs its files hold -- see `scanned`.
local foreign_trees: {string:boolean} = {
  ["ci"] = true,
}

--- Whether `name`, a directory at the root of cosmic's own tree, is a
--- tree of its own (`foreign_trees`).
function work.is_foreign_tree(name: string): boolean
  return foreign_trees[name] == true
end

--- The top-level directory an entry sits under, or the entry itself
--- at the top. A plain find, since this runs for every entry walked.
local function first_of(entry: string): string
  local slash = entry:find("/", 1, true)
  if slash == nil then
    return entry
  end
  return entry:sub(1, slash - 1)
end

--- Whether an entry under `vendor/` is one tree's pin, or the tree's
--- own directory on the way to it.
local function is_vendor_pin(entry: string): boolean
  local second = entry:find("/", 8, true)
  if second == nil then
    return true
  end
  return entry:sub(second) == "/PIN"
end

--- Whether `file` is a doc this tree extracts runnable examples from --
--- exactly `doc/guides/*.md`, never a markdown file anywhere else in
--- the tree ([`doc/design.md`], [`doc/roadmap.md`], and [`doc/meta.md`] are
--- prose with no examples, and stay out of scope on purpose).
local function is_doc_guide(file: string): boolean
  return file:match("^doc/guides/[^/]+%.md$") ~= nil
end

--- The walk's predicates take the entry's bare name second, so what
--- is hidden is one byte compare, and the top-level rules run on the
--- top-level component alone.
local function skip_input(entry: string, name: string): boolean
  if name:sub(1, 1) == "." then
    return true
  end
  local first = first_of(entry)
  if first == "doc" then
    if entry == "doc" or entry == "doc/guides" then
      return false
    end
    return not is_doc_guide(entry)
  end
  return not_input[first] == true
end

local function skip_in_own_tree(entry: string, name: string): boolean
  local first = first_of(entry)
  -- `.github/` is walked, for `scanned` alone: its workflows, actions
  -- and scripts carry TODOs the build never reads. Hidden names under
  -- it are skipped like any other.
  if first == ".github" then
    return entry ~= first and name:sub(1, 1) == "."
  end
  if name:sub(1, 1) == "." then
    return true
  end
  if foreign_trees[first] then
    return entry == first .. "/o"
  end
  if first == "vendor" then
    return not is_vendor_pin(entry)
  end
  if tool_trees[first] or tool_files[entry] or tool_dirs[entry] then
    return false
  end
  -- The rest of `bin/` is walked too, for `scanned`: its scripts carry
  -- TODOs the build otherwise never reads.
  if tool_dirs[first] and entry:find("/", #first + 2, true) == nil then
    return false
  end
  return skip_input(entry, name)
end

--- Whether a file the walk found is one the build consumes: Teal
--- source and declarations, a doc guide, and, in cosmic's own tree,
--- the headers the declarations of [`cosmic.sys`] and the raw process
--- table are generated from ([`build.gen_syscalls`]' targets). Never
--- anything under the trees the tool alone is made of.
local function is_input(file: string, own_tree: boolean): boolean
  local first = first_of(file)
  if not_input[first] or (own_tree and foreign_trees[first]) then
    return false
  end
  if String.ends_with(file, ".tl") then
    return true
  end
  if first == "doc" then
    return is_doc_guide(file)
  end
  if not own_tree then
    return false
  end
  for _, derivation in ipairs(gen_syscalls.targets) do
    if file == derivation.target.header then
      return true
    end
  end
  return false
end

--- Whether a Teal file is one the tool carries wherever it sits in the
--- tree: every module the `inputs` view reads ([`build.analysis_schema`]:
--- Teal outside a `testdata/` directory) except a test, which [`is_tool`]
--- has already left out. The tool carries every module of the tree but
--- its tests and examples ([`build.writer`]'s `dropped_modules`), so
--- eval/'s and test/portable's are carried as much as build/'s, and a
--- tree that holds none of the tool's C still moves `boot_hash` when one
--- of its modules does. An example outside the tool trees is taken too,
--- as one inside them is: a carried module may require it, and one more
--- reboot costs less than a stale tool.
local function carried_teal(file: string, own_tree: boolean): boolean
  if not String.ends_with(file, ".tl") or not is_input(file, own_tree) then
    return false
  end
  return file:sub(1, 9) ~= "testdata/" and file:find("/testdata/", 1, true) == nil
end

--- Whether a file is one the tool is made of, in cosmic's own tree: a
--- file under one of its trees, one of its named files, a module it
--- carries from elsewhere ([`carried_teal`]), or a vendored tree's pin. A
--- Teal test (`*_test.tl`, the `inputs` view's `test` kind) never is: no
--- binary carries a test ([`build.writer`]'s `carried`), and in cosmic's
--- own tree only a test may require one ([`build.positions`]), so none is
--- carried for being required either. So an edit to a test moves neither
--- fingerprint ([`work.record_fingerprint`]) and never rebuilds the tool,
--- though the test is staged as an input all the same.
local function is_tool(file: string, own_tree: boolean): boolean
  if not own_tree then
    return false
  end
  local first = first_of(file)
  if first == "vendor" then
    return file:sub(-4) == "/PIN"
  end
  if String.ends_with(file, "_test.tl") then
    return false
  end
  return tool_trees[first] == true or tool_files[file] == true
    or carried_teal(file, own_tree)
end

--- What a stat said about a file the last time it was staged, read
--- once per table into memory, so an unchanged file costs a stat and
--- a comparison and never a query.
local record Known
  size: integer
  --- nil for a row staged before its file settled, which no stat matches.
  mtime_ns: integer | nil
  ino: integer
  dev: integer
end

local function known_in(db: Sqlite.Handle,
                        table_name: string): {string:Known} | nil, string
  local statement, trouble = db:prepare(
    "SELECT path, size, mtime_ns, ino, dev, mtime_ns IS NULL FROM " .. table_name)
  if statement == nil then
    return nil, trouble
  end
  local out: {string:Known} = {}
  while true do
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return nil, failure
    end
    if state == "done" then
      break
    end
    out[statement:bytes(0)] = {
      size = statement:integer(1),
      mtime_ns = statement:integer(5) == 0 and statement:integer(2) or nil,
      ino = statement:integer(3),
      dev = statement:integer(4),
    }
  end
  statement:finalize()
  return out
end

--- `files` keeps the bytes; `tool` and `scanned` keep only what a stat
--- and a hash say about them. The put for each takes the bytes as its
--- sixth parameter and their hash, made once per read, as its seventh;
--- `todo` is one TODO's row.
local puts: {string:string} = {
  files = "INSERT OR REPLACE INTO files (path, size, mtime_ns, ino, dev, " ..
    "sha256, data) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?6)",
  tool = "INSERT OR REPLACE INTO tool (path, size, mtime_ns, ino, dev, " ..
    "sha256) VALUES (?1, ?2, ?3, ?4, ?5, ?7)",
  scanned = "INSERT OR REPLACE INTO scanned (path, size, mtime_ns, ino, dev, " ..
    "sha256) VALUES (?1, ?2, ?3, ?4, ?5, ?7)",
  linked = "INSERT OR REPLACE INTO linked (path, size, mtime_ns, ino, dev, " ..
    "sha256, kind) VALUES (?1, ?2, ?3, ?4, ?5, ?7, ?8)",
  todo = "INSERT OR IGNORE INTO todos (sha256, line, last, text) " ..
    "VALUES (?1, ?2, ?3, ?4)",
}

--- The largest file `scanned` reads for TODOs.
local scanned_limit = 1024 * 1024

local once = bind.once

--- How long a file's modification time has to be in the past before
--- a stat is trusted to stand for its bytes.
local settle_ns = 2 * 1000000000

--- Whether a file's row no longer stands for it, consuming the row
--- from `known` either way, so what is left in `known` at the end is
--- what the walk no longer finds.
local function moved(known: {string:Known}, file: string, st: sys.Stat,
                     mtime_ns: integer): boolean
  local was = known[file]
  known[file] = nil
  return was == nil or was.size ~= st.size or was.mtime_ns == nil or
    was.mtime_ns ~= mtime_ns or
    was.ino ~= st.ino or was.dev ~= st.dev
end

--- Whether any row [`work.stage`] last recorded under `tool` no longer
--- matches a stat of its own file, without walking the tree: only the
--- paths a previous stage knows about are stat'd. A file new to the tree
--- does not register until something already known requires it, which
--- edits that known file's bytes and so its stat. A row whose file is
--- gone fails its stat, which counts as moved. This lets a caller that
--- never edits the tree itself ([`build.reboot.stale_exit`], for a
--- read-only verb) ask whether the tool's inputs changed since the last
--- stage for a handful of stats instead of [`work.stage`]'s directory walk
--- over everything.
function work.tool_moved(handle: work.Handle): boolean | nil, string
  local known, trouble = known_in(handle.db, "tool")
  if known == nil then
    return nil, trouble
  end
  for path in pairs(known) do
    local st, _ = Fs.stat(handle.root .. "/" .. path)
    if st == nil then
      return true, ""
    end
    local mtime_ns = st.mtime * 1000000000 + st.mtime_ns
    if moved(known, path, st, mtime_ns) then
      return true, ""
    end
  end
  return false, ""
end

--- Writes one file's row: its stat, with the modification time kept
--- only once it has settled, its bytes, and their hash.
local function put_row(put: Sqlite.Statement, file: string, st: sys.Stat,
                       mtime_ns: integer, settled: boolean,
                       data: string, sha256: string): boolean, string
  local bound, trouble = put:bind_text(1, file)
  if bound then bound, trouble = put:bind_integer(2, st.size) end
  if bound then
    if settled then
      bound, trouble = put:bind_integer(3, mtime_ns)
    else
      bound, trouble = put:bind_null(3)
    end
  end
  if bound then bound, trouble = put:bind_integer(4, st.ino) end
  if bound then bound, trouble = put:bind_integer(5, st.dev) end
  if bound then bound, trouble = put:bind_blob(6, data) end
  if bound then bound, trouble = put:bind_text(7, sha256) end
  if not bound then
    return false, file .. ": " .. trouble
  end
  return once(put)
end

--- Whether a file's TODOs are the tree's own: a patch record's context
--- lines and a vendored pin are upstream's.
local function holds_own_todos(file: string): boolean
  local first = first_of(file)
  return first ~= "patch" and first ~= "vendor"
end

--- Records the TODOs in one file's bytes under their hash, unless a
--- file with the same bytes already has. Text holding no `TODO:`, or
--- holding a NUL, is not scanned.
local function put_todos(put: Sqlite.Statement, data: string,
                         sha256: string): boolean, string
  if data:find("TODO:", 1, true) == nil or data:find("\0", 1, true) ~= nil then
    return true, ""
  end
  for _, found in ipairs(todo_scan.scan(data)) do
    local ok, trouble = put:bind_text(1, sha256)
    if ok then ok, trouble = put:bind_integer(2, found.line) end
    if ok then ok, trouble = put:bind_integer(3, found.last) end
    if ok then ok, trouble = put:bind_text(4, found.text) end
    if ok then ok, trouble = once(put) end
    if not ok then
      return false, trouble
    end
  end
  return true, ""
end

--- Finalizes every statement `stage` prepared, by the `puts` key.
local function finish(put: {string:Sqlite.Statement})
  for _, statement in pairs(put) do
    statement:finalize()
  end
end

--- Deletes the rows `known` still holds, which the walk did not find.
local function forget(db: Sqlite.Handle, table_name: string,
                      known: {string:Known}): boolean, string
  for path in pairs(known) do
    local ok, why = Sqlite.run(db,
      "DELETE FROM " .. table_name .. " WHERE path = ?1", { text(path) })
    if not ok then
      return false, path .. ": " .. why
    end
  end
  return true, ""
end

--- Reads the links of the files of `linked` not yet read (see its
--- definition, which needs [`hash_over`]).
local find_links: function(handle: work.Handle, texts: {string:string}): boolean, string

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
--- @param own_tree whether `root` is cosmic's own tree
function work.stage(handle: work.Handle, own_tree: boolean): work.Staged | nil, string
  local db = handle.db
  local root = handle.root
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
  local skip_path = own_tree and skip_in_own_tree or skip_input
  -- Each entry only the walk for links reaches.
  local links_only: {string:boolean} = {}
  local link_skip = link_files.skipper(root)
  local function for_links(entry: string): boolean
    return not link_skip(entry) and not (own_tree and foreign_trees[first_of(entry)])
  end
  local ancestors: {string:boolean} = nil
  local above = ""
  local function skip(entry: string, name: string, kind: string): boolean
    local parent = entry:match("^(.*)/[^/]*$")
    if (parent ~= nil and links_only[parent]) or skip_path(entry, name) then
      if not for_links(entry) then
        return true
      end
      links_only[entry] = true
    end
    if kind ~= "link" then
      return false
    end
    if ancestors == nil then
      ancestors = {}
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
          ancestors[key] = true
        end
        last = key
        path = path .. "/.."
      end
    end
    -- One that leads nowhere is not walked, so it is let be.
    local st, _ = Fs.stat(root .. "/" .. entry)
    if st ~= nil and ancestors[tostring(st.dev) .. ":" .. tostring(st.ino)] then
      if above == "" then
        local target, _ = Fs.absolute(root .. "/" .. entry)
        above = root .. "/" .. entry .. ": a link to " .. (target or "a directory") ..
          ", above the root, whose whole tree would be staged"
      end
      return true
    end
    return false
  end
  local walked, walk_trouble = Fs.walk_following(root, skip)
  if walked == nil then
    return nil, walk_trouble
  end
  if above ~= "" then
    return nil, above
  end
  local files: {string} = walked
  local known: {string:{string:Known}} = {}
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local rows, trouble = known_in(db, table_name)
    if rows == nil then
      return nil, trouble
    end
    known[table_name] = rows
  end
  local put: {string:Sqlite.Statement} = {}
  for _, name in ipairs({ "files", "tool", "scanned", "linked", "todo" }) do
    local statement, trouble = db:prepare(puts[name])
    if statement == nil then
      finish(put)
      return nil, trouble
    end
    put[name] = statement
  end
  local now = Time.now_ns()
  local staged: work.Staged = { files = 0, read = 0 }
  -- The text of each file of `linked` read here, by path.
  local texts: {string:string} = {}

  for _, file in ipairs(files) do
    local only = links_only[file] == true
    local input = not only and is_input(file, own_tree)
    local tool = not only and is_tool(file, own_tree)
    local scan = not only and not input and not tool and holds_own_todos(file)
    local link_kind = for_links(file) and link_files.checked(file, own_tree) or nil
    local st, stat_trouble = Fs.stat(root .. "/" .. file)
    if st == nil then
      finish(put)
      return nil, stat_trouble
    end
    if scan and st.size > scanned_limit then
      scan = false
    end
    if input or tool or scan or link_kind ~= nil then
      local mtime_ns = st.mtime * 1000000000 + st.mtime_ns
      local settled = mtime_ns < now - settle_ns
      if input or tool then
        staged.files = staged.files + 1
      end
      local write_files = input and moved(known.files, file, st, mtime_ns)
      local write_tool = tool and moved(known.tool, file, st, mtime_ns)
      local write_scanned = scan and moved(known.scanned, file, st, mtime_ns)
      local write_linked = link_kind ~= nil and moved(known.linked, file, st, mtime_ns)
      if write_files or write_tool or write_scanned or write_linked then
        local data, read_trouble = Fs.read(root .. "/" .. file)
        if data == nil then
          finish(put)
          return nil, read_trouble
        end
        staged.read = staged.read + 1
        local sha256 = Hash.hex_sha256(data)
        if (input or tool or scan) and holds_own_todos(file) then
          local ok, why = put_todos(put["todo"], data, sha256)
          if not ok then
            finish(put)
            return nil, file .. ": " .. why
          end
        end
        local function write(wanted: boolean, statement: Sqlite.Statement): boolean, string
          if not wanted then
            return true, ""
          end
          return put_row(statement, file, st, mtime_ns, settled, data, sha256)
        end
        local ok, why = write(write_files, put["files"])
        if ok then
          ok, why = write(write_tool, put["tool"])
        end
        if ok then
          ok, why = write(write_scanned, put["scanned"])
        end
        if ok and write_linked then
          texts[file] = data
          ok, why = put["linked"]:bind_text(8, link_kind)
          if ok then
            ok, why = write(true, put["linked"])
          end
        end
        if not ok then
          finish(put)
          return nil, file .. ": " .. why
        end
      end
    end
  end
  finish(put)
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local forgot, forget_trouble = forget(db, table_name, known[table_name])
    if not forgot then
      return nil, forget_trouble
    end
  end
  local found, found_trouble = find_links(handle, texts)
  if not found then
    return nil, found_trouble
  end
  local pruned, prune_trouble = db:exec(
    "DELETE FROM todos WHERE sha256 NOT IN " ..
    "(SELECT sha256 FROM files UNION SELECT sha256 FROM tool " ..
    "UNION SELECT sha256 FROM scanned)")
  if not pruned then
    return nil, prune_trouble
  end
  return staged
end

--- The hash over some of the rows of `tool`, in path order.
local function hash_over(db: Sqlite.Handle, where: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(group_concat(path || ' ' || sha256, char(10) " ..
    "ORDER BY path)))) FROM tool WHERE " .. where)
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- The code finding links as this process runs it, and the boot hash
--- of the tool that runs it, kept in `meta` as `links_by` and
--- `links_boot`. A tool whose boot hash is `links_boot` runs the code
--- `links_by` names. Any other tool names it by a hash of each module
--- `require` reaches from [`build.link_files`], by name and source as
--- the binary holds it, so that only an edit to that code reads every
--- file's links again. A boot runs the tree's own code and carries no
--- database: it names its code by the boot hash of the tool it writes
--- ([`work.record_fingerprint`]'s `boot`), which it keeps as
--- `links_boot` too, so that tool goes on from the boot's rows.
local function links_finder(db: Sqlite.Handle): string | nil, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil then
    local fingerprint, trouble = hash_over(db, "1")
    if fingerprint == nil then
      return nil, trouble
    end
    local ok, record_trouble = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_boot', ?1)", { text(fingerprint) })
    if not ok then
      return nil, record_trouble
    end
    return fingerprint
  end
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT key, value FROM meta WHERE key IN ('links_boot', 'links_by')")
  if last == nil then
    return nil, last_trouble
  end
  local recorded: {string:string} = {}
  for _, row in ipairs(last) do recorded[row[1]] = row[2] end
  if recorded["links_boot"] == boot_hash and recorded["links_by"] ~= nil then
    return recorded["links_by"]
  end
  local reached: {string:boolean} = {}
  local stack: {string} = { "build.link_files" }
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = Store.requires(name)
      if required == nil then
        return nil, trouble
      end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  local parts: {string} = {}
  for _, name in ipairs(names) do
    local source, _ = Store.source(name)
    parts[#parts + 1] = name .. "\n" .. (source or "")
  end
  local finder = Hash.hex_sha256(table.concat(parts, "\n\0\n"))
  local ok, trouble = Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_boot', ?1)", { text(boot_hash) })
  if not ok then
    return nil, trouble
  end
  return finder
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
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'links_by'")
  if last == nil then
    return false, last_trouble
  end
  if #last == 0 or last[1][1] ~= finder then
    for _, statement in ipairs({ "DELETE FROM linked_found", "DELETE FROM linked_texts" }) do
      local ok, trouble = db:exec(statement)
      if not ok then
        return false, trouble
      end
    end
    local ok, trouble = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_by', ?1)", { text(finder) })
    if not ok then
      return false, trouble
    end
  end
  local unread, unread_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, sha256 FROM linked l WHERE NOT EXISTS (SELECT 1 FROM linked_texts t " ..
    "WHERE t.sha256 = l.sha256 AND t.kind = l.kind) ORDER BY path")
  if unread == nil then
    return false, unread_trouble
  end
  for _, row in ipairs(unread) do
    local path, kind, sha256 = row[1], row[2], row[3]
    local data = texts[path]
    if data == nil then
      local read, read_trouble = Fs.read(handle.root .. "/" .. path)
      if read == nil then
        return false, read_trouble
      end
      data = read
      local now_hash = Hash.hex_sha256(data)
      if now_hash ~= sha256 then
        sha256 = now_hash
        local ok, trouble = Sqlite.run(db,
          "UPDATE linked SET sha256 = ?2, mtime_ns = NULL WHERE path = ?1",
          { text(path), text(sha256) })
        if not ok then
          return false, trouble
        end
      end
    end
    local fresh, fresh_trouble = Sqlite.text_rows(db,
      "INSERT OR IGNORE INTO linked_texts (sha256, kind) VALUES (?1, ?2) RETURNING 1",
      { text(sha256), text(kind) })
    if fresh == nil then
      return false, fresh_trouble
    end
    if #fresh > 0 then
      for ordinal, entry in ipairs(link_files.found(kind, data)) do
        local link = entry.link
        local ok, trouble = Sqlite.run(db,
          "INSERT INTO linked_found (sha256, kind, ordinal, line, column, form, text, " ..
          "target, own) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
          { text(sha256), text(kind), { integer = ordinal }, { integer = link.line },
            { integer = link.column }, text(link.form), text(link.text), text(link.target),
            { integer = entry.own and 1 or 0 } })
        if not ok then
          return false, path .. ": " .. trouble
        end
      end
    end
  end
  for _, name in ipairs({ "linked_found", "linked_texts" }) do
    local ok, trouble = db:exec("DELETE FROM " .. name .. " WHERE NOT EXISTS " ..
      "(SELECT 1 FROM linked l WHERE l.sha256 = " .. name .. ".sha256 AND l.kind = " ..
      name .. ".kind)")
    if not ok then
      return false, trouble
    end
  end
  return true, ""
end

--- The tool's fingerprints, over `tool` (which holds no test: see
--- [`is_tool`]): `boot` over every row, and `image` over what the C core
--- is built from. That is `core/` but the Teal beside its C (no core is
--- built from it), the zig build and wrapper, every vendored tree's pin
--- and patches (the Teal compiler's included), and [`build/patch.tl`],
--- which applies them: only `bin/zig build boot` applies a patch record
--- to a pin, so a change under [`vendor/tl/PIN`], `patch/tl/*` or to the
--- applier needs it too, as with every other vendored tree.
--- [`build/launcher.tl`] also belongs to the retained portable prefix: a
--- database-only rebuild reuses its existing shell bytes. So does
--- [`build/artifact.tl`], which lays the artifact out: a rebuild lays it
--- out with the running tool's own copy, so an edit to it boots too.
---
--- Both fingerprints are written into `meta` for the projection to carry
--- into the binary, which is how a binary knows what it was built from,
--- so a project reads them rather than computing any. Returns the
--- fingerprint written; [`work.recorded_boot_hash`] reads it back.
function work.record_fingerprint(handle: work.Handle): work.Fingerprint | nil, string
  local db = handle.db
  local boot, boot_trouble = hash_over(db, "1")
  if boot == nil then
    return nil, boot_trouble
  end
  local image, image_trouble = hash_over(db,
    "(path GLOB 'core/*' AND NOT path GLOB 'core/*.tl') OR " ..
    "path IN ('build.zig', 'build.zig.zon', " ..
    "'bin/zig', 'bin/zig.pin', 'build/artifact.tl', 'build/launcher.tl', " ..
    "'build/patch.tl') OR " ..
    "path GLOB 'vendor/*/PIN' OR " ..
    "path GLOB 'patch/*'")
  if image == nil then
    return nil, image_trouble
  end
  for _, pair in ipairs({ { "boot_hash", boot }, { "image_hash", image } }) do
    local ok, why = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) })
    if not ok then
      return nil, why
    end
  end
  return { boot = boot, image = image }
end

--- The `boot` fingerprint [`work.record_fingerprint`] wrote into `meta` at
--- the last stage, read back rather than recomputed. It is for a caller
--- that only wants to know whether the tool it is running still matches
--- the tree (paired with [`work.tool_moved`] to know the `tool` table is
--- accurate), not to restage anything itself. `nil, ""` when the
--- database holds no such row yet: a fresh `o/`, or one nothing has
--- staged for.
function work.recorded_boot_hash(handle: work.Handle): string | nil, string
  local rows, trouble = Sqlite.text_rows(handle.db,
    "SELECT value FROM meta WHERE key = 'boot_hash'")
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, ""
  end
  return rows[1][1]
end

--- The Teal compiler's and Lua's pins and patches, as one text: part
--- of the compiler's identity, and the whole of `runtime_basis`.
local pins <const> =
  "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) " ..
  "ORDER BY path) FROM tool WHERE path IN ('vendor/tl/PIN', 'vendor/lua/PIN') " ..
  "OR path GLOB 'patch/tl/*' OR path GLOB 'patch/lua/*'), '')"

--- What a module of the tree in the working database requires, as
--- `requires` holds of its source: the walk [`work.compiler_modules`] and
--- [`work.writer_modules`] take over it.
local function requires_in(db: Sqlite.Handle): function(string): {string} | nil, string
  return function(name: string): {string} | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
      "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
      "ORDER BY r.name", { text(name) })
    if rows == nil then return nil, rows_trouble end
    local required: {string} = {}
    for _, row in ipairs(rows) do required[#required + 1] = row[1] end
    return required, ""
  end
end

--- The hash of the source hash of each of `names` the tree holds, by
--- path, then `extra`, an SQL expression.
local function hash_of(db: Sqlite.Handle, names: {string}, extra: string): string | nil, string
  local slots: {string} = {}
  local values: {Sqlite.Value} = {}
  for index, name in ipairs(names) do
    slots[#slots + 1] = "?" .. index
    values[#values + 1] = text(name)
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(coalesce((SELECT group_concat(path || ' ' || " ..
    "source_hash, char(10) ORDER BY path) FROM inputs WHERE path IN (" ..
    table.concat(slots, ", ") .. ")), '') || char(10) || " .. extra .. ")))", values)
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- Where the compiler's identity starts ([`work.compiler_modules`]):
--- build.importer, for its own source alone, and each module whose code
--- a compile or a parse runs to decide what it stores. See
--- [`work.compiler_identity`].
local compiler_roots: {string} = {
  -- TODO: hold only build.importer's compile and parse -- `generate`,
  -- `with_test_tail`, `dependency_keys`, `parse_new` and the shared
  -- parses' packing -- once they are split from what else it runs (a
  -- refusal's hints, the caches' plumbing, the sweeps) into a module of
  -- their own: today every edit to build/importer.tl moves the
  -- identity, and about half of them change nothing a compile or a
  -- parse stores.
  "build.importer",
  -- The analyzer ([`build.importer`]'s `analyzer_roots`): the extractors,
  -- generators and parser a parse runs, whose `tests` rows a compile
  -- appends a test module's tail from (`with_test_tail`).
  "build.analysis_schema", "build.analyzer", "build.ast", "build.bind",
  "build.compiler", "build.doctest", "build.gen_syscalls", "build.link_text",
  -- The compile's own: the checker's environment, the rules a module is
  -- refused by and the tree they hold in, and the record-field uses
  -- the checker finds.
  "build.contracts", "build.receivers", "build.teal", "build.tree",
}

--- The modules the compiler's identity holds, sorted, as `requires`
--- answers what a module of the tree requires: every one `require`
--- reaches from `compiler_roots` that is the build's own
--- (`build.*`). build.importer's own requires are
--- not followed: it is here for its compile and parse, not for the
--- rest of the build it runs.
function work.compiler_modules(requires: function(string): {string} | nil, string): {string} | nil, string
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(compiler_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      if name ~= "build.importer" then
        local required, trouble = requires(name)
        if required == nil then return nil, trouble end
        for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
      end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do
    if name:sub(1, 6) == "build." then names[#names + 1] = name end
  end
  table.sort(names)
  return names, ""
end

--- The compiler's identity ([`Identities.compiler`]) over what the
--- working database holds now, recorded nowhere: the source hash of each
--- of [`work.compiler_modules`] the tree holds, and the Teal compiler's and
--- Lua's pins and patches. A boot names its analyzer by it before it
--- parses ([`build.importer.tree_code`]).
---
--- What a module requires is what `requires` holds of its source, which
--- only a parse fills. So before [`build.importer.derive`] the walk
--- reaches only what earlier parses found: the same modules, and so the
--- same identity, while none of them has changed, and another whenever
--- one it reaches has, since each one's source hash is in it.
---
--- It holds what a compile or a parse stores is a function of beyond its
--- own key (a module's Lua, bytecode, record-field uses and refusal, and
--- a source's rows in the analysis tables), and nothing else:
---
--- - the pinned compiler and Lua;
--- - build.importer's own compile and parse;
--- - the checker's environment ([`build.teal`]), and the names it is
---   stripped of, which build.teal spells itself (its `withheld`) rather
---   than reading [`cosmic.removed`]: the rest of that catalog is only
---   what a refusal says, which no compile keeps;
--- - the rules a module is refused by and the tree they hold in
---   ([`build.contracts`], [`build.tree`]);
--- - the uses the checker finds ([`build.receivers`]);
--- - the analyzer, whose `tests` rows a test module's compile is
---   appended from;
--- - the schema of the rows a parse stores and of the `inputs` view a
---   compile reads a source through ([`build.analysis_schema`]).
---
--- The rule: a module build.importer calls that can change a row a
--- compile or a parse stores is one of `compiler_roots`, or is reached
--- from one. What it leaves out only stages (the rest of this module),
--- fingerprints, reports (build.symbols' hints, in a refusal's message,
--- which no compile keeps), fails a whole build before any key is looked
--- up (build.positions), or finds the host's caches (build.caches,
--- build/zig.tl): an edit to one compiles and parses nothing again.
--- importer_test's `test_the_compiler_modules_are_closed_under_require`
--- holds each require of build.importer to one side or the other.
function work.compiler_identity(handle: work.Handle): string | nil, string
  local names, trouble = work.compiler_modules(requires_in(handle.db))
  if names == nil then
    return nil, trouble
  end
  return hash_of(handle.db, names, pins)
end

--- Where the writer's identity starts ([`work.writer_modules`]): what
--- decides a projection's bytes beside the rows it is filled from, each
--- of which its signature holds by value or by a key ([`build.writer`]'s
--- `signature_sql`). Those are build.writer, which fills and vacuums it,
--- and this module, which computes the fingerprint and the identities it
--- carries in `meta`. A tool rebuilt by a stale tool carries them as
--- that tool's code took them, and is told apart from one the tree's
--- code wrote only by this module's being in the identity
--- ([`build.reboot`]'s `unsettled`).
-- TODO: hold only this module's fingerprint ([`is_tool`], `tool_files`,
-- [`record_fingerprint`]) and identities ([`compiler_identity`],
-- [`writer_identity`]) once they are split from the staging, the scans and
-- the records into a module of their own: today every edit to
-- build/work.tl moves the writer's identity and settles a rebuilt tool
-- again.
local writer_roots <const>: {string} = { "build.writer", "build.work" }

--- What a writer root requires that the writer's identity leaves out,
--- and why none decides a projection's bytes beside its rows. Only a
--- root's own require is left out: a module that another module of the
--- identity requires is in it, whichever of these it is.
local writer_left_out <const>: {string:string} = {
  ["build.importer"] = "build.writer requires it for its `Result` type alone " ..
    "(`local type`), which `requires` still records; what its " ..
    "compiles and parses store reaches a projection as rows the compiler's " ..
    "identity keys",
  ["build.analysis_schema"] = "the schema of the rows a parse stores, which " ..
    "the compiler's identity holds",
  ["build.gen_syscalls"] = "generates cosmic.sys's declaration, whose source " ..
    "a projection's signature holds, and is the compiler's",
  ["build.todo_scan"] = "fills the TODO tables, which no projection carries",
}

--- The modules the writer's identity holds, sorted, as `requires`
--- answers what a module of the tree requires: every one `require`
--- reaches from `writer_roots`, the standard library's included (down
--- to the SQLite binding that vacuums a projection and the codec that
--- decodes the CA roots into it), except what a root itself requires
--- that `writer_left_out` names. build/importer_test.tl's
--- `test_the_writer_modules_are_closed_under_require` holds that list
--- to the roots' requires.
function work.writer_modules(requires: function(string): {string} | nil, string): {string} | nil, string
  local roots: {string:boolean} = {}
  for _, name in ipairs(writer_roots) do roots[name] = true end
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(writer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do
        if not (roots[name] and writer_left_out[next_name] ~= nil) then
          stack[#stack + 1] = next_name
        end
      end
    end
  end
  local names: {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  return names, ""
end

--- What `writer_left_out` names, for build/importer_test.tl to hold
--- the roots' requires to.
function work.writer_left_out(): {string:string}
  local copy: {string:string} = {}
  for name, why in pairs(writer_left_out) do copy[name] = why end
  return copy
end

--- The writer's identity ([`Identities.writer`]) over what the working
--- database holds now, recorded nowhere: the source hash of each of
--- [`work.writer_modules`] the tree holds, and the core image's hash
--- (`image_hash`), whose SQLite writes the bytes. What a module requires
--- is what `requires` holds of its source, as for [`compiler_identity`].
--- An edit to a module outside it -- build.positions, build.todo_scan,
--- the analyzer -- writes the same projection from the same rows, so
--- it moves no signature and settles no rebuilt tool.
local function writer_identity(handle: work.Handle): string | nil, string
  local names, trouble = work.writer_modules(requires_in(handle.db))
  if names == nil then
    return nil, trouble
  end
  return hash_of(handle.db, names,
    "coalesce((SELECT value FROM meta WHERE key = 'image_hash'), '')")
end

--- The identities, computed over the tree and written into `meta` for
--- the projections to carry, and returns them. See [`Identities`] for what
--- each is over. The compiler's closes over `requires`, so the tree must be parsed
--- ([`build.importer.derive`]) first: on a fresh working database the
--- closure would otherwise stop at [`build.importer`] itself, and keys
--- made under that identity would match no later build's.
function work.record_identities(handle: work.Handle): work.Identities | nil, string
  local db = handle.db
  local compiler, compiler_trouble = work.compiler_identity(handle)
  if compiler == nil then
    return nil, compiler_trouble
  end
  local writer, writer_trouble = writer_identity(handle)
  if writer == nil then
    return nil, writer_trouble
  end
  local bases, basis_trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(" .. pins .. ")))")
  if bases == nil then
    return nil, basis_trouble
  end
  local identities: work.Identities = {
    compiler = compiler,
    runtime_basis = bases[1][1],
    writer = writer,
  }
  for _, pair in ipairs({ { "compiler", identities.compiler },
                          { "runtime_basis", identities.runtime_basis },
                          { "writer", identities.writer } }) do
    local ok, why = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) })
    if not ok then
      return nil, why
    end
  end
  return identities
end

--- Puts the compiler in (the Lua that the vendored `tl.tl`, patched, was
--- compiled to: core/bridge.lua's `bootstrap`) as the one input with no
--- file behind it, for every later build to carry. It replaces any
--- compiler row already there, under whatever file it named: there is
--- only ever one.
function work.put_compiler(handle: work.Handle, source: string): boolean, string
  local cleared, trouble = handle.db:exec("DELETE FROM derived WHERE origin = 'vendor'")
  if not cleared then
    return false, trouble
  end
  return Sqlite.run(handle.db,
    "INSERT OR REPLACE INTO derived (file, path, kind, origin, from_hash, " ..
    "source, source_hash) VALUES ('o/vendor/tl/tl.tl', 'vendor.tl', " ..
    "'vendor', 'vendor', lower(hex(sha256(?1))), ?1, lower(hex(sha256(?1))))",
    { text(source) })
end

--- Every TZif file under `dir`, a `zoneinfo` tree as `vendor/tzdata`
--- holds it, by zone name: its path under `dir`. A zone that is a link
--- to another (as a system zoneinfo's aliases are) is read as the zone
--- it leads to, under its own name.
function work.read_zoneinfo(dir: string): {string:string} | nil, string
  local names, trouble = Fs.walk_following(dir)
  if names == nil then
    return nil, trouble
  end
  local zones: {string:string} = {}
  for _, name in ipairs(names) do
    local data, read_trouble = Fs.read(dir .. "/" .. name)
    if data == nil then
      return nil, read_trouble
    end
    zones[name] = data
  end
  return zones, ""
end

--- Every zone the database `db` carries in its `zoneinfo` table, by
--- name: none when it has no such table.
function work.zoneinfo_of(db: Sqlite.Handle): {string:string} | nil, string
  local tables, trouble = Sqlite.text_rows(db,
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = 'zoneinfo'")
  if tables == nil then
    return nil, trouble
  end
  local zones: {string:string} = {}
  if tables[1][1] == "0" then
    return zones, ""
  end
  local rows, rows_trouble = Sqlite.rows(db, "SELECT name, data FROM zoneinfo")
  if rows == nil then
    return nil, rows_trouble
  end
  for _, row in ipairs(rows) do
    zones[row[1].text] = row[2].blob or row[2].text
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
    return false, trouble
  end
  local names: {string} = {}
  for name in pairs(zones) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, why = Sqlite.run(db,
      "INSERT INTO zoneinfo (name, data) VALUES (?1, ?2)",
      { text(name), { blob = zones[name] } })
    if not ok then
      return false, why
    end
  end
  return true, ""
end

--- Replaces the zones the binary will carry with `zones`, by name.
function work.put_zoneinfo(handle: work.Handle, zones: {string:string}): boolean, string
  return work.write_zones(handle.db, zones)
end

--- Writes this run's row into `builds`.
function work.record(handle: work.Handle, ms: integer, staged: work.Staged,
                     compiled: integer, cached: integer,
                     verdict: string): boolean, string
  return Sqlite.run(handle.db,
    "INSERT OR REPLACE INTO builds (run, ms, files, read, compiled, cached, " ..
    "verdict) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    { integer(handle.run), integer(ms), integer(staged.files),
      integer(staged.read), integer(compiled), integer(cached), text(verdict) })
end

--- Closes the database, keeping whatever a still-open transaction
--- did. The handle is finished after this.
function work.close(handle: work.Handle): boolean, string
  local committed, trouble = work.commit(handle)
  if not committed then
    local _, _ = handle.db:close()
    return false, trouble
  end
  return handle.db:close()
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
    return false, close_trouble
  end
  return true, ""
end

return work
