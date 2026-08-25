## Goal

G3 — an honest type layer. The parent (`3IOK2cxG`) is "close the 55
any-map field walk `from any` sites"; this is its largest single shape,
20 of the 55, and the one whose record already exists. The public
surface already promises the typed contract — `cosmic/quicksand/init.tl:45`
declares `merge: function(...: BoxOptions): BoxOptions` — so this slice
makes the implementation keep a promise the API has been making all
along.

## Evidence

Measured 2026-08-25 against `9c1ff401` (`main`) with
`grep -n -- "-- cast: " <file>`.

| file | sites | of which `from any` | lines |
| --- | --- | --- | --- |
| `cosmic/quicksand/box/merge.tl` | 4 | 4 | 140 |
| `cosmic/quicksand/box/merge_test.tl` | 14 | 14 | 153 |
| `cosmic/quicksand/box/init_test.tl` | 3 | 2 (`:120`, `:122`) | 138 |
| `cosmic/quicksand/box/init.tl` | 4 | 0 (`:186` is `untyped merge result`) | — |

20 `from any` sites, matching this item's headline. The whole bucket is
144 today (`git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from
any" | wc -l`), and 342 casts overall.

**The item's earlier count for `init_test.tl` is stale and this
re-measurement replaces it.** It said 9 `from any` in that file with
only `:118-121` in class; the file now carries 3 casts total, 2 of them
`from any` (`:120` `fs.ro as {string}`, `:122` `(fs.rw as {string})[1]`),
with `:119` already reasoned `record inspected as map`. The other 7 were
closed by another slice. The in-class total is unchanged at 20.

**One cast the item did not count also closes.**
`cosmic/quicksand/box/init.tl:186` is

```text
  return box_merge.merge(...) as BoxOptions -- cast: untyped merge result
```

inside `local function merge(...: BoxOptions): BoxOptions`. It exists
only because the module it delegates to is untyped, so typing that
module deletes it and drops `init.tl`'s floor row 4 → 3.

**What is actually untyped.** `cosmic/quicksand/box/merge.tl:117`
declares `merge(...: {string: any}): {string: any}`, and its module
record (`:128`) repeats that. `merge_test.tl` requires that module
DIRECTLY (`:2`, `local m = require("cosmic.quicksand.box.merge")`), so
every field it reads off a merged policy is an index into `any` — all 14
of its sites, and `init_test.tl`'s 2 through the `Box.merge` re-export.
`BoxOptions` is `cosmic/quicksand/types.tl:82`.

**Four typing facts, probe-verified 2026-08-25 against `9c1ff401`, that
decide the shape.** A scratch file through `bin/cosmic --check types`:

1. `pairs()` over a heterogeneous record is **refused**: "attempting
   pairs on a record with attributes of different types (types of
   fields 'fs' and 'cwd' do not match)". `merge_section` cannot walk a
   `BoxOptions` directly.
2. Passing a record where `{string: any}` is expected is **refused**:
   "record is not a valid map; not all fields have the same type".
3. Returning a `{string: any}` where the record is expected is
   **refused**: "got {string : <any type>}, expected Outer".
4. `v is {string: any} and v or {}` **type-checks clean** — the `is`
   narrows in the `and` operand — as do `v is {any} and v or nil` and
   `v is {any: any} and v or nil`.

(1)-(3) mean a typed `merge` needs exactly TWO casts at its boundary:
record-to-map on each incoming policy, map-to-record on the result.
They are not `from any` — they are the record-as-map boundary Teal has
no other spelling for, and `init_test.tl:119` already uses that reason
verbatim (`record inspected as map`). (4) means the four casts INSIDE
`merge_section` close with no cast at all.

**The precedent to copy.** `cosmic/sandbox/init.tl:246` implements
`merge(...: Options): Options` and carries zero casts; its test reads
`check.equal(merged.fs.ro[1], "/etc", …)`
(`cosmic/sandbox/init_test.tl:259-272`) with no cast anywhere. That is
exactly what `merge_test.tl` should look like afterwards.

**Headroom** (`wc -l`, 500-line cap): `merge.tl` 140, `merge_test.tl`
153, `init_test.tl` 138, all far under.

**The ratchet.** `_build/casts.tl` counts every `as` token per file
against `_build/casts_baseline.tl`. Today's rows:
`cosmic/quicksand/box/init.tl` 4, `…/init_test.tl` 3, `…/merge.tl` 4,
`…/merge_test.tl` 14.

## Change

1. **`cosmic/quicksand/box/merge.tl`** — declare
   `merge(...: types.BoxOptions): types.BoxOptions`, in the function
   and in `BoxMergeModule` (`:128`), and update the `@param`/`@return`
   comments. Keep `merge_section`, `concat_unique`, `merge_map` and
   `schema` walking `{string: any}` — the walk is schema-driven and
   dynamic on purpose, as the module's own header says of unknown keys.
   Bridge the two with the boundary casts fact (1)-(3) force:

   - in `merge`'s loop, cast each `select(i, ...)` policy to
     `{string: any}` with `-- cast: record inspected as map`;
   - cast the accumulated result back with
     `-- cast: dynamic walk rebuilt as the record it walked`.

   That is two `as` tokens in the file, both honestly reasoned.

   Then close the four internal `from any` casts with fact (4), and
   widen the two helpers to admit the nil their bodies already handle
   (`concat_unique` and `merge_map` both open with `if a then`):

   - `concat_unique(a: {any} | nil, b: {any} | nil)`, called
     `concat_unique(av is {any} and av or nil, bv is {any} and bv or nil)`
   - `merge_map` likewise over `{any: any} | nil`
   - `:100-101` become `av is {string: any} and av or {}` and the same
     for `bv`; the `elseif type(av) == "table" or type(bv) == "table"`
     guard above them is the same test `is` compiles to, so nothing
     changes at runtime.

2. **`cosmic/quicksand/box/init.tl`** — delete the `as BoxOptions` at
   `:186`; `box_merge.merge(...)` now returns `BoxOptions`.

3. **`cosmic/quicksand/box/merge_test.tl`** — delete all 14 casts. Every
   `(out.fs as {string: any}).ro as {string}` becomes `out.fs.ro`, and
   the same for `out.net`, `out.env`, `out.proc`, `out.sys`. Where a
   test reads a MAP field (`net.allow`, `env.set`), the record declares
   it, so the read is typed too. Model the result on
   `cosmic/sandbox/init_test.tl:259-272`.

4. **`cosmic/quicksand/box/init_test.tl`** — delete `:120` and `:122`;
   `:119` (`record inspected as map`) goes with them, since `out` is now
   a `BoxOptions` and `out.fs.ro` reads directly. The file's floor row
   drops 3 → 0.

`cosmic/quicksand/init.tl:45` already declares
`merge: function(...: BoxOptions): BoxOptions` and needs no change —
confirm it still type-checks rather than editing it.

Then rewrite the ratchet floor with exactly the command the gate
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and
commit the result. Never hand-edit `_build/casts_baseline.tl`.

## Non-goals

- **Do not change what `merge` DOES.** Scalar-later-wins,
  list-concat-dedupe, map-per-key, unknown-keys-as-scalars, and the
  explicit nil-checked indexing that keeps a stored `false` from
  collapsing to nil (`merge.tl:85-90`) all stay exactly as they are.
  This slice moves types, not behaviour.
- **Do not narrow the schema or make `BoxOptions` closed.** Unknown
  keys must still merge as scalars: the module header calls that "the
  right default for forward-compatible additions", and a policy table
  carrying a field `BoxOptions` does not name must still survive a
  merge.
- **Do not touch `cosmic/sandbox/**`.** Its `merge` is a separate,
  already-typed implementation; it is the precedent to copy, not a file
  to edit.
- **Do not touch the other 7 casts in `cosmic/quicksand/box/init_test.tl`'s
  siblings** or any other `quicksand` file: `run.tl` (2) and the
  remaining `init.tl` casts belong to other classes under the same
  parent.
- **Do not weaken or delete a test assertion.** Casts come out; asserts
  stay.
- **No new `-- cast: from any` anywhere.** The only casts this diff adds
  are the two boundary ones in `merge.tl`, with the reasons named above.

## Acceptance

All commands run verbatim from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The 20 sites are gone.**

  ```
  grep -c -- "-- cast: .*from any" cosmic/quicksand/box/merge.tl \
    cosmic/quicksand/box/merge_test.tl cosmic/quicksand/box/init_test.tl
  ```

  reports `0` for each (4, 14 and 2 at `9c1ff401`), and

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports exactly **20 fewer** than at pull — 124 if the bucket is still
  144. Re-measure at pull and quote both numbers.

- **The boundary casts are the only ones left in `merge.tl`, and they
  say what they are.**

  ```
  grep -n -- "-- cast: " cosmic/quicksand/box/merge.tl
  ```

  reports exactly **2** lines, neither containing `from any`, and

  ```
  grep -c -- "-- cast: " cosmic/quicksand/box/merge_test.tl \
    cosmic/quicksand/box/init_test.tl
  ```

  reports `0` for both.

- **The signature is the one the public surface already promised.**

  ```
  grep -n 'merge' cosmic/quicksand/box/merge.tl | grep 'BoxOptions'
  ```

  shows it at both the function and the module record, and

  ```
  grep -c -- "-- cast: " cosmic/quicksand/box/init.tl
  ```

  reports **3** (4 today — `:186`'s `untyped merge result` is gone).

- **The behaviour is unchanged**, which is what the existing tests are
  for:

  ```
  bin/cosmic --make test cosmic/quicksand
  ```

  ends `test: PASS`, with no test file losing an assertion:

  ```
  grep -c 'assert(\|check.equal(' cosmic/quicksand/box/merge_test.tl \
    cosmic/quicksand/box/init_test.tl
  ```

  reports at least **30** and **23** — the counts at `9c1ff401`.

- **A forward-compatible field still merges.** The unknown-key rule is
  the one behaviour a typed signature could quietly break, so it needs
  its own check rather than a claim: add or keep a test in
  `merge_test.tl` that merges two policies carrying a key `BoxOptions`
  does not declare and asserts the later one wins, and name it in the
  PR description.

- **The floor was regenerated, not edited.** After
  `bin/cosmic --make run _build/casts.tl --baseline`,
  `bin/cosmic --make test _build/casts_test.tl` ends `test: PASS`;
  `_build/casts_baseline.tl` shows `cosmic/quicksand/box/merge.tl` at
  **2**, `cosmic/quicksand/box/init.tl` at **3**, and no row for
  `merge_test.tl` or `init_test.tl`.

## Enablement

No blocker, and no mechanism to invent: `BoxOptions` exists
(`cosmic/quicksand/types.tl:82`), the public signature this slice
implements is already written down (`cosmic/quicksand/init.tl:45`), and
`cosmic/sandbox/init.tl:246` with `cosmic/sandbox/init_test.tl:259-272`
is a landed worked example of the same shape — a typed variadic merge
with no casts and typed test reads.

The one thing a session could get wrong is assuming a record can be
walked or returned as a map; facts (1)-(3) above are the refusals it
would hit, measured rather than guessed, and fact (4) is the narrowing
that replaces the four internal casts. Re-run those probes at pull if
the `tl` pin has moved.

Conventions are AGENTS.md; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.
