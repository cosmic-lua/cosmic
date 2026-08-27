## Goal

G4, under the tree-migration container (3IOCdooE): put a release
carrying #1455's discover counter fix behind `bin/cosmic.pin`, so
build generation 1 — and every cold build — sees every `test_*`
definition a migrated file defines. The seam pin bump (3IU62YqO,
#1450) was the first of two; this is the second, and five of the seven
migration batches cannot land until it does.

## Evidence (measured 2026-08-27 against `origin/main` at `555873eb`)

The checkout measured is byte-identical to that commit:
`git rev-parse HEAD^{tree}` and `git rev-parse origin/main^{tree}` both
print `4b53ee3e79b648ef146e899a386f0869fc9a5b85`.

- **The pin predates the counter fix.** `bin/cosmic.pin` names
  `2026-08-27-cb39b65`; #1455 merged as `2724a719` at
  `2026-08-26 22:59:07 -0700`, after that release was cut
  (`cb39b65d`, `2026-08-26 21:50:30 -0700`).
  `git merge-base --is-ancestor 2724a719 cb39b65` → exit 1.
- **No released tag carries it yet**, so this item waits on a release
  being cut, exactly as 3IU62YqO did:

  ```
  for t in $(git tag --sort=-creatordate | head -8); do
    git merge-base --is-ancestor 2724a719 $t && echo "$t carries it"
  done
  ```

  prints nothing today. `_build/pin_probe_test.tl` and 3ITx1Gtr are
  the standing cautions about which sha a tag's binary was built from.
- **The exact cold-build failure, measured with coldbuild's own
  instrument.** Mirror every `*_test.tl` outside `testdata/` to a
  scratch directory with `sed -E '/^test_[A-Za-z0-9_]*\(\)$/d'`
  applied — i.e. the whole tree migrated — then run
  `_build/coldbuild_test.tl`'s argv over the mirror:

  ```
  COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types \
    --include-dir . --include-dir o/_types/types_gen \
    $(find "$MIRROR" -name '*_test.tl' | sort)
  ```

  → exit 1, `243` of `251` files pass, and **eight files fail with
  twelve `warning: unused function test_*` lines**:

  | file | migration batch |
  |------|-----------------|
  | `_types/tlast_test.tl` (1) | 1 |
  | `cosmic/fs/find_close_test.tl` (1), `cosmic/sandbox/init_test.tl` (2) | 3 |
  | `cosmic/sqlite/advanced_test.tl` (2), `cosmic/sqlite/close_test.tl` (2) | 4 |
  | `cosmic/_teal_ast_test.tl` (1), `cosmic/fd_read_test.tl` (1) | 5 |
  | `cosmic/searcher_test.tl` (2) | 6 |

  Batches 2 and 7 have no failing file, so this blocks batches 1, 3,
  4, 5 and 6.
- **The tree's own checker already sweeps it clean**, which is what
  makes this a pin bump and not a code fix. The same argv under
  `o/bin/cosmic` instead of `o/bootstrap/cosmic`, over batch 1's 65
  migrated files, is exit 0 with `65` passed; the pinned bootstrap is
  64 of 65.
- **This is the cold-build rule's staging case** (AGENTS.md): land the
  checker first, bump the pin to a release carrying it, then land the
  code that needs it. `_build/coldbuild_test.tl`'s own assertion
  message names the same remedy.

## Change

`bin/cosmic.pin`: set `url` to a `cosmic-lua` release asset that
contains `2724a719` (#1455), and `sha256` to that asset's digest.
Both lines together — the file is read by `bin/cosmic` with sed and
stays two plain lines. Nothing else in the repo changes.

Verify the chosen release actually carries the counter fix before
bumping, rather than trusting its date. `_types/tlast_test.tl` is the
shortest probe, because its `test_cache_thaws_on_fresh_tl` contains
`assert(thaw is function(any): (any, any), …)` — a `function` token in
type position, the shape the old depth walk lost:

```
printf 'local function test_a()\n  local f: function(any): (any, any)\n  assert(f == nil)\nend\n' > /tmp/probe_test.tl
<the-release-binary> --check types /tmp/probe_test.tl
```

must print `Type check passed`, where the current pin's binary emits
`unused function test_a`.

## Non-goals

No migration edits — deleting self-call lines is the batch children's
work and none of it belongs in this diff. No other pin
(`3p/cosmos/cosmos_pin.tl`, `3p/tl/tl_pin.tl`) moves. No change to
`bin/cosmic`, to `_tool/discover.tl`, to `_build/coldbuild_test.tl`,
or to the release workflow. Cutting the release itself is not this
diff either; if none carries the fix yet, this item waits.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`, run from a tree with no
  prior `o/` so the new pin is what bootstraps it.
- `bin/cosmic --make test _build/coldbuild_test.tl` passes.
- The pinned bootstrap accepts a migrated tree — the command that
  fails today:
  `COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types --include-dir . --include-dir o/_types/types_gen $(find "$MIRROR" -name '*_test.tl' | sort)`
  over a scratch mirror built as in Evidence exits 0, with `251` of
  `251` files passing (today: exit 1, 243 of 251).
- `grep -c '^url = ' bin/cosmic.pin` is `1` and
  `grep -c '^sha256 = ' bin/cosmic.pin` is `1` — the file stays two
  plain lines.

## Enablement

The gap this item exists to close is already a gate:
`_build/coldbuild_test.tl` fails the PR that needs a newer checker, so
no batch can land this silently. What it did NOT catch is the ordering
— 3IU62YqO bumped for the seam while #1455 was still in flight, so a
second bump was needed and nobody had filed it. The countermeasure is
this item plus the batch specs' `## Enablement` sections naming it, so
`next` sequences the release, the bump, and the batches in that order.
