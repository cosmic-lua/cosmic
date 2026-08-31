## Capture

Moving cosmic from Lua 5.4 to Lua 5.5. Research recorded, decision deferred — this
is a project, not a version bump, and it is not pullable as written.

### Where the versions stand

The tree vendors **Lua 5.4.6** (May 2023). Upstream released **5.5.0** on 22 Dec
2025 and **5.5.1** on 3 Aug 2026. The 5.4 line ended at **5.4.9** (25 Aug 2026)
with no further releases planned, so 5.4 is now a closed line and 5.5 is where
upstream Lua lives.

### Why it is not a bump

**Note: its blocker changes this calculus.** The 5.4.9 item now restructures
`third_party/lua` into pristine sources plus a mechanical transform plus numbered
patches, on the `third_party/sqlite3/update.sh` model. Once that lands, moving to
5.5 is not "rebase 3,312 lines across +6,583/-4,029" — it is: point `update.sh` at
the 5.5.1 tarball, let the mechanical transform run, and see which of the ~1,531
lines of semantic patch still apply. The ones that fail are the real work, and they
fail *loudly and individually* rather than as one intractable merge. The interpreter
half of this item is therefore best re-measured after its blocker, not before.

The raw churn, for scale:

| | files | churn |
|---|---|---|
| 5.4.6 → 5.4.9 | 32 | +488 / -296 |
| 5.4.6 → 5.5.1 | 63 | **+6,583 / -4,029** |

The tree's Lua carries 3,312 lines of divergence from stock 5.4.6 — overwhelmingly
upstream cosmopolitan's integration, since this fork's own changes under
`third_party/lua` are bindings (`lunix.c`, the two encoders, the REPL) with exactly
one core-file touch (`lauxlib.c`, +6/-5). Rebasing that integration across
+6,583/-4,029 is a different order of work from rebasing it across +488/-296.

### The cosmic-side surface, which is the larger half

The interpreter is only part of it. Cosmic *is* a Lua 5.4 distribution:

- `tlconfig.lua` sets `gen_target = "5.4"`, so every `.tl` in the tree compiles for
  5.4 semantics.
- The Teal compiler is pinned at `0.24.8` (`3p/tl/tl_pin.tl`). Teal's **master**
  accepts `"5.5"` as a `gen_target` — its validation carries "gen-compat must be
  explicitly 'off' when gen-target is '5.4' or '5.5'" — but **whether the pinned
  0.24.8 does is unverified and must be checked before anything else**, since a tl
  bump has its own carried-patch consequences (`3p/tl/tl_patch/`).
- The whole `cosmic.*` standard library is written against 5.4 semantics, and the
  generated `cosmo.*` type declarations describe a 5.4-era binding surface.
- User artifacts compile to Lua and run on the embedded runtime, so this is a
  language-version change for every downstream project, not an internal detail.

### What refinement must establish first

- **The 5.4 → 5.5 incompatibility list.** Not captured here: lua.org's 5.5 readme
  only links to reference manual §8 rather than restating it, and it was not
  retrieved. Read §8 and enumerate what breaks for embedders (C API) and for
  existing 5.4 code, then measure that against `cosmic/**` rather than assuming.
- **Whether the pinned Teal targets 5.5**, and if not, what a tl bump costs given
  the carried patch set.
- **Who does the interpreter work.** Same question as the 5.4.9 item: upstream
  cosmopolitan owns the integration being rebased, and that repo is running about
  two commits a month.
- **Whether it is wanted at all.** 5.4.9 closes the safety gap that motivates
  moving at all. Beyond that, 5.5 has to be justified by what it *gives* cosmic —
  its new features against a whole-distribution language migration — and no such
  case is recorded here.

### Sequencing

Do the blocker first regardless. It lands the memory-safety fixes, it commits
nobody to 5.5, and it converts the interpreter half of this item from a rebase into
a patch-reapplication whose failures are enumerable. Re-measure the cost here after
it lands; the numbers below describe today's shape, not the shape this item will
meet. Nothing here should block on this capture,
and this capture should not be pulled until the four questions above are answered.

## Non-goals

- No decision to adopt 5.5.
- No Teal pin bump.
