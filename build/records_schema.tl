--- The shape of `o/records.db`, kept apart from `build.schema` because
--- the two databases keep apart what they promise: `o/cosmic.db` is a
--- pure function of the tree, byte-identical from any build of it, and
--- `o/records.db` is a log of what happened on one host on one run --
--- wall-clock time, pass or fail, what a test was observed to read --
--- which is allowed, expected even, to differ the next time. It is
--- never shipped and never attached to the tree's own database.
---
--- `runs` holds one row per test, keyed by the module and the test's
--- own name inside it, so a later run of the same test replaces its
--- row rather than piling up a history the runner has no use for yet.
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

local record records_schema
  tables: {string}
  settings: {string}
end

--- The statements that create the database, in order. `IF NOT EXISTS`
--- because, unlike `build.schema`'s tables, this file is meant to be
--- opened again and again across runs rather than built fresh every
--- time.
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
records_schema.tables = {
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

--- The same settings `o/cosmic.db` states outright, so the two files
--- agree on encoding even though only one of them promises to be
--- byte-identical across builds.
records_schema.settings = {
  "PRAGMA encoding = 'UTF-8'",
}

return records_schema
