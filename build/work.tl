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
local sys = require("cosmic.sys")
local identity = require("build.identity")
local type tree = require("build.tree")
local analysis_schema = require("build.analysis_schema")
local todo_scan = require("build.todo_scan")
local gen_syscalls = require("build.gen_syscalls")
local bind = require("build.bind")
local link_files = require("build.link_files")
local rebuild_lock = require("build.rebuild_lock")
local log = require("build.logger").log

local record work
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
    db: Sqlite.Handle
    root: string
    --- The directory the build writes into: `root`'s build directory, or another
    --- [`open`] was given.
    dir: string
    --- This run's number: one more than the last run over this file.
    run: integer
    --- Whether the run's transaction is open.
    inside: boolean
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
    files: integer
    read: integer
    --- One line for each file under `static/` newly staged whose name
    --- says it was meant as a module (`.tl`, `.tmpl`): it is carried as an
    --- asset. Also complained of as it is found.
    notes: mut {string}
  end

  --- The statements that create the database, in order. `IF NOT
  --- EXISTS` because this file is opened again and again across runs
  --- rather than built fresh every time.
  schema: {string}
end

--- The shape of the schema. A file of another shape holds nothing the
--- tree cannot produce again, so it is thrown away.
local version <const> = "31"

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
--- binary, its standard library included, since `cosmic.*` resolves
--- from the binary rather than the tree. Test sources are staged in
--- `files` but excluded from `tool` ([`identity.is_tool`]). A vendored tree is
--- a function of its `PIN` and the records under `patch/`, and is
--- never edited in place, so the pin and the records are its inputs
--- and the tree itself is not walked. Its hash is the boot hash, and
--- a self-tree command refuses a mismatch.
---
--- `tool_discovery` holds the input walk's directories and links, including
--- the root. Their metadata witnesses membership changes for read-only
--- freshness checks; it contributes nothing to a build or verdict identity.
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
--- `policy` declaration ([`cosmic.test`]), as the `needs` it stands for:
--- one row per value a field lists (`true` for a flag, and the line the
--- declaration starts on under `line`).
--- `links` is each link its comments hold ([`build.link_text`]), as
--- written: what it names is resolved only once every module is
--- known, as a projection is written ([`build.link_index`]).
--- `stubs` is the stub of a source (build.stub): the text a
--- project's checker reads in place of a module's, which cosmic's own
--- projection carries for its standard library, and whether it is
--- declaration-only. Every source with a top-level `return` has one,
--- though only those modules' are read: a test has none.
--- `globals` is where each `global` declaration of a source starts
--- (build.globals), a row each by line and column: the rows a build
--- refuses from ([`build.plans`]'s `refuse_globals`) without
--- reading a source again. A guide's example is at the line of the
--- module extracted from the guide.
--- `places` is where each type a source declares, and each field, method
--- and `function R.f` of one, has its name ([`build.syntax_places`]): a
--- row each by dotted symbol from the top of the module (`R`, `R.Inner`,
--- `R.f`), its kind, and the line, byte column and byte length of the
--- name. `cosmic lsp` finds a declaration in another module by it
--- ([`build.lsp.source`]) without parsing the module. A source derived
--- from another file (`mapped`) has none: its lines are not the file's.
---
--- `executable` is [`build.coverage.syntax_lines.executable`]'s answer for one
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
--- rule alone -- a change to the rule bumps `version`, and so does one
--- to what [`build.patch`]'s [`Patch.parse`] takes as a record, whose
--- TODOs the rule reads apart. A row no
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
--- Raw cores are build outputs under the build directory's `core`; they are never copied into
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
--- `web_assets` is the browser-side files [`cosmic.web`] serves under
--- `/_web/` (`vendor/htmx`, `vendor/htmx-ext-sse`), each with its
--- SHA-256, its SHA-384 as base64 (the value of a `integrity` attribute)
--- and its version, which a boot computes from the vendored bytes. Like
--- `zoneinfo` it has no staged file behind it.
---
--- `compiled` is one compile of one module, keyed by the module's key
--- -- the hash of its kind, its source, its import closure's keys and
--- the tool -- so a module whose key stands is never compiled again,
--- and `plan` is this run's key for every module it built, in build
--- order. `tool` is the hash of the tool that made a compile, and
--- `seen` the last run that used it: a compile another tool made is
--- dropped the moment this one runs, and one no run has used in the
--- last hundred (and ten more: [`build.importer`] writes `seen` only
--- once it is ten runs old, since a row holds the Lua and the bytecode)
--- goes too, so an edit undone is still free and the cache stays
--- bounded.
---
--- `deflated` is the compressed text of a source, by the source's SHA-256
--- and the core that compressed it, which [`build.writer`] puts in a
--- projection beside it instead of compressing every source on each write.
--- `deflated_bytecode` is the same for a compile's bytecode, by the
--- compile's key.
---
--- `compressed` is the gzip and zstd of a static file (NULL where not worth
--- keeping), by its path, SHA-256, the digest of the rules that chose them
--- ([`cosmic.mime`]) and the core that compressed it, which [`build.writer`]
--- puts in a projection's `payload` instead of compressing every file on
--- each write. A file whose encoder failed has no row, so it is tried again.
---
--- TODO: share `compressed` across checkouts through the shared cache
--- ([`build.shared_compiles`]'s cache.db), keyed as it is now: it lives in
--- the working database, so every fresh worktree, clone and CI run of a
--- project with static files pays the cold compression (about 51 s for
--- 10.6 MB at level 19). Waits on the shared cache holding the table.
---
--- `link_answers` is what the disk answered the last time
--- [`build.link_index`]'s `pending` resolved the tree's links, by a
--- fingerprint of the links and the code that resolves them, so a run
--- that finds every answer the same does not resolve them again.
---
--- `link_fill` and `link_fill_rows` are the `links` rows the last
--- `fill` wrote, with a fingerprint of what they were written from, so a
--- projection whose symbols and links did not move copies them.
---
--- `compiled_interface` names, by a module's interface key
--- ([`build.plans`]'s `interface_keys`), the compile that stood
--- for it last: what a module's key that moved without its source or the
--- interface of anything it reaches moving takes its compile from.
---
--- `keys_memo` is the keys [`build.plans`]'s `dependency_keys` made
--- of the last few sets of inputs, by a digest of everything they are a
--- function of, so a run where no source moved does not make them again.
---
--- `key_memo` and `key_frags` are the keys of the last build's modules and
--- the digest of each node of their import graphs, written together
--- under the compiler they were made for, so that a build keys again only
--- the modules that reach a node that changed ([`build.plans`]'s
--- `dependency_keys`).
---
--- `typed_refs` is what one compile's checker found a record's field
--- used through (build.receivers): keyed by the compile's own key,
--- since a value's type depends on everything its module imports, and
--- dropped with the compile it rode on.
---
--- `builds` is one row per run: what was staged, what was read, what
--- was compiled and what came from the cache, and how the run ended.
--- `ms` is from the run's start to when its row was written, which is
--- not the same point for every verb. `cosmic test` and a boot, which
--- hold the rebuild lock, write the row once the projection is
--- published, so it counts the publication. Every other build (a file
--- run, `cosmic build`, `embed`, a lookup's or `fix`'s) writes it in the
--- transaction its compile commits ([`build.writer`]'s `write_recorded`), so
--- that a run removing the file once the locks are free cannot lose
--- it; its `ms` stops at that commit and leaves the publication out.
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
--- hashes, the tree's tool and vendor/ among them -- by absolute path,
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
--- `type_violations` holds what the last `cosmic test --check-types` run
--- reported ([`build.test`]'s `keep_violations`): a row for each distinct
--- violation, where it was met and the first test that met it, replacing
--- the run before's. `type_violation_tests` holds a row for every test that
--- met each, with how often, so the tests that meet any are counted.
---
--- The statements of `derived`, `inputs` and the tables a parse fills
--- are [`build.analysis_schema`]'s, which this places between the
--- stage's and the records': what a parse's rows are shaped by is kept
--- apart from the rest of this module, which the compiler's identity
--- does not hold ([`identity.compiler_identity`]).
work.schema = {
  [[CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,
                                     value BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY,
                                      size INTEGER NOT NULL,
                                      mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                      ino INTEGER NOT NULL,
                                      dev INTEGER NOT NULL,
                                      sha256 TEXT NOT NULL,
                                      data BLOB NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tool (path TEXT PRIMARY KEY,
                                     size INTEGER NOT NULL,
                                     mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                     ino INTEGER NOT NULL,
                                     dev INTEGER NOT NULL,
                                     sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS scanned (path TEXT PRIMARY KEY,
                                        size INTEGER NOT NULL,
                                        mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                        ino INTEGER NOT NULL,
                                        dev INTEGER NOT NULL,
                                        sha256 TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS linked (path TEXT PRIMARY KEY,
                                       size INTEGER NOT NULL,
                                       mtime_ns INTEGER,
                                      ctime_ns INTEGER,
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
work.schema[#work.schema + 1] = [[CREATE TABLE IF NOT EXISTS tool_discovery (
  path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER,
  ctime_ns INTEGER, ino INTEGER NOT NULL, dev INTEGER NOT NULL) WITHOUT ROWID]]
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
    [[CREATE TABLE IF NOT EXISTS web_assets (name TEXT PRIMARY KEY,
                                           data BLOB NOT NULL,
                                           sha256 TEXT NOT NULL,
                                           sha384 TEXT NOT NULL,
                                           version TEXT NOT NULL) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS compiled (key TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         lua TEXT NOT NULL,
                                         bytecode BLOB NOT NULL,
                                         seen INTEGER NOT NULL,
                                         fact_wraps INTEGER NOT NULL DEFAULT 0,
                                         parameter_checks INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID]],
    [[CREATE INDEX IF NOT EXISTS compiled_by_checks ON compiled (key, seen, fact_wraps, parameter_checks)]],
    [[CREATE TABLE IF NOT EXISTS deflated (source_hash TEXT NOT NULL,
                                         core TEXT NOT NULL,
                                         data BLOB NOT NULL,
                                         PRIMARY KEY (source_hash, core)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS deflated_bytecode (key TEXT NOT NULL,
                                                  core TEXT NOT NULL,
                                                  data BLOB NOT NULL,
                                                  PRIMARY KEY (key, core)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS compressed (path TEXT NOT NULL,
                                           sha256 TEXT NOT NULL,
                                           rules TEXT NOT NULL,
                                           core TEXT NOT NULL,
                                           gzip BLOB,
                                           zstd BLOB,
                                           PRIMARY KEY (path, sha256, rules, core)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS link_answers (kind TEXT NOT NULL,
                                          path TEXT NOT NULL,
                                          value TEXT NOT NULL,
                                          found INTEGER NOT NULL,
                                          PRIMARY KEY (kind, path)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS link_fill (fingerprint TEXT NOT NULL)]],
    [[CREATE TABLE IF NOT EXISTS link_fill_rows (module TEXT NOT NULL,
                                               symbol TEXT NOT NULL,
                                               path TEXT NOT NULL,
                                               anchor TEXT NOT NULL,
                                               from_file TEXT NOT NULL,
                                               line INTEGER NOT NULL,
                                               column INTEGER NOT NULL,
                                               from_module TEXT NOT NULL,
                                               kind TEXT NOT NULL,
                                               form TEXT NOT NULL,
                                               source TEXT NOT NULL,
                                               text TEXT NOT NULL,
                                               PRIMARY KEY (module, symbol, path, anchor,
                                                            from_file, line, column))
                                              WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS compiled_interface (ikey TEXT PRIMARY KEY,
                                                   key TEXT NOT NULL) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS stub_holds (key TEXT NOT NULL,
                                              stub TEXT NOT NULL,
                                              held INTEGER NOT NULL,
                                              PRIMARY KEY (key, stub)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS key_memo (path TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         file TEXT NOT NULL,
                                         key TEXT NOT NULL,
                                         graph TEXT NOT NULL) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS key_frags (slot TEXT PRIMARY KEY,
                                          tool TEXT NOT NULL,
                                          digest TEXT NOT NULL) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS typed_refs (key TEXT NOT NULL,
                                           ordinal INTEGER NOT NULL,
                                           module TEXT NOT NULL,
                                           member TEXT NOT NULL,
                                           line INTEGER NOT NULL,
                                           PRIMARY KEY (key, ordinal)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS plan (path TEXT PRIMARY KEY,
                                     key TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS keys_memo (id INTEGER PRIMARY KEY,
                                          fp TEXT NOT NULL UNIQUE,
                                          body TEXT NOT NULL)]],
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
    [[CREATE TABLE IF NOT EXISTS type_violations (ran_at_ns INTEGER NOT NULL,
                                                kind TEXT NOT NULL,
                                                site TEXT NOT NULL,
                                                target TEXT NOT NULL,
                                                declared TEXT NOT NULL,
                                                actual TEXT NOT NULL,
                                                count INTEGER NOT NULL,
                                                test TEXT NOT NULL,
                                                PRIMARY KEY (kind, site, target, declared,
                                                             actual)) WITHOUT ROWID]],
    [[CREATE TABLE IF NOT EXISTS type_violation_tests (test TEXT NOT NULL,
                                                     kind TEXT NOT NULL,
                                                     site TEXT NOT NULL,
                                                     target TEXT NOT NULL,
                                                     declared TEXT NOT NULL,
                                                     actual TEXT NOT NULL,
                                                     count INTEGER NOT NULL,
                                                     PRIMARY KEY (test, kind, site, target, declared,
                                                                  actual)) WITHOUT ROWID]],
}) do
  work.schema[#work.schema + 1] = statement
end

local text = bind.text

local integer = bind.integer

--- One column of one row, read as the integer it was written as.
local function integer_of(rows: Sqlite.Rows): integer
  if #rows == 0 then
    return 0
  end
  return math.tointeger(tonumber(rows[1]:text(1)) or 0) or 0
end

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

--- What a step that takes the write lock did: took it and went on
--- ("done"), or, waiting for no other run ([`work.try_open`]), found
--- another holding it ("busy").
local enum Took
  "done"
  "busy"
end

--- Begins the run's transaction on `db`, the working database at `path`,
--- waiting up to `wait_ns` for another run that holds it and saying so
--- after `notice_ns`. The handle keeps the long wait for every statement
--- after ([`work.begin`]'s transactions among them). Unless `wait`, it
--- waits for no other run: where one holds the lock it answers "busy".
local function begin_waiting(db: Sqlite.Handle, path: string, wait: boolean): Took?, string
  if not wait then
    db:busy_timeout(0)
    local tried = db:exec_result("BEGIN IMMEDIATE")
    db:busy_timeout(wait_ns)
    if tried.code == Sqlite.OK then return "done", "" end
    if tried.code == Sqlite.BUSY then return "busy", "" end
    return nil, tried.reason
  end
  db:busy_timeout(notice_ns)
  local begun = db:exec_result("BEGIN IMMEDIATE")
  db:busy_timeout(wait_ns)
  if begun.cancelled == true then return nil, "interrupted while waiting for the write lock" end
  if begun.code == Sqlite.OK then
    return "done", ""
  end
  if begun.code ~= Sqlite.BUSY then
    return nil, begun.reason
  end
  log:complain("another cosmic run holds " .. path .. "; waiting for it")
  local waited = db:exec_result("BEGIN IMMEDIATE")
  if waited.cancelled == true then return nil, "interrupted while waiting for the write lock" end
  if waited.code ~= Sqlite.OK then return nil, waited.reason end
  return "done", ""
end

--- Puts `db`, the working database at `path`, in write-ahead mode, so a
--- reader -- `cosmic lsp`'s ([`build.lsp.source`]), `cosmic docs`,
--- `cosmic sql --build` -- reads the last commit while a run holds its
--- write transaction open for minutes, and never waits on it. In the
--- rollback mode a file is made in, a writer whose cache spills, or that
--- commits, holds the file whole, and every reader waits or fails
--- "database is locked". A file already in write-ahead mode answers so
--- from its header. Switching one that is not writes the header, and
--- where another run holds the write lock SQLite answers "database is
--- locked" at once, calling no busy handler: the run waits for that
--- lock as for its own transaction ([`begin_waiting`]), lets it go, and
--- asks again. Any mode answered but "wal" is kept: a file system with
--- no shared memory, which write-ahead mode needs, leaves the file in
--- rollback mode, where its readers wait on a writer as they always
--- did. Unless `wait`, it waits for no other run, answering "busy".
local function to_wal(db: Sqlite.Handle, path: string, wait: boolean): Took?, string
  while true do
    local result = Sqlite.text_rows_result(db, "PRAGMA journal_mode = WAL")
    if result.rows ~= nil then return "done", "" end
    if result.cancelled then return nil, "interrupted while waiting for the write lock" end
    if result.code ~= Sqlite.BUSY and result.code ~= Sqlite.LOCKED then
      return nil, result.reason
    end
    local begun, begin_trouble = begin_waiting(db, path, wait)
    if begun == nil then return nil, begin_trouble end
    if begun == "busy" then return "busy", "" end
    local rolled_back, roll_trouble = db:exec("ROLLBACK")
    if not rolled_back then return nil, roll_trouble end
  end
end

--- Whether the `SELECT count(*)` in `counting` counted none. It answers
--- one row; a database that answers none is in trouble.
local function counted_none(db: Sqlite.Handle, counting: string): boolean?, string
  local counted, trouble = Sqlite.text_rows(db, counting)
  if counted == nil then
    return nil, trouble
  end
  local row = counted[1]
  if row == nil then
    return nil, "`" .. counting .. "` answered no row"
  end
  return row:text(1) == "0", ""
end

--- Creates every table the schema names, in order, in the working
--- database `db` at `path`. A fresh file's go in in one transaction,
--- which commits, and syncs, once rather than once a statement: about
--- 6 ms where a transaction a statement takes 40 or more. That one is
--- begun as the run's is ([`begin_waiting`]), so a run that meets another
--- holding the file says so while it waits. A file that has tables keeps
--- a transaction a statement, each a no-op, and waits, if it must, at the
--- run's own [`begin_waiting`]. Unless `wait`, it waits for no other
--- run, answering "busy".
local function create(db: Sqlite.Handle, path: string, wait: boolean): Took?, string
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
      local columns, columns_trouble = Sqlite.text_rows(db, "PRAGMA table_info(compiled)")
      if columns == nil then return nil, columns_trouble end
      local present = #columns == 0
      for _, column in ipairs(columns) do
        if column:text(2) == name then present = true end
      end
      if not present then
        local added, add_trouble = db:exec("ALTER TABLE compiled ADD COLUMN " .. name .. " INTEGER NOT NULL DEFAULT 0")
        if not added then
          local again, again_trouble = Sqlite.text_rows(db, "PRAGMA table_info(compiled)")
          if again == nil then return nil, again_trouble end
          local now_present = false
          for _, column in ipairs(again) do
            if column:text(2) == name then now_present = true end
          end
          if not now_present then return nil, add_trouble end
        end
      end
    end
    local dropped, drop_trouble = db:exec("DROP INDEX IF EXISTS compiled_by_seen")
    if not dropped then return nil, drop_trouble end
  end
  if fresh then
    local begun, begin_trouble = begin_waiting(db, path, wait)
    if begun == nil then return nil, begin_trouble end
    if begun == "busy" then return "busy", "" end
  end
  for _, statement in ipairs(work.schema) do
    local ok, trouble = db:exec(statement)
    if not ok then
      if fresh then
        local _, _ = db:exec("ROLLBACK")
      end
      return nil, trouble
    end
  end
  if fresh then
    local committed, commit_trouble = db:exec("COMMIT")
    if not committed then return nil, commit_trouble end
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
  local tables, table_trouble = Sqlite.text_rows(db,
    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
  if tables == nil then return nil, table_trouble end
  if assert(tables[1]):text(1) == "0" then return nil, "" end
  local versions, version_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'schema'")
  if versions == nil then return nil, version_trouble end
  local row = versions[1]
  if row == nil then return nil, "" end
  return row:text(1), ""
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
      return false, remove_trouble
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
--- answers one of another schema with no handle, having read nothing
--- else of it. Unless `wait`, it waits for no other run, for neither
--- lock ([`work.try_open`]). `locked` says the rebuild lock is held for
--- the open already: by this process, or a parent that handed it on.
local function opened(root: string, dir: string?, wait: boolean,
                      remake: string, locked: boolean): work.Opening?, string
  local out: string
  if dir == nil then
    local found, directory_trouble = build_paths.prepare(root)
    if found == nil then return nil, directory_trouble end
    out = found
  else
    local made, mkdir_trouble = Fs.mkdirs(dir)
    if not made then
      return nil, mkdir_trouble
    end
    out = dir
  end
  local path = build_paths.under(out).working
  -- Before the open, and once it has written: a file put at the path
  -- between the two is opened anew.
  local before = identity_of(path)
  local db, open_trouble = Sqlite.open(path, { writable = true })
  if db == nil then
    return nil, path .. ": " .. open_trouble
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
    return nil, path .. ": " .. encode_trouble
  end
  -- After the encoding: on a fresh file the switch is the first write,
  -- which fixes the encoding.
  local logged, log_trouble = to_wal(db, path, wait)
  -- Whatever the switch answered, a file put at the path since the open,
  -- or removed, as another run may while this one waits for its lock, is
  -- opened anew. SQLite refuses to write to the file it opened once
  -- moved ("attempt to write a readonly database"), and a file removed
  -- under a run is one it would build in unlinked.
  local file = identity_of(path)
  if file == "" or (before ~= "" and file ~= before) then
    local _, _ = db:close()
    return opened(root, dir, wait, remake, locked)
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
      local again, again_trouble = opened(root, dir, wait, remake, true)
      if took then rebuild_lock.release() end
      if again == nil then return nil, again_trouble end
      return again, ""
    end
    -- The write lock next: a run building in the file holds it till its
    -- commit.
    local begun, begin_trouble = begin_waiting(db, path, wait)
    if begun ~= "done" then
      local _, _ = db:close()
      if begun == "busy" then return { handle = nil, other_schema = found }, "" end
      return nil, path .. ": " .. begin_trouble
    end
    local gone, gone_trouble = let_go_of_another_schema(db, path, file)
    if not gone then return nil, gone_trouble end
    return opened(root, dir, wait, remake, locked)
  end

  local created, create_trouble = create(db, path, wait)
  if created ~= "done" then
    local _, _ = db:close()
    if created == "busy" then return { handle = nil, other_schema = nil }, "" end
    return nil, path .. ": " .. create_trouble
  end

  -- IMMEDIATE takes the write lock before reading, so a second build of
  -- the same tree waits for the first ([`begin_waiting`]) instead of both
  -- reading and then one failing to upgrade.
  local begun, begin_trouble = begin_waiting(db, path, wait)
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
    return opened(root, dir, wait, remake, locked)
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
    return opened(root, dir, wait, remake, locked)
  end
  -- Old rows have no change time: retain their content caches, but read
  -- their files once before trusting metadata again.
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local columns, trouble = Sqlite.text_rows(db, "PRAGMA table_info(" .. table_name .. ")")
    if columns == nil then
      local _, _ = db:close()
      return nil, trouble
    end
    local has_ctime = false
    for _, column in ipairs(columns) do
      if column:text(2) == "ctime_ns" then has_ctime = true end
    end
    if not has_ctime then
      local added, why = db:exec("ALTER TABLE " .. table_name .. " ADD COLUMN ctime_ns INTEGER")
      if not added then
        local _, _ = db:close()
        return nil, why
      end
    end
  end
  local stamp, stamp_trouble = Sqlite.run(db,
    "INSERT INTO meta (key, value) VALUES ('schema', ?1) " ..
      "ON CONFLICT (key) DO NOTHING", { text(version) })
  if not stamp then
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
  return { handle = { db = db, root = root, dir = out, run = integer_of(runs), inside = true, standing = nil },
    other_schema = nil }, ""
end

--- Opens `build.db` in `dir`, or where nil in `root`'s build directory,
--- which [`build.paths`] names and makes, waiting for another run that
--- holds its write lock, as a build does ([`opened`]).
function work.open(root: string, dir?: string): work.Handle?, string
  local found, trouble = opened(root, dir, true, "any", false)
  if found == nil then return nil, trouble end
  local handle = found.handle
  if handle == nil then return nil, "another cosmic run holds the write lock" end
  return handle, ""
end

--- Opens `root`'s working database as [`work.open`] does, but waits for
--- no other run: where another holds its write lock it answers an
--- opening with no handle. A verb that only reads ([`rebuild.here`]) or
--- `cosmic lsp`'s stage ([`rebuild.stage`]) opens it so: the run
--- holding the lock builds the same tree, and what it last committed is
--- read meanwhile, never waited for. A file of another schema it neither
--- reads nor removes, whoever holds the lock: it answers no handle, and
--- the schema it found (`other_schema`).
function work.try_open(root: string): work.Opening?, string
  return opened(root, nil, false, "never", false)
end

--- Opens `root`'s working database as [`work.try_open`] does, waiting for
--- no other run, but a file of another schema it removes and makes again
--- as [`work.open`] does, where no run holds the checkout's rebuild lock
--- ([`build.rebuild_lock`]) or the file's write lock. Where one does, it
--- answers no handle and the schema it found. The check a verb that only
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
--- a newer schema is left where it is, answered with no handle and the
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
  tell_once("busy", path, verb .. ": another cosmic run holds the write lock of " .. path ..
      "; not waiting for it, reading what it last committed")
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
local function checkpoint(db: Sqlite.Handle)
  db:busy_timeout(notice_ns)
  local _ = Sqlite.text_rows_result(db, "PRAGMA wal_checkpoint(TRUNCATE)")
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
    return false, trouble
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
    return false, trouble
  end
  handle.inside = false
  return true, ""
end

--- Opens another transaction on the run, for a phase that comes after
--- the projection: the test runner's records, written together.
function work.begin(handle: work.Handle): boolean, string
  local begun = handle.db:exec_result("BEGIN IMMEDIATE")
  if begun.cancelled == true then
    return false, "interrupted while waiting for " .. handle.dir .. "/build.db"
  end
  if begun.code ~= Sqlite.OK then return false, begun.reason end
  handle.inside = true
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
  local statement, trouble = db:prepare(
    "SELECT path, size, mtime_ns, ino, dev, mtime_ns IS NULL, ctime_ns, ctime_ns IS NULL FROM " .. table_name)
  if statement == nil then
    return nil, trouble
  end
  local out: mut {string:Known} = {}
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
      ctime_ns = statement:integer(7) == 0 and statement:integer(6) or nil,
      ino = statement:integer(3),
      dev = statement:integer(4),
    }
  end
  statement:finalize()
  return out, ""
end

--- `files` keeps the bytes; `tool` and `scanned` keep only what a stat
--- and a hash say about them. The put for each takes the bytes as its
--- sixth parameter and their hash, made once per read, as its seventh;
--- `todo` is one TODO's row.
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
}

--- The largest file `scanned` reads for TODOs.
local scanned_limit = 1024 * 1024

local once = bind.once

--- How long a file's modification and change times must be in the past before
--- a stat is trusted to stand for its bytes.
local settle_ns = Clock.seconds(2)

--- Whether a file's row no longer stands for it, consuming the row
--- from `known` either way, so what is left in `known` at the end is
--- what the walk no longer finds.
local function moved(known: mut {string:Known}, file: string, st: sys.Stat,
                     mtime_ns: integer): boolean
  local was = known[file]
  known[file] = nil
  local was_mtime_ns = was and was.mtime_ns
  local ctime_ns = was and was.ctime_ns
  return was == nil or was.size ~= st.size or was_mtime_ns == nil or
    was_mtime_ns ~= mtime_ns or ctime_ns == nil or
    st.ctime_ns == nil or ctime_ns ~= Clock.seconds(st.ctime) + st.ctime_ns or
    was.ino ~= st.ino or was.dev ~= st.dev
end

--- Whether the tool's recorded files or discovery directories moved. The
--- same walk that stages inputs records its directories, so a new input
--- invalidates the fast path without listing an unchanged tree again.
function work.tool_moved(handle: work.Handle): boolean?, string
  for _, table_name in ipairs({ "tool", "tool_discovery" }) do
    local known, trouble = known_in(handle.db, table_name)
    if known == nil then return nil, trouble end
    if table_name == "tool_discovery" and known[""] == nil then return true, "" end
    for path in pairs(known) do
      local st, _ = Fs.stat(handle.root .. "/" .. path)
      if st == nil then return true, "" end
      local mtime_ns = Clock.seconds(st.mtime) + st.mtime_ns
      if moved(known, path, st, mtime_ns) then return true, "" end
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
  if bound then
    if settled and st.ctime_ns ~= nil then
      bound, trouble = put:bind_integer(9, Clock.seconds(st.ctime) + st.ctime_ns)
    else
      bound, trouble = put:bind_null(9)
    end
  end
  if not bound then
    return false, file .. ": " .. trouble
  end
  return once(put)
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

--- Records the TODOs in one file's bytes under their hash, unless a
--- file with the same bytes already has: text that parses as a patch
--- record is scanned as one wherever it sits, since the rows are keyed
--- by the bytes alone. Text holding no `TODO:`, or holding a NUL,
--- is not scanned.
local function put_todos(put: Sqlite.Statement, data: string,
                         sha256: string): boolean, string
  if data:find("TODO:", 1, true) == nil or data:find("\0", 1, true) ~= nil then
    return true, ""
  end
  local scanned = todo_scan.scan_record(data) or todo_scan.scan(data)
  for _, found in ipairs(scanned) do
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

--- Why the static asset `file` of `root` (whose real path is `real_root`)
--- cannot be carried, or nil: what [`identity.static_refusal`] refuses by
--- name and size, a spelling that differs from another staged one only in
--- case (`seen`, by lowercase spelling: a tree must build the same on a
--- case-insensitive disk), and a link that leads out of the project, which
--- would make the executable depend on files outside the checkout.
local function static_refusal(root: string, real_root: string, file: string, size: integer,
                              seen: mut {string:string}): string?
  local refusal = identity.static_refusal(file, size)
  if refusal ~= nil then return refusal end
  local lowered = file:lower()
  local earlier = seen[lowered]
  if earlier ~= nil and earlier ~= file then
    return ("%s: differs from %s only in case; rename one, so the tree builds the same on a " ..
      "case-insensitive disk"):format(file, earlier)
  end
  seen[lowered] = file
  local real, trouble = Fs.absolute(root .. "/" .. file)
  if real == nil then return trouble end
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
  mut ancestors: {string:boolean}?
  mut above: string
end

--- What [`work.stage`] told `handle` its root is. Raises on a handle that was not staged: every compile and write
--- reads a staged tree.
function work.standing(handle: work.Handle): tree.Standing
  return (assert(handle.standing, "the tree was not staged: work.stage tells a handle what its root is"))
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
  local db = handle.db
  local root = handle.root
  handle.standing = standing
  local own_tree = standing.own
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
    if st == nil then return nil, trouble end
    discovery[""] = st
  end
  local skip_path = own_tree and identity.skip_in_own_tree or identity.skip_input
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
  local walked, walk_trouble = Fs.walk_following(root, skip)
  if walked == nil then
    return nil, walk_trouble
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
  for _, name in ipairs({ "files", "tool", "scanned", "linked", "todo" }) do
    local statement, trouble = db:prepare((assert(puts[name], "every name listed has its put")))
    if statement == nil then
      finish(put)
      return nil, trouble
    end
    put[name] = statement
  end
  -- Prepared by the loop above, one for each name it lists.
  local put_files = assert(put["files"], "every put was prepared")
  local put_tool = assert(put["tool"], "every put was prepared")
  local put_scanned = assert(put["scanned"], "every put was prepared")
  local put_linked = assert(put["linked"], "every put was prepared")
  local put_todo = assert(put["todo"], "every put was prepared")
  local now = Clock.now_ns()
  local staged: work.Staged = { files = 0, read = 0, notes = {} }
  -- The real path of `root`, once a static asset asks for it, and the
  -- static paths seen by their lowercase spelling.
  local real_root: string? = nil
  local static_seen: mut {string:string} = {}
  -- The text of each file of `linked` read here, by path.
  local texts: mut {string:string} = {}

  for _, file in ipairs(files) do
    local only = links_only[file] == true
    local input = not only and is_input(file, own_tree)
    local tool = not only and identity.is_tool(file, own_tree)
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
    if input and identity.is_static(file) then
      local static_root: string
      if real_root ~= nil then
        static_root = real_root
      else
        local resolved, resolve_trouble = Fs.absolute(root)
        if resolved == nil then
          finish(put)
          return nil, resolve_trouble
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
      local settled = st.ctime_ns ~= nil and
        math.max(mtime_ns, Clock.seconds(st.ctime) + st.ctime_ns) < now - settle_ns
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
        if write_files and identity.is_static(file) and
            (file:match("%.tl$") ~= nil or file:match("%.tmpl$") ~= nil) then
          local note = file .. ": under static/, so it is carried as an asset and is no module"
          staged.notes[#staged.notes + 1] = note
          log:complain(note)
        end
        local sha256 = Hash.hex_sha256(data)
        if (input or tool or scan) and holds_own_todos(file) then
          local ok, why = put_todos(put_todo, data, sha256)
          if not ok then
            finish(put)
            return nil, file .. ": " .. why
          end
        end
        local stat, content: sys.Stat, string = st, data
        local function write(wanted: boolean, statement: Sqlite.Statement): boolean, string
          if not wanted then
            return true, ""
          end
          return put_row(statement, file, stat, mtime_ns, settled, content, sha256)
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
          ok, why = put_linked:bind_text(8, link_kind)
          if ok then
            ok, why = write(true, put_linked)
          end
        end
        if not ok then
          finish(put)
          return nil, file .. ": " .. why
        end
      end
    end
  end
  if own_tree then
    local cleared, trouble = db:exec("DELETE FROM tool_discovery")
    if not cleared then
      finish(put)
      return nil, trouble
    end
    local discovery_put, prepare_trouble = db:prepare(
      "INSERT INTO tool_discovery (path, size, mtime_ns, ctime_ns, ino, dev) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    if discovery_put == nil then
      finish(put)
      return nil, prepare_trouble
    end
    for path, st in pairs(discovery) do
      local mtime_ns = Clock.seconds(st.mtime) + st.mtime_ns
      local ctime_ns = if st.ctime_ns ~= nil then Clock.seconds(st.ctime) + st.ctime_ns else nil end
      local settled = ctime_ns ~= nil and math.max(mtime_ns, ctime_ns) < now - settle_ns
      local saved, why = discovery_put:bind_text(1, path)
      if saved then saved, why = discovery_put:bind_integer(2, st.size) end
      if saved then
        if settled then
          saved, why = discovery_put:bind_integer(3, mtime_ns)
        else
          saved, why = discovery_put:bind_null(3)
        end
      end
      if saved then
        if settled then
          saved, why = discovery_put:bind_integer(4, ctime_ns or 0)
        else
          saved, why = discovery_put:bind_null(4)
        end
      end
      if saved then saved, why = discovery_put:bind_integer(5, st.ino) end
      if saved then saved, why = discovery_put:bind_integer(6, st.dev) end
      if saved then saved, why = once(discovery_put) end
      if not saved then
        discovery_put:finalize()
        finish(put)
        return nil, why
      end
    end
    discovery_put:finalize()
  end
  finish(put)
  for _, table_name in ipairs({ "files", "tool", "scanned", "linked" }) do
    local forgot, forget_trouble = forget(db, table_name,
      (assert(known[table_name], "every table forgotten was read above")))
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
  local by, by_trouble = running_tool(db)
  if by == nil then
    return nil, by_trouble
  end
  local recorded, record_trouble = Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('staged_by', ?1)", { text(by) })
  if not recorded then
    return nil, record_trouble
  end
  return staged, ""
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
  local rows, trouble = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'staged_by'")
  if rows == nil then
    return nil, trouble
  end
  local row = rows[1]
  if row == nil then
    return "", ""
  end
  local recorded = row:text(1)
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
local function links_finder(db: Sqlite.Handle): string?, string
  local boot_hash = Store.meta("boot_hash")
  if boot_hash == nil then
    local fingerprint, trouble = identity.hash_over(db, "1")
    if fingerprint == nil then
      return nil, trouble
    end
    local ok, record_trouble = Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('links_boot', ?1)", { text(fingerprint) })
    if not ok then
      return nil, record_trouble
    end
    return fingerprint, ""
  end
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT key, value FROM meta WHERE key IN ('links_boot', 'links_by')")
  if last == nil then
    return nil, last_trouble
  end
  local recorded: mut {string:string} = {}
  for _, row in ipairs(last) do recorded[row:text(1)] = row:text(2) end
  if recorded["links_boot"] == boot_hash and recorded["links_by"] ~= nil then
    return recorded["links_by"], ""
  end
  local reached: mut {string:boolean} = {}
  local stack: mut {string} = { "build.link_files" }
  while #stack > 0 do
    local name = table.remove(stack)
    if name ~= nil and reached[name] ~= true then
      reached[name] = true
      local required, trouble = Store.requires(name)
      if required == nil then
        return nil, trouble
      end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reached) do names[#names + 1] = name end
  table.sort(names)
  local parts: mut {string} = {}
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
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'links_by'")
  if last == nil then
    return false, last_trouble
  end
  if #last == 0 or last[1]:text(1) ~= finder then
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
    local path, kind, sha256 = row:text(1), row:text(2), row:text(3)
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
            { integer = if entry.own then 1 else 0 end } })
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

--- Every TZif file under `dir`, a `zoneinfo` tree as `vendor/tzdata`
--- holds it, by zone name: its path under `dir`. A zone that is a link
--- to another (as a system zoneinfo's aliases are) is read as the zone
--- it leads to, under its own name.
function work.read_zoneinfo(dir: string): {string:string}?, string
  local names, trouble = Fs.walk_following(dir)
  if names == nil then
    return nil, trouble
  end
  local zones: mut {string:string} = {}
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
  local rows, rows_trouble = Sqlite.rows(db, "SELECT name, data FROM zoneinfo")
  if rows == nil then
    return nil, rows_trouble
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
    return false, trouble
  end
  local names: mut {string} = {}
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
      return nil, pin_trouble
    end
    local pinned = pin:match("^version%s+(%S+)") or pin:match("\nversion%s+(%S+)")
    if pinned == nil then
      return nil, vendor .. "/" .. file.tree .. "/PIN names no version"
    end
    local data, read_trouble = Fs.read(vendor .. "/" .. file.tree .. "/" .. file.path)
    if data == nil then
      return nil, read_trouble
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
  local rows, rows_trouble = Sqlite.rows(db,
    "SELECT name, data, sha256, sha384, version FROM web_assets ORDER BY name")
  if rows == nil then
    return nil, rows_trouble
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
    return false, trouble
  end
  for _, asset in ipairs(assets) do
    local ok, why = Sqlite.run(handle.db,
      "INSERT INTO web_assets (name, data, sha256, sha384, version) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(asset.name), { blob = asset.data }, text(asset.sha256), text(asset.sha384),
        text(asset.version) })
    if not ok then
      return false, why
    end
  end
  return true, ""
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
