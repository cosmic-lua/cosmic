## Goal

G3 — an honest type layer. `cosmic/sandbox/` is the entire remaining
library share of the nil-flow census: 12 rows #1580 (library
latent-nil outside fs/ and time.tl) did not reach.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`:

```text
cosmic/sandbox/init.tl:407      4 rows (arguments)
cosmic/sandbox/init.tl:417      4 rows (record fields fs / sys / net / scope)
cosmic/sandbox/landlock.tl:352, :354, :356   assignments
cosmic/sandbox/plan.tl:201      return value
```

These are the "library share unmoved at 12" baseline every child of
3IQfJ1tn quotes. Re-measure at pull time with the Method's recipe
recorded in 3IQfJ1tn's `## Enablement`.

## Change

Guard or widen each site per the library rule: never `check.must` in
library code; a `T | nil` reaching a `T` sink gets an explicit nil
branch that returns the module's failure shape, or the declaration
widens where the nil is legitimate. `cosmic/sandbox/**` only.

## Non-goals

- No behaviour change to sandbox plans or landlock rules.
- No test-side `check.must` (that is 3IQfJ1tn's children).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan reports **0** library rows under `cosmic/`.
