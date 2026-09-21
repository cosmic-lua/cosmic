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
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

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

  --- What the tool is made of, as two hashes: everything, and the
  --- part the C core is built from. A binary carries both; a tree
  --- whose `boot` differs but whose `image` matches needs only a new
  --- database combined with the exact portable prefix the binary carries, and
  --- the tool can do that to itself.
  record Fingerprint
    boot: string
    image: string
  end

  --- What a compile and a verdict are functions of, beyond their own
  --- inputs. `compiler` is the build's own modules in the importer's
  --- import closure and the Teal compiler's and Lua's pins and
  --- patches: what turns source into bytecode. The standard library
  --- the importer runs on is plumbing, not transformation -- a bug
  --- there breaks the build loudly rather than changing bytecode
  --- quietly -- and is left out, which is what keeps an edit to it
  --- from recompiling everything. `runtime_basis` is the host-independent
  --- hash of the Teal and Lua pins and patches. Portable startup combines
  --- it with the validated target, configuration and exact raw-core digest.
  --- Both are computed over the tree being built and carried by its portable
  --- projection, so a tool always names what it actually is.
  record Identities
    compiler: string
    runtime_basis: string
  end

  --- The statements that create the database, in order. `IF NOT
  --- EXISTS` because this file is opened again and again across runs
  --- rather than built fresh every time.
  schema: {string}

  --- The shape of the schema above. A file of another shape holds
  --- nothing the tree cannot produce again, so it is thrown away.
  version: string
end

work.version = "15"

--- `files` is the staged tree, one row per file the build consumes,
--- holding the bytes exactly as they were on disk. A file gone from
--- the tree is a row gone from the table. A file written within the
--- last two seconds of being staged is recorded with no modification
--- time, so the next run reads it again rather than trusting a stat
--- that a second write inside one timestamp tick could leave
--- unchanged -- the rule zig's cache applies to its own inputs.
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
--- can never be stale.
---
--- `executable` is `build.coverage.lines.executable`'s answer for one
--- source, keyed by content hash the same way as `parsed`: which lines
--- could ever be hit is a pure function of the bytes alone, so a row
--- can never be stale and, like `parsed`, is never pruned. `lines` is
--- every executable line number in ascending order, joined by single
--- spaces (e.g. "1 3 4 9"), rather than one row per line, since a
--- caller always wants the whole set back at once. A row is a
--- function of the bytes and of that module's rule for what counts as
--- executable, so a change to the rule bumps `work.version`, as a
--- change to what a parse records does for `parsed`.
---
--- Raw cores remain build outputs under `o/core`; they are never copied into
--- this working database. The compiler lives in `derived`, the one row there
--- with no file behind it.
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
--- `builds` is one row per run: what was staged, what was read, what
--- was compiled and what came from the cache, and how the run ended.
---
--- `runs` is one row per test, keyed by the module and the test's own
--- name inside it, so a later run of the same test replaces its row
--- rather than piling up a history the runner has no use for yet.
--- `key` is what the verdict is a function of: the module's key and
--- the hash of every file under the root the test was observed to
--- read; `reads` is what it opened, as recorded, and `run_at_ns` the
--- `cosmic test` invocation whose coverage rows credit the verdict.
---
--- `verdicts` is one row per key ever seen, with its verdict and the
--- invocation that produced it, and `seen` the last run that relied on
--- it: while a key stands and its verdict passed, the test is not run
--- again, and an edit undone finds its old key again. One no run has
--- relied on in the last ten (`build.test`'s `kept_runs`) is dropped,
--- and with it the `coverage_by_test` rows no verdict credits any
--- more.
---
--- `test_runs`/`coverage`/`coverage_by_test` are real history instead:
--- one snapshot per `cosmic test` invocation, each run identified by
--- its own start time in nanoseconds (`ran_at_ns`) rather than an
--- autoincrement id -- `cosmic.sqlite` has no `last_insert_rowid`
--- helper, and a nanosecond timestamp is already how `runs.ran_at_ns`
--- identifies things above, so reusing that convention needs no new
--- sqlite API surface. This database is dev-only and never shipped,
--- but its growth is still bounded: `build.test`'s `prune_history`
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
--- which specific test(s) hit a given line in a given run -- the input
--- test-impact analysis needs later ("given a changed file, which
--- tests are worth re-running"). A row's mere presence means that test
--- hit that line in that run: there is no `hit` column, since absence
--- already means "not hit by that test in that run" and only lines a
--- test actually hit are ever inserted.
work.schema = {
  [[CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,
                                     value BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY,
                                      size INTEGER NOT NULL,
                                      mtime_ns INTEGER NOT NULL,
                                      ino INTEGER NOT NULL,
                                      dev INTEGER NOT NULL,
                                      sha256 TEXT NOT NULL,
                                      data BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tool (path TEXT PRIMARY KEY,
                                     size INTEGER NOT NULL,
                                     mtime_ns INTEGER NOT NULL,
                                     ino INTEGER NOT NULL,
                                     dev INTEGER NOT NULL,
                                     sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS derived (file TEXT PRIMARY KEY,
                                        path TEXT NOT NULL,
                                        kind TEXT NOT NULL,
                                        origin TEXT NOT NULL,
                                        from_hash TEXT NOT NULL,
                                        source TEXT NOT NULL,
                                        source_hash TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE VIEW IF NOT EXISTS inputs AS
      SELECT path AS file,
             replace(CASE WHEN path GLOB '*.d.tl' THEN substr(path, 1, length(path) - 5)
                          WHEN path GLOB '*/init.tl' THEN substr(path, 1, length(path) - 8)
                          ELSE substr(path, 1, length(path) - 3) END, '/', '.') AS path,
             CASE WHEN path GLOB '*.d.tl' THEN 'decl'
                  WHEN path GLOB '*_test.tl' THEN 'test'
                  WHEN path GLOB '*_example.tl' THEN 'example'
                  WHEN path GLOB 'cmd/*/main.tl' AND path NOT GLOB 'cmd/*/*/*' THEN 'main'
                  ELSE 'module' END AS kind,
             'tree' AS origin,
             sha256 AS from_hash,
             CAST(data AS TEXT) AS source,
             sha256 AS source_hash
        FROM files WHERE path GLOB '*.tl'
      UNION ALL
      SELECT file, path, kind, origin, from_hash, source, source_hash FROM derived]],
  [[CREATE TABLE IF NOT EXISTS parsed (source_hash TEXT PRIMARY KEY,
                                       has_return INTEGER NOT NULL,
                                       export TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS executable (source_hash TEXT PRIMARY KEY,
                                           lines TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS requires (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tests (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS catalog (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        symbol TEXT NOT NULL,
                                        message TEXT NOT NULL,
                                        line INTEGER NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS docs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     symbol TEXT NOT NULL,
                                     source_symbol TEXT NOT NULL,
                                     exported INTEGER NOT NULL,
                                     kind TEXT NOT NULL,
                                     signature TEXT NOT NULL,
                                     text TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS refs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     module TEXT NOT NULL,
                                     member TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS examples (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         text TEXT NOT NULL,
                                         source TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS compiled (key TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         lua TEXT NOT NULL,
                                         bytecode BLOB NOT NULL,
                                         seen INTEGER NOT NULL) WITHOUT ROWID]],
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
                                     reads TEXT NOT NULL,
                                     key TEXT NOT NULL,
                                     run_at_ns INTEGER NOT NULL,
                                     PRIMARY KEY (path, test)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS verdicts (key TEXT PRIMARY KEY,
                                         passed INTEGER NOT NULL,
                                         run_at_ns INTEGER NOT NULL,
                                         seen INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS test_runs (ran_at_ns INTEGER NOT NULL
                                          PRIMARY KEY)]],
  [[CREATE TABLE IF NOT EXISTS coverage (ran_at_ns INTEGER NOT NULL,
                                         path TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         hit INTEGER NOT NULL,
                                         PRIMARY KEY (ran_at_ns, path, line))
                                        WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS coverage_by_test (ran_at_ns INTEGER NOT NULL,
                                                 path TEXT NOT NULL,
                                                 line INTEGER NOT NULL,
                                                 test TEXT NOT NULL,
                                                 PRIMARY KEY (ran_at_ns, path,
                                                              line, test))
                                                WITHOUT ROWID]],
}

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function integer(value: integer): Sqlite.Value
  return { integer = value }
end

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
  db:exec("PRAGMA encoding = 'UTF-8'")
  local created, create_trouble = create(db)
  if not created then
    db:close()
    return nil, path .. ": " .. create_trouble
  end

  local versions, version_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'schema'")
  if versions == nil then
    db:close()
    return nil, path .. ": " .. version_trouble
  end
  if #versions > 0 and versions[1][1] ~= work.version then
    db:close()
    local removed, remove_trouble = Fs.remove(path)
    if not removed then
      return nil, remove_trouble
    end
    return work.open(root)
  end

  local begun, begin_trouble = db:exec("BEGIN")
  if not begun then
    db:close()
    return nil, path .. ": " .. begin_trouble
  end
  local stamped, stamp_trouble = Sqlite.run(db,
    "INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
    "ON CONFLICT (key) DO NOTHING", { text(work.version) })
  if not stamped then
    db:close()
    return nil, path .. ": " .. stamp_trouble
  end
  local counted, count_trouble = Sqlite.run(db,
    "INSERT INTO meta (key, value) VALUES ('run', 1) " ..
    "ON CONFLICT (key) DO UPDATE SET value = value + 1")
  if not counted then
    db:close()
    return nil, path .. ": " .. count_trouble
  end
  local runs, run_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'run'")
  if runs == nil then
    db:close()
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
    -- A failed COMMIT leaves SQLite's transaction open. Discard it so
    -- close cannot preserve a partial phase and the handle state remains
    -- truthful even when the database reports a deferred error here.
    local rolled_back = handle.db:exec("ROLLBACK")
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
  if rolled_back then
    handle.inside = false
  end
  return rolled_back, trouble
end

--- Opens another transaction on the run, for a phase that comes after
--- the projection: the test runner's records, written together.
function work.begin(handle: work.Handle): boolean, string
  local begun, trouble = handle.db:exec("BEGIN")
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
--- `build.doctest` over them. In cosmic's own tree the patches, the
--- vendor pins and the zig wrapper are walked after all, as inputs to
--- the tool rather than to the build.
local not_input: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["bin"] = true,
}

--- The trees and files the tool is made of, in cosmic's own tree.
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
--- The directories the files above sit in, walked for them alone.
--- `vendor` is walked one level down for each tree's `PIN`.
local tool_dirs: {string:boolean} = {
  ["bin"] = true,
  ["vendor"] = true,
}

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
--- the tree (`doc/design.md`, `doc/roadmap.md`, and `doc/meta.md` are
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
  if name:sub(1, 1) == "." then
    return true
  end
  local first = first_of(entry)
  if first == "vendor" then
    return not is_vendor_pin(entry)
  end
  if tool_trees[first] or tool_files[entry] or tool_dirs[entry] then
    return false
  end
  return skip_input(entry, name)
end

--- Whether a file the walk found is one the build consumes: Teal
--- source and declarations, a doc guide, and, in cosmic's own tree,
--- the syscall header the declaration of `cosmic.sys` is generated
--- from. Never anything under the trees the tool alone is made of.
local function is_input(file: string, own_tree: boolean): boolean
  local first = first_of(file)
  if not_input[first] then
    return false
  end
  if file:sub(-3) == ".tl" then
    return true
  end
  if first == "doc" then
    return is_doc_guide(file)
  end
  return own_tree and file == "core/syscalls.h"
end

--- Whether a file is one the tool is made of, in cosmic's own tree: a
--- file under one of its trees, one of its named files, or a vendored
--- tree's pin.
local function is_tool(file: string, own_tree: boolean): boolean
  if not own_tree then
    return false
  end
  local first = first_of(file)
  if first == "vendor" then
    return file:sub(-4) == "/PIN"
  end
  return tool_trees[first] == true or tool_files[file] == true
end

--- What a stat said about a file the last time it was staged, read
--- once per table into memory, so an unchanged file costs a stat and
--- a comparison and never a query.
local record Known
  size: integer
  mtime_ns: integer
  ino: integer
  dev: integer
end

local function known_in(db: Sqlite.Handle,
                        table_name: string): {string:Known} | nil, string
  local statement, trouble = db:prepare(
    "SELECT path, size, mtime_ns, ino, dev FROM " .. table_name)
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
      mtime_ns = statement:integer(2),
      ino = statement:integer(3),
      dev = statement:integer(4),
    }
  end
  statement:finalize()
  return out
end

--- `files` keeps the bytes; `tool` keeps only what a stat and a hash
--- say about them. The put for either takes the bytes as its sixth
--- parameter and hashes them in place.
local puts: {string:string} = {
  files = "INSERT OR REPLACE INTO files (path, size, mtime_ns, ino, dev, " ..
    "sha256, data) VALUES (?1, ?2, ?3, ?4, ?5, lower(hex(sha256(?6))), ?6)",
  tool = "INSERT OR REPLACE INTO tool (path, size, mtime_ns, ino, dev, " ..
    "sha256) VALUES (?1, ?2, ?3, ?4, ?5, lower(hex(sha256(?6))))",
}

--- Runs a statement that yields no rows, once, and readies it to run
--- again with other parameters.
local function once(statement: Sqlite.Statement): boolean, string
  local state, trouble = statement:step()
  if state == nil then
    return false, trouble
  end
  statement:reset()
  return true, ""
end

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
  return was == nil or was.size ~= st.size or was.mtime_ns ~= mtime_ns or
    was.ino ~= st.ino or was.dev ~= st.dev
end

--- Writes one file's row: its stat, with the modification time kept
--- only once it has settled, and its bytes, hashed in place.
local function put_row(put: Sqlite.Statement, file: string, st: sys.Stat,
                       mtime_ns: integer, settled: boolean,
                       data: string): boolean, string
  put:bind_text(1, file)
  put:bind_integer(2, st.size)
  put:bind_integer(3, settled and mtime_ns or 0)
  put:bind_integer(4, st.ino)
  put:bind_integer(5, st.dev)
  put:bind_blob(6, data)
  return once(put)
end

local function finish(put_files: Sqlite.Statement, put_tool: Sqlite.Statement)
  put_files:finalize()
  put_tool:finalize()
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

--- Reads the tree into `files` and, in cosmic's own tree, fingerprints
--- what the tool is made of into `tool`, in one pass: a file both
--- tables want is stat'd once and read at most once. A file whose stat
--- matches its row is not read; one that differs, or is new, is read,
--- hashed and written; one the walk no longer finds is deleted. Only a
--- change reaches the database.
--- @param own_tree whether `root` is cosmic's own tree
function work.stage(handle: work.Handle, own_tree: boolean): work.Staged | nil, string
  local db = handle.db
  local root = handle.root
  local walked, walk_trouble =
    Fs.walk(root, own_tree and skip_in_own_tree or skip_input)
  if walked == nil then
    return nil, walk_trouble
  end
  local files: {string} = walked
  local known_files, files_trouble = known_in(db, "files")
  if known_files == nil then
    return nil, files_trouble
  end
  local known_tool, tool_trouble = known_in(db, "tool")
  if known_tool == nil then
    return nil, tool_trouble
  end
  local put_files, put_files_trouble = db:prepare(puts.files)
  if put_files == nil then
    return nil, put_files_trouble
  end
  local put_tool, put_tool_trouble = db:prepare(puts.tool)
  if put_tool == nil then
    put_files:finalize()
    return nil, put_tool_trouble
  end
  local now = Time.now_ns() or 0
  local staged: work.Staged = { files = 0, read = 0 }

  for _, file in ipairs(files) do
    local input = is_input(file, own_tree)
    local tool = is_tool(file, own_tree)
    if input or tool then
      local st, stat_trouble = Fs.stat(root .. "/" .. file)
      if st == nil then
        finish(put_files, put_tool)
        return nil, stat_trouble
      end
      local mtime_ns = st.mtime * 1000000000 + st.mtime_ns
      local settled = mtime_ns < now - settle_ns
      staged.files = staged.files + 1
      local write_files = input and moved(known_files, file, st, mtime_ns)
      local write_tool = tool and moved(known_tool, file, st, mtime_ns)
      if write_files or write_tool then
        local data, read_trouble = Fs.read(root .. "/" .. file)
        if data == nil then
          finish(put_files, put_tool)
          return nil, read_trouble
        end
        staged.read = staged.read + 1
        if write_files then
          local ok, why = put_row(put_files, file, st, mtime_ns, settled, data)
          if not ok then
            finish(put_files, put_tool)
            return nil, file .. ": " .. why
          end
        end
        if write_tool then
          local ok, why = put_row(put_tool, file, st, mtime_ns, settled, data)
          if not ok then
            finish(put_files, put_tool)
            return nil, file .. ": " .. why
          end
        end
      end
    end
  end
  finish(put_files, put_tool)
  local forgot, forget_trouble = forget(db, "files", known_files)
  if not forgot then
    return nil, forget_trouble
  end
  forgot, forget_trouble = forget(db, "tool", known_tool)
  if not forgot then
    return nil, forget_trouble
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

--- The tool's fingerprints, over `tool`: `boot` over every row, and
--- `image` over what the C core is built from -- `core/`, the zig
--- build and wrapper, and every vendored tree's pin and patches,
--- the Teal compiler's included: only `bin/zig build boot` applies a
--- patch record to a pin, so a change under `vendor/tl/PIN` or
--- `patch/tl/*` needs it too, the same as every other vendored tree.
--- `build/launcher.tl` also belongs to the retained portable prefix: a
--- database-only rebuild reuses its existing shell bytes.
--- Both are kept in `meta` for the projection to carry into the
--- binary, which is how a binary knows what it was built from, so a
--- project reads them rather than computing any.
function work.fingerprint(handle: work.Handle): work.Fingerprint | nil, string
  local db = handle.db
  local boot, boot_trouble = hash_over(db, "1")
  if boot == nil then
    return nil, boot_trouble
  end
  local image, image_trouble = hash_over(db,
    "path GLOB 'core/*' OR path IN ('build.zig', 'build.zig.zon', " ..
    "'bin/zig', 'bin/zig.pin', 'build/launcher.tl') OR " ..
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

--- The identities, computed over the tree and kept in `meta` for the
--- projections to carry. See `Identities` for what each is over.
--- The compiler's closes over `requires`, so the tree must be parsed
--- (`build.importer.derive`) first: on a fresh working database the
--- closure would otherwise stop at `build.importer` itself, and keys
--- made under that identity would match no later build's.
function work.identities(handle: work.Handle): work.Identities | nil, string
  local db = handle.db
  local pins =
    "coalesce((SELECT group_concat(path || ' ' || sha256, char(10) " ..
    "ORDER BY path) FROM tool WHERE path IN ('vendor/tl/PIN', 'vendor/lua/PIN') " ..
    "OR path GLOB 'patch/tl/*' OR path GLOB 'patch/lua/*'), '')"
  local compilers, compiler_trouble = Sqlite.text_rows(db,
    "WITH RECURSIVE closure(path) AS (SELECT 'build.importer' UNION " ..
    "SELECT r.name FROM closure c JOIN inputs i ON i.path = c.path " ..
    "JOIN requires r ON r.source_hash = i.source_hash) " ..
    "SELECT lower(hex(sha256(coalesce((SELECT group_concat(path || ' ' || " ..
    "source_hash, char(10) ORDER BY path) FROM inputs WHERE path IN " ..
    "(SELECT path FROM closure) AND path GLOB 'build.*'), '') || char(10) || " ..
    pins .. ")))")
  if compilers == nil then
    return nil, compiler_trouble
  end
  local bases, basis_trouble = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(" .. pins .. ")))")
  if bases == nil then
    return nil, basis_trouble
  end
  local identities: work.Identities = {
    compiler = compilers[1][1],
    runtime_basis = bases[1][1],
  }
  for _, pair in ipairs({ { "compiler", identities.compiler },
                          { "runtime_basis", identities.runtime_basis } }) do
    local ok, why = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(pair[1]), text(pair[2]) })
    if not ok then
      return nil, why
    end
  end
  return identities
end

--- Puts the vendored compiler in, as the one input with no file behind
--- it, for every later build to carry.
function work.put_compiler(handle: work.Handle, source: string): boolean, string
  return Sqlite.run(handle.db,
    "INSERT OR REPLACE INTO derived (file, path, kind, origin, from_hash, " ..
    "source, source_hash) VALUES ('o/vendor/tl/tl.lua', 'vendor.tl', " ..
    "'vendor', 'vendor', lower(hex(sha256(?1))), ?1, lower(hex(sha256(?1))))",
    { text(source) })
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
    handle.db:close()
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
  return closed, close_trouble
end

return work
