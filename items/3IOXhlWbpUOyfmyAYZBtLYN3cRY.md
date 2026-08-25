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

**What the first attempt got wrong, and why the shape below changed.**
PR #1375 produced a 388-line census (359 sites, 125 files) that passed
`--make ci` and all five CI lanes, and was bounced at review. The
document's classes, mechanisms, doctrine dividend and upstream
recommendation all held up. Its per-site claims did not, and nothing in
the deliverable could have caught that — the prototype and the scan
output were deleted before the gate, leaving the eight quoted examples
as a reviewer's only instrument. Measured against that PR's head
`faf54789`, with `o/_types/types_gen` built:

- **Four of the eight fenced `-- <path>:<line>` citations did not match
  the source at the line they named.** `cosmic/fetch/verbs_test.tl:78`
  quoted `local res = fetch.head(base .. "/x", …)`; that line is
  `return fetch.get(base .. "/x", …)` and `grep -n 'fetch.head'
  cosmic/fetch/verbs_test.tl` reports nothing. The other three were
  off by one or four lines (`cosmic/fs/tree.tl:24`, `cosmic/time.tl:32`,
  `_build/size.tl:160`). The check in `Acceptance` below finds exactly
  those four when run against that document.
- **The flagship example misdescribed the binding.**
  `o/_types/types_gen/cosmo/unix.d.tl` declares `clock_gettime:
  function(clock?: integer): integer | nil, integer, string, Errno` —
  slot 2 is `integer`. A probe binding both slots and leaving them
  unused reports `secs: integer | nil` and `nanos: integer`. The
  document said "`unix.clock_gettime` returns `integer | nil` in both
  slots" and annotated `cosmic/time.tl`'s `now()` as "flagged twice".
  It is flagged once.
- **A top-file attribution was unsupportable.** The document listed
  `cosmic/fs/tree.tl` as the #2 file (10 sites) of its largest class.
  With the generated types, every union in that 122-line file is either
  guarded by `if not … then return` or is not a union at all: every
  `cosmo.unix` binding declares slot 2 `string`, so `errstr(oerr, …)`
  passes a plain string, and `ueno` is `Errno`. Only `entry` from
  `h:read()` (`cosmic/fs/types.tl:115`, `read: function(self): string |
  nil, integer`) is an unguarded union, used at `:28` and `:29` — 2
  sites, which is what the document's own non-`return`-exit table
  already said for the file.
- **An exemplar contradicted its own class.** `_build/size.tl`'s
  `local cbin = cur.binary_bytes or 0` (`:155`) was offered as the
  plain shape of the "no guard anywhere" class, while the `or`-fallback
  class's own exemplar is the identical shape (`local text =
  fs.read(path) or ""`, `_docs/derive.tl:87`).

The lesson is not "check the line numbers harder". It is that a census
whose evidence is deleted before review is unreviewable by
construction, so this pass keeps the scan output.

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
2. Edit `o/3p/tl/tl.lua` in place — build output under `o/`, committed
   by nothing — so the four admitting positions above report an error
   instead of passing. `tl.lua` is the checker that RUNS and the file
   the binary embeds; `o/3p/tl/tl.tl` beside it is the Teal source
   carried for `_types/gentl.tl`, and editing that one alone changes no
   behaviour (measured at pull 2026-08-25: a `tl.tl`-only edit rebuilds
   and the probe still passes). Rebuild with `bin/cosmic --make build`.

   The rebuild has a bootstrap order the spec cannot leave implicit: a
   strict `o/bin/cosmic` CANNOT compile this tree, so the strict binary
   must be built by a lax one. Build once with the pin (`rm -f
   o/bin/cosmic` forces `bin/cosmic` to reach for it), keep that lax
   binary aside, and restore it before each strict rebuild.

   Confirm the prototype works by running
   `TEST_TMPDIR=$T o/bin/cosmic cosmic/teal_narrowing_test.tl`
   directly — `--make test` re-execs into the strict binary and fails
   at the build instead — which must now FAIL on
   `test_nil_union_is_admitted_outside_an_index` and only on it. The
   file calls each test where it defines it, so proving "only on it"
   means neutralising that one call in a scratch COPY and seeing the
   rest pass; never edit the tracked file.
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
8. **Commit the scan output as `docs/design/nil-flow-sites.tsv`** —
   one flagged site per line, three tab-separated fields: the path,
   the line number, and the class name the document gives it. This is
   the evidence a reviewer checks the document against, and it is what
   the first attempt did not have; it replaces the reviewer's only
   instrument being eight hand-picked quotes. Sort it by path then
   line so a diff against a later re-derivation is readable. Write it
   from the strict binary's output before step 10 deletes the
   prototype — it cannot be reconstructed afterwards.

   The 500-line file cap (`_tool/lint.tl:24`, `DEFAULT_FILE_LINES`)
   applies to any file lint walks, data files included, and the first
   attempt found 359 sites. If the re-derived count exceeds 500, split
   by class into `docs/design/nil-flow-sites-<class>.tsv` and say so in
   `## Method`; never reach for `.cosmicignore` to carry an oversized
   one.
9. **Verify every citation the document makes**, before gating: run the
   `Acceptance` citation check below and fix what it names, and read
   each quoted example against its own class definition — an example
   that carries an `or`, an `and` or any guard cannot illustrate the
   no-guard class. Where an example asserts something about a
   `cosmo.*` binding, read the declaration in
   `o/_types/types_gen/cosmo/*.d.tl` and quote it rather than
   inferring the shape from the call.
10. Fix the "Four edits" word at `3p/tl/tl_patch.tl:18` — the one
   source line this slice changes.
11. Delete the prototype before gating: `bin/cosmic --make clean`, then
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
  `3p/tl/tl_patch.tl` is the one-word comment fix in step 10.
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
  This diff is two documents, one data file and one comment word.
- **Do not hand-write, edit or extend `nil-flow-sites.tsv`.** It is the
  strict binary's output, sorted; a line added or corrected by hand is
  a fabricated measurement, and the file exists precisely so a reviewer
  need not take the document's word for anything.

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

- **The evidence file agrees with the document.** The scan output is
  committed and its length is the total the document opens with:

  ```
  wc -l docs/design/nil-flow-sites.tsv
  ```

  reports that same number, and

  ```
  cut -f3 docs/design/nil-flow-sites.tsv | sort | uniq -c | sort -rn
  ```

  reproduces the document's `## Classes` table, class for class and
  count for count. Every per-file figure the document quotes (each
  class's `Top:` list) is likewise `grep -c` over this file. Where the
  document and the file disagree, the file is right and the document
  is wrong — that is what it is for.

- **Every site in the evidence file resolves.**

  ```
  while IFS=$'\t' read -r p n c; do
    [ -f "$p" ] || echo "MISSING $p"
    [ "$(wc -l < "$p")" -ge "$n" ] || echo "PAST-EOF $p:$n"
  done < docs/design/nil-flow-sites.tsv
  ```

  prints nothing. A path that does not exist or a line past
  end-of-file means the scan and the tree disagree about which tree
  was measured.

- **Every citation in the document quotes the line it names.** Each
  fenced example opens with a `-- <path>:<line>` comment; this check
  reads that line from the source and compares:

  ```
  awk '
    /^-- [A-Za-z0-9_\/.]+\.tl:[0-9]+$/ {
      split($2, a, ":"); path=a[1]; ln=a[2]
      if ((getline quoted) <= 0) next
      gsub(/^[ \t]+|[ \t]+$/, "", quoted)
      sub(/ *-- (flagged|cast):.*$/, "", quoted)
      cmd = "sed -n " ln "p " path
      src = ""; cmd | getline src; close(cmd)
      gsub(/^[ \t]+|[ \t]+$/, "", src)
      if (src == "" || index(src, quoted) == 0)
        printf "MISMATCH %s\n  doc: %s\n  src: %s\n", $2, quoted, src
    }
  ' docs/design/nil-flow.md
  ```

  prints nothing. Measured 2026-08-25 against PR #1375 at `faf54789`,
  where the document carried 8 such citations, this printed 4
  MISMATCH blocks — `cosmic/fs/tree.tl:24`, `cosmic/fetch/verbs_test.tl:78`,
  `cosmic/time.tl:32` and `_build/size.tl:160` — so the check
  discriminates rather than passing vacuously. It reads the FIRST
  quoted line of each block only; a multi-line quote whose later lines
  drift is not caught, which is why step 9 is a read as well as a run.

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

  names exactly `docs/design/nil-flow.md`,
  `docs/design/nil-flow-sites.tsv` and `3p/tl/tl_patch.tl`, and no
  other path. And

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

No blocker. The prototype rides `o/`, which every verb already
rebuilds and `--make clean` removes, so no mechanism has to be
invented and nothing outside `o/` is at risk. The document's shape is
`docs/design/casts.md`, read as the template; the comment-and-prose
standard is `skills/docs-style/SKILL.md`; conventions are AGENTS.md.
The one judgment this slice cannot delegate — which sink shapes are
worth a follow-up slice and which are noise — is exactly what a
research slice is for, and step 4 says to cite and quote the sites
that decide it.

The wrong turn PR #1375 took — a document whose claims about the tree
no gate can check — has its countermeasure filed as **3IPbDw9B** (a
`--check lint` check that resolves every `<path>:<line>` a tracked
markdown file cites and, for the fenced form, compares the quoted line
to the source). It is NOT a blocker and is deliberately not in
`blocked_by`: a lint that landed inside the PR it polices would prove
nothing, and this slice does not need it — the `Acceptance` citation
check above is the same test, run by hand, which is exactly the
evidence 3IPbDw9B needs to justify generalising it.
