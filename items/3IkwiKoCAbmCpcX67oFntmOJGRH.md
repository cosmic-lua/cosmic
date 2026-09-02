## Goal

G9's win condition requires "pruning work is opened from the report's
numbers, not from taste." The report (`_build/size.tl`, shipped every
release) exists and works, but nothing in the repo ever turns its
numbers into a filed item: every current G9 board item is either a
gate-honesty bug or size-motivated work whose evidence traces to the
`_perf` benchmark scenarios, not to `size.json`/`size-compare.txt`.
There is no documented step, cadence, or threshold anywhere
(`skills/work/decompose.md`, `release.yml`, or elsewhere) that says
who reads a release's size report, when, or what triggers a pruning
item from it. Until one exists, this clause of G9's win condition has
no mechanism to hold by — it can only ever be true by accident.

## Evidence

- Every item under the G9 root (`3HyRcrR35sYRwZl3guddvOBhFoK`, 19
  items enumerated from the `board` branch's `items/` tree) is either
  a gate-honesty fix (e.g. "dupes gate misses _fuzz/: byte-identical
  bodies in two files passed ci", "coverage report should derive its
  exclusions from .cosmicignore", "snippets gate is blind to indented
  doc-comment code") or size-motivated pruning whose own spec cites
  the `_perf` startup/embed scenarios as evidence (`embed policy:
  store exactly the measured boot set, deflate the rest`), not
  `_build/size.tl`'s release report.
- `skills/work/decompose.md` documents the VERIFICATION-item and
  held-root procedures in full but says nothing about a periodic size
  review or a growth threshold that opens work.
- `release.yml`'s size-report steps (the "measure the tree size" and
  "compare tree size against the previous release" steps) only
  publish and print `size.json`/`size-compare.txt` — nothing reads
  them back to open an item.

## Change

Decide and document (as a decision record if it settles a real
tradeoff — e.g. what growth threshold or cadence counts as
report-driven versus noise) a concrete, mechanical step that turns
the size report's numbers into filed G9 work, for example: after each
release (or on some cadence), a session reads that release's
`size-compare.txt` (once the sibling item extending format_compare
with a doctrine-size line lands, including the doctrine delta)
against the prior release(s), and any per-tree growth outside normal
PR-by-PR noise (a threshold to be decided, not a taste call) gets
filed as a G9 item citing the exact numbers from the report as its
evidence. Land this as a documented step in `skills/work/decompose.md`
(or wherever the release/board cadence is otherwise documented), and
demonstrate it once by actually reading the current `size.json` trend
and filing (or explicitly declining to file, with reasoning) at least
one real pruning candidate from it — so the practice is proven, not
just written down.

## Non-goals

- Not a redesign of `_build/size.tl`'s report format itself (a sibling
  item under G9 already covers that).
- Not a commitment to prune any specific tree found along the way —
  only to establish that pruning work traces to the report's numbers
  when it does happen.
- Not an automated bot/CI gate that opens items — a documented,
  followable human step is sufficient to hold this clause.

## Acceptance

- `skills/work/decompose.md` (or the correct home for release-cadence
  process) documents the concrete step that turns size-report growth
  into a filed G9 item, including what threshold or judgment call (if
  any) distinguishes report-driven pruning from taste.
- If a tradeoff was settled (a threshold, a cadence), it is recorded
  as a decision record via the `decide` skill.
- At least one real item citing `size.json`/`size-compare.txt` numbers
  as its evidence exists under the G9 root, demonstrating the
  documented step actually works.
