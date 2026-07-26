# D15 — an artifact carries its modules and `embed/**`; shipping is opt-in

- **date:** 2026-07
- **context:** the `--make` project model declares intent by position or
  marker — a test is `*_test.*`, a pin is `*_pin.tl`, payload is
  `embed/**`, internal is `_`. One row inverted that: "everything else
  is an asset, embedded at its relative path". Shipping was the
  default, not a declaration, and the design's open problems clustered
  exactly there — cosmic's own `--make` artifact came out 10.2 MB
  against the Makefile's 8.7 because a repo is full of files that are
  *about* a project rather than *of* its artifact (`docs/`, `mk/`,
  `Makefile`, `_perf/`, both agent files); `.cosmicignore` was about to
  acquire a second meaning ("not shipped" beside "not seen"); and
  `testdata/`'s exclusion and `.d.tl`'s never-embedded rule existed
  solely to carve exceptions out of the default.
- **decision:** an artifact carries its **modules plus `embed/**`**, and
  nothing else. `embed/` was already "where a project puts a file the
  layout rule cannot place"; this promotes it to *the* place a
  non-module file says it belongs in the binary. Everything else stays
  an ordinary part of the project and never reaches an artifact.
- **rejected:** a second `.cosmicignore` knob (it treats the symptom —
  an opt-in model has nothing to un-ship); per-artifact include lists
  (an enumeration, which is what the layout rule exists to avoid);
  keeping the default and shrinking it with heuristics (a heuristic
  about what "looks like" project metadata is exactly the silent
  behaviour the model is built to refuse).
- **consequences:** the asset-at-relative-path convenience is gone —
  a `schema.sql` an artifact needs becomes `embed/schema.sql`, one
  `git mv` per asset. In exchange an artifact's contents are greppable
  from the tree (`ls embed/` plus the module set), the same
  enumerable-surface property already bought for network and exec.
  Cosmic's own binary now *declares* the two non-module trees it ships
  (`sys/**` for `--help`, `skills/cosmic/**` for `--docs`) in its
  payload generator, where the rest of its payload is already declared.
  Decided while the `assets/` fixture and the layout rule were young:
  the cost of this change grows with every downstream project that
  accretes implicit assets.

