## Goal

G3 — the cast epic's wave 6b. Wave 6's re-measure (item `3I7OygFC`,
research) tested every `narrowing-gap` cast site against the tree at
main `aaf4af95` by deleting it and running `--check types`. Ten sites
under the single reason string `function shape` came back clean: the
checker no longer needs the cast, so it is pure noise standing between
a reader and the code. This wave deletes exactly those ten.

**Attach this item under `3HyRcW05` (the cast epic), sibling of
`3I7OygFC`.** It is filed unparented only because `plan` was over its
WIP limit when the research landed.

## Change

Delete the `as` cast and its `-- cast: function shape` marker at each
of these ten sites, and nothing else. Every one was verified
individually (`--check types <file>` clean with that one cast gone) and
all ten together in one worktree (`--make check: PASS (513 files)`,
`--make lint: PASS (605 files)`, `--make fmt: PASS (513 files)` at
`aaf4af95`).

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

Line numbers are at `aaf4af95`; re-locate by the marker string, not by
number, if main has moved. `cmd/cosmic/main.tl:467` carries a varargs
return (`: any ...`) — the whole ` as function(...: any): any ...`
suffix goes, leaving `local run_chunk = chunk`.

Regenerate the cast floor in the same commit
(`bin/cosmic --make lint` passed with the deletions and the floor
untouched, since the ratchet is a ceiling — but the floor should still
fall to match). Expected per-file delta in `_build/casts_baseline.tl`:

```
_cli/require_hints.tl        -1
cmd/cosmic/main.tl           -1
cosmic/coverage/init_test.tl -1
cosmic/fetch/init.tl         -7
```

Tree total: 444 markers → 434 (the enumeration grep below).

## Non-goals

- no other cast site moves — the other 32 verified-removable
  `narrowing-gap` sites are wave 6c's, and the 40 still-blocked ones
  are the D5 upstream-first backlog's.
- no restructuring: every one of these ten is a pure deletion. If a
  site does not check clean after deleting the cast alone, main has
  moved — stop and bounce the item rather than reshaping the code.
- no tl patch work (`3p/tl/tl_patch.tl`).
- the four `-- cast: function shape (…)` sites
  (`cosmic/net/connect.tl:95`, `cosmic/net/socket.tl:333,396,436`) are
  NOT in this wave: wave 6 confirmed all four are genuine binding
  overload boundaries that refuse deletion.

## Acceptance

```
bin/cosmic --make ci
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc -l          # 434 (was 444)
git grep -h -o -E -- '-- cast: function shape$' -- '*.tl' | wc -l # 5 (was 15)
```

- `ci: PASS`, quoted in the PR description.
- the diff touches only the four files above and
  `_build/casts_baseline.tl`.
- the marker count falls from 444 to 434 and no other cast marker
  changes.

## Enablement

none needed — the ten sites are enumerated by `file:line`, each
deletion is pre-verified individually and as a set, and the method is
a plain deletion with no judgment left in it.
