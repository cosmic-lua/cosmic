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
established this is a real gap, not a reviewer misreading:

1. Reverting `FileIter.__call` back to `string | nil, {string}` while
   leaving the paired `check.must` removals in place (as the PR left
   them) still passed `--make check` cleanly — the shipped checker
   only narrows a `T | nil` at an INDEX position
   (`docs/design/nil-flow.md`), never at an argument, so `--make ci`
   would not catch either half of the retype/unwrap pairing
   regressing independently.
2. Reverting only `cosmic/sse_test.tl`'s mock `lines()` signature
   back to `string | nil` while leaving `Body.lines` retyped failed
   the build with a declared-signature mismatch — confirming that
   file's edit was a required consequence of the retype, not scope
   creep, and that the type change genuinely propagates through the
   whole call graph.

Secondary, smaller finding folded in here rather than filed
separately: `cosmic/fs/find.tl:271-274` (inside `find()`, untouched
by the rejected PR) still documents `FileIter.__call` as honestly
`string | nil, {string}` — the PR's `## Change` said to sweep doc
lines that spell the old type, and missed this one; whatever this
decision lands on, that comment needs to say the same thing the
declaration does.

## Change

A decision, recorded on this item: whether this class of
"multi-purpose iterator" (payload on ordinary calls, DIFFERENT
payload semantics on its terminating call, read directly outside the
for-in protocol by design) is:

a. retyped anyway, accepting that a direct terminating call needs its
   own narrowing/cast at each of the three call sites named above
   (the checker cannot see it, so each site's honesty depends on the
   caller doing it right, forever — arguably no improvement on the
   `string | nil` status quo for those specific calls, even though it
   fixes the seven `for … in` census rows);
b. left as `string | nil` at the type level (status quo — the
   `check.must(<var>)` wraps in `for … in` bodies stay, and the seven
   census rows are accepted as this iterator shape's structural cost,
   not closed);
c. given a narrow-only `for … in` mechanism — e.g. a distinct type
   for "the loop-position return" versus "the direct-call return," or
   teaching the checker to narrow a for-in loop variable independent
   of the iterator's own declared signature (in the spirit of the
   existing narrowing patches under `3p/tl/tl_patch/`) — closing the
   census rows AND keeping the terminating-call sites honest, at the
   cost of a checker change (which is D-something's cold-build-rule
   territory: land the checker change, bump the pin, then the type
   change, per AGENTS.md's "the cold-build rule").

The decision belongs to the project owner; the orchestrator carries
the a/b/c question (and the reviewer's evidence above) to them.

## Non-goals

- No code; the build is «bj12_PZHY» once this item's decision names
  the direction (or «bj12_PZHY»'s spec is rewritten to match option
  (b) — no cast retype — if that is chosen).
- Not re-litigating the `for … in` body fix's correctness itself —
  the reviewer confirmed that half of the PR worked; only the
  terminating-call honesty gap is in question here.
