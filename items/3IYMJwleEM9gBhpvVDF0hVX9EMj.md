## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **userdata boundary** class, 22 sites.
Files: `cosmic/fs/types.tl` 12; `cosmic/fs/find.tl` 3;
`cosmic/fs/ops.tl` 2; `cosmic/fs/walk.tl` 2; `cosmic/embed/init.tl` 1;
`cosmic/fs/tree.tl` 1; `cosmic/zip.tl` 1. The shape is a raw userdata
handle from a binding re-typed to the record that describes it, or a
method table typed `{string: any}` whose `self` is `any` and is
re-typed once per method. The census verdict is **why it is a floor**:
a userdata value has no structure Teal can read, so the record
describing it is an assertion by construction and the assertion has to
be written somewhere — but the floor is one cast per handle TYPE at its
wrap point, not one per use. Six handle types exist today (`Stat`,
`Statfs`, the two directory handles, the embed handle, the zip reader),
so 22 sites sit over a floor of six, and the gap is almost entirely
`cosmic/fs/types.tl`: nine of its twelve are `(self as unix.Statfs):`
method bodies that exist only because the method table is typed
`{string: any}`. Declaring that table's `self` closes all nine at once
and is the bulk of the work; the remaining call-site casts in `find`,
`walk`, `ops` and `tree` collapse once each wrap function returns the
handle already typed. The closure diff lowers the affected
`_build/casts_baseline.tl` rows, and a residual six is the expected
end state rather than a failure. The class description and exemplar
citations are the `### userdata boundary` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.

## Change

In `cosmic/fs/types.tl` (300 lines — `wc -l cosmic/fs/types.tl`),
retype the `statfs_methods` table's 9 method functions (the block at
lines 213–241) so each one declares its `self` parameter as
`unix.Statfs` instead of `any`, and calls the binding method directly
on `self` instead of casting first. `grep -n "cast: userdata boundary"
cosmic/fs/types.tl` shows the 9 casts to remove sit at lines 215, 218,
221, 224, 227, 230, 233, 236, 239 — one per method, all inside
`statfs_methods`. For each of these 9 (`block_size_bytes`→`bsize`,
`fragment_size_bytes`→`frsize`, `total_blocks`→`blocks`,
`free_blocks`→`bfree`, `available_blocks`→`bavail`,
`total_files`→`files`, `free_files`→`ffree`, `id`→`fsid`,
`max_name_bytes`→`namelen`), change:

```
NAME = function(self: any): RET
  return (self as unix.Statfs):BINDING() -- cast: userdata boundary
end,
```

to:

```
NAME = function(self: unix.Statfs): RET
  return self:BINDING()
end,
```

Leave everything else in the file untouched: `statfs_methods`'s own
declared type stays `{string: any}` (a concretely-typed function value
still satisfies an `any`-valued table, and `extend_metatable`'s
signature — `extend_metatable(raw: any, extra: {string: any}):
boolean` — does not change); `raw_predicates`, `install_predicates`,
`wrap`, and `wrap_statfs` are untouched, including the 3 casts that are
NOT part of this change: `install_predicates`'s `raw as any` (line
263), `wrap`'s `raw as fs_types.Stat` (line 280), and `wrap_statfs`'s
`raw as fs_types.Statfs` (line 294). Those 3 are wrap-point casts —
part of the census's six-wrap-point floor in `docs/design/casts.md`'s
`### userdata boundary` section — and stay. Every edited line is a
1-for-1 replacement (the function-header line and its one-line body
each keep their line count), so the file stays 300 lines and none of
the surviving casts' line numbers move: `docs/design/casts.md`'s
fenced quote at `cosmic/fs/types.tl:280` needs no update.

After the edit:

- Run `bin/cosmic --make ci` — the 9 rewritten lines must type-check
  with no `as`, and the whole gate (fmt, check, example, lint,
  coverage) must stay green.
- Run `bin/cosmic --make run _build/casts.tl --baseline` and commit
  the result — `_build/casts_baseline.tl`'s row `["cosmic/fs/types.tl"]
  = 12,` (confirmed today: `grep -n 'fs/types.tl' _build/casts_baseline.tl`)
  must become `= 3,`.
- Run `bin/cosmic --make run _build/cast_sites.tl --reconcile` and
  commit the result — `docs/design/cast-sites.tsv` drops its 9 rows for
  `cosmic/fs/types.tl` at lines 215/218/221/224/227/230/233/236/239.
  `_build/cast_sites_test.tl` fails the build if this file and the
  baseline disagree, so both regenerations land in the same commit.

Add a runtime test proving the retyped methods still work against the
real binding: today nothing calls `fs.statfs`/`fs.statfs_fd` in any
test — `grep -rln 'statfs\b' cosmic --include=*_test.tl` finds only
`cosmic/fs/traps_test.tl` (a capability-name list that mentions the
string `statfs_fd`, never calls it) and `cosmic/fs/dir_test.tl` (an
unrelated match); no test exercises the wrapped `Statfs` methods this
change retypes. In `cosmic/fs/ops_test.tl` (348 lines — `wc -l
cosmic/fs/ops_test.tl`, well under the 500-line cap), add
`test_statfs_reports_plausible_values`: call `fs.statfs(".")`, assert
success, then assert on values from all 9 retyped methods without
hardcoding filesystem-specific numbers — e.g. `block_size_bytes() > 0`,
`total_blocks() > 0`, `free_blocks() <= total_blocks()`,
`total_files() >= 0`, `free_files() <= total_files()`,
`fragment_size_bytes() > 0`, `available_blocks() <= total_blocks()`,
`max_name_bytes() > 0`, and `id()`'s two returned values are both
integers.

## Non-goals

The Goal above cites 22 userdata-boundary sites across 7 files; the
tree today actually carries 23, across 8 files —
`awk -F'\t' '$3=="userdata boundary" {print $1}' docs/design/cast-sites.tsv
| sort | uniq -c` gives `cosmic/embed/init.tl 1, cosmic/fs/dir_test.tl
1, cosmic/fs/find.tl 3, cosmic/fs/ops.tl 2, cosmic/fs/tree.tl 1,
cosmic/fs/types.tl 12, cosmic/fs/walk.tl 2, cosmic/zip.tl 1`. The site
the Goal's tally omits is `cosmic/fs/dir_test.tl:170`, a fabricated
userdata test double (`return raw as unix.Dir -- cast: test double for
userdata boundary`) built to exercise `Dir`'s EOPNOTSUPP clamp; this
item does not touch it.

This item closes only the 9 sites inside `cosmic/fs/types.tl`'s
`statfs_methods` table. Everything else the Goal describes stays open,
and is not a smaller version of the same fix — it is a different
change, deferred rather than attempted here:

- `cosmic/fs/find.tl` (3 sites), `cosmic/fs/walk.tl` (2),
  `cosmic/fs/tree.tl` (1) and `cosmic/embed/init.tl` (1) — 7 sites —
  each cast `unix.opendir()`'s raw return straight to a locally-declared
  alias of `types.DirHandle` (`WalkDirHandle` in find.tl and walk.tl,
  `TreeDirHandle` in tree.tl, `EmbedDirHandle` in embed/init.tl —
  confirmed by `grep -n DirHandle cosmic/fs/find.tl cosmic/fs/walk.tl
  cosmic/fs/tree.tl cosmic/embed/init.tl`). Unlike `Stat`/`Statfs`,
  there is no `wrap_dir` function in `cosmic/fs/types.tl` today for
  these to route through — collapsing these 7 into one wrap point means
  designing and adding that function, then re-threading 4 files'
  `unix.opendir` call sites through it, each gaining a new failure
  branch. That is a separate, materially larger, multi-file change,
  not a self-typing fix, and is not this item.
- `cosmic/fs/ops.tl`'s 2 sites (`info as any` feeding
  `types.wrap_statfs(raw: any)`) and `cosmic/zip.tl`'s 1 site (tagged
  `-- cast: from any` in its own source comment, not `userdata
  boundary`, despite the census filing it under that heading) are also
  left alone here.
- The 3 remaining casts in `cosmic/fs/types.tl` itself — lines 263,
  280 and 294 — are not deferred work; they are permanent wrap-point
  floor (3 of the census's 6) and are expected to stay after this item
  lands.

A follow-up item for the 11 non-floor sites left open (the 7-site
DirHandle collapse, ops.tl's 2, zip.tl's 1, and a classification call
on dir_test.tl's test double) is recommended but not created by this
refinement.
