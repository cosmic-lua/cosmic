## Goal

G3 — the cast epic's wave 6b. Wave 6's re-measure (item `3I7OygFC`,
research) tested every `narrowing-gap` cast site against the tree by
deleting it and running `--check types`. Ten sites under the single
reason string `function shape` came back clean: the checker no longer
needs the cast, so it is pure noise standing between a reader and the
code. This wave deletes exactly those ten.

## Change

Delete the `as` cast and its `-- cast: function shape` marker at each
of these ten sites, and nothing else.

**Re-verified end to end 2026-08-23 at main `d01ea6ac`** in a detached
worktree: all ten deletions applied together, `bin/cosmic --make check`
ends `check: PASS (513 files)` and `bin/cosmic --make ci` ends
`ci: PASS (5 stages)` with the regenerated baseline. Nothing has drifted
since the wave-6 research at `aaf4af95` — the markers are at the same
line numbers, and `git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc
-l` still prints 444.

```
_cli/require_hints.tl:237       _G.require = enhanced_require as function(string): any
cmd/cosmic/main.tl:467          local run_chunk = chunk as function(...: any): any ...
cosmic/coverage/init_test.tl:23 return chunk as function()
cosmic/fetch/init.tl:381        Fetch as (function(string, any): (any, any)),
cosmic/fetch/init.tl:382        stream as (function(string, any): (any, any)),
cosmic/fetch/init.tl:419        get = made.get as (function(string, Options): (Response | nil, Error)),
cosmic/fetch/init.tl:421        post = made.post as (…)
cosmic/fetch/init.tl:423        put = made.put as (…)
cosmic/fetch/init.tl:425        delete = made.delete as (…)
cosmic/fetch/init.tl:427        download = made.download as (…)
```

Re-locate by the marker string, not by number, if main has moved.
`git grep -n -- "-- cast: function shape" -- '*.tl'` prints 20 lines
today; the ten above are the ones this wave takes. Three shapes:

- `cmd/cosmic/main.tl:467` carries a varargs return, so the whole
  ` as function(...: any): any ...` suffix goes, leaving
  `local run_chunk = chunk`.
- `cosmic/fetch/init.tl:381-382` are ARGUMENTS to `fetch_extras.make`,
  each on its own line with a trailing marker: the line becomes
  `  Fetch,` and `  stream,`.
- `cosmic/fetch/init.tl:419-427` carry the marker as a STANDALONE
  comment on the line above each entry, so both lines collapse to one
  (`  get = made.get,` and its four siblings).

**Regenerate the cast floor in the same commit** —
`bin/cosmic --make run _build/casts.tl --baseline`. This is required,
not cosmetic: `_build/casts_test.tl` matches the counts EXACTLY, not as
a ceiling. Measured 2026-08-23, `--make ci` without the regen ends
`ci: FAIL (coverage)` on
`.coverage/_build/casts_test.tl` with `cosmic/fetch/init.tl: 8 casts
(baseline 15)`. The regenerated file's own summary line reads
`casts: wrote _build/casts_baseline.tl — 434 casts in 130 files`
(444 in 132 today), and its diff is exactly four rows — note that TWO
of them are row REMOVALS, because a file at zero is absent from the
floor rather than present with a 0:

```
-  ["_cli/require_hints.tl"] = 1,          (row deleted)
-  ["cosmic/coverage/init_test.tl"] = 1,   (row deleted)
-  ["cmd/cosmic/main.tl"] = 4,   +  ["cmd/cosmic/main.tl"] = 3,
-  ["cosmic/fetch/init.tl"] = 15, +  ["cosmic/fetch/init.tl"] = 8,
```

**In-flight overlap to expect.** PR #1328 (item `3I7Otbvg`, cast wave 4)
also regenerates `_build/casts_baseline.tl` and is in `check` as of
2026-08-23. If it merges first, main's totals are 443 in 132 files and
the two numbers in Acceptance below become 433 and 5, `_tool/testrun.tl`
reads 1 and `cosmic/string_test.tl` reads 3 — refresh them at pull per
the slice loop. A conflict in `_build/casts_baseline.tl` is resolved by
re-running the regen command on the merged tree, never by editing the
rows by hand.

## Non-goals

- no other cast site moves — the other 32 verified-removable
  `narrowing-gap` sites are wave 6c's (item `3IFUaiGA`), and the 40
  still-blocked ones are the D5 upstream-first backlog's.
- no restructuring: every one of these ten is a pure deletion. If a
  site does not check clean after deleting the cast alone, main has
  moved — stop and bounce the item rather than reshaping the code.
- no tl patch work (`3p/tl/tl_patch.tl`).
- the four `-- cast: function shape (…)` sites
  (`cosmic/net/connect.tl:95`, `cosmic/net/socket.tl:333,396,436`) are
  NOT in this wave: wave 6 confirmed all four are genuine binding
  overload boundaries that refuse deletion. They carry a parenthesized
  reason, so the `function shape$` grep in Acceptance already excludes
  them.
- the five bare `function shape` markers that SURVIVE this wave
  (`cosmic/check_assertions_test.tl:382`, `cosmic/coverage/init.tl:162`,
  `cosmic/quicksand/init.tl:73`, `cosmic/quicksand/proxy.tl:144,145`)
  stay untouched, and the sixth quicksand marker
  (`proxy.tl:142`, `-- cast: function shape from map view`) with them.
- no change to `FetchModule`'s declared field types or to what
  `fetch_extras.make` returns — the casts go, the contract does not.

## Acceptance

```
bin/cosmic --make ci
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc -l          # 434 (was 444)
git grep -h -o -E -- '-- cast: function shape$' -- '*.tl' | wc -l # 5 (was 15)
git status --short
```

- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`, quoted in the PR
  description. (Measured 2026-08-23 at `d01ea6ac` with this exact
  change applied: it does.)
- the marker count falls from 444 to 434 and the bare `function shape`
  count from 15 to 5.
- `git status --short` lists exactly five modified files and no others:
  `_build/casts_baseline.tl`, `_cli/require_hints.tl`,
  `cmd/cosmic/main.tl`, `cosmic/coverage/init_test.tl`,
  `cosmic/fetch/init.tl`.

## Enablement

none needed — the ten sites are enumerated by `file:line` AND by the
grep that relocates them, the deletion shape is spelled out for each of
the three forms they take, the whole set was applied and gated green at
`d01ea6ac` during this refinement pass, and the one wrong turn a
literal session could take (skipping the baseline regen because the
older spec called the ratchet a ceiling) is now measured, corrected,
and caught by the `--make ci` acceptance.
