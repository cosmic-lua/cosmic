# D21 — carried patches: the middle path between pin and fork

- **date:** 2026-08
- **context:** D5 says upstream-first, fork-if-blocked on Teal. The gap
  between those two states was unpriced: an improvement this project
  wants NOW (truthiness narrowing of nil unions, whilp/cosmic#942)
  takes an upstream review cycle to land and a release to reach the
  pin, and forking for one edit buys a whole compiler's maintenance to
  get it. Meanwhile the workaround scar tissue D5 names — casts after
  guards, `check.must`, the gotcha-9 doc — keeps accruing in every file
  written while waiting.
- **decision:** a pin may carry a patch: `<stem>_patch.tl` beside
  `<stem>_pin.tl`, literal data (named find/replace edits, read by
  `cosmic.literal`, never executed) applied by `fetch` after the
  pristine, digest-verified unpack — see `_make/patch.tl`. Safety is
  exactness: an anchor must occur once in the target or the fetch fails
  loudly, so a pin bump that moves the anchored code is a forced
  re-audit, never silent drift. Application is idempotent, and every
  graph verb repairs patches locally (no network — the archive already
  on disk is the source), which is also what bootstraps a patch through
  CI's pinned-release fetch. Patches ride archive pins only: editing a
  formatless pin's single output would fail its own digest forever.
  The first cargo is the tl narrowing patch (`3p/tl/tl_patch.tl`:
  truthiness, then `assert(x)` and `== nil`/`~= nil`, then the left
  operand of `and` — `if x and x.field`, the shape the tree's own cast
  sweep tripped on — and — whilp/cosmic#1065 —
  a one-line declaration change making `assert` strip nil, so it
  narrows in expression position and not only as a statement), with its
  own canary test (`cosmic/teal_test.tl`) so a lost patch fails as one
  named test, not a hundred downstream type errors.
- **rejected:** forking tl for one edit (a compiler of maintenance for
  a function of change); waiting for upstream (unbounded, and the scar
  tissue compounds while waiting); diff files and an external patch
  tool (a format and a dependency where two exact strings suffice);
  patching at build time only (fetch owns "what the unpacked tree is",
  and a patch is part of that contract).
- **consequences:** each carried patch is debt with a written-down
  maturity date: it must be submitted upstream, and a pin bump that
  includes it upstream deletes the patch file. Until then every tl pin
  bump pays a re-audit when the anchor moves — which is the mechanism
  working, not it failing. The checker the tree gates under is no
  longer byte-identical to released tl 0.24.8; the divergence is one
  named, tested, documented edit.
