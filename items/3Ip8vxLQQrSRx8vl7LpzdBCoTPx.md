## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`).

`docs/decisions/d20-naming-charter.md` (159 lines; status line 4:
`amended 2026-08 (the kept-POSIX set; rule 11)`) records at
`:126-141` ("applying rule 11 (2026-08, #1063)") that `fs.find_iter`
"became the closeable handle", and the tree still documents the
payload read the note left in place:

    git show origin/main:cosmic/fs/find.tl | sed -n '108p;125p;278p'
    metamethod __call: function(self: FileIter): string | nil, {string}
    ---     local _, errs = iter() -- subtree errors, nil when clean
      local _, errs = iter()

That idiom is what the reviewer of PR #1643 caught: retyping
`__call` to plain `string` (to close seven `for … in` nil-flow rows)
makes the terminating call's real `nil` invisible to the checker.
Board item `3ImmKYCJNNxTS9eAISxrHCW59sk` («rHCW_59sk», resolution
`completed`, 2026-09-03) settled the direction; its recorded decision,
quoted:

> d. give the terminating payload its own accessor, decoupled from the
> loop-call, instead of overloading one `__call` signature for two
> different purposes. […] `for … in iter do` keeps calling `iter()`
> exactly as it does today and that call's first return is retyped to
> plain, non-nilable `string` […] The terminating payload —
> `FileIter`'s trailing subtree-error list, `LineIter`/`Body.lines`'s
> read-failure message — moves to a NEW, separate accessor with its own
> honestly-nilable signature, called once after the loop ends instead
> of by calling `iter()` again.

It also names the cost: `stream.LineIter` is a bare function type
(`cosmic/stream.tl:56`) and becomes a callable record. Three
iterators today, and every future one, follow it — that is a rule
future work will want to do the other way, with a losing option
(retype and accept a blind spot; keep `string | nil`) and a reason
invisible from the code: `skills/decide/SKILL.md`'s three tests for a
record. The record it belongs to exists — D20's rule 11 owns the slot
shapes — so per the skill this is an **amend**, not a new number.

## Change

- `docs/decisions/d20-naming-charter.md`: append one final bullet,
  body above it untouched:
  `- **amended 2026-09 (iterator payload, #1643 review):**` — an
  iterator's `__call` returns only the loop value (`string`, no nil
  in slot 1); whatever the exhausted iterator has to say — `FileIter`'s
  subtree-error list, `LineIter`'s read failure — is read through a
  named accessor on the iterator after the loop, never by calling the
  iterator once more. Say what stopped being true (the
  `local _, errs = iter()` idiom recorded at `:126-141`), what
  replaced it, and that `LineIter` promotes from a bare function type
  to a callable record for it. Quote the decision text above as the
  provenance (records are exempt from the no-history rule).
- Line 4: `- **status:** amended 2026-09 (iterator terminating payload; earlier: the kept-POSIX set, rule 11)`.
- `bin/cosmic _docs/derive.tl` rewrites `docs/decisions/README.md`'s
  table from the H1 and status; commit it (`_build/docs_test.tl`
  fails on drift).
- Accessor NAMES are not decided here — `bj12_PZHY`'s build picks
  them under rule 1; the amendment states the shape only.
- `bin/cosmic --make ci` ends `ci: PASS` (the doc-citation lint reads
  the paths the bullet names).

## Non-goals

No code: `cosmic/fs/find.tl`, `cosmic/stream.tl`, `cosmic/fetch/body.tl`
change under `bj12_PZHY` (`3IlWcRWIzkW7s4x4Wlhbj12PZHY`), which
should cite this amendment in its PR; this item does not block it.
