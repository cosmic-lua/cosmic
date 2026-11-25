--- The schema of the working database, `build.db` ([`build.work`]), in a module of its own, which requires only
--- [`build.analysis_schema`]: a module that [`build.work`] requires may take a handle of it by its type without requiring
--- [`build.work`] back. The modules of the compiler's, the analyzer's and the writer's identities (plans, derivation,
--- identity, link_index, the importer) take it by type too, so the checker reads their SQL: an edit to these tables
--- moves those identities, which is right, since it changes what they read.

local analysis_schema = require("build.analysis_schema")

--- The statements of the stage: `meta` to `tool_discovery`.
local STAGE <const> = [[CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,
                                     value BLOB NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY,
                                      size INTEGER NOT NULL,
                                      mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                      ino INTEGER NOT NULL,
                                      dev INTEGER NOT NULL,
                                      sha256 TEXT NOT NULL,
                                      data BLOB NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS tool (path TEXT PRIMARY KEY,
                                     size INTEGER NOT NULL,
                                     mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                     ino INTEGER NOT NULL,
                                     dev INTEGER NOT NULL,
                                     sha256 TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS scanned (path TEXT PRIMARY KEY,
                                        size INTEGER NOT NULL,
                                        mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                        ino INTEGER NOT NULL,
                                        dev INTEGER NOT NULL,
                                        sha256 TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS linked (path TEXT PRIMARY KEY,
                                       size INTEGER NOT NULL,
                                       mtime_ns INTEGER,
                                      ctime_ns INTEGER,
                                       ino INTEGER NOT NULL,
                                       dev INTEGER NOT NULL,
                                       sha256 TEXT NOT NULL,
                                       kind TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS linked_texts (sha256 TEXT NOT NULL,
                                             kind TEXT NOT NULL,
                                             PRIMARY KEY (sha256, kind)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS linked_found (sha256 TEXT NOT NULL,
                                             kind TEXT NOT NULL,
                                             ordinal INTEGER NOT NULL,
                                             line INTEGER NOT NULL,
                                             column INTEGER NOT NULL,
                                             form TEXT NOT NULL,
                                             text TEXT NOT NULL,
                                             target TEXT NOT NULL,
                                             own INTEGER NOT NULL,
                                             PRIMARY KEY (sha256, kind, ordinal)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS tool_discovery (
  path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER,
  ctime_ns INTEGER, ino INTEGER NOT NULL, dev INTEGER NOT NULL) WITHOUT ROWID]]

--- The statements of the records: `todos` to `type_violation_tests`.
local RECORDS <const> = [[CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY,
                                      sha256 TEXT NOT NULL,
                                      line INTEGER NOT NULL,
                                      last INTEGER NOT NULL,
                                      text TEXT NOT NULL,
                                      UNIQUE (sha256, line))]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS todo_misses (sha256 TEXT NOT NULL,
                                            line INTEGER NOT NULL,
                                            spelling TEXT NOT NULL,
                                            PRIMARY KEY (sha256, line)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE VIRTUAL TABLE IF NOT EXISTS todos_fts
      USING fts5(text, content=todos, content_rowid=id)]] .. ";\n" ..
  [[CREATE TRIGGER IF NOT EXISTS todos_inserted AFTER INSERT ON todos BEGIN
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text);
    END]] .. ";\n" ..
  [[CREATE TRIGGER IF NOT EXISTS todos_deleted AFTER DELETE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END]] .. ";\n" ..
  [[CREATE TRIGGER IF NOT EXISTS todos_updated AFTER UPDATE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text);
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text);
    END]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS blames (path TEXT NOT NULL,
                                       line INTEGER NOT NULL,
                                       sha256 TEXT NOT NULL,
                                       head TEXT NOT NULL,
                                       commit_id TEXT NOT NULL,
                                       author_time INTEGER NOT NULL,
                                       summary TEXT NOT NULL,
                                       boundary INTEGER NOT NULL,
                                       PRIMARY KEY (path, line)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS zoneinfo (name TEXT PRIMARY KEY,
                                         data BLOB NOT NULL)]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS web_assets (name TEXT PRIMARY KEY,
                                           data BLOB NOT NULL,
                                           sha256 TEXT NOT NULL,
                                           sha384 TEXT NOT NULL,
                                           version TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS compiled (key TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         lua TEXT NOT NULL,
                                         bytecode BLOB NOT NULL,
                                         seen INTEGER NOT NULL,
                                         fact_wraps INTEGER NOT NULL DEFAULT 0,
                                         parameter_checks INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE INDEX IF NOT EXISTS compiled_by_checks ON compiled (key, seen, fact_wraps, parameter_checks)]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS deflated (source_hash TEXT NOT NULL,
                                         core TEXT NOT NULL,
                                         data BLOB NOT NULL,
                                         PRIMARY KEY (source_hash, core)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS code_hashes (source_hash TEXT NOT NULL,
                                            by TEXT NOT NULL,
                                            code_hash TEXT NOT NULL,
                                            PRIMARY KEY (source_hash, by)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS kept_bytecode (key TEXT PRIMARY KEY NOT NULL,
                                              data BLOB NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS compressed (path TEXT NOT NULL,
                                           sha256 TEXT NOT NULL,
                                           rules TEXT NOT NULL,
                                           core TEXT NOT NULL,
                                           gzip BLOB,
                                           zstd BLOB,
                                           PRIMARY KEY (path, sha256, rules, core)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS link_answers (kind TEXT NOT NULL,
                                          path TEXT NOT NULL,
                                          value TEXT NOT NULL,
                                          found INTEGER NOT NULL,
                                          PRIMARY KEY (kind, path)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS link_fill (fingerprint TEXT NOT NULL)]] .. ";\n" ..
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
                                              WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS compiled_interface (ikey TEXT PRIMARY KEY,
                                                   key TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS stub_holds (key TEXT NOT NULL,
                                              stub TEXT NOT NULL,
                                              held INTEGER NOT NULL,
                                              PRIMARY KEY (key, stub)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS key_memo (path TEXT PRIMARY KEY,
                                         tool TEXT NOT NULL,
                                         file TEXT NOT NULL,
                                         key TEXT NOT NULL,
                                         graph TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS key_frags (slot TEXT PRIMARY KEY,
                                          tool TEXT NOT NULL,
                                          digest TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS typed_refs (key TEXT NOT NULL,
                                           ordinal INTEGER NOT NULL,
                                           module TEXT NOT NULL,
                                           member TEXT NOT NULL,
                                           line INTEGER NOT NULL,
                                           PRIMARY KEY (key, ordinal)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS plan (path TEXT PRIMARY KEY,
                                     key TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS keys_memo (id INTEGER PRIMARY KEY,
                                          fp TEXT NOT NULL UNIQUE,
                                          body TEXT NOT NULL)]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS builds (run INTEGER PRIMARY KEY,
                                       ms INTEGER NOT NULL,
                                       files INTEGER NOT NULL,
                                       read INTEGER NOT NULL,
                                       compiled INTEGER NOT NULL,
                                       cached INTEGER NOT NULL,
                                       verdict TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS runs (path TEXT NOT NULL,
                                     test TEXT NOT NULL,
                                     passed INTEGER NOT NULL,
                                     message TEXT NOT NULL,
                                     ran_at_ns INTEGER NOT NULL,
                                     key TEXT NOT NULL,
                                     run_at_ns INTEGER NOT NULL,
                                     elapsed_ns INTEGER NOT NULL,
                                     PRIMARY KEY (path, test)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS failures (path TEXT NOT NULL,
                                         test TEXT NOT NULL,
                                         message TEXT NOT NULL,
                                         ran_at_ns INTEGER NOT NULL,
                                         key TEXT NOT NULL,
                                         run_at_ns INTEGER NOT NULL,
                                         PRIMARY KEY (path, test, ran_at_ns)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS verdicts (key TEXT PRIMARY KEY,
                                         passed INTEGER NOT NULL,
                                         run_at_ns INTEGER NOT NULL,
                                         seen INTEGER NOT NULL,
                                         elapsed_ns INTEGER NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS digests (path TEXT PRIMARY KEY,
                                        signature TEXT NOT NULL,
                                        sha256 TEXT NOT NULL) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS test_runs (ran_at_ns INTEGER NOT NULL
                                          PRIMARY KEY)]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS coverage (ran_at_ns INTEGER NOT NULL,
                                         path TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         hit INTEGER NOT NULL,
                                         PRIMARY KEY (ran_at_ns, path, line))
                                        WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS hits_by_test (ran_at_ns INTEGER NOT NULL,
                                             test TEXT NOT NULL,
                                             hits TEXT NOT NULL,
                                             PRIMARY KEY (ran_at_ns, test))]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS coverage_by_test (ran_at_ns INTEGER NOT NULL,
                                                 test TEXT NOT NULL,
                                                 hits TEXT NOT NULL,
                                                 PRIMARY KEY (ran_at_ns, test))]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS type_violations (ran_at_ns INTEGER NOT NULL,
                                                kind TEXT NOT NULL,
                                                site TEXT NOT NULL,
                                                target TEXT NOT NULL,
                                                declared TEXT NOT NULL,
                                                actual TEXT NOT NULL,
                                                count INTEGER NOT NULL,
                                                test TEXT NOT NULL,
                                                PRIMARY KEY (kind, site, target, declared,
                                                             actual)) WITHOUT ROWID]] .. ";\n" ..
  [[CREATE TABLE IF NOT EXISTS type_violation_tests (test TEXT NOT NULL,
                                                     kind TEXT NOT NULL,
                                                     site TEXT NOT NULL,
                                                     target TEXT NOT NULL,
                                                     declared TEXT NOT NULL,
                                                     actual TEXT NOT NULL,
                                                     count INTEGER NOT NULL,
                                                     PRIMARY KEY (test, kind, site, target, declared,
                                                                  actual)) WITHOUT ROWID]]

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
--- `files` but excluded from `tool` ([`build.identity.is_tool`]). A vendored tree is
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
--- [`build.work`]'s `scanned_limit` is left out, as data rather than text.
---
--- `linked` is every file whose links `cosmic fix` checks that is not
--- Teal ([`build.link_files.checked`]): its Markdown, its Zig and, in cosmic's
--- own tree, its C, but for a tree of its own inside it (`ci/`).
--- Fingerprinted like `tool`, with the kind of file it is, and read to
--- find its links: `linked_found` holds each link as [`build.link_files.found`]
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
--- `links` is each link its comments hold ([`cosmic.internal.link_text`]), as
--- written: what it names is resolved only once every module is
--- known, as a projection is written ([`build.link_index`]).
--- `stubs` is the stub of a source (build.stub): the text a
--- project's checker reads in place of a module's, which cosmic's own
--- projection carries for its standard library, and whether it is
--- declaration-only. Every source with a top-level `return` has one,
--- though only those modules' are read: a test has none.
--- `globals` is where each `global` declaration of a source starts
--- (build.globals), a row each by line and column: the rows a build
--- refuses from ([`build.plans`]'s `global_refusals`) without
--- reading a source again. A guide's example is at the line of the
--- module extracted from the guide.
--- `places` is where each type a source declares, and each field, method
--- and `function R.f` of one, and each value of an enum, has its name
--- ([`build.syntax_places`]): a row each by dotted symbol from the top of the module (`R`, `R.Inner`,
--- `R.f`), its kind, and the line, byte column and byte length of the
--- name, and whether that name is `plain`: its line holds only ASCII and the
--- protocol numbers the lines before it as the lexer does, so its protocol
--- character is its column less one. `cosmic lsp` finds a declaration in
--- another module by it ([`build.lsp.source`]) without parsing the module,
--- and without reading its text where the place is plain. A source derived
--- from another file (`mapped`) has the rows its `-- line` map names, at the
--- map's line of that file (column 1, length 0), and none if it has no map.
--- `members` is what each type a source declares has: a row for the type
--- (`name` ""), and one for each field, method, enum value and `function
--- R.f` of it ([`build.syntax_members`]), under the same dotted symbol as
--- `places`, with its kind, where it is offered (`scope`) and its type as
--- written. `cosmic lsp` completes the members of a module by it
--- ([`build.lsp.completion`]) without the checker's declarations of the
--- module. It is a table of its own because neither neighbour can hold
--- it: `places` has a row for where a name is declared and no more, and
--- `docs` is the documentation's view (a symbol is named as the module
--- exports it, a type no export reaches is left out, a member has no
--- scope or kind a read of it needs).
---
--- `executable` is [`build.coverage.syntax_lines.executable`]'s result for one
--- source, keyed by content hash as `parsed` is and written by the same
--- parse ([`build.syntax_derivation`]), so a source parsed here or taken
--- from another checkout's parse is never parsed again for its coverage.
--- Its rule is the analyzer's, so a change to it forgets the row with the
--- rest of the parse. Coverage writes the row of a source that has none.
--- `lines` is every executable line number in ascending order, joined by
--- single spaces (e.g. "1 3 4 9"), rather than one row per line, since a
--- caller always wants the whole set back at once.
---
--- `todos` is every `TODO:` comment [`build.todo_scan`] finds in one
--- staged file, keyed by the file's content hash like `parsed`: staging
--- scans a file in the same moment it reads it, so an unchanged file
--- costs nothing, and a row is a function of the bytes and the scan's
--- rule alone -- a change to the rule bumps [`build.work`]'s `version`, and so does one
--- to what [`build.patch`]'s [`Patch.parse`] takes as a record, whose
--- TODOs the rule reads apart. A row no
--- staged file hashes to any more is dropped at the end of the stage.
--- `todo_misses` is every comment that opens with a near miss of the
--- spelling ([`build.todo_scan.misses`]), keyed and dropped as `todos` is, so
--- `cosmic todos` can say what it did not index and how to spell it.
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
--- `code_hashes` is the hash of a module's code text ([`build.code_text`]), by the source's SHA-256 and the boot hash
--- of the tool whose lexer read it, which [`build.identity`] hashes into the tool's identities instead of lexing each
--- module on each build; it holds the running tool's rows alone.
--- `kept_bytecode` is a compile's bytecode alone, as `string.dump` wrote it,
--- by the compile's key, which a projection's modules take theirs from.
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
--- `link_answers` is what the disk gave the last time
--- [`build.link_index`]'s `pending` resolved the tree's links, by a
--- fingerprint of the links and the code that resolves them, so a run
--- that finds every result the same does not resolve them again.
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
--- name inside it, so a later run of the same test replaces its row.
--- `key` is what the verdict is a function of, the digest of the
--- test's declared inputs ([`build.declared_key`]), and, after a space,
--- the key it is shared under; `run_at_ns` the `cosmic test`
--- invocation whose coverage rows credit the verdict.
--- `elapsed_ns` is how long the test function itself took to run, by
--- [`cosmic.time`]'s monotonic clock: wall time, not CPU time. For a test
--- settled from a standing verdict it is the elapsed time of the run
--- that produced that verdict, so `runs` always tells "how long does
--- this test take", even when most tests are cached.
---
--- `failures` is the history `runs` does not keep: a row for each
--- failure a run recorded, with its `runs` `key` and `message`, the
--- newest `kept_failures` of each test ([`build.test`]'s
--- `prune_history`). A failure whose nonempty `key` is that of a later
--- pass is a flake: the same inputs gave both.
---
--- `verdicts` is one row per key ever seen, with its verdict and the
--- invocation that produced it, and `seen` the last run that relied on
--- it: while a key stands and its verdict passed, the test is not run
--- again, and an edit undone finds its old key again. One no run has
--- relied on in the last ten ([`build.test`]'s `kept_runs`) is dropped,
--- and with it the `hits_by_test` rows no verdict credits any
--- more. `elapsed_ns` carries the duration of the run that reached this
--- verdict, which `runs` reports for a test settled from it.
---
--- `digests` is the hash of each file a sandboxed run's keys looked
--- at ([`build.declared_key`]) -- declared inputs beyond what the stage
--- hashes, the tree's tool and vendor/ among them -- by absolute path,
--- with what `lstat` said of it then: a later run whose `lstat` says
--- the same reads none of them again. A sandboxed run that read one
--- writes what it looked at: a run of the whole tree in place of the
--- rest, so a file no test declares any more goes.
---
--- `test_runs`/`coverage`/`hits_by_test` are real history instead:
--- one snapshot per `cosmic test` invocation, each run identified by
--- its own start time in nanoseconds (`ran_at_ns`), the convention
--- `runs.ran_at_ns` uses. This database never ships, but its growth is
--- still bounded: [`build.test`]'s `prune_history`
--- runs in the same transaction as every write here and keeps
--- `coverage` to the newest `kept_snapshots` runs, `hits_by_test`
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
--- `hits_by_test` records what `coverage` cannot:
--- which lines a given test hit in a given run. It is one row per test
--- per run, its `hits` every line the test hit, as [`build.test`]'s
--- `take_hits` writes them, each module's lines beside the text they are
--- numbered in (a pure store's import's by instruction, which the run that
--- stands on them places), or, for a row another checkout's verdict
--- brought, as the shared verdicts hold them, under a first line that
--- says so ([`build.test`]'s `decode_kept`): one row per line hit would be millions a
--- run, and writing them, then deleting the last run's, cost a full run
--- most of its time.
---
--- `coverage_by_test` is the table of rows before `hits_by_test`: the same, but each line a number of its own, where
--- `hits_by_test` writes a run of adjacent lines as one ([`build.test`]'s `runs_of`). A binary before that reads
--- `coverage_by_test` alone, so it never reads a run as two lines. This one writes and reads none there, and prunes
--- them as before. Every key holds the code of [`build.shared_verdicts`] ([`build.test_key`]), which changed with the
--- runs, so no verdict a binary from before reached stands for this one, nor one of this for that.
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
--- does not hold ([`build.identity.compiler_identity`]).
local schema Database = STAGE .. ";\n" .. analysis_schema.Analysis.ddl .. ";\n" .. RECORDS

local record work_schema
  --- The schema of the working database: [`work_schema.statements`] joined.
  type Database = Database
  --- What creates the database, in order: the stage's statements as
  --- one, each of the analysis's (the `inputs` view on its own, which
  --- an open makes again where its text moved), then the records' as
  --- one. `IF NOT EXISTS` because the file is opened again and again
  --- across runs rather than built fresh every time.
  mut statements: mut {string}
end

work_schema.statements = { STAGE }
for _, statement in ipairs(analysis_schema.statements) do
  work_schema.statements[#work_schema.statements + 1] = statement
end
work_schema.statements[#work_schema.statements + 1] = RECORDS

return work_schema
