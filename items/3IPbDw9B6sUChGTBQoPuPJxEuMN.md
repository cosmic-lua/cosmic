## Goal

G3 — an honest type layer, no escape hatches. The design documents this
outcome decomposes through (`docs/design/casts.md`,
`docs/design/nil-flow.md`) carry their whole value in quoted `file:line`
citations: the measuring prototype is thrown away by construction, so a
reader's only check on a class count is the two or three sites the
document quotes. Nothing verifies that a quoted line is the line that is
actually there.

## Evidence

Filed from the review of 3IOXhlWb (`docs/design/nil-flow.md`, PR #1375),
where reading the cited sites against the tree at the PR's own head
(`faf54789`) found three defects in six examples: a quoted line that was
in neither its stated position nor its stated file, a block whose quoted
line was two lines off, and a prose range one line early. `--make ci`
passed on that head with five CI lanes green.

**Re-measured 2026-08-26 against `d5a6d788`**, by a throwaway script over
`git ls-files '*.md'` — the numbers the design below is sized on:

- **Inline backticked references** (`` `cosmic/json.tl:135` `` in running
  prose): **37** tree-wide, all of them in `docs/`, 13 in
  `docs/design/casts.md`. Of the 37, **3 do not resolve**, and all three
  cite GENERATED files under `o/`:
  `o/_types/types_gen/cosmo/unix.d.tl:1938` (twice) and
  `o/_types/types_gen/cosmo/path.d.tl:40`, at
  `docs/design/nil-flow.md:216`, `:318`, `:320`. Nothing else fails to
  resolve.
- **Fenced-block header comments** (`-- <path>:<line>` as a block's first
  line, followed by the quoted source): **12** tree-wide, all in
  `docs/design/nil-flow.md`. All 12 resolve. **One quote does not
  match**: `docs/design/nil-flow.md:377` cites `-- _build/size.tl:162`
  and quotes `cbin, cbin - pbin,`, which is at `_build/size.tl:176`
  today (`grep -n 'cbin, cbin - pbin,' _build/size.tl`); line 162 is
  `--- @param prev Report The prior report`. That is this lint's own
  defect class, live in the tree, found by the measurement that sized
  the lint.
- 116 tracked `.md` files, 66 of them under `docs/`.

Every one of the nil-flow follow-ups (3IPXQ1Zw, 3IPXQcgW, 3IPXQuYu,
3IPXRRd2, 3IPktATw) plus the casts slices carries its parent document's
numbers and sites into its own spec, so the genre grows with the
outcome.

## Change

Add `_cli/citations.tl`, a new lint check module beside the other
lexer-free-but-not-strip-floor checks (`_cli/returns.tl` 283 lines,
`_cli/pattern_args.tl` 255, `_cli/reads_lint.tl` 80), exporting

```teal
check_citations(file: string, lines: {string}): {Diagnostic}
```

with `Diagnostic` the record `_tool.lint` already defines
(`file`, `line`, `col`, `rule`, `message`), and `rule = "doc-citation"`.

Wire it into `_cli/lint.tl`'s `lint_file`, in a new `%.md$` branch
beside the existing `%.tl$` one — that function already runs over every
file the project walk sees, so no new walk and no opt-in list is needed.
Measured headroom: `_cli/lint.tl` is **457** lines (43 under the
500-line cap), which fits the four-line wiring; the check itself lives in
the new file, which is why it is a new file.

The two shapes, each checked at the strength it admits:

1. **Both shapes — the citation resolves.** `<path>` is a tracked file
   (`git ls-files`) and `<line>` is within it. A renamed file or a line
   past end-of-file is a diagnostic naming the document, the citation,
   and what is actually there.
2. **Fenced shape — the quote matches.** The block's next non-empty line
   must equal the source at `<line>` after both are stripped of leading
   and trailing whitespace.

The four open questions, decided:

- **Scope: every tracked `.md`.** Not `docs/**` only and no opt-in
  marker. All 49 citations live under `docs/` today, so the wider scope
  costs nothing now and catches `AGENTS.md` the day it grows one.
- **Generated paths are skipped, everything else must resolve.** A
  citation whose path begins with the build output directory (`o/`) is
  skipped — it is generated, legitimately untracked, and the 3 such
  citations today are correct as written. Any OTHER unresolvable path is
  a diagnostic. Skipping every untracked path instead would fail open on
  exactly the rename this check exists to catch.
- **Multi-line quotes: the FIRST non-empty line only.** The nil-flow
  blocks quote 2-6 lines with elisions, so a whole-block match is not
  achievable; the first line is what pins the position.
- **Ranges resolve, they do not match.** `AGENTS.md:180-184` is checked
  only for both ends being within the file. Asserting what a prose range
  CONTAINS needs the document to state it, which is a different and
  larger design — so defect 3's class stays uncaught, deliberately, and
  this spec says so rather than implying otherwise.

**Fix the one live mismatch in the same diff.** Change
`docs/design/nil-flow.md:377` from `-- _build/size.tl:162` to
`-- _build/size.tl:176`. This is a deliberate, single-line exception to
the non-goal below: a gate that cannot go green cannot land, and the
alternative — landing the resolution half now and the quote half later —
splits one check across two slices for one wrong digit.

Add `_cli/citations_test.tl` covering: a resolving inline citation, an
inline citation past end-of-file, an inline citation naming a path that
is not tracked, an `o/`-prefixed citation (skipped), a range with both
ends inside the file, a fenced block whose quote matches, and a fenced
block whose quote does not. Build the fixtures under `TEST_TMPDIR`;
each `test_*` is called on the line after its `end`, per AGENTS.md.

## Non-goals

- **Not the markdown cross-reference lint (3IKEcDqs).** That resolves
  stable IDs and links BETWEEN documents and is blocked on
  `cosmic.markdown` (3IKD33rv). This one reads a source file at a
  numbered line and needs no markdown AST.
- **Do not fix any document's citations beyond the one named above.**
  The `_build/size.tl:162` → `:176` change is the whole documentation
  edit this diff may make. If the check finds another mismatch at
  implementation time, that is a re-measurement finding: fix it only if
  it is likewise one line, and say so in the PR.
- **Do not assert what a prose line RANGE contains.** Decided above.
- **Do not touch `_tool/lint.tl`.** It is inside the strip floor and
  holds only the checks a stripped artifact can run; this check reads
  other files and belongs in the dispatcher.
- **Do not change the `Diagnostic` record, the `--check lint` verdict
  line format, or any existing rule name.** Downstream output is parsed.
- **Do not add a `.md` branch to any other gate** (`fmt`, `types`).
- **Do not widen this to link checking, spelling, or heading structure.**

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/citations_test.tl` ends `test: PASS`.
- `bin/cosmic --check lint docs/design/nil-flow.md` reports no
  `doc-citation` diagnostic (today the file carries the one mismatch
  above, and no check reads it at all).
- `grep -rn 'doc-citation' _cli/ | wc -l` reports at least `2` — the
  rule is registered and tested.
- `wc -l _cli/lint.tl` reports at most `500` (457 today) and
  `wc -l _cli/citations.tl` reports at most `500`.
- `git diff --name-only origin/main` lists `_cli/citations.tl`,
  `_cli/citations_test.tl`, `_cli/lint.tl` and
  `docs/design/nil-flow.md`, and nothing else.

## Bounced 2026-08-26 — a dated document's citations are not claims
## about HEAD

Pulled and bounced without a PR at `e0d217dd`, minutes after two sibling
slices under this same parent landed (3IPXQcgW / PR #1385, 3IPktATw /
PR #1386). What they did to this document is the gap.

**Measured at `e0d217dd`.** Re-running the Evidence measurement — 12
fenced blocks in `docs/design/nil-flow.md`, each header's `<path>:<line>`
read against the tree and its quote compared:

```text
MISS cosmic/fs/tree.tl:28
  doc: local s = cosmo_path.join(src, entry)
  src: local s = fs_path.join(src, entry)
MISS cosmic/time.tl:53
  doc: return secs * 1000 + math.floor(nanos / 1000000)
  src: --- Get current wall clock time in whole milliseconds since the epoch.
MISS cosmic/time.tl:35
  doc: return secs, nanos
  src: -- assert: clock_gettime fails only on an invalid clock id, and
MISS _build/size.tl:162
  doc: cbin, cbin - pbin,
  src: --- @param prev Report The prior report
```

Four mismatches, not the one the `Change` budgets for. Three of them
were created by PRs #1385 and #1386 in the hour between this spec being
written and being pulled. The 37 inline citations still resolve.

**The gap.** `docs/design/nil-flow.md:17` states its own terms: *"Measured
against `e7ac1580` on 2026-08-25, over the 527 tracked `.tl` files"*. Its
citations are positions in a NAMED PAST COMMIT, not claims about HEAD, and
its prose reads them as evidence of a defect: the block at `:159` says of
`cosmic/fs/tree.tl:28` that "`s` and `d` are themselves `string | nil`,
because `cosmo.path.join` is declared to return one", and the block at
`:210` calls `cosmic/time.tl:35` "the worst of the whole census … in the
published API". Both statements were true at `e7ac1580` and are false at
`e0d217dd`, because the census's own remediation slices landed.

So the check as specified does not merely find stale line numbers here —
it forces every future nil-flow slice to also rewrite the census
document that motivated it. Three such slices are still queued under
this parent (3IPXQ1Zw, 3IPXQuYu, 3IPXRRd2), and each will invalidate
more of the same 12 blocks. That standing cost is a design decision this
spec does not make, and it cannot be improvised inside the slice:
`cosmic/fs/tree.tl:28`'s quoted text no longer exists anywhere in the
tree, so there is no line to re-point to and no one-line repair. The
`Change`'s "fix the one live mismatch in the same diff" exception, and
the Non-goal that bounds it to one line, are both sized for a tree that
is not moving underneath the document.

**What the refinement has to settle**, before this is pullable again:

1. **What a citation into a dated document means.** Three shapes, none
   of them free: freeze the citation form so it names the commit it was
   measured against (`cosmic/time.tl@e7ac1580:35`) and have the check
   resolve it there; exempt a document that declares a measurement
   commit, and say how it declares one; or accept that HEAD is the only
   referent and that a remediation slice repoints its own census rows,
   making that an explicit, budgeted step of every such slice.
2. **Who repairs the four mismatches above**, and with what prose. It is
   plausibly not this item at all: re-pointing a census whose subject
   was fixed is a documentation change with its own judgment in it, and
   it now blocks this one whichever way (1) is decided.
3. **How the check decides a path is real, without `git`.** The `Change`
   says "a tracked file (`git ls-files`)". `--check lint` runs per file
   inside the fence and over user projects that need not be git
   checkouts at all, so a subprocess per run is not available to it; no
   `_cli/**` check shells out today (`_make/vcs.tl` is the tree's only
   `git` caller, and it is not on this path). `fs.is_file` relative to
   the project root gives the same answer for every citation in the
   tree and keeps the "any other unresolvable path is a diagnostic"
   property the `Change` asks for — but it is a different rule from the
   one written, so it needs deciding rather than substituting.

Nothing about the check's core — the two shapes, the `o/` skip, the
first-non-empty-line quote match, the ranges-resolve-only decision — was
found wanting. The measurement that sized it was sound; what moved is
the tree it measures.

## Enablement

none needed. `_cli/returns.tl` and `_cli/pattern_args.tl` are the two
worked examples of a check module and its wiring into `_cli/lint.tl`'s
`lint_file`; `_tool/lint.tl` defines the `Diagnostic` record and
`_cli/lint_render.tl` renders it. The measurement script that produced
the Evidence figures is throwaway by design — the Acceptance commands
above are what a reader re-runs, and the check itself replaces the
script once it lands.
