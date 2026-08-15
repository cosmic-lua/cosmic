# D5 — upstream-first, fork-if-blocked on Teal

- **date:** 2026-07
- **status:** active
- **context:** "types never lie" collides with Teal's limitations (no
  flow-narrowing of record unions, casts forced at boundaries). the
  workaround doctrine and per-cast justification are scar tissue. cosmic
  already
  forks Cosmopolitan and ships its own formatter, so owning tools has
  precedent.
- **decision:** contribute narrowing/soundness fixes to upstream Teal;
  fork only when upstream declines a change the goals require. target:
  zero casts in `cosmic/`, then the cast scaffolding retires (G3).
- **rejected:** living within pinned Teal forever; forking now;
  replacing Teal with an own checker.
- **consequences:** external lead time on upstream review cycles; the
  cast scaffolding is explicitly temporary and excluded from the
  user-facing gate verb (G4).

