# Problem

G9 may be the first outcome whose win condition holds, and nobody has
checked. The machinery is built end to end: the public-surface
ratchet gates per PR against a committed baseline
(`_build/public_surface_test.tl`, `_build/public_surface_baseline.tl`),
the size report measures per release and compares against the
previous one (`_build/size.tl`, wired into release.yml's "measure the
tree size" step, published as the `size.json` asset), and the report
carries the doctrine-size and cast-count columns the win condition
names. What has not been done is reading the win condition against
the evidence: does the surface ratchet hold, has the size report
shipped with every release since it landed, is doctrine size trending
down, and is pruning work being opened from the report's numbers
rather than taste (the current G9 backlog items are gate-honesty
bugs, which is close but not the same thing).

# Change

The verification slice for G9, in the form the held-outcome mechanism
defines: run each of G9's `measured by:` clauses against the release
history and the tree, quote the evidence in the spec trail, and
deliver a held / not-held-because verdict. If held: the goals.md
amendment and the root's transition per the mechanism. If not: the
gap becomes the item(s) that close it, filed under G9 with the
evidence.

# Non-goals

- Fixing any gate bug found along the way (file it).
- Declaring any other goal held.

# Acceptance

- every `measured by:` clause of G9 in docs/goals.md has a quoted,
  re-runnable evidence line in this item's trail.
- a recorded verdict: held (with the goals.md PR) or the named gaps
  as new G9 items.

# Verdict — 2026-09-02: NOT HELD

Every `measured by:` command was re-run against the tree and the
release history (`cosmic-lua/cosmic` releases, `2026-08-17-a3cd318`
through `2026-09-01-3c80edc`, 17 releases since `_build/size.tl`
landed).

- **surface ratchet holds** — HELD. `o/bin/cosmic --make test
  _build/public_surface_test.tl` → `3 tests: 3 passed`; regenerating
  the baseline (`--make run _build/public_surface.tl --baseline`)
  against the tree produces a byte-identical
  `_build/public_surface_baseline.tl` (`git diff` empty, 51 public
  modules).
- **size report ships with every release** — HELD. `size.json` and a
  `size:` note appear on every release since `2026-08-17-a3cd318`
  (the one `SKIP` on that release is the documented first-measured
  case, not a gap); `release.yml`'s publish step hard-fails
  (`exit 1`) if `size_src`/`size_compare_src` are absent, so this is
  structurally guaranteed as long as a release exists at all.
- **growth named in the diffs that caused it** — supported by
  sampling (not exhaustively audited): every commit in the largest
  single-release jump (`+8421` lines, `2026-08-17`→`2026-08-22`) is a
  distinctly-described, reviewed PR; several quote exact before/after
  counts in the subject line (e.g. `casts: delete the 12
  checker-verified fixture casts, floor 455 -> 443 (#1281)`).
- **doctrine size trends down (shared with G3)** — net-true,
  non-monotonic, and NOT actually compared release over release.
  `agents_md_lines` moved 498 (`2026-08-17-a3cd318`) → 384
  (`2026-09-01-3c80edc`), confirmed by downloading and reading
  `size.json` from 10 releases directly (it rose 454→489 across
  `2026-08-22`–`2026-08-30` before a single large cut to 384 on
  `2026-08-31`). But `_build/size.tl`'s `format_compare` (L165-179)
  never includes `agents_md_lines` in its summary line — every real
  release body prints only `size: lines N (+d), files N (+d), binary
  N (+d), public modules N (+d)`. The number is written every
  release but never surfaced in what is actually published and
  diffed; answering this clause required manually downloading two
  `size.json` assets and diffing them by hand. Gap, filed as a new
  G9 item.
- **pruning work opened from the report's numbers, not taste** — NOT
  HELD. Every item under the G9 root (19 items on the `board`
  branch, `items/` under parent `3HyRcrR35sYRwZl3guddvOBhFoK`) is
  either a gate-honesty bug (`dupes gate misses _fuzz/`, `coverage
  report should derive its exclusions from .cosmicignore`, `snippets
  gate is blind to indented doc-comment code`, ...) or size-motivated
  pruning that traces its evidence to the `_perf` startup/embed
  benchmark scenarios (`embed policy: store exactly the measured
  boot set`), not to `_build/size.tl`'s own release report. No item
  anywhere cites `size.json`/`size-compare.txt` as its trigger, and
  no process step turns the report's numbers into filed work. Gap,
  filed as a new G9 item.

**Verdict: NOT HELD.** Two gaps close the remaining distance to G9's
win condition; both are filed as new items under the G9 root
(`3HyRcrR35sYRwZl3guddvOBhFoK`), described in this item's history.
This item stays open (or is closed as a research slice per the
orchestrator's process) with no goals.md edit and no `gitboard hold`
— G9 is not yet a candidate for the `## Holding` section.
