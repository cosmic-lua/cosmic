## Goal

G3 — an honest type layer. Three library iterator declarations put
the terminating nil in the iterator's first return type, so every
`for … in` body over them types its variable as `string | nil` and
seven census rows exist with no producing call to wrap.

## Evidence

Census Method (`docs/design/nil-flow.md`, `## Method`) re-run
2026-09-02 at `5a36e7c9` under a strict binary that reproduced the
Method's proof-of-life. Probe: `for x in it()` with `it(): function():
string | nil` flags `take(x)` at a `string` sink; the same with
`function(): string` does not — tl's own stdlib declares
`string.gmatch`'s iterator without the nil for this reason. The three
declarations and the rows they cause:

```text
cosmic/fs/find.tl:108   FileIter.__call: function(self: FileIter): string | nil, {string}
  -> cosmic/fs/path_test.tl:210, fs/traps_test.tl:159, fs/walk_example.tl:87,
     fs/walk_test.tl:89, fs/walk_test.tl:430
cosmic/stream.tl:56     type LineIter = function(): string | nil, string
  -> cosmic/net/io_test.tl:103
cosmic/fetch/body.tl:19,137   Body.lines(): function(): string | nil, string
  -> cosmic/fetch/stream_test.tl:69
```

### A first attempt at this Change was rejected (PR #1643) — read why

A prior build of this item retyped all three declarations to plain
`string`, which fixes the `for … in` rows above but silently breaks
honesty at three DIFFERENT call sites that use the same iterator
DIRECTLY, outside a `for … in` loop, specifically to read its
TERMINATING call's payload — a documented, tested pattern, not an
edge case:

- `cosmic/fs/find.tl:123-125` (docstring) and `:271-274`: 
  `local _, errs = iter()` reads `FileIter`'s trailing subtree-error
  list.
- `cosmic/net/io_test.tl:174-176`: `local line, err =
  stream.lines(b)()` then asserts `line == nil and err ~= nil` on a
  read failure.
- `cosmic/fetch/stream_test.tl:118-126`: three direct `iter()` calls
  asserting `nil` on a mid-stream failure.

A blanket retype makes the checker claim these calls can never return
`nil` when they genuinely, currently do — confirmed by two mutation
tests on the rejected PR's head (see board item `3ImmKYCJ`'s history
for the full trace) — which is worse than the `string | nil` status
quo it started from: `--make ci` now passes on code that crashes at
runtime.

Board item `3ImmKYCJ` (handle «rHCW_59sk») settled the direction to
take instead — see `## Change` below, which supersedes the blanket
retype this section describes.

## Change

Revised per board item `3ImmKYCJ`'s decision (2026-09-03), superseding
the blanket-retype approach described in the rejected-PR note above.

Split the two purposes these iterators currently overload onto one
`__call` signature, instead of retyping that one signature to cover
both:

1. **The `for … in` call** keeps its existing calling convention
   (`iter()`, called by the for-in protocol) and its first return is
   retyped to plain, non-nilable `string` — this closes the seven
   census rows above exactly as the original Change intended.
2. **The terminating payload** (the subtree-error list, the
   read-failure message) moves to a NEW, separate accessor with its
   own honestly-nilable/typed signature, called once after the loop
   ends — never by calling the iterator again.

The concrete shape differs per iterator; do this per-iterator, not
uniformly:

- **`FileIter`** (`cosmic/fs/find.tl:107-113`): already a record
  with a `__call` metamethod and an existing `close` method — already
  an object. Add a new method (e.g. `errors(self: FileIter):
  {string}` — exact name is this build's own naming call, per D20)
  returning the trailing subtree-error list. Retype
  `metamethod __call` to `function(self: FileIter): string`.
  Migrate `cosmic/fs/find.tl:123-125`'s documented direct-call
  pattern (and its docstring, and the stale copy at `:271-274`) from
  `local _, errs = iter()` to the new accessor call.
- **`stream.LineIter` / `Body.lines()`** (`cosmic/stream.tl:56`,
  `cosmic/fetch/body.tl:137` — `Body:lines()` returns exactly
  `stream_mod.lines(self)`, so fixing `stream.LineIter` fixes both):
  currently a BARE FUNCTION type
  (`type LineIter = function(): string | nil, string`), not a table
  — there is nothing to hang a second accessor on today. Promote
  `LineIter` to a callable record: a `__call` metamethod (retyped to
  plain `string`) plus a new method exposing the terminal
  read-failure message. This is a real shape change — every existing
  holder of a `LineIter`-typed value needs to keep working against
  the new record shape, not just the two direct-call sites named
  above; audit for others during the build (grep `LineIter`,
  `stream.lines`, `:lines()` across `cosmic/`).

Then drop the corresponding `check.must(<var>)` wraps in whichever
sweep children have landed (or leave them; they are harmless). A
public-API type AND shape change (LineIter goes from function to
record): name it plainly in the PR and in the module docs.

## Non-goals

- No behaviour change to what data the iterators expose — only how a
  caller reaches the terminating payload changes (a method call
  instead of re-invoking the iterator), and only for the two
  direct-call purposes named above.
- No compiler/checker change and no `3p/cosmos`-style pin-bump
  gating — this is an ordinary library-level change, achievable in
  one or two normal PRs.
- No test-side edits beyond removing wraps made unnecessary and
  migrating the three named direct-call sites (plus whatever the
  `LineIter` audit above turns up) to the new accessor.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan no longer reports the seven `for … in` rows
  above (or their `check.must(<var>)` successors are removable
  without a new row).
- The three originally-flagged direct-call sites (`find.tl:123-125`,
  `io_test.tl:174-176`, `stream_test.tl:118-126`) are migrated to the
  new accessor and remain HONESTLY typed — re-run this item's own
  mutation-test standard against the new code before calling it done:
  confirm a wrong narrowing/unwrap at one of those three sites is
  actually caught by `--make check`, not silently passed the way the
  rejected PR was.
