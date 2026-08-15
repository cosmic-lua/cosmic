# D6 — the promise transfers via runtime defaults plus ratchets

- **date:** 2026-07
- **status:** active
- **context:** the gates protecting cosmic itself (format, coverage
  ratchet, examples, verdict discipline) live in cosmic's Makefile;
  user projects get pieces, not the apparatus.
- **decision:** the binary carries the transfer: a zero-config gate
  verb runs the full suite — format, strict types, tests, examples,
  coverage ratcheting against committed baselines — against any project
  (G4).
- **rejected:** teaching-only (docs show how to assemble gates);
  scaffolding-only (`cosmic new` stamps then drifts).
- **consequences:** user projects and eval agents inherit cosmic's own
  discipline from one command; the gate verb becomes stable-in-practice
  because everything depends on it (in tension with D10 — resolved by
  pinning, as D10 prescribes).

