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
(`faf54789`) found three defects in six examples. `--make ci` passed on
that head with five CI lanes green.

**Re-measured 2026-08-26 against `e0d217dd`.** Commands and their output:

- **Inline backticked references** — a whole backticked span that is
  `<path>.<ext>:<line>` or `<path>.<ext>:<line>-<line>`:
  `git ls-files '*.md' | xargs grep -oh '`[A-Za-z_0-9][A-Za-z_0-9./-]*\.[A-Za-z_0-9]\+:[0-9]\+\(-[0-9]\+\)\?`' | wc -l`
  reports **37**, across 7 files
  (`… | xargs grep -c -o … | grep -v ':0$'`):
  `docs/design/nil-flow.md` 16, `docs/design/casts.md` 13,
  `docs/agent-usability.md` 2, `docs/decisions/d18-step-skip.md` 1,
  `docs/decisions/d28-shape-combinators.md` 1,
  `docs/design/make/resolution.md` 1, `docs/guides/testing.md` 1.
  Three of the 37 cite generated files under `o/`
  (`o/_types/types_gen/cosmo/unix.d.tl:1938` twice,
  `o/_types/types_gen/cosmo/path.d.tl:40`), all in
  `docs/design/nil-flow.md`.
- **Fenced-block header comments** — `-- <path>:<line>` as a fenced
  block's first content line, followed by the quoted source:
  `git ls-files '*.md' | xargs grep -c '^-- [A-Za-z_0-9][A-Za-z_0-9./-]*:[0-9]\+$' | grep -v ':0$'`
  reports **12**, all in `docs/design/nil-flow.md`.
- 116 tracked `.md` files (`git ls-files '*.md' | wc -l`), 66 under
  `docs/`.

### The correction that reshaped this item

The item was pulled at `e0d217dd` and bounced without a PR. Reading the
12 fenced quotes against HEAD reports **four** that do not match, not
the one the previous spec budgeted for — `cosmic/fs/tree.tl:28`,
`cosmic/time.tl:35`, `cosmic/time.tl:53` and `_build/size.tl:162`.

**All four are exact at the commit the document declares.**
`docs/design/nil-flow.md:17` states its own terms — *"Measured against
`e7ac1580` on 2026-08-25, over the 527 tracked `.tl` files"* — and:

```text
$ for c in _build/size.tl:162 cosmic/fs/tree.tl:28 \
    cosmic/time.tl:35 cosmic/time.tl:53; do \
    f=${c%%:*}; n=${c##*:}; \
    printf '%s => [%s]\n' "$c" "$(git show e7ac1580:$f | sed -n "${n}p")"; done
_build/size.tl:162 => [    cbin, cbin - pbin,]
cosmic/fs/tree.tl:28 => [      local s = cosmo_path.join(src, entry)]
cosmic/time.tl:35 => [  return secs, nanos]
cosmic/time.tl:53 => [  return secs * 1000 + math.floor(nanos / 1000000)]
```

Each matches the document's quote character for character. The document
was never wrong; the previous spec read a dated document against HEAD
and called the difference a defect — which is the same misreading a
check that assumes HEAD would make 41 times over. Three of the four
drifted in the hour between that spec being written and being pulled,
when two sibling slices under this same parent landed (3IPXQcgW / PR
#1385, 3IPktATw / PR #1386) and remediated the very sites the census
cites as broken.

`docs/design/casts.md:10` declares itself the same way — *"Measured
against `d3e59de7` on 2026-08-25. The counts here are a snapshot of that
commit"*. Between them these two documents hold **29 of the 37 inline
citations and all 12 fenced ones**, so a check that treats every
citation as a claim about HEAD would be wrong about 41 of the 49.

## The shape, decided

**A citation is a claim about HEAD unless its document says it is a
snapshot, and the two census documents already say so.** The check reads
the sentence they already write; no new grammar, and no document edit in
this diff.

A document is a **snapshot** when a line OUTSIDE a fenced block matches
`^Measured against `(%x%x%x%x%x%x%x+)`` — true today for exactly
`docs/design/casts.md:10` and `docs/design/nil-flow.md:17`
(`git ls-files '*.md' | xargs grep -n '^Measured against `'` reports
those two lines and no others). Everything else is a **HEAD document**.

What is checked, by document kind:

| | path exists | line within file | fenced quote matches |
|---|---|---|---|
| HEAD document | yes | yes | yes |
| snapshot | yes | no | no |

A snapshot's POSITIONS are claims about a commit the check cannot read —
`git show` is not available to it, see below — so they are not judged. Its
PATHS still are: a file renamed away is a citation no reader can follow,
whichever commit it was measured at, and that is the rename case this
check exists to catch.

The alternatives, rejected:

- **Treat HEAD as the only referent and repoint the census on every
  landing.** It forces every remaining nil-flow slice (3IPXQ1Zw,
  3IPXQuYu, 3IPXRRd2) to also rewrite the document that motivated it,
  and it cannot be done mechanically: `cosmic/fs/tree.tl:28`'s quoted
  text no longer exists anywhere in the tree, so there is no line to
  repoint to, and the prose reading it ("`s` and `d` are themselves
  `string | nil`, because `cosmo.path.join` is declared to return one",
  `docs/design/nil-flow.md:167`) would have to change with it. A dated
  census whose examples are edited away from its stated commit is a
  worse document, not a better one.
- **A per-citation commit marker** (`cosmic/time.tl@e7ac1580:35`). 41
  edits, a new grammar for every author to learn, and it still cannot
  be verified without `git`.

**No `git` in the check.** `embed/cosmic.mk:252-257` states the gate's
existing position: `lint_sources` is "every file the walk found … the
tracked-shaped set already, minus `o/` and minus what `.cosmicignore`
excludes, with no `git ls-files` and so no git in the gate at all."
`--check lint` also runs over user projects that need not be git
checkouts. So a cited path is real when `fs.is_file` says so, relative
to the project root, which is `--check lint`'s cwd. This preserves the
property that matters: only an `o/`-prefixed path is skipped, and any
other unresolvable path is a diagnostic — the check never fails open.

## Change

Touch exactly three files: `_cli/citations.tl` (new),
`_cli/citations_test.tl` (new), `_cli/lint.tl`. No document changes.

**1. `_cli/citations.tl`** — a new check module beside the other
lexer-free checks (`_cli/returns.tl` 283 lines, `_cli/pattern_args.tl`
255, `_cli/reads_lint.tl` 80; `wc -l` at `e0d217dd`), exporting

```teal
check_citations(file: string, lines: {string}): {Diagnostic}
```

with `Diagnostic` the record `_tool/lint.tl:17` defines (`file`, `line`,
`col`, `rule`, `message`) and `rule = "doc-citation"` on every finding.

One pass over `lines`, tracking fenced-block state (a line whose first
non-space characters are ``` or ~~~ toggles it), doing:

- **Snapshot detection.** Outside a fence, a line matching
  ``^Measured against `(%x%x%x%x%x%x%x+)` `` marks the document a
  snapshot. The fence guard is required, not decorative: a document that
  QUOTES that sentence inside a code block — this spec does — must not
  be read as a snapshot.
- **Outside a fence: inline citations.** For each backticked span
  (`` line:gmatch("`([^`]+)`") ``), the WHOLE span must match
  `^([%w_%-%./]+%.[%w_%-]+):(%d+)$` or the same with `-(%d+)` appended.
  Requiring the whole span is what keeps the count at the 37 measured
  above: a span like `` `grep -c '^<file>\t' docs/…tsv` `` contains a
  path but is not a citation.
- **Inside a fence: the header shape.** Only the block's FIRST content
  line is examined, and only against `^%-%- ([%w_%-%./]+):(%d+)$`. When
  it matches, the block's next non-empty line is the quote.

For each citation: skip it when the path begins `o/`. Otherwise read the
cited file once per path (a table keyed by path, local to the call, so a
document citing one file 13 times reads it once) and report:

- the path is not a file → *"`<citation>` names no file"*, naming the
  document and the citation.
- HEAD document, the line (or a range's upper end) is past the file's
  last line → *"`<citation>` is past end of file (`<path>` has N lines)"*.
- HEAD document, fenced shape, the quote and the source line at
  `<line>` differ after both are stripped of leading and trailing
  whitespace → a message carrying BOTH, so the fix is visible without
  opening either file.

A range (`AGENTS.md:180-184`) is checked for both ends being within the
file and nothing more. Asserting what a prose range CONTAINS needs the
document to state it, which is a different and larger design.

Multi-line quotes match on the FIRST non-empty line only: the nil-flow
blocks quote 2-6 lines with elisions, so a whole-block match is not
achievable, and the first line is what pins the position.

Every diagnostic's `message` opens `"%s:%d: "` with the document and its
line, matching `_cli/pattern_args.tl:123` and `_cli/reads_lint.tl:59`.

**2. `_cli/lint.tl`** — a new `%.md$` branch in `lint_file` (the
function at line 345 today) beside the existing `%.tl$` one, plus the
`require("_cli.citations")` at the top: six lines in all. Do NOT add
`check_citations` to the `LintModule` record or to `M` —
`_cli/citations_test.tl` requires the module directly, so the export
would have no caller. `wc -l _cli/lint.tl` reports **457** at
`e0d217dd`, 43 lines under the 500-line cap.

**3. `_cli/citations_test.tl`** — fixtures built under `TEST_TMPDIR`,
with the test chdir'ing in and restoring the old cwd afterwards
(`fs.cwd` / `fs.chdir`; `cosmic/fs/init_test.tl:211`'s
`test_getcwd_and_chdir` is the worked example), because cited paths
resolve relative to cwd. Each `test_*` is called on the line after its
`end`, per AGENTS.md. Cover, one test each:

- a resolving inline citation → no diagnostic
- an inline citation past end-of-file → one diagnostic
- an inline citation naming a path that is not a file → one diagnostic
- an `o/`-prefixed citation into a path that does not exist → skipped
- a range with both ends inside the file → no diagnostic
- a range whose upper end is past end-of-file → one diagnostic
- a fenced block whose quote matches → no diagnostic
- a fenced block whose quote does not match → one diagnostic naming both
- a snapshot document (carrying the `Measured against` line) whose
  fenced quote does not match and whose inline line is past
  end-of-file → no diagnostic
- a snapshot document citing a path that is not a file → one diagnostic
- a document whose only `Measured against` line is INSIDE a fenced block
  → treated as a HEAD document, so its bad quote is still a diagnostic

## Non-goals

- **Do not edit any document.** The two census documents already declare
  their commits, and nothing else in the tree fails the check — proved
  by the Acceptance commands below. A diff that repoints
  `docs/design/nil-flow.md`'s citations has not understood the
  correction above.
- **Not the markdown cross-reference lint (3IKEcDqs).** That resolves
  stable IDs and links BETWEEN documents and is blocked on
  `cosmic.markdown` (3IKD33rv). This one reads a source file at a
  numbered line and needs no markdown AST.
- **Do not shell out to `git`,** for the reason `embed/cosmic.mk:252`
  gives. No subprocess of any kind.
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

- `bin/cosmic --make ci` ends `ci: PASS`. The lint stage covers every
  `.md` in the model (`embed/cosmic.mk:247-263`), so this is what proves
  no citation in the tree fails.
- `bin/cosmic --make test _cli/citations_test.tl` ends `test: PASS`.
- `bin/cosmic --check lint docs/design/nil-flow.md` prints
  `Style check passed: docs/design/nil-flow.md`. This passes ONLY
  because of the snapshot rule: the file carries the four fenced quotes
  that do not match HEAD, listed in Evidence.
- `bin/cosmic --check lint docs/design/casts.md` prints
  `Style check passed: docs/design/casts.md`.
- `bin/cosmic --check lint docs/agent-usability.md` prints
  `Style check passed: docs/agent-usability.md` — a HEAD document whose
  two citations are fully checked. The other four HEAD documents holding
  citations (`docs/decisions/d18-step-skip.md`,
  `docs/decisions/d28-shape-combinators.md`,
  `docs/design/make/resolution.md`, `docs/guides/testing.md`) pass the
  same way and are covered by `--make ci`.
- `grep -rn 'doc-citation' _cli/ | wc -l` reports at least `2` (today
  `0`) — the rule is registered and tested.
- `wc -l _cli/lint.tl` reports at most `500` (457 today),
  `wc -l _cli/citations.tl` at most `500`, and
  `wc -l _cli/citations_test.tl` at most `500`.
- `git diff --name-only origin/main` lists exactly `_cli/citations.tl`,
  `_cli/citations_test.tl` and `_cli/lint.tl`, and nothing else.

The census's own Method (`docs/design/nil-flow.md`, `## Method`) is NOT
an acceptance command: it needs a throwaway strict checker that is not
committed and was deleted, so it cannot be run literally.

## Enablement

none needed. `_cli/returns.tl` and `_cli/pattern_args.tl` are the two
worked examples of a check module and its wiring into `_cli/lint.tl`'s
`lint_file`; `_tool/lint.tl:17` defines the `Diagnostic` record and
`_cli/lint_render.tl` renders it; `cosmic/fs/init_test.tl:211` is the
worked example of a test that changes cwd and restores it.

The bounce that produced this revision was this item's own
specification failure — it asserted a tree-fact ("one quote does not
match … this lint's own defect class, live in the tree") without
checking it against the commit the document names — and the
countermeasure is the corrected, commanded measurement above, not a new
item.
