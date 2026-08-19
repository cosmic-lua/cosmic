Imported from whilp/cosmic#1238.

## Goal

G4 — "a gate's PASS means something" — applied to the gates themselves. The
repo's doctrine is that a mistake which keeps happening becomes a mechanism
(the fallible-returns lint, the `-- cast:` justification, the find-needle lint,
the coverage ratchet). Copy-pasted function bodies are currently outside that
set: `fmt`, `check`, `example`, `lint`, `coverage` and `repro` all pass a tree
holding three copies of the same function, so the only thing standing between a
duplicate and `main` is a reviewer noticing.

Filed as mandated by the review of PR #1185 (issue #1156), where the same point
had to be made twice on one card.

## The wrong turn

Issue #1156's `## Change` said the relocation of `source_dirs` should "mirror"
existing patterns. A literal-minded implementer reads "mirror" as "write one
like it" rather than "import it", and duplication is the choice that leaves no
error behind — nothing fails, so nothing teaches. On this one card it happened
three times:

1. **`compiled_kinds` / `runs_against_the_stage`** — relocating `source_dirs`
   from `_make/graph.tl` to `_make/project.tl` produced a second copy of the
   constant set it reads, justified in a comment with a cycle claim that was
   false in the direction that mattered. Caught in review round 2; cost a full
   rework round. Now single-sourced in `_make/types.tl:175-176,236-247`.
2. **`write_if_changed`** — three copies across `_make/graph.tl` (×2) and the
   new `_make/envstamp.tl`, byte-identical modulo one parameter rename
   (`content` → `body`). Caught in review round 4; cost a second rework round.
   Now single-sourced at `_make/stamp.tl:201`.
3. **`ENV_SWITCHES`** — mirrored into `_make/imports.tl:204-212` rather than
   imported from `_cli/build/work.tl:59`. This one is spec-mandated (Change item
   1 spelled the list out) and drift fails **loud** as a refused declaration, so
   it stays — but it is the same reflex, and the comment's stated reason ("this
   module has no dependency on `_cli/build`") is true of `imports.tl` and false
   of the `_make` tree, which already requires `_cli.build` at
   `_make/generate.tl:13`.

Two rework rounds, four green CI runs, one card. Every gate was green the whole
time.

## Change

A whole-tree gate that fails on identical normalized function bodies.
Refinement correction to the imported issue, from the tree's own
mechanics: `--make lint` is per-file (`_cli/lint.tl`'s `lint_file`, one
path per call from `_cli/main_handlers.tl:340`, and `_cli/lint.tl` is at
448/500 lines besides), while every existing whole-tree gate is a
`_build/` test — the cast ratchet (`_build/casts.tl` +
`_build/casts_test.tl`) is the pattern to copy, TREES constant and all.
So:

1. **`_build/dupes.tl`** (new): the scanner.
   - Files: every `.tl` under `TREES < const > = {"_make", "_cli"}`,
     excluding `*_test.tl` and any path containing `testdata/`.
   - Body extraction is textual and rests on a gate: `fmt` enforces
     2-space indentation, so a top-level body spans from a line matching
     `^(local )?function ` to the next line that is exactly `end` —
     nested closers are indented and cannot match.
   - Normalization: strip `--` comments to end of line, drop blank
     lines, collapse runs of whitespace to one space; parse the
     parameter names out of the header line and replace word-boundary
     occurrences in the body with positional placeholders (`__p1`,
     `__p2`, …). Both observed defects were byte-identical under less.
   - Floor: a normalized body under **5 lines** is skipped. Measured
     basis, 2026-08-19 at `f420391`, comment/whitespace normalization
     over the same scope: 812 top-level functions, 9 duplicate groups,
     of which exactly one is non-test — a 4-line `fail` forwarder
     tripled across `_cli/build/{batch,steps,work}.tl` — and the
     historical `write_if_changed` normalizes to ~14 lines. Floor 5
     therefore exempts the trivial forwarder and starts the gate at
     ZERO findings with no allowlist, while catching every observed
     defect. Record the number and this basis in the doc comment.
   - Failure message names both sites and the remedy:
     `identical body at A:12 and B:34 — export one and require it`.
2. **`_build/dupes_test.tl`** (new): the gate (scan the tree, assert no
   findings) plus unit pins on the scanner run over inline fixtures: a
   true duplicate fails; the same body with different parameter names
   fails; two bodies differing by one statement pass; a 4-line body
   passes.

## Non-goals

Not a general clone detector: no near-miss or token-similarity matching,
no cross-tree analysis, no thresholds beyond the one size floor, no
committed baseline — the gate starts and stays at zero. Test files are
excluded from this slice: the same scan measured 8 duplicate groups of
test-helper boilerplate (16-line setup helpers ×4 among them), and
widening to them — whose real fix is shared fixtures — is a follow-up
once this gate has a false-positive record, as is `cosmic/**`. Constants
(`compiled_kinds`, `ENV_SWITCHES`) are out of scope: this keys on
function bodies, per the evidence. No change to `_cli/lint.tl`. No
change to the three historical sites, all resolved on `main` via #1185.

## Acceptance

- `bin/cosmic --make test _build/dupes_test.tl` ends
  `test: PASS (1 files)`.
- Reintroducing the `write_if_changed` duplication as a scratch edit
  (copy `_make/stamp.tl:201-216` into `_make/graph.tl` under another
  name) makes that same command fail, naming both sites; revert the
  scratch.
- `bin/cosmic --make ci` ends `ci: PASS` on the tree as it stands, with
  no baseline file and no allowlist added.

## Enablement

none needed — the pattern to copy (`_build/casts.tl` + test), the
capacity fact that rules lint out (448/500), the floor, and the
zero-findings start are all measured above; the fmt gate underwrites the
textual body extraction.
