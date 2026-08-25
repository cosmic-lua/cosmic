## Goal

G3 — an honest type layer, no escape hatches. The parent
(3IODJgkO) cannot be sized until somebody knows how many sites a
strict nil-flow checker would flag and what shapes they take; its
own text says so ("measure the tree's violation count first"). This
slice is that measurement, and its deliverable is a census document
plus the follow-up slices it seeds — no checker change, no site fixed.

The precedent is exact: `docs/design/casts.md` (286 lines,
`wc -l docs/design/casts.md`, measured 2026-08-25) classified the
192-site `from any` bucket and seeded six sibling slices under this
same parent outcome. This does the same for the nil-flow gap.

## Evidence

Measured 2026-08-25 against `whilp/cosmic` `e7ac1580` (`main`), re-run
at refinement; the figures below are that run's, not an earlier one's.

**The gap is pinned as a passing test, not a bug report.**
`cosmic/teal_narrowing_test.tl:222`
(`test_nil_union_is_admitted_outside_an_index`, called at `:250`) writes
a fixture and asserts `result.ok` — that is, asserts the checker does
NOT complain — for five sinks in one program:

```text
local n = gi()                        -- inferred local, union kept
local m: integer = gi()               -- declared non-nil local
local t: string = gs()                -- declared non-nil local
print(n + 1, take_int(gi()), ("abc"):sub(1, gi()))
print(gs() .. "x", m, t)
```

so the admitting positions this slice must census are: **assignment to
a declared non-nil local**, **a non-nil parameter**, **arithmetic**,
and **concatenation**. An index is the one position that refuses (the
negative twin is `test_nil_union_is_refused_at_an_index` at `:255`,
called at `:268`).

**The doctrine that exists because of the gap** is 92 lines of
AGENTS.md (`awk '/^### Error Handling Patterns/,/^## Build System/'
AGENTS.md | wc -l`), plus `docs/stdlib.md` (58 lines) and
`docs/guides/checking.md` (380 lines). G3's win condition names that
doctrine's size as half of what it measures, so the census has to say
which of those lines a strict mode would actually retire.

**The change would ride the carried patch, and that machinery is
already load-bearing.** `3p/tl/tl_patch.tl` is 395 lines carrying 11
anchored edits (`grep -o '^  \["[a-z0-9-]*"\]' 3p/tl/tl_patch.tl`),
five of them narrowing edits (`narrow-assert-decl`,
`narrow-assert-decl-tl-tl`, `narrow-and-operand`, `narrow-assert`,
`narrow-eq-nil`, `narrow-truthiness` — six keys, five behaviours, the
`-tl-tl` twin being the Teal-source copy of the first). `_make/patch.tl`
(190 lines) is the mechanism, and each anchor must match the pinned
`tl` (0.24.8, `3p/tl/tl_pin.tl`) exactly once. So the question the
census answers is not "can this be patched" but "how much does the
patch cost to adopt", which is the flagged-site count.

**The tree is 579 `.tl` files** (`git ls-files '*.tl' | wc -l`). The
number of them a strict mode flags is UNKNOWN today, and establishing
it is this slice's entire point — no figure for it appears anywhere in
this spec, and a session must not invent one.

**One inconsistency to fix in passing, in a file this slice reads:**
`3p/tl/tl_patch.tl:18` says "Four edits teach the checker that a nil
union narrows" and then lists five `-- - narrow-*` bullets
(`grep -n "Four edits" 3p/tl/tl_patch.tl` reports line 18). Correct the
word to match the bullets; it is a one-word comment fix in a file the census cites,
and it is the only source edit this slice makes.

## Change

Produce `docs/design/nil-flow.md`, a new file, modelled section-for-section
on `docs/design/casts.md`: an opening that states the total and why it
matters, a `## Method` naming every command the tables were built from,
`## Classes` with one subsection per sink shape, and a closing section
naming the mechanism that closes each class.

The session builds a THROWAWAY strict checker to produce the census —
it is never committed:

1. `bin/cosmic --make fetch && bin/cosmic --make build` to land the
   pinned `tl` under `o/3p/tl/` and a working `o/bin/cosmic`.
2. Edit `o/3p/tl/tl.tl` in place — build output under `o/`, committed
   by nothing — so the four admitting positions above report an error
   instead of passing. Rebuild with `bin/cosmic --make build`. Confirm
   the prototype works by re-running
   `o/bin/cosmic --make test cosmic/teal_narrowing_test.tl`, which must
   now FAIL on `test_nil_union_is_admitted_outside_an_index` and only
   on it: that failure is the prototype's proof of life.
3. Run the strict binary over every tracked source —
   `git ls-files '*.tl' | xargs o/bin/cosmic --check types` — and
   capture the flagged sites to a scratch file outside the tree.
4. Classify every flagged site into disjoint classes by the SHAPE of
   the sink, the way `casts.md` classifies by the shape of the site.
   Start from the four positions the pinned test names and add a class
   whenever a real site fits none of them (a return position, a table
   field, a `for` bound). Each class gets: its count, its file table,
   two or three cited `file:line` examples read and quoted, and the
   mechanism that closes it — a guard the author should have written,
   a signature that should not have returned a union, or a checker
   behaviour that would be wrong to demand.
5. Separate, explicitly, the sites where the union is a LATENT NIL
   (the value really can be nil at runtime) from those where it is a
   declaration that should never have been a union. The second kind is
   fixed by narrowing a signature, not by adding a guard, and the two
   seed different follow-up slices.
6. State the doctrine dividend: which of AGENTS.md's 92 narrowing
   lines, and which sections of `docs/guides/checking.md`, a strict
   mode would retire. Quote the line ranges; do not edit them.
7. State a recommendation on upstream-first: whether this is a
   proposal to teal-language/tl, a sixth carried-patch group, or both,
   with the reasoning that follows from the census — not from taste.
8. Fix the "Four edits" word at `3p/tl/tl_patch.tl:18` — the one
   source line this slice changes.
9. Delete the prototype before gating: `bin/cosmic --make clean`, then
   `bin/cosmic --make fetch && bin/cosmic --make build`, so the gate
   below runs against an unmodified pinned `tl`.

Then file the follow-up slices as children of this item's parent,
one per class the census says is worth closing, from the board
worktree: `o/bin/gitboard new "<title>" --parent 3IODJgkO
--spec-file <file>`. Each carries the census's own numbers for its
class. Filing them is what turns 3IODJgkO into a container and is
part of this slice, not a note for later.

## Non-goals

- **Do not commit a checker change.** `3p/tl/tl_patch.tl` gains no new
  edit key, `_make/patch.tl` is not touched, and the prototype from
  step 2 lives and dies inside `o/`. The only edit to
  `3p/tl/tl_patch.tl` is the one-word comment fix in step 8.
- **Do not fix a single flagged site.** Every site the census finds is
  a follow-up slice's work. A diff that guards even one of them is
  scope creep, and the census would then describe a tree that no
  longer exists.
- **Do not touch `cosmic/teal_narrowing_test.tl`.** Its
  `test_nil_union_is_admitted_outside_an_index` asserts today's
  boundary on purpose; it changes in the slice that moves the
  boundary, never in the one that measures it.
- **Do not edit the doctrine.** AGENTS.md, `docs/stdlib.md` and
  `docs/guides/checking.md` describe the gap accurately while the gap
  is open. Step 6 QUOTES the lines a strict mode would retire; it does
  not delete them.
- **Do not bump the `tl` pin.** `3p/tl/tl_pin.tl` stays at 0.24.8; a
  census measured against one tl and a patch audited against another
  is two facts that cannot be compared.
- **Do not touch `whilp/cosmopolitan`.** Nothing here reaches the C
  boundary or `definitions.lua`.
- **Do not open a teal-language/tl issue or PR in this slice.** Step 7
  writes the recommendation down; acting on it is a follow-up slice, so
  that the upstream text is reviewed here before it is published.
- **Do not add a cast, a `-- cast:` line, or a coverage exclusion.**
  This diff is one markdown file and one comment word.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root except the
last, which runs from the board worktree. None writes into the
committed tree.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The census exists and is bounded.**

  ```
  test -f docs/design/nil-flow.md && wc -l docs/design/nil-flow.md
  ```

  succeeds and reports **at most 500** lines (the repo's file cap;
  `docs/design/casts.md` is 286 for a 192-site bucket).

- **It has the four sections the shape demands.**

  ```
  grep -c '^## ' docs/design/nil-flow.md
  ```

  is at least `3`, and

  ```
  grep -n '^## Method' docs/design/nil-flow.md
  ```

  reports a line — the Method section is what makes every table in it
  re-derivable by a reviewer.

- **Its total is re-derivable.** The document states the flagged-site
  total in its opening paragraph and names, in `## Method`, the exact
  command that produced it, including the prototype edit that command
  depends on. A reviewer re-running that command after re-applying the
  stated edit gets the stated number.

- **The pinned boundary did not move.**

  ```
  bin/cosmic --make test cosmic/teal_narrowing_test.tl
  ```

  ends `test: PASS`, and

  ```
  git fetch origin main && git diff --stat origin/main...HEAD -- cosmic/teal_narrowing_test.tl
  ```

  prints nothing. The three-dot form diffs against the merge base, so
  it says what THIS branch changed and stays correct however far `main`
  has moved ahead. A bare `main` does not: a checkout's local `main` is
  whatever it last pulled. Measured at refinement:
  `git rev-list --count main..origin/main` reported 12, and
  `git diff --name-only main` on a clean checkout of `origin/main`
  named 49 files — all of them other people's landings, none of them
  this slice's work.

- **Nothing else moved.**

  ```
  git diff --name-only origin/main...HEAD
  ```

  names exactly `docs/design/nil-flow.md` and `3p/tl/tl_patch.tl`, and
  no other path. And

  ```
  git diff origin/main...HEAD -- 3p/tl/tl_patch.tl | grep -c '^[-+]'
  ```

  is `4` — the two `---`/`+++` file headers plus the one line replaced.

- **The follow-ups are on the board.** From the board worktree
  (`git worktree add o/board board; cd o/board; bin/cosmic --make build`):

  ```
  o/bin/gitboard show 3IODJgkO | grep '^role:'
  ```

  reports `role: container` — which it does only once children are
  attached, so this discriminates — and `o/bin/gitboard tree` lists
  those children indented under it.

## Enablement

none needed. The prototype rides `o/`, which every verb already
rebuilds and `--make clean` removes, so no mechanism has to be
invented and nothing outside `o/` is at risk. The document's shape is
`docs/design/casts.md`, read as the template; the comment-and-prose
standard is `skills/docs-style/SKILL.md`; conventions are AGENTS.md.
The one judgment this slice cannot delegate — which sink shapes are
worth a follow-up slice and which are noise — is exactly what a
research slice is for, and step 4 says to cite and quote the sites
that decide it.
