--- The working database, `o/build.db`: where a build stages the tree
--- and keeps everything it learns about it on this host.
---
--- Two databases, two promises. `o/cosmic.db` is a pure function of
--- the tree, byte-identical from any build of it, and ships. This one
--- is a log of what happened on one host -- the tree as it was last
--- read, what a stat said about each file, test verdicts, coverage --
--- and is allowed, expected even, to differ the next time. It never
--- ships and is never attached to the tree's own database.
---
--- Staging comes first: every input the build consumes is read off
--- disk into the `files` table before anything transforms it, so the
--- rest of the build reads rows, never paths. An unchanged file is a
--- stat: when its size, modification time and inode all match the row,
--- the bytes and the hash on the row are still right and the file is
--- not read again.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record work
  --- An open working database, for one run.
  record Handle
    db: Sqlite.Handle
    root: string
    --- This run's number: one more than the last run over this file.
    run: integer
  end

  --- What one staging pass found and what it had to read.
  record Staged
    files: integer
    read: integer
  end

  --- The statements that create the database, in order. `IF NOT
  --- EXISTS` because this file is opened again and again across runs
  --- rather than built fresh every time.
  schema: {string}

  --- The shape of the schema above. A file of another shape holds
  --- nothing the tree cannot produce again, so it is thrown away.
  version: string
end

work.version = "5"

--- `files` is the staged tree, one row per file the build consumes,
--- holding the bytes exactly as they were on disk. `seen` is the run
--- that last found the file, so a file gone from the tree is a row
--- gone from the table.
---
--- `tool` is what the tool itself is made of, fingerprinted the same
--- way but without the bytes: every source input to the embedded
--- binary, its standard library and tests included, since `cosmic.*`
--- resolves from the binary rather than the tree. Its hash is the
--- boot hash, and a self-tree command refuses a mismatch.
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
--- `images` is the core executable for every target, deflated at
--- rest, which a boot puts here and every later build carries into
--- the database it writes. The compiler is the same kind of thing and
--- lives in `derived`, the one row there with no file behind it.
---
--- `compiled` is one compile of one module, keyed by the module's key
--- -- the hash of its kind, its source, its import closure's keys and
--- the tool -- so a module whose key stands is never compiled again,
--- and `plan` is this run's key for every module it built, in build
--- order. `seen` is the last run that used a compile; one no run has
--- used in the last hundred is dropped, so an edit undone is still
--- free and the cache stays bounded.
---
--- `builds` is one row per run: what was staged, what was read, what
--- was compiled and what came from the cache, and how the run ended.
---
--- `runs` is one row per test, keyed by the module and the test's own
--- name inside it, so a later run of the same test replaces its row
--- rather than piling up a history the runner has no use for yet.
--- That table's shape and semantics are unrelated to everything below
--- and untouched by it.
---
--- `test_runs`/`coverage`/`coverage_by_test` are real history instead:
--- one snapshot per `cosmic test` invocation, never overwritten, each
--- run identified by its own start time in nanoseconds (`ran_at_ns`)
--- rather than an autoincrement id -- `cosmic.sqlite` has no
--- `last_insert_rowid` helper, and a nanosecond timestamp is already
--- how `runs.ran_at_ns` identifies things above, so reusing that
--- convention needs no new sqlite API surface. Rows here are expected
--- to accumulate across many runs over time; this database is dev-only
--- and never shipped, so that growth is accepted, not pruned.
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
--- over time is a plain query away.
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
                                      data BLOB NOT NULL,
                                      seen INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tool (path TEXT PRIMARY KEY,
                                     size INTEGER NOT NULL,
                                     mtime_ns INTEGER NOT NULL,
                                     ino INTEGER NOT NULL,
                                     dev INTEGER NOT NULL,
                                     sha256 TEXT NOT NULL,
                                     seen INTEGER NOT NULL) WITHOUT ROWID]],
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
                                       has_return INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS requires (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tests (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS images (target TEXT PRIMARY KEY,
                                       sha256 BLOB NOT NULL,
                                       size INTEGER NOT NULL,
                                       encoding TEXT NOT NULL,
                                       data BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS compiled (key TEXT PRIMARY KEY,
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
                                     PRIMARY KEY (path, test)) WITHOUT ROWID]],
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

  local versions, version_trouble = Sqlite.rows(db,
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

  local counted, count_trouble = Sqlite.transact(db, function(): boolean, string
    local stamped, stamp_trouble = Sqlite.run(db,
      "INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
      "ON CONFLICT (key) DO NOTHING", { text(work.version) })
    if not stamped then
      return false, stamp_trouble
    end
    return Sqlite.run(db,
      "INSERT INTO meta (key, value) VALUES ('run', 1) " ..
      "ON CONFLICT (key) DO UPDATE SET value = value + 1")
  end)
  if not counted then
    db:close()
    return nil, path .. ": " .. count_trouble
  end
  local runs, run_trouble = Sqlite.rows(db,
    "SELECT value FROM meta WHERE key = 'run'")
  if runs == nil then
    db:close()
    return nil, path .. ": " .. run_trouble
  end
  return { db = db, root = root, run = integer_of(runs) }
end

--- What is never an input: the build's own output, the upstream
--- sources and the records that patch them, prose, and anything
--- hidden. `doc` is handled on its own: almost all of it is prose with
--- no examples, but `doc/guides/*.md` is the one place doc/meta.md's
--- grammar applies, and the build has to see those files to run
--- `build.doctest` over them. In cosmic's own tree the upstream
--- sources, the patches and the zig wrapper are walked after all, as
--- inputs to the tool rather than to the build.
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
  ["vendor"] = true,
}
local tool_files: {string:boolean} = {
  ["build.zig"] = true,
  ["build.zig.zon"] = true,
  ["bin/zig"] = true,
  ["bin/zig.pin"] = true,
}
--- The directories the files above sit in, walked for them alone.
local tool_dirs: {string:boolean} = {
  ["bin"] = true,
}

local function first_of(entry: string): string
  return entry:match("^([^/]+)") or entry
end

--- Whether `file` is a doc this tree extracts runnable examples from --
--- exactly `doc/guides/*.md`, never a markdown file anywhere else in
--- the tree (`doc/design.md`, `doc/roadmap.md`, and `doc/meta.md` are
--- prose with no examples, and stay out of scope on purpose).
local function is_doc_guide(file: string): boolean
  return file:match("^doc/guides/[^/]+%.md$") ~= nil
end

local function skip_input(entry: string): boolean
  local first = first_of(entry)
  if first == "doc" then
    if entry == "doc" or entry == "doc/guides" then
      return false
    end
    return not is_doc_guide(entry)
  end
  if not_input[first] then
    return true
  end
  local name = entry:match("([^/]+)$") or entry
  return name:sub(1, 1) == "."
end

local function skip_in_own_tree(entry: string): boolean
  if tool_trees[first_of(entry)] or tool_files[entry] or tool_dirs[entry] then
    local name = entry:match("([^/]+)$") or entry
    return name:sub(1, 1) == "."
  end
  return skip_input(entry)
end

--- Whether a file the walk found is one the build consumes: Teal
--- source and declarations, a doc guide, and, in cosmic's own tree,
--- the syscall header the declaration of `cosmic.sys` is generated
--- from. Never anything under the trees the tool alone is made of:
--- the vendored compiler ships its own `.tl` source, which is an
--- input to the tool's hash and nothing else.
local function is_input(file: string, own_tree: boolean): boolean
  if not_input[first_of(file)] then
    return false
  end
  if file:sub(-3) == ".tl" or is_doc_guide(file) then
    return true
  end
  return own_tree and file == "core/syscalls.h"
end

--- Whether a file is one the tool is made of, in cosmic's own tree.
local function is_tool(file: string, own_tree: boolean): boolean
  return own_tree and (tool_trees[first_of(file)] or tool_files[file] or false)
end

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

--- The three statements one staging pass runs over one table,
--- prepared once each.
local record Statements
  look: Sqlite.Statement
  touch: Sqlite.Statement
  put: Sqlite.Statement
end

--- `files` keeps the bytes; `tool` keeps only what a stat and a hash
--- say about them. The put for either takes the bytes as its sixth
--- parameter and hashes them in place, and the run as its seventh.
local puts: {string:string} = {
  files = "INSERT OR REPLACE INTO files (path, size, mtime_ns, ino, dev, " ..
    "sha256, data, seen) " ..
    "VALUES (?1, ?2, ?3, ?4, ?5, lower(hex(sha256(?6))), ?6, ?7)",
  tool = "INSERT OR REPLACE INTO tool (path, size, mtime_ns, ino, dev, " ..
    "sha256, seen) VALUES (?1, ?2, ?3, ?4, ?5, lower(hex(sha256(?6))), ?7)",
}

local function prepare(db: Sqlite.Handle, table_name: string): Statements | nil, string
  local look, look_trouble = db:prepare(
    "SELECT size, mtime_ns, ino, dev FROM " .. table_name .. " WHERE path = ?1")
  if look == nil then
    return nil, look_trouble
  end
  local touch, touch_trouble = db:prepare(
    "UPDATE " .. table_name .. " SET seen = ?2 WHERE path = ?1")
  if touch == nil then
    look:finalize()
    return nil, touch_trouble
  end
  local put, put_trouble = db:prepare(puts[table_name])
  if put == nil then
    look:finalize()
    touch:finalize()
    return nil, put_trouble
  end
  return { look = look, touch = touch, put = put }
end

local function finish(statements: Statements)
  statements.look:finalize()
  statements.touch:finalize()
  statements.put:finalize()
end

--- Stages one file: a stat that matches its row touches the row; any
--- other reads the file and writes the row. Reports whether the file
--- was read.
local function stage_one(statements: Statements, root: string, file: string,
                         run: integer): boolean | nil, string
  local st, stat_trouble = Fs.stat(root .. "/" .. file)
  if st == nil then
    return nil, stat_trouble
  end
  local mtime_ns = st.mtime * 1000000000 + st.mtime_ns
  local look = statements.look
  look:bind_text(1, file)
  local state, step_trouble = look:step()
  if state == nil then
    return nil, step_trouble
  end
  local same = state == "row" and look:integer(0) == st.size and
    look:integer(1) == mtime_ns and look:integer(2) == st.ino and
    look:integer(3) == st.dev
  look:reset()

  if same then
    local touch = statements.touch
    touch:bind_text(1, file)
    touch:bind_integer(2, run)
    local touched, touch_trouble = once(touch)
    if not touched then
      return nil, touch_trouble
    end
    return false
  end

  local data, read_trouble = Fs.read(root .. "/" .. file)
  if data == nil then
    return nil, read_trouble
  end
  local put = statements.put
  put:bind_text(1, file)
  put:bind_integer(2, st.size)
  put:bind_integer(3, mtime_ns)
  put:bind_integer(4, st.ino)
  put:bind_integer(5, st.dev)
  put:bind_blob(6, data)
  put:bind_integer(7, run)
  local written, put_trouble = once(put)
  if not written then
    return nil, put_trouble
  end
  return true
end

--- Stages every file `chosen` picks into one table. A file whose stat
--- matches its row is not read; one that differs, or is new, is read
--- and hashed; one the walk no longer finds is deleted.
local function stage_into(handle: work.Handle, table_name: string,
                          files: {string}, chosen: function(string): boolean,
                          staged: work.Staged): boolean, string
  local db = handle.db
  local statements, prepare_trouble = prepare(db, table_name)
  if statements == nil then
    return false, prepare_trouble
  end
  for _, file in ipairs(files) do
    if chosen(file) then
      local read, why = stage_one(statements, handle.root, file, handle.run)
      if read == nil then
        finish(statements)
        return false, file .. ": " .. why
      end
      staged.files = staged.files + 1
      if read then
        staged.read = staged.read + 1
      end
    end
  end
  finish(statements)
  return Sqlite.run(db, "DELETE FROM " .. table_name .. " WHERE seen < ?1",
    { integer(handle.run) })
end

--- Reads the tree into `files` and, in cosmic's own tree, fingerprints
--- what the tool is made of into `tool`, in one transaction.
--- @param own_tree whether `root` is cosmic's own tree
function work.stage(handle: work.Handle, own_tree: boolean): work.Staged | nil, string
  local walked, walk_trouble =
    Fs.walk(handle.root, own_tree and skip_in_own_tree or skip_input)
  if walked == nil then
    return nil, walk_trouble
  end
  local files: {string} = walked
  local staged: work.Staged = { files = 0, read = 0 }
  local made, trouble = Sqlite.transact(handle.db, function(): boolean, string
    local ok, why = stage_into(handle, "files", files,
      function(file: string): boolean
        return is_input(file, own_tree)
      end, staged)
    if not ok then
      return false, why
    end
    return stage_into(handle, "tool", files, function(file: string): boolean
      return is_tool(file, own_tree)
    end, staged)
  end)
  if not made then
    return nil, trouble
  end
  return staged
end

--- The hash of the tool itself, over every fingerprint in `tool`. A
--- row compiled by an older importer is never mistaken for a current
--- one, because this is part of every module's key. A binary carries
--- the number it was built with, so a project reads it rather than
--- computing one.
function work.boot_hash(handle: work.Handle): string | nil, string
  local rows, trouble = Sqlite.rows(handle.db,
    "SELECT lower(hex(sha256(group_concat(path || ' ' || sha256, char(10) " ..
    "ORDER BY path)))) FROM tool")
  if rows == nil then
    return nil, trouble
  end
  return rows[1][1]
end

--- Puts one target's core image in, deflated, for every later build
--- to carry.
function work.put_image(handle: work.Handle, target: string,
                        image: string): boolean, string
  local packed, deflate_trouble = Compress.deflate(image)
  if packed == nil then
    return false, target .. ": " .. deflate_trouble
  end
  return Sqlite.run(handle.db,
    "INSERT OR REPLACE INTO images (target, sha256, size, encoding, data) " ..
    "VALUES (?1, sha256(?2), ?3, 'deflate', ?4)",
    { text(target), { blob = image }, integer(#image), { blob = packed } })
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

--- Closes the database. The handle is finished after this.
function work.close(handle: work.Handle): boolean, string
  return handle.db:close()
end

return work
