## Problem

`cosmic/fs/walk.tl:75` stats every entry with
`unix.stat(AT_SYMLINK_NOFOLLOW)`, wraps it (`types.wrap`) and builds a
fresh `Entry` table, before the visitor has said whether it wants any
of that. The dirent `d_type` — already the second return of
`DirHandle:read()` (`cosmic/fs/types.tl:112-115`) — answers the walk's
own only question, "is this a real directory". Probe numbers from the
2026-08-23 research pass recorded on this item's parent (200 iters,
scouting numbers, not the gate): raw d_type walk 81µs; walk +
stat-per-entry 276µs; today's `fs.visit` 429-447µs; a lazy prototype
171µs when the visitor never touches `e.stat` (−62%) and 354µs when it
does (−21%).

`cosmic/fs/find.tl:200-236` already runs this exact engine — d_type
decides `DT_DIR` (descend, no stat) vs. a known non-directory kind (no
stat) vs. `DT_UNKNOWN` (stat fallback, needed to classify) — and
`cosmic/embed/init.tl:128-141` repeats the same shape. `walk.tl` is the
one directory-scanning path in the tree that still stats everything
unconditionally.

This is the contract-adjacent half of the parent hypothesis, and the
exact wall whilp/cosmic#469 stopped at: "walk() hands every visitor a
full WalkStat, per its documented contract … a future pass could
revisit them with an explicitly lazy-stat visitor API, but that's a
bigger, contract-changing effort out of scope here." Its sibling item
(routing `fs.find` through the existing d_type engine) already landed
above — this item is the remaining, contract-changing half, and
touches `cosmic/fs/walk.tl` and `cosmic/fs/types.tl`.

## Change

This item makes one call: `Entry.stat` becomes a lazy, memoized method
(`function(self): Stat | nil, string`), not an eager field, and
`walk_entries` classifies from `d_type` instead of stat-ing
everything. That is a breaking change to a public record, so it ships
with the decision record the `decide` skill requires for a public-API
tradeoff, in the same PR (`skills/decide/SKILL.md`: "the record lands
in the pull request that makes the change"). Concretely:

### 1. Write `docs/decisions/d41-lazy-entry-stat.md`

`ls docs/decisions/` (run 2026-08-31) shows the highest number in use
is `d40-sandbox-enforcement-report.md` — `d41` is next; re-run `ls
docs/decisions/` before writing in case another item claimed it first,
and bump the number rather than reuse one. Use this body (adjust only
the number/date if `d41` moved):

```markdown
# D41 — entry.stat is a lazy method, not an eager field

- **date:** 2026-08
- **status:** active
- **context:** `cosmic/fs/walk.tl`'s `walk_entries` stats every
  directory entry with `unix.stat(AT_SYMLINK_NOFOLLOW)` before the
  visitor is asked whether it wants that — 429-447µs against a 81µs
  raw d_type walk and 171µs for a lazy prototype that skips the stat
  entirely when unused (200-iter probes, whilp/cosmic#469's research
  pass). `cosmic/fs/find.tl:200-236` and `cosmic/embed/init.tl:128-141`
  already classify entries from the dirent `d_type`
  (`DirHandle:read()`'s second return, `cosmic/fs/types.tl:112-115`),
  falling back to a real stat only on `DT_UNKNOWN`; `fs.visit` is the
  one directory walk left that stats unconditionally. `Entry.stat` is
  declared a plain, non-nil `Stat` field
  (`cosmic/fs/types.tl:151-156`), and making it lazy without an honest
  failure path collides with this project's own doctrine: a fallible
  value is `T | nil, string` (AGENTS.md), and a plain data field can
  return only one value, never a paired error string. Measured
  2026-08-31 at main `54d754f1`, `Entry.stat` is read as a field at 11
  call sites across 11 files: `cosmic/fs/find.tl:298-299` (`find_info`),
  `cosmic/fs/walk_example.tl:23`, `_docs/publish.tl:93`,
  `_tool/coverage/report.tl:203`, `_make/project.tl:305`,
  `_make/extract.tl:37-38,55`, `_make/artifact.tl:215`, plus the tests
  `cosmic/fs/path_test.tl:178`, `cosmic/coverage/init_test.tl:30` and
  `_make/fixpoint_test.tl:75,80` — and unknown callers outside the
  repo.
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
```

Then `bin/cosmic _docs/derive.tl` (rewrites the derived index table)
and `bin/cosmic --make test _build/docs_test.tl` (gates it).

### 2. `cosmic/fs/types.tl` (299 lines, `wc -l cosmic/fs/types.tl`)

Change the `Entry` record (lines 151-156):

```teal
record Entry
  path: string
  name: string
  depth: integer
  stat: function(self: Entry): Stat | nil, string
end
```

Update its doc comment (lines 147-150) to describe `stat` as a lazy,
memoized accessor instead of a pre-computed field, and reword the
`WalkStat` alias doc (line 103) to note it's what `Entry.stat()`
returns rather than what `Entry.stat` holds.

### 3. `cosmic/fs/walk.tl` (168 lines, `wc -l cosmic/fs/walk.tl`)

Add a helper above `walk_entries` that builds the memoized accessor
and folds a failure into the shared error list:

```teal
local function lazy_stat(full_path: string, errs: {string}):
    function(self: Entry): WalkStat | nil, string
  local wst: WalkStat | nil
  local werr: string
  local done = false
  return function(_self: Entry): WalkStat | nil, string
    if not done then
      done = true
      local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
      if st then
        wst, werr = types.wrap(st)
      end
      if not wst then
        werr = werr or errstr(serr, "stat: " .. full_path)
        errs[#errs + 1] = werr
      end
    end
    return wst, werr
  end
end
```

Rewrite `walk_entries` (lines 65-103) to classify from `d_type`
instead of stat-ing every entry, matching `find.tl:200-236`'s shape:

```teal
local function walk_entries<T>(dir: string, h: WalkDirHandle,
    visitor: function(Entry, T): (WalkAction ...), ctx: T,
    errs: {string}, depth: integer, max_depth: integer): boolean
  while true do
    local entry, kind = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = fs_path.join(dir, entry)
      local e: Entry = {path = full_path, name = entry, depth = depth,
        stat = lazy_stat(full_path, errs)}
      local is_dir: boolean
      local skip_entirely = false
      if kind == unix.DT_DIR then
        -- d_type never follows symlinks, so this is a real directory
        -- (a symlinked dir reports DT_LNK); no stat(2) needed.
        is_dir = true
      elseif kind ~= unix.DT_UNKNOWN then
        is_dir = false
      else
        -- Filesystem doesn't expose d_type: force the stat now, since
        -- the recursion decision needs it. A failure is recorded by
        -- lazy_stat itself and the entry is skipped, matching
        -- find.tl's identical DT_UNKNOWN fallback (find.tl:219-235)
        -- and this function's own prior behavior.
        local st = e:stat()
        if st then
          is_dir = st:is_dir()
        else
          skip_entirely = true
        end
      end
      if not skip_entirely then
        local action = visitor(e, ctx)
        if action == "stop" then
          h:close()
          return true
        end
        if action ~= "skip" and is_dir
        and (max_depth == 0 or depth < max_depth) then
          if walk_tree(full_path, visitor, ctx, errs, depth + 1, max_depth) then
            h:close()
            return true
          end
        end
      end
    end
  end
  h:close()
  return false
end
```

The `unix.S_ISDIR((st as unix.Stat):mode())` cast and the `wst is
WalkStat` narrowing both disappear with this rewrite — recursion now
turns on `is_dir`, computed above.

Update the doc comments this rewrite makes stale:
- `Walked.errors` (lines 34-36): "Subtree failures, in encounter
  order" overstates it now — reword to say failures are recorded in
  the order a stat was actually attempted (opendir failures and
  `DT_UNKNOWN` fallbacks immediately; a decisive-`d_type` entry's
  failure only if and when a visitor calls `e:stat()`).
- `visit()`'s doc comment (lines 123-138): `stat` is no longer a bare
  `fs.Stat` field — describe it as `stat()`, a lazy `Stat | nil,
  string` accessor — and update the runnable example (lines 129-131)
  to narrow it, e.g.:
  ```
  ---   fs.visit(dir, function(e: fs.Entry, acc: {string})
  ---     local st = e:stat()
  ---     if st and st:is_file() then table.insert(acc, e.path) end
  ---   end, {})
  ```
  Also add one sentence to this block stating the decision-2
  consequence in the module's own words: a walk can finish with
  `errors == nil` even though some unvisited-by-`stat()` entry would
  have failed to stat, because the walk no longer stats what nobody
  asked for.

### 4. `cosmic/fs/walk_test.tl` (419 lines, `wc -l cosmic/fs/walk_test.tl`, 81 lines of headroom)

- `test_walk_symlink_file_visited` (line 100): its comment at line 114
  ("alias.txt: walk calls lstat, sees S_ISLNK") is now wrong — the new
  code never stats a symlinked file at all (`DT_LNK` is a known,
  non-`DT_DIR` kind); reword to say the walk classifies it from
  `d_type` without a stat.
- `test_visit_entry_and_depth` (line 337) uses only `e.path`/`e.name`/
  `e.depth` — unaffected.
- Add one new test proving both halves of D41 at once: that a
  decisive-`d_type` entry is handed to the visitor even when its stat
  would fail, and that the failure comes back honestly through
  `e:stat()` rather than crashing the walk or silently vanishing.
  Delete the file out from under the entry from inside the visitor —
  deterministic, no OS race:
  ```teal
  local function test_visit_stat_is_lazy_and_honest()
    local base = mksubdir("visit_lazy_stat")
    write_file(fs.join(base, "target.txt"), "x")
    local saw = false
    local walked, err = fs.visit(base, function(e: fs.Entry, _c: {string})
        if e.name == "target.txt" then
          saw = true
          assert(fs.remove(e.path), "setup: could not remove target.txt")
          local st, serr = e:stat()
          assert(st == nil, "stat on a removed entry must fail")
          assert(serr and serr:match("target%.txt"), "got: " .. tostring(serr))
        end
      end, {})
    assert(saw, "the visitor must still see an entry whose later stat fails")
    assert(walked ~= nil, "the walk itself must not fail: " .. tostring(err))
    assert(walked.errors and walked.errors[1] and walked.errors[1]:match("target%.txt"),
      "the stat failure must still land in walked.errors once e:stat() was called")
  end
  ```
  (confirm `fs.remove`'s exact name via `cosmic --docs fs` if it
  differs — the walk test file already imports `fs` as
  `cosmic.fs`).

### 5. Migrate the 8 non-test call sites (mechanical: `e.stat` field read → `local st, _serr = e:stat()` + narrow)

- `cosmic/fs/find.tl:298-299` (`find_info`, file is 410 lines, ample
  headroom): narrow before use —
  ```
  local st, _serr = e:stat()
  if st and st:is_file() and e.name:match(lua_pattern) then
    acc[e.path] = {mode = st:mode() & 0x1ff}
  end
  ```
- `cosmic/fs/walk_example.tl` (97 lines): line 6's comment and line 23
  need `check.must(e:stat())` (the module already has `check.must` as
  the house idiom for narrowing in examples) —
  ```
  local check = require("cosmic.check")
  ...
  local st = check.must(e:stat())
  local kind = st:is_dir() and "dir" or "file"
  ```
- `_docs/publish.tl:92-93` (302 lines):
  ```
  local st, _serr = e:stat()
  if st and not st:is_dir() and e.name:match("%.md$") then
  ```
- `_make/artifact.tl:214-215` — **this file is 499 lines
  (`wc -l _make/artifact.tl`), one line under the 500-line cap**, so
  the added narrowing line lands it exactly at 500 (`500 > 500` is
  false — compliant, but with zero headroom left afterward):
  ```
  local _ok, _err = fs.visit(dir, function(e: fs.Entry): fs.WalkAction
      local st, _serr = e:stat()
      if st and st:is_file() then
        local inside = e.path:sub(#dir + 2)
        out[#out + 1] = {source = fs.join(rel, inside), stored = inside, is_module = bytecode.is_module_path(inside)}
      end
      return nil
    end)
  ```
- `_tool/coverage/report.tl:201-205` — **this file is exactly 500
  lines (`wc -l _tool/coverage/report.tl`), the hard cap, zero
  headroom**: the migration must be net line-neutral or negative.
  Collapse the guard onto one line (this repo already writes
  single-line `if cond then return end` guards, e.g.
  `cosmic/quicksand/netns_example.tl:30`) so the edit is net **−1**
  line, leaving one line of headroom rather than breaking the cap:
  ```
  local st, _serr = e:stat()
  if not st or st:is_dir() then return end
  local path = e.path
  ```
  (replaces the current 4 lines — `local path = e.path` /
  `if e.stat:is_dir() then` / `return` / `end` — with 3).
- `_make/extract.tl:37-38,55` (163 lines): this function already fails
  loudly (`failure = ...; return "stop"`) on a symlink or a read/write
  error, and its own comment says why ("Loudly, not silently."); a
  stat failure gets the same treatment rather than a silent skip:
  ```
  local path = e.path
  local st, serr = e:stat()
  if not st then
    failure = path:sub(#from + 2) .. ": " .. serr
    return "stop"
  end
  if st:is_link() then
  ```
  and the later `if not st:is_file() then` (line 55) is unchanged
  since `st` is now guaranteed non-nil at that point.
- `_make/project.tl:294-306` (`visit`, file is 478 lines, 22 lines of
  headroom): the dotfile/ignore pruning at the top of `visit` reads
  only `path`/`name` and stays as-is; add the stat narrowing right
  before the classification that needs it —
  ```
  local path, name = e.path, e.name
  ...
  local st, _serr = e:stat()
  if not st then
    return
  elseif st:is_dir() then
  ```
  No other change to `_make/project.tl` is needed: `scan()`'s existing
  `walked.errors[1]` check (lines 361-363) already turns any stat
  failure `lazy_stat` records — including one surfaced through this
  very `e:stat()` call — into the same "make: incomplete scan of …"
  fatal error it produces today, because `lazy_stat` still pushes onto
  the walk's own `errs` list.

### 6. Migrate the 3 test call sites (same mechanical pattern)

- `cosmic/fs/path_test.tl:178` (422 lines, already imports
  `cosmic.check` as `check`): `local stat_obj = e.stat` →
  `local stat_obj = check.must(e:stat())`.
- `cosmic/coverage/init_test.tl:30` (162 lines): same shape as
  `report.tl` above — `local st, _serr = e:stat(); if st and not
  st:is_dir() and e.path:match("%.cov$") then`.
- `_make/fixpoint_test.tl:75,80` (257 lines): `local path, entry, st =
  e.path, e.name, e.stat` → split `st` off into its own narrowed line;
  this function already sets `failure` and returns `"stop"` on other
  errors (line 85-86), so treat a stat failure the same way rather
  than silently continuing.

## Non-goals

- No new `_perf/bench/fs_bench.tl` scenario for the stat-touching path
  (`e:stat()` called on every entry). `fs_walk_tree`'s visitor reads
  only `e.path` and is the gate for the stat-free win this item
  targets; pricing the stat-touching −21% side with a companion
  scenario is real, independent work — a separate item, not folded in
  here.
- No rewrite of `cosmic/fs/find.tl`'s own traversal engine beyond
  `find_info`'s mechanical `Entry.stat` migration above — `find`/
  `find_iter`/`glob` already run their own d_type-based loop
  (`find.tl:151-255`) and are untouched by this item.
- No attempt to discover or migrate callers outside this repo — D41's
  consequences section records that cost; it is not this item's to
  close.
- `_tool/coverage/report.tl` (499 lines after the net −1 edit above)
  and `_make/artifact.tl` (500 lines after the net +1 edit above) land
  with one line or zero lines of headroom under the 500-line cap as a
  direct result of this migration — any future change to either file
  inherits that, and will need its own trim; that is a cost this item
  accepts, not a problem it solves.
