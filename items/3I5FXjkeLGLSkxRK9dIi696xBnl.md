
## Goal

G3 — an honest type layer, no escape hatches (docs/goals.md). This is wave 0.5
("Transition scaffolds") of the epic 3HyArM3A3zHuRxn3VYCvKmUZ7KW ("G3: measure and
drive down the as-cast count"): the cheapest remaining large win, to land before wave 3.

## Change

Both surfaces these two test files reach through `as {string: any}` are now fully
declared and typed on `fs` and `time` — the casts are dead scaffolding left over from
when those surfaces were still landing. Remove the scaffolding and call the typed API
directly, in two files:

**`cosmic/fs/traps_test.tl`** (19 cast sites -> 1):

- Delete the `-- cast: from any` sites reached through `fsa.copy_tree` (lines 30, 52,
  76, 103) — `fs.copy_tree` is declared at `cosmic/fs/init.tl:141`
  (`function(src: string, dst: string): boolean, string`). Call `fs.copy_tree(...)`
  directly in `test_copytree`, `test_copytree_missing_src_errors`,
  `test_copytree_symlink_overwrite`, `test_copytree_dir_mode_exact`.
- Delete the `fsa.temp_file` cast sites (lines 117, 121, 123, 124, 125, 127, 134, 137,
  139, 140, 141) in `test_tmpfile_handle_and_path` and
  `test_tmpfile_default_template`. `fs.temp_file` is declared at
  `cosmic/fs/init.tl:165` returning `fs_ops.TempFile | nil, string`; `TempFile`
  (`cosmic/fs/ops.tl:366`) has typed fields `handle: Handle` and `path: string`; `Handle`
  (`cosmic/fd.tl:28`) has typed `write(self, data, offset?): integer | nil, string` and
  `close(self): boolean, string`. Call `fs.temp_file(...)`, use `check.must` to narrow,
  and call `tf.handle:write(...)` / `tf.handle:close()` / `tf.path` directly — no cast
  at any of these sites.
- Delete the `local dd = d as {string: any}` cast and its two `dd.read`/`dd.close`
  casts (lines 210, 211, 212) in `test_dir_read_returns_d_type`. `fs.open_dir` returns
  `Dir | nil, string` (`cosmic/fs/dir.tl:167`), and `Dir` (`cosmic/fs/types.tl:122`) has
  typed `read(self): string | nil, integer` and `close(self)`. Call `d:read()` /
  `d:close()` directly on the `Dir` from `assert(fs.open_dir(dir))`.
- Replace every `fsa.DT_DIR` / `fsa.DT_REG` reference (lines 207, 208, 220, 222) with
  `fs.DT_DIR` / `fs.DT_REG` — both are typed `integer` fields on `fs`
  (`cosmic/fs/init.tl:221`, `:224`).
- **Keep** `local fsa = fs as {string: any}` (line 10), and change its reason string
  from `signature transition` to `probe removed surface` (the house phrasing already
  used at `cosmic/compress_test.tl:171`). It remains the only cast in the file, still
  needed by `test_mkstemp_is_gone` (`fsa.mkstemp == nil` — `mkstemp` is not a field on
  `fs`), `test_is_accessible` (`fsa.access == nil` — `access` is not a field on `fs`),
  and `test_retired_aliases_are_gone` (dynamic `fsa[name]` lookups over the retired and
  live name arrays, plus `fsa.rename`, `fsa.major`, `fsa.minor`, `fsa.ext`) — every one
  of these asserts a name's ABSENCE from the typed record, which structurally requires
  indexing through `any`.
- Update the file's header comment (lines 2-4, "New/changed surfaces are reached via
  casts so this file typechecks red (pre-change) and green alike") to describe the
  post-change state: the file reaches `fs` directly and typed, except for the one
  removed-surface probe.

**`cosmic/time_test.tl`** (2 cast sites -> 0):

- Delete both `-- cast: signature transition` sites (lines 61-62 in
  `test_sleep_ms_uninterrupted_returns_zero_ms`, lines 71-72 in
  `test_sleep_ms_interrupted_returns_ms_remainder`) that reach `(time as {string:
  any}).sleep_ms as function(number): number, string`. `time.sleep_ms` is declared at
  `cosmic/time.tl:106` as `function(ms: number): integer | nil, string` — call
  `time.sleep_ms(...)` directly; both tests already treat the remainder as possibly
  nil-shaped (`rem == 0`, `rem == nil`), so no test assertion changes.
- Delete the now-stale explanatory comment above them (lines 55-58, "Reached via casts
  so this file's typechecking does not depend on sleep_ms's exact declared
  signature") — the reason no longer applies once the cast is gone.

This retires the `signature transition` reason string from the tree entirely (it has
exactly 4 sites today, all in these two files — see facts below).

```facts
$ grep -c -- "-- cast:" cosmic/fs/traps_test.tl
19
$ grep -n -- "-- cast:" cosmic/fs/traps_test.tl
10:local fsa = fs as {string: any} -- cast: signature transition
29:  -- cast: from any
51:  -- cast: from any
76:  -- cast: from any
103:  -- cast: from any
117:  local temp_file = fsa.temp_file as function(string): any, string -- cast: from any
121:  local t = tf as {string: any} -- cast: from any
123:  local hh = h as {string: any} -- cast: from any
124:  local path = t.path as string -- cast: from any
125:  -- cast: from any
127:  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
134:  local temp_file = fsa.temp_file as function(): any, string -- cast: from any
137:  local t = tf as {string: any} -- cast: from any
139:  local hh = h as {string: any} -- cast: from any
140:  local path = t.path as string -- cast: from any
141:  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
210:  local dd = d as {string: any} -- cast: signature transition
211:  local read = dd.read as function(any): string, number -- cast: from any
212:  local close = dd.close as function(any) -- cast: from any

$ grep -c -- "-- cast:" cosmic/time_test.tl
2
$ grep -n -- "-- cast:" cosmic/time_test.tl
61:  -- cast: signature transition
71:  -- cast: signature transition

$ git grep -n -- "-- cast: signature transition"
cosmic/fs/traps_test.tl:10:local fsa = fs as {string: any} -- cast: signature transition
cosmic/fs/traps_test.tl:210:  local dd = d as {string: any} -- cast: signature transition
cosmic/time_test.tl:61:  -- cast: signature transition
cosmic/time_test.tl:71:  -- cast: signature transition

$ git grep -n -- "-- cast:.*probe removed surface"
cosmic/compress_test.tl:171:  local m = compress as {string: any} -- cast: probe removed surface

$ grep -n "function copy_tree\|copy_tree:" cosmic/fs/init.tl cosmic/fs/tree.tl
cosmic/fs/init.tl:141:  copy_tree: function(src: string, dst: string): boolean, string
cosmic/fs/tree.tl:110:local function copy_tree(src: string, dst: string): boolean, string

$ grep -n "temp_file:\|temp_fd:\|DT_DIR:\|DT_REG:" cosmic/fs/init.tl
165:  temp_file: function(template?: string): fs_ops.TempFile | nil, string
167:  temp_fd: function(): Handle | nil, string
221:  DT_DIR: integer
224:  DT_REG: integer

$ grep -n "record TempFile" -A6 cosmic/fs/ops.tl
366:local record TempFile
367-  --- Open handle to the created file; the Handle owns the descriptor.
368-  handle: Handle
369-  --- Path to the created file. NOT unlinked automatically -- remove it
370-  --- when done. For an anonymous file with no path at all, use temp_fd().
371-  path: string
372-end

$ grep -n "record Handle is" -A11 cosmic/fd.tl
28:local record Handle is stream.Reader, stream.Writer
29-  metamethod __close: function(self: Handle)
30-  close: function(self: Handle): boolean, string
31-  closed: function(self: Handle): boolean
32-  fd: function(self: Handle): integer
33-  read: function(self: Handle, size?: integer, offset?: integer): string | nil, string
34-  write: function(self: Handle, data: string, offset?: integer): integer | nil, string
35-  seek: function(self: Handle, offset: integer, whence?: integer): integer | nil, string
36-  truncate: function(self: Handle, length?: integer): boolean, string
37-  sync: function(self: Handle): boolean, string
38-  datasync: function(self: Handle): boolean, string
39-  dup: function(self: Handle, newfd?: integer, flags?: integer, lowest?: integer): Handle | nil, string

$ grep -n "function open_dir" -A1 cosmic/fs/dir.tl
167:local function open_dir(path: string): Dir | nil, string
168-  -- `is` is safe here since every cosmic-installed loader (dispatcher

$ grep -n "record Dir$" -A16 cosmic/fs/types.tl
122:  record Dir
123-    metamethod __close: function(self: Dir)
124-    read: function(self: Dir): string | nil, integer
125-    close: function(self: Dir)
126-    fd: function(self: Dir): integer
127-    rewind: function(self: Dir)
128-    tell: function(self: Dir): integer

$ grep -n "sleep_ms" cosmic/time.tl | head -3
106:local function sleep_ms(ms: number): integer | nil, string
390:  sleep_ms: function(ms: number): integer | nil, string
411:  sleep_ms = sleep_ms,

$ grep -n "^  access\b\|  access:\|access =\|mkstemp" cosmic/fs/init.tl
(no output -- neither `access` nor `mkstemp` is a declared field on fs, confirming
both retired-surface probes in test_is_accessible / test_mkstemp_is_gone genuinely
need to index through `any`)

$ grep -c '_test.tl' .cosmic-coverage
0

$ grep -n -B1 "traps_test\|time_test" _build/casts_baseline.tl
71-  ["cosmic/fs/path_test.tl"] = 1,
72:  ["cosmic/fs/traps_test.tl"] = 19,
--
129-  ["cosmic/time.tl"] = 7,
130:  ["cosmic/time_test.tl"] = 2,
```

## Non-goals

- No other cast-removal wave from the epic's plan (waves 1-7, or the `_eval`/`_fuzz`
  ratchet-hole fix in wave 7) is touched in this slice. In particular, do not touch
  `cosmic/time.tl`'s own 7 casts (unrelated `binding-boundary`/`from any` sites, a
  later wave) — only `cosmic/time_test.tl` is in scope.
- No new `is` guards are introduced anywhere in either file. This slice is deletion
  only: call the now-typed API directly, or (for the one surviving probe) keep the
  `{string: any}` escape hatch as-is. Do not replace the survivor with an `is` check —
  the whole point of `test_mkstemp_is_gone` / `test_is_accessible` /
  `test_retired_aliases_are_gone` is that the probed names are ABSENT from the typed
  record, so there is nothing for `is` to narrow.
- The coverage floor (`.cosmic-coverage`) is not touched and needs no regen: it holds
  zero `_test.tl` rows (see facts), so deleting test-file casts changes no covered-line
  count the ratchet tracks.
- No behavioral change to any test's assertions. Every `assert(...)` in both files
  keeps checking exactly what it checks today; only how the value under test is reached
  changes (typed call vs. cast-through-`any`).

## Acceptance

- `bin/cosmic --make run _build/casts.tl --baseline` (from the repo root) regenerates
  `_build/casts_baseline.tl` from the post-change tree, and the diff shows exactly:
  `cosmic/fs/traps_test.tl` dropping from `19` to `1`, and `cosmic/time_test.tl`
  dropping from `2` to `0` (its baseline row disappears — a file with a zero count is
  absent from the baseline, per `_build/casts.tl`'s own comment on why absent-means-zero).
  No other file's baseline row changes. Commit the regenerated
  `_build/casts_baseline.tl` in the same PR as the test-file edits — this is required
  because `_build/casts_test.tl`'s `test_the_cast_counts_match_the_committed_baseline`
  gates the tree against the committed baseline, and it fails the moment the cast
  counts move without a matching baseline update.
- `grep -c -- "-- cast:" cosmic/fs/traps_test.tl` prints `1`, and
  `grep -n -- "-- cast:" cosmic/fs/traps_test.tl` shows only line 10, reading
  `-- cast: probe removed surface`.
- `grep -c -- "-- cast:" cosmic/time_test.tl` prints `0`.
- `git grep -n -- "-- cast: signature transition"` prints nothing (the reason string
  is retired from the tree).
- `bin/cosmic --make test cosmic/fs/traps_test.tl cosmic/time_test.tl` passes.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

None needed. Every fact this slice depends on is already mechanized: the typed
declarations it calls out (`fs.copy_tree`, `fs.temp_file`, `TempFile`, `Handle`,
`fs.open_dir`/`Dir`, `fs.DT_DIR`/`DT_REG`, `time.sleep_ms`) are all landed and
type-checked today; the `-- cast: <reason>` justification convention and its lint are
already enforced by `--make lint`; the cast-count ratchet and its regen command
(`bin/cosmic --make run _build/casts.tl --baseline`) already exist and are exercised by
`_build/casts_test.tl`; and the house phrasing for the one surviving reason string
(`probe removed surface`) already has a precedent to copy verbatim
(`cosmic/compress_test.tl:171`). No decision in this slice is left open for an
implementer to invent.
