## Question

`h38H_4UJ0`'s batch 1 (`appendvfs base64 base85 completion dbdata`) cannot
land under the extraction rule as specified: 3 of its 5 units fail facts
the item's own Evidence section didn't account for. How should the
registry extraction rule (or `tool/lua/test_sqlite_extensions.lua`'s
checks) be extended to cover them, if at all?

## Evidence

Found by the builder of `h38H_4UJ0` while attempting batch 1, verified
directly against the current `third_party/sqlite3/shell.c` and
`tool/lua/test_sqlite_extensions.lua`:

- **`dbdata`**: its shell.c section is bracketed
  `/* Begin ext/recover/dbdata.c */` … `/* End ext/recover/dbdata.c */`
  (shell.c:19701, 20726) — under `ext/recover/`, not `ext/misc/`. The
  test's marker lookup is hardcoded to `"ext/misc/" .. name .. ".c"`
  (batch 2's `MARKER_STEM` override, already landed in PR #370, only
  substitutes the STEM, never the directory prefix). `dbdata` cannot
  pass `no Begin marker for ext/misc/dbdata.c` under that mechanism.
- **`base64`** and **`base85`**: shell.c wraps each one's init
  declaration in `#ifndef SQLITE_SHELL_EXTFUNCS … #else static int …
  #endif` (shell.c:6988-6997, 7365-7374), splitting
  `int sqlite3_base64_init` from its `(` onto separate lines. The
  test's definition check
  (`src:find("\nint sqlite3_base64_init(", 1, true)`, a plain-text
  substring match) requires that literal substring, which a
  byte-faithful extraction of the bracketed block does not contain as
  one line.
- `appendvfs` and `completion` are clean: direct `ext/misc/` markers,
  immediate `int sqlite3_<name>_init(` on one line. Only these two of
  batch 1's five extracted without incident.

## Change

A decision: extend the extraction rule/test to cover `dbdata`,
`base64`, `base85` (three independent sub-questions, may have three
independent answers), or exclude them from the "corrected 13" list
with a documented reason, same as `backup`/`recover` were already
excluded by `3In3TXtn`. Candidates per unit, none yet evaluated for
cost:

- `dbdata`: teach the test's marker lookup a per-unit directory
  override (parallel to batch 2's `MARKER_STEM`, but for the
  `ext/<dir>/` prefix instead of the stem) — or exclude it, since its
  only registry-shaped component is arguably niche recovery tooling.
- `base64`/`base85`: either relax the test's definition check to
  tolerate the `#ifndef SQLITE_SHELL_EXTFUNCS` wrapper (e.g. match
  `int sqlite3_<name>_init(` anywhere in the block rather than
  requiring a leading newline immediately before it), or extract only
  the `#else` branch's definition if that one is the registry-legal
  shape and the `#ifndef` branch is dead under this build's actual
  `SQLITE_SHELL_EXTFUNCS` setting (check whether that macro is defined
  in this build at all — if never defined, the `#else` branch is what
  ships today and the `#ifndef` branch can be dropped from the
  extracted unit entirely).

Once resolved, batch 1 (or whatever subset survives) lands the same
way batches 2 and 3 did: `THIRD_PARTY_SQLITE3_A_SRCS`/`_OBJS`,
`extensions.h` inits, registry + alias entries, size delta reported,
green on `make -j$(nproc) o//tool/lua/test`.

## Non-goals

- Not re-opening batches 2 or 3 (`appendvfs`, `completion` from batch
  1 are unaffected and still land cleanly once this resolves).
- Not deciding whether `dbdata`/`base64`/`base85` get registered by
  any per-connection API — same non-goal as the rest of `h38H_4UJ0`.
