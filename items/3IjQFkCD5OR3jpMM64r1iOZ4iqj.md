## Goal

`unix.nanosleep`'s return shape changed in `cosmic-lua/cosmopolitan`
(board item `3IivGU58CJHrof9ObOc0YFjout2`, PR #315, "unix.nanosleep:
return one remainder table instead of sharing slots with errors") —
a breaking, cross-repo change this repo's own `cosmic/time.tl` wrapper
depends on directly. Track the wrapper fix so it lands in the same PR
that bumps `3p/cosmos/cosmos_pin.tl` to the first cosmopolitan release
carrying PR #315, rather than being discovered as a build break after
the pin bump lands.

## Evidence

`cosmic/time.tl:83`, in `sleep_remaining_ms`, currently destructures
`unix.nanosleep`'s OLD shape directly:

```lua
local rem_s, rem_ns, eno, eintr_s, eintr_ns = unix.nanosleep(seconds, ns)
```

with a comment right above it: "Slot 2 is slot-accurate since the pin
bump: the error string only when slot 1 is nil, the remainder's
nanoseconds past this guard."

PR #315's new shape (from its own description, verify against the
actual landed code once the pin carries it):

- success: `remaining:table` — one value, `{seconds=0, nanos=0}`
  (POSIX leaves the buffer unspecified on success, so this is always
  zero)
- failure (non-EINTR): `nil, error:str, errno:int` — unchanged
- failure (EINTR): `nil, error:str, errno:int, eintr_remaining:table`
  — `eintr_remaining` is `{seconds=N, nanos=N}`

`tool/net/definitions.lua` in cosmopolitan gains a `unix.SleepRemainder`
record (`@field seconds`, `@field nanos`) for this — the generated
`cosmo.d.tl` type declarations `sleep_remaining_ms` currently types
against will change shape too.

`cosmic/quicksand/proxy.tl:81` calls `unix.nanosleep(0, 10000000)` and
discards all return values — confirmed unaffected by this change
(per PR #315's own author, who checked this before opening it).

## Change

Once `bin/cosmic --make fetch` picks up a cosmos pin built from a
cosmopolitan release carrying PR #315 (`3p/cosmos/cosmos_pin.tl`
version + sha256 bump), in the same PR:

1. Rewrite `cosmic/time.tl:83`'s `sleep_remaining_ms` to destructure
   the new shape: a `remaining` table on success/non-EINTR-failure
   position, and a fourth `eintr_remaining` table only present on the
   EINTR branch. Preserve `sleep_remaining_ms`'s own existing contract
   (`integer | nil, string` — the internal millisecond-remainder
   engine, per its own comment: "reports the remainder in MILLISECONDS
   because a (secs, nanos) pair would push the error into slot 3, out
   of `local v, err`'s reach") — only the INTERNAL destructuring of
   `unix.nanosleep`'s return values changes; the function's own public
   shape does not need to.
2. Re-run `bin/cosmic --make ci` and confirm `cosmic/time_test.tl` (if
   it exercises `sleep_remaining_ms`/`sleep_ms` directly — check) still
   passes; add coverage for the EINTR path if none exists today.
3. Confirm no other `cosmic/*.tl` file calls `unix.nanosleep` directly
   (`grep -rn 'unix\.nanosleep\|cosmo\.unix\.nanosleep' cosmic/` at
   pickup time — re-run rather than trust this item's own grep, since
   the tree will have moved).

## Non-goals

- Does not itself bump `3p/cosmos/cosmos_pin.tl` — that is ordinary
  pin-bump process (`bin/cosmic --make fetch` after updating the pin
  file), ideally batched with other accumulated cosmopolitan contract
  fixes from the same census effort (openpty #311, capget #309,
  isatty #307, the `too_large` %I fix #310, the `Database:serialize`
  crash fix #313, the `ConvertLuaArrayToStringList` crash fix #312) —
  landing them together avoids repeated pin-bump PRs for a burst of
  independent, already-merged cosmopolitan fixes. Whether to batch or
  bump per-fix is the pin-bump PR's own call, not this item's.
- Does not touch `cosmic/quicksand/proxy.tl:81` — confirmed unaffected.
- Does not itself verify PR #315's design (already reviewed and
  merged on the cosmopolitan side) — this item trusts that verdict and
  only tracks the consuming change.

## Acceptance

- `cosmic/time.tl`'s `sleep_remaining_ms` correctly destructures
  whatever shape the pinned cosmopolitan release's `unix.nanosleep`
  actually returns (verify against the generated `o/_types/types_gen`
  declaration at pickup time, not this item's description, in case the
  landed shape drifted from PR #315's description before it shipped).
- `bin/cosmic --make ci` ends `ci: PASS`.
- A probe or test exercises both the uninterrupted-sleep path and an
  EINTR-interrupted path through `cosmic.time`'s public API
  (`sleep_ms`), confirming behavior is unchanged from before the pin
  bump (same external contract, different internal destructuring).
