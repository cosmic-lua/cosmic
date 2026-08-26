## Goal

G3, via the cosmo-contracts container: the payoff inside cosmic. The
pin carries exact contracts, so the interim assert dance retires and
the generated types say what the C does — nothing left to dispose of.

## Evidence

Re-measured at refinement, 2026-08-26, against whilp/cosmic main
`b5739e40`:

- The pin: `3p/cosmos/cosmos_pin.tl` at `2026.08.24-354c17e08`.
- **The target release exists and is verified**: whilp/cosmopolitan
  release `2026.08.26-1e1658153`, whose tag commit `1e165815` IS the
  merge of #277 (clock_gettime raises) with #276 (path.join raises) as
  the commit directly beneath it (`git log origin/master` shows
  `1e165815`, `5fb988db`, in that order). Its `cosmos.zip` sha256,
  computed from the downloaded asset at refinement:
  `ea7e05a6a13bb9e1f6b3d99829f0fd9639f069e7aa527976b59914748ec18001`.
  A newer release also containing both is equally valid; re-verify
  ancestry and recompute the sha if choosing one.
- The interim asserts this slice deletes: both PRs are merged, and
  `grep -rn -- '-- assert:' cosmic/time.tl cosmic/fs/path.tl | wc -l`
  reports **6** on `b5739e40` (five in `cosmic/time.tl`, one in
  `cosmic/fs/path.tl`).
- The generated declarations today (any built tree):
  `o/_types/types_gen/cosmo/path.d.tl` `join` line declares
  `string | nil`; `o/_types/types_gen/cosmo/unix.d.tl`
  `clock_gettime` declares `integer | nil` in slot 1 plus trailing
  `string, Errno` slots.

## Change

1. **`3p/cosmos/cosmos_pin.tl`**: set `version` to
   `2026.08.26-1e1658153` and the `sha` to
   `ea7e05a6a13bb9e1f6b3d99829f0fd9639f069e7aa527976b59914748ec18001`
   (or a newer verified release per Evidence). Then `bin/cosmic
   --make fetch && bin/cosmic --make build` — the types regenerate
   from the new pin's embedded `definitions.lua`; nothing is committed
   under `o/`.
2. **`cosmic/time.tl`**: at the five clock sites, revert each
   three-line assert dance to the direct two-slot read
   (`local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)` and
   the MONOTONIC equivalents), deleting the `-- assert:` comments and
   the `secs_or_nil` renames. Signatures and doc comments stay: they
   already declare plain integers, which is now the binding's own type.
3. **`cosmic/fs/path.tl`**: the `join` wrapper body returns to
   `return cosmo_path.join(...)`; delete the assert and its comments;
   the doc comment keeps the sentence "Calling with no arguments, or
   with every argument nil, is a caller error and throws" — true as
   ever, the throw now comes from the binding. The routing of
   `walk.tl`/`find.tl`/`tree.tl` through this wrapper STAYS — one
   boundary for the binding is right regardless of its type.
4. **Tests stay.** `cosmic/time_test.tl`'s
   `test_clock_readers_return_integers` and `cosmic/fs/path_test.tl`'s
   `test_join_returns_a_plain_string` / `test_join_with_no_arguments_throws`
   pass unchanged (the no-args throw now originates in C; the test
   asserts `pcall` failure without matching the message). Update only
   their comments where they attribute the behavior to the D23 assert.
5. **Compare gate**: per the pin-bump procedure (cosmopolitan
   AGENTS.md), run the `_perf` compare against the previous pin —
   baseline on the old pin, current on the new, per the optimize
   skill's commands — and quote the gate verdict in the PR.

## Non-goals

- No consumption of census follow-ups — each later contract fix gets
  its own pin-bump slice or rides a scheduled one.
- No D23 edit: the rule ("assert an unreachable binding nil, with the
  comment") stays licensed; its instance count falling to zero here is
  the outcome, not a doctrine change. `docs/decisions/**` untouched.
- No `3p/tl` changes, no `tl_patch.tl` changes.
- No other `cosmo.*` call-site changes beyond the six assert sites —
  the latent-nil sweeps own their sites.

## Acceptance

Run from the cosmic repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -rn -- '-- assert:' cosmic/time.tl cosmic/fs/path.tl | wc -l`
  reports 0 (at pull: 6).
- `grep -n 'join: function' o/_types/types_gen/cosmo/path.d.tl` shows
  a return of `string` with no `| nil` (today: `string | nil`).
- `grep -n 'clock_gettime' o/_types/types_gen/cosmo/unix.d.tl` shows
  no `| nil` (today: `integer | nil` slot 1).
- `bin/cosmic --make test cosmic/time_test.tl cosmic/fs/path_test.tl`
  ends `test: PASS`.
- The perf compare gate verdict (old pin vs new) quoted in the PR
  reports no regression.

## Enablement

none needed any more: both blockers (3IQtfuCx, 3IQtg7Sm) are ended —
their block edges are recorded as cleared on this item — and the
release carrying them is published and verified in Evidence, with its
sha computed. Everything the implementer needs is literal in this
spec.
