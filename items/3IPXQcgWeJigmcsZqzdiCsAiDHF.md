## Goal

G3 — an honest type layer, and the "types never lie" promise at its
sharpest. `docs/design/nil-flow.md`'s census found one site in the
PUBLISHED API where the type does not merely fail to prove a value is
non-nil — it asserts something the binding underneath does not support:

```
-- cosmic/time.tl:33
--- @return integer Seconds since epoch
--- @return integer Nanoseconds
local function now(): integer, integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs, nanos
end
```

`unix.clock_gettime` returns `integer | nil` in slot 1. `now()` declares
`integer, integer`. A clock failure is therefore a nil handed to a caller
whose type says it cannot receive one — and every caller of
`cosmic.time.now()` inherits that lie. `monotonic`, `now_ms`,
`monotonic_ms` and `monotonic_ns` repeat the shape; the census flags
seven rows in the file — two `return` rows (`cosmic/time.tl:35`, `:44`)
and five operand rows (`:53`, `:61`, `:71` and their siblings), per
`docs/design/nil-flow.md` lines 176 and 205 (`cosmic/time.tl` 5 operand
+ 2 return).

Re-measured 2026-08-26 against `d5a6d788`:
`grep -c clock_gettime cosmic/time.tl` reports `5`;
`wc -l cosmic/time.tl` reports `423` (77 lines of headroom under the
500-line cap).

## The shape, decided

**The module asserts the read and throws if it ever fails.** The three
candidates the census left open, and why this is the one:

1. **Fallible return** (`now(): integer | nil, string`) — rejected on
   count. `grep -rn --include='*.tl' -E '\btime\.(now|monotonic)(_ms|_ns)?\('`
   finds **43 call sites** outside `o/` (re-measured 2026-08-26), most of
   them timing loops and log timestamps. Pushing an unreachable nil onto
   all 43 is the failure the Non-goals below name: it moves the lie one
   level out and buys no caller a decision they can act on.
2. **Throw** — chosen. `clock_gettime`'s `integer | nil` is honest for an
   arbitrary caller-supplied clock id and unreachable for the two
   CONSTANTS this module passes, `unix.CLOCK_REALTIME` and
   `unix.CLOCK_MONOTONIC`. `assert` is the Lua primitive for exactly that
   claim, and the carried `narrow-assert-decl` patch makes
   `local secs = assert(...)` yield a plain `integer`, so the fix is two
   lines per site with no cast.
3. **Document and guard without throwing** — rejected as incoherent:
   there is no honest value to return in place of the time. A `or 0`
   fallback replaces a type lie with a data lie, silently.

**The blocker has landed.** D23 is amended (`d5a6d788`, PR #1384) and now
licenses exactly this shape as a RULE:

> a `cosmic.*` module may `assert` a `cosmo.*` binding return whose
> declared `| nil` is unreachable for the arguments that call passes,
> provided the assert carries a trailing `-- assert: <why the nil cannot
> occur>` comment naming the reason.

So this slice must carry that comment at every assert it adds; an assert
without one is outside what D23 licenses.

**The unreachability argument is documented upstream, not inferred.**
`whilp/cosmopolitan`'s `tool/net/definitions.lua` (the source
`o/_types/types_gen/cosmo/unix.d.tl` is generated from) says of
`clock_gettime`: "Returns `EINVAL` if clock isn't supported on platform.
**This function only fails if `clock` is invalid.**" — and, per clock,
"Cosmopolitan guarantees this clock will never raise `EINVAL`" for BOTH
`CLOCK_REALTIME` and `CLOCK_MONOTONIC`. That sentence pair is the reason
the `-- assert:` comments must state.

Note the binding's declared shape:
`---@return integer|nil seconds, integer nanos`. Only slot 1 admits nil;
`nanos` is already declared `integer`. Assert slot 1 only.

## Change

Touch exactly two files: `cosmic/time.tl` and `cosmic/time_test.tl`.

In `cosmic/time.tl`, at each of the five `unix.clock_gettime` call sites
(lines 34, 43, 52, 60, 70 today — the bodies of `now`, `monotonic`,
`now_ms`, `monotonic_ms`, `monotonic_ns`), bind slot 1 through `assert`
so the local is a plain `integer` and the declared returns stop lying.
Rename only the raw binding, so the asserted local keeps the name the
rest of the body already uses:

```teal
local secs_or_nil, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
-- assert: clock_gettime fails only on an invalid clock id, and
-- cosmopolitan guarantees CLOCK_REALTIME never raises EINVAL
local secs = assert(secs_or_nil, "clock_gettime(CLOCK_REALTIME) failed")
```

and the `CLOCK_MONOTONIC` equivalent at the three monotonic sites. Every
site gets its own `-- assert:` comment naming its clock, because D23's
rule is per-assert; the FIRST site (`now`) carries the fuller form above
(binding contract plus the guarantee), the other four may carry the
one-line form (`-- assert: cosmopolitan guarantees CLOCK_MONOTONIC never
raises EINVAL; clock_gettime fails only on an invalid clock id`).

The five functions' signatures and their `---` doc comments do NOT
change — that is the point of the shape chosen. No caller changes.

In `cosmic/time_test.tl` (353 lines today), add one test beside the
existing `test_now` / `test_monotonic` asserting that each of the five
public readers returns a non-nil integer and that a monotonic pair does
not go backwards — the failure path is unreachable through the public
API, so the test pins that the asserted values reach callers, not a
forced failure. Call it on the line after its `end`, per AGENTS.md.

## Non-goals

- **Do not widen the return type by reflex.** `integer | nil` with no
  decision about what a caller does with the nil moves the lie one level
  out; that is the failure mode this slice exists to avoid.
- **Do not touch `AGENTS.md` or `docs/decisions/**`.** PR #1384 already
  landed the D23 amendment and rewrote `AGENTS.md:237` to name three
  sanctioned shapes. There is nothing left to update there, and a diff
  that touches those files is out of scope.
- **Do not touch `whilp/cosmopolitan`.** `clock_gettime`'s C contract is
  frozen and correct: the union is right for an arbitrary clock id, and
  the defect is this side's, in passing a constant and then declaring
  the result infallible without saying so.
- **Do not assert `nanos`.** Slot 2 is declared `integer`, not
  `integer | nil`; an assert there licenses nothing and adds noise.
- **Do not touch `cosmic/time.tl`'s other `unix.*` call sites.**
  `unix.nanosleep` (line 83, inside `sleep_remaining_ms`),
  `unix.gmtime` (line 128) and `unix.localtime` (line 158) are
  REACHABLE failures already returned fallibly — `integer | nil, string`
  and `DateTime | nil, string`. D23's new rule does not admit them and
  converting them to asserts would be a real regression.
- **Do not fix other census sites.** `_build/size.tl`,
  `cosmic/fs/tree.tl`, and `cosmic/time.tl:397`'s own `format_iso8601`
  producer (8 flagged sites, `docs/design/nil-flow.md` line 323) are
  separate work.
- **Do not change `cosmic.time`'s public function names or units.** D20
  governs; this slice changes honesty, not naming.
- **Do not add a lint for the `-- assert:` comment.** That is board item
  3IQfhI33, out of this diff.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/time_test.tl` ends `test: PASS`.
- `grep -c -- '-- assert:' cosmic/time.tl` reports `5` or more (today
  `0`, and `0` across the whole tree:
  `grep -rn --include='*.tl' -- '-- assert:' . | grep -v '^\./o/' | wc -l`
  reports `0`).
- `grep -c 'assert(' cosmic/time.tl` reports `5` (today `0`).
- `grep -c 'clock_gettime' cosmic/time.tl` still reports `5` — no call
  site was added or dropped.
- `grep -c 'unix.nanosleep\|unix.gmtime\|unix.localtime' cosmic/time.tl`
  still reports `3` — the fallible sites are untouched.
- `git diff --name-only origin/main` lists exactly `cosmic/time.tl` and
  `cosmic/time_test.tl` — no `AGENTS.md`, no `docs/**`, and no caller.

The census's own Method (`docs/design/nil-flow.md`, `## Method`) is NOT
an acceptance command: it needs a throwaway strict checker that is not
committed and was deleted, so it cannot be run literally. The greps
above are the runnable contract; a reader who rebuilds that prototype
should find `cosmic/time.tl` gone from the flagged files (today 7 rows).

## Enablement

none needed. The doctrine seat landed with PR #1384 (D23 amended
2026-08), and its rule — assert plus a trailing `-- assert: <why>` — is
restated at `AGENTS.md:237`. `narrow-assert-decl` already makes `assert`
narrow in expression position (`3p/tl/tl_patch.tl`), and this slice is
the FIRST use of the `-- assert:` convention in the tree, so there is no
existing example to match; the `Change` block above is the form.
