# D8 — eval win condition: correctness gates, then efficiency

- **date:** 2026-07
- **status:** active
- **context:** the harness (G1) yields absolute scores (silent bugs,
  errors) and relative ones (cycles vs Python/Node/Go). absolute and
  relative bars fail differently.
- **decision:** hard gate first: zero silent bugs across the suite.
  standing target second: strictly fewer cycles than every baseline on
  the same tasks. both numbers stated per release.
- **rejected:** correctness-only; efficiency-only; a blended composite
  score (easy to trend, easy to game, hard to interpret).
- **consequences:** cosmic can be "losing" to Python on cycles and
  still refuse a change that introduces silent-bug risk.

