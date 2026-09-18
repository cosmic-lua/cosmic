--- The shape of `o/records.db`, kept apart from `build.schema` because
--- the two databases keep apart what they promise: `o/cosmic.db` is a
--- pure function of the tree, byte-identical from any build of it, and
--- `o/records.db` is a log of what happened on one host on one run --
--- wall-clock time, pass or fail, what a test was observed to read --
--- which is allowed, expected even, to differ the next time. It is
--- never shipped and never attached to the tree's own database.
---
--- One row per test, keyed by the module and the test's own name
--- inside it, so a later run of the same test replaces its row rather
--- than piling up a history the runner has no use for yet.

local record records_schema
  tables: {string}
  settings: {string}
end

--- The statements that create the database, in order. `IF NOT EXISTS`
--- because, unlike `build.schema`'s tables, this file is meant to be
--- opened again and again across runs rather than built fresh every
--- time.
records_schema.tables = {
  [[CREATE TABLE IF NOT EXISTS runs (path TEXT NOT NULL,
                                     test TEXT NOT NULL,
                                     passed INTEGER NOT NULL,
                                     message TEXT NOT NULL,
                                     ran_at_ns INTEGER NOT NULL,
                                     reads TEXT NOT NULL,
                                     PRIMARY KEY (path, test)) WITHOUT ROWID]],
}

--- The same settings `o/cosmic.db` states outright, so the two files
--- agree on encoding even though only one of them promises to be
--- byte-identical across builds.
records_schema.settings = {
  "PRAGMA encoding = 'UTF-8'",
}

return records_schema
