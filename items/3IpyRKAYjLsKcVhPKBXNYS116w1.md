## Evidence

Found while building board item `FePr_L4FB` (casts: record-field
narrowing — the tl patch closing 5 record-union-after-guard sites,
blocked on `3IpyN3BP` pending an upstream issue number).

Two of the five sites `FePr_L4FB` names as in-scope for the eventual
cast-deletion follow-up (once the checker patch lands and a pin bump
picks it up) turn out not to need that patch at all, and a third
cannot be closed by any guard-narrowing mechanism:

- `_make/generate.tl:100` (`local it = (into as fs.Stat):modify_time() -- cast: same`)
  and `cosmic/check.tl:298` (`local status = (wr as proc.WaitResult).status`)
  both type-check cleanly TODAY with the cast simply removed, using
  only the already-shipped bare-variable narrowing
  (`narrow-eq-nil`/early-return) — verified directly against the
  current tree by the `FePr_L4FB` builder, no new patch needed. These
  two `docs/design/cast-sites.tsv` rows are classified "record union
  after guard" but appear stale/already-closable independent of the
  new record-field-narrowing patch.
- `_make/stage.tl:183` (`local sel = v.select as Selection -- cast: a
  graph verb always has one`) has no reachable guard on `v.select`
  anywhere in `graph_stage` — the invariant is enforced elsewhere (by
  `validate.validate(proj)`, in a different function), so no
  guard-based narrowing mechanism (the new patch or any other) can
  ever close this site. It looks misclassified under "record union
  after guard."

## The question

Re-audit the `record union after guard` class in
`docs/design/cast-sites.tsv` against the current tree:

1. `_make/generate.tl:100` and `cosmic/check.tl:298`: confirm they
   close today (no patch needed) and file/build that as its own small
   item — deleting a cast where the checker already accepts the
   unguarded form is independent of `FePr_L4FB`'s patch and doesn't
   need to wait on it.
2. `_make/stage.tl:183`: decide the right fix — is there actually a
   guard reachable in a wider scope this class's mechanism should
   cover, or does this site need reclassifying to a different cast
   class (or accepted as a floor case) since no guard-narrowing
   mechanism can close it?

This re-audit should land before (or alongside) whatever follow-up
item eventually deletes `FePr_L4FB`'s remaining 2 casts
(`_perf/bench/micro_bench.tl:192`, `cosmic/quicksand/box/run.tl:254`)
post pin-bump, so that follow-up's own scope is accurate.
