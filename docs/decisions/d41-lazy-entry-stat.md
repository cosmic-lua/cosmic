# D41 — entry.stat is a lazy method, not an eager field

- **date:** 2026-08
- **status:** active
- **context:** `cosmic/fs/walk.tl`'s `walk_entries` stats every
  directory entry with `unix.stat(AT_SYMLINK_NOFOLLOW)` before the
  visitor is asked whether it wants that — 429-447µs against a 81µs
  raw d_type walk and 171µs for a lazy prototype that skips the stat
  entirely when unused (200-iter probes, whilp/cosmic#469's research
  pass). `cosmic/fs/find.tl`'s `step` function and `cosmic/embed/init.tl`
  already classify entries from the dirent `d_type`
  (`DirHandle:read()`'s second return, in `cosmic/fs/types.tl`),
  falling back to a real stat only on `DT_UNKNOWN`; `fs.visit` is the
  one directory walk left that stats unconditionally. `Entry.stat` is
  declared a plain, non-nil `Stat` field in `cosmic/fs/types.tl`, and
  making it lazy without an honest failure path collides with this
  project's own doctrine: a fallible value is `T | nil, string`
  (AGENTS.md), and a plain data field can return only one value, never
  a paired error string. Measured 2026-08-31 at main `54d754f1`,
  `Entry.stat` is read as a field at 11 call sites across 11 files:
  `find_info` in `cosmic/fs/find.tl`, `cosmic/fs/walk_example.tl`,
  `_docs/publish.tl`, `_tool/coverage/report.tl`, `_make/project.tl`,
  `_make/extract.tl`, `_make/artifact.tl`, plus the tests
  `cosmic/fs/path_test.tl`, `cosmic/coverage/init_test.tl` and
  `_make/fixpoint_test.tl` — and unknown callers outside the repo.
- **decision:**
  - `Entry.stat` is `function(self: Entry): Stat | nil, string`: a
    closure created once per entry (capturing the entry's full path),
    memoized after its first call, computing `unix.stat` +
    `types.wrap` only when actually invoked.
  - `walk_entries` no longer stats every entry. It reads the dirent
    `d_type` from `DirHandle:read()`'s second return: `DT_DIR` means
    "descend, no stat" (a symlinked directory always reports `DT_LNK`,
    never `DT_DIR`, so the existing cycle-safety guarantee holds by
    construction, unchanged); any other known kind means "not a
    directory, no stat"; `DT_UNKNOWN` forces the lazy stat immediately,
    because the recursion decision needs it — mirroring
    `find.tl`'s identical fallback.
  - A stat failure — forced on `DT_UNKNOWN`, or triggered later by a
    visitor's own `e:stat()` call — is pushed onto the same `errs`
    accumulator `walk_entries` already threads through recursion, so
    it still surfaces as `Walked.errors`, with one narrowing: it is
    recorded only if the stat was actually attempted. A `DT_UNKNOWN`
    failure still means the entry is skipped and never reaches the
    visitor (unchanged from today). A decisive-`d_type` entry is
    always handed to the visitor, even one a stat would fail for (e.g.
    removed between readdir and access) — the failure surfaces only if
    and when something calls `e:stat()`.
- **rejected:**
  - retyping the field itself to `Stat | nil` — a bare nil has no slot
    for the paired error string D24/AGENTS.md's honest-nil contract
    requires; it silently downgrades a real stat failure to "absent"
    while still forcing every reader to narrow, all the breakage with
    none of the honesty.
  - a metatable `__index` computing `Stat` lazily on first field
    access — invisible to `pairs()` and a table copy (either sees
    whatever was already materialized, never triggers the compute),
    and a plain field access can return only one value, so it has
    nothing honest to hand back when the underlying stat fails.
  - leaving `stat` eager and adding a separate `kind`/`type` field
    carrying the `d_type` for free — doesn't touch the actual cost,
    since `walk_entries` would still call `unix.stat` for every entry
    to populate the field; it buys a visitor a cheaper `is_dir()` than
    `e.stat:is_dir()` already gives it today, not the measured win.
- **consequences:** every one of the 11 in-repo call sites above
  migrates from `e.stat` to `e:stat()` plus narrowing, landed in this
  same PR; an external consumer of `cosmic.fs`'s `Entry` breaks and has
  no warning beyond this record. `Walked.errors` no longer means
  "every stat this walk could have failed on" — it means "every stat
  this walk actually attempted", so a clean walk (`errors == nil`) no
  longer guarantees every entry's stat would have succeeded, only that
  none of the attempted ones failed. The measured win applies to
  visitors that never call `e:stat()` (171µs vs. 429-447µs, the
  `fs_walk_tree` perf scenario's case); a visitor that always calls it
  still pays close to today's cost. Revisit if a caller needs the old
  guarantee — a complete, pre-computed error list regardless of what
  the visitor reads.
