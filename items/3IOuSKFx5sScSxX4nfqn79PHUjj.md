G3, under `3IOK4SZH` — the third of the dynamic-value boundary's three
closures: the 17-site residue that no declaration can fix, because the
value genuinely is unknown where it crosses.

Measured 2026-08-25 against `dbca9e77` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

- **`pcall` verdicts** — `cosmic/sqlite/extras.tl:32,60,102` (`why as
  string`, `verdict as string`); `cosmic/_teal_engine.tl:248`
  (`result_or_err as TlResult`); `cmd/cosmic/main.tl:480,482`
  (`results[1] as boolean`, `results[2] as string`).
- **`package.loaded` / indirected stdlib** —
  `cosmic/_seal_coverage.tl:21,22,26` and
  `cosmic/coverage/init.tl:93,96,98` reach a module through a table index
  to keep the checker from binding it statically;
  `cosmic/coverage/init.tl:124` is the `os_mod["exit"]` indirection.
- **Test and harness sites** — `_perf/harness_test.tl:16,43`;
  `_tool/benchmark.tl:182`; `_perf/run.tl:130`; `cosmic/rand_test.tl:145`
  (`rand.choice({...}) as string`, which may instead be a generic-return
  fix in `cosmic/rand.tl`).

`cosmic/coverage/init.tl` carries six `from any` casts in all; only the
three named above are this class — the other three are the binding
boundary class and close in `whilp/cosmopolitan`, so a slice here must
not claim the file whole.

The mechanism is an `is` guard at the point of use rather than a cast,
which is a per-site judgment, not one API. Refinement's job is to decide
which of the 17 are genuinely irreducible (and so keep a cast with a
better-than-`from any` reason) and which have a guard available — and to
check whether `cosmic/rand.tl`'s `choice` should return the element type
instead, which would take its site out of this class entirely.

**Five of the 17 are now claimed by open siblings** (recorded 2026-08-25,
when `3IOuS3IE` decomposed). Refinement must re-measure and drop them
rather than plan them twice:

- `cosmic/sqlite/extras.tl:32,60,102` belong to `3IQQf63I`, which owns the
  whole file: `:44` is a declaration fix and these three are guard-shaped,
  and one file is one PR.
- `_perf/harness_test.tl:16,43` belong to `3IQQeXC3`, together with `:40`;
  the file's three `from any` casts close as one uniform `is` sweep.

`_perf/run.tl:130` (`rawget(arg, -1) as string`, now `:132`) is
deliberately NOT claimed by either sibling — closing it restructures an
`or` chain rather than adding a guard — so it stays this item's, and
`3IQQeXC3`'s `Non-goals` says so.

The residue this item ends up owning is therefore 12 sites, not 17,
once both siblings land. Re-measure with the same command before
committing to the number.

**Decomposed 2026-08-25**, re-measured against `47adef2c`. The residue is
12 sites once the two `3IOuS3IE` children take theirs, and it splits by
what a session needs in order to decide, not by what the value is:

- **`3IQRDRwW`** — the six that are decidable from a read: `cosmic/_teal_engine.tl:248`
  (`is TlResult` after a `pcall`), `cmd/cosmic/main.tl:480,482` (capture
  `xpcall`'s two values instead of packing them into `{any}` — the file is
  exactly at the 500-line cap, so the change must shrink it), and
  `cosmic/_seal_coverage.tl:21,22,26` (one local `CoverageModule` record
  and one `is` guard behind the deliberate `package.loaded` read). Written
  to the ready bar.
- **`3IQREPC5`** — the rest, whose closure turns on a question a read
  cannot answer: whether Teal's `is` narrows to a function TYPE (which
  decides `cosmic/coverage/init.tl:93,124` and `_tool/benchmark.tl:182`
  between a guard and a truer-reason rewrite), which of
  `cosmic/coverage/init.tl`'s six casts are the C-binding boundary class
  that closes in whilp/cosmopolitan, whether `rand.choice` should be
  generic, and `_perf/run.tl:132`'s `or`-chain rewrite. Refining it needs
  a built tree; that is the whole reason it is cut away from `3IQRDRwW`,
  which does not.

**Outcome verified 2026-08-26** against whilp/cosmic main `50780911`
(both children merged: #1396 for `3IQRDRwW`, #1397 for `3IQREPC5`).
Every site this container enumerated now carries no `from any` cast:

```
git grep -n -- "-- cast: .*from any" origin/main -- \
  cosmic/sqlite/extras.tl cosmic/_teal_engine.tl cmd/cosmic/main.tl \
  cosmic/_seal_coverage.tl cosmic/coverage/init.tl \
  _perf/harness_test.tl _tool/benchmark.tl _perf/run.tl \
  cosmic/rand_test.tl
```

prints nothing (17 lines at `dbca9e77`, 12 of them this container's).
Three sites kept a cast with a truthful, better-than-`from any` reason
rather than closing — `cosmic/_teal_engine.tl:248` (pcall slot 2 is
tl's nominal `Result`), `cosmic/coverage/init.tl`'s `table.pack` `n`
(mixed-return packing erases the element type) and its two
patch-stdlib table views — which is the decision this container asked
refinement to make. Nothing moved to whilp/cosmopolitan: the three
`thread as thread` casts once classed as C-binding-boundary work
closed here once `is` was shown to narrow a function SIGNATURE.

The repo-wide `from any` residue is **11 lines**
(`git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"`),
none of them this container's: two are literal strings inside
`_build/casts_test.tl`'s own fixtures, three are `cosmic/fetch/init.tl`
(board item `3IQCrJpB`), and the remaining six are one-off binding and
dynamic-lookup boundaries in `errno`, `fd`, `quicksand/proc`,
`surface_test`, `teal` and `zip`.
