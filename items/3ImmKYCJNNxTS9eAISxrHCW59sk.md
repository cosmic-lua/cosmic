## Question

Can `FileIter.__call`, `stream.LineIter`, and `Body.lines()` be
honestly retyped to a non-nilable first return (`string` instead of
`string | nil`) at all — given each is a documented, tested pattern
where the iterator is called DIRECTLY, outside a `for … in` loop, to
read its terminating payload — or does G3 need a different mechanism
for this class of iterator instead of mistyping the declaration?

## Evidence

Found by the fresh-context reviewer of item `3IlWcRWIzkW7s4x4Wlhbj12PZHY`
(«bj12_PZHY», "library iterators declare their terminating nil in the
first return...") on PR cosmic-lua/cosmic#1643, which it rejected.

The PR retyped all three iterators' first return from `string | nil`
to plain `string`, which fixes the `for … in` body case the item
targeted, but all three carry meaningful payload on their
TERMINATING call that documented/tested code reads by calling the
iterator directly, outside any for-in loop — exactly where the new
non-nilable type is false:

- `cosmic/fs/find.tl:123-125` (docstring) and `:278`:
  `local _, errs = iter()` is the documented way to read `FileIter`'s
  trailing subtree-error list.
- `cosmic/net/io_test.tl:174-176` (untouched by the rejected PR):
  `local line, err = stream.lines(b)()` then
  `assert(line == nil and err ~= nil, ...)`.
- `cosmic/fetch/stream_test.tl:118-126` (in a file the rejected PR
  itself edited, a few lines from its own change at line 69): three
  direct `iter()` calls asserting `second == nil`, `third == nil` on
  a mid-stream failure.

The reviewer confirmed on the PR's head that these files compiled
with NO warning under `o/bin/cosmic --make check` even though
`line`/`second`/`third` are genuinely `nil` there under the retyped
signature — the opposite of G3's "an honest type layer" goal. Two
mutation tests on a fresh clone of the PR's head (`ab49522e`)
established this is a real gap, not a reviewer misreading (details
in this item's history).

Secondary, smaller finding folded in here rather than filed
separately: `cosmic/fs/find.tl:271-274` (inside `find()`, untouched
by the rejected PR) still documents `FileIter.__call` as honestly
`string | nil, {string}` — whatever this decision lands on, that
comment needs to say the same thing the declaration does.

## Change

A decision, recorded on this item and applied to bj12_PZHY's spec.
Three original candidates were on the table:

a. retype anyway, accepting a permanent per-site blind spot at the
   three direct-call sites;
b. leave as `string | nil` status quo, the seven census rows stay
   open;
c. a checker-level narrow-only-in-`for…in` mechanism — closes both,
   at the cost of a compiler change gated by the cold-build rule.

## Decision (confirmed by the project owner, 2026-09-03)

**d. give the terminating payload its own accessor, decoupled from
the loop-call, instead of overloading one `__call` signature for two
different purposes.** Not one of the three originally-posed options
— found by asking "is there another way to check the iterator after
the loop" and verified against the actual object shapes before
accepting it:

- `for … in iter do` keeps calling `iter()` exactly as it does today
  and that call's first return is retyped to plain, non-nilable
  `string` (the fix `bj12_PZHY` originally wanted for the seven
  census rows).
- The terminating payload — `FileIter`'s trailing subtree-error list,
  `LineIter`/`Body.lines`'s read-failure message — moves to a NEW,
  separate accessor with its own honestly-nilable signature, called
  once after the loop ends instead of by calling `iter()` again.

**Cost differs by iterator — verified against source, not assumed
uniform:**

- `FileIter` (`cosmic/fs/find.tl:107-113`) is already a record with a
  `__call` metamethod AND an existing `close` method — it is already
  an object, not a bare closure. Adding `errors(self: FileIter):
  {string}` (or similar) alongside the existing `close` is a small,
  additive change. The one documented direct-call site
  (`cosmic/fs/find.tl:123-125`) moves from `local _, errs = iter()`
  to `local errs = iter:errors()`.
- `stream.LineIter` is currently declared as a BARE FUNCTION type —
  `type LineIter = function(): string | nil, string`
  (`cosmic/stream.tl:56`) — not a table. `Body.lines()`
  (`cosmic/fetch/body.tl:137`) returns exactly this same value
  (`return stream_mod.lines(self)`), so the two share one fix.
  Achieving the same accessor-based split here requires promoting
  `LineIter` from a bare function to a callable record (a `__call`
  metamethod plus a new method for the terminal error) — a real,
  if smaller-than-option-(c), shape change that touches every
  existing consumer currently typed as `stream.LineIter =
  function(): ...` (at minimum `cosmic/net/io_test.tl:174-176` and
  `cosmic/fetch/stream_test.tl:118-126`, the two direct-call sites
  named in Evidence above, plus any other holder of a `LineIter`-
  typed local).

No compiler/checker change, no cold-build-rule gating, no pin bump —
this is a library-level shape change achievable in ordinary PRs.

## Non-goals

- No code in this item; the build is «bj12_PZHY», whose spec is
  rewritten to match this decision as a follow-up edit.
- Not re-litigating the `for … in` body fix's correctness itself —
  the reviewer confirmed that half of the original PR worked; only
  the terminating-call honesty gap was ever in question.
- Not mandating a specific accessor name/method shape for `FileIter`
  or the promoted `LineIter` record — that is `bj12_PZHY`'s own
  build-time refinement, consistent with this repo's existing naming
  conventions (charter, D20).
