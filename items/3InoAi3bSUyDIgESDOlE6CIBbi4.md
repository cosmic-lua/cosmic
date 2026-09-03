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

Extend the rule to cover all three — no exclusions needed. Verified end
to end against a fresh clone, cold build (`make -j$(nproc)
o//tool/lua/test`) and the real `o//tool/lua/lua.dbg` interpreter:

- **`dbdata`**: its marker lives under `ext/recover/`, not `ext/misc/` —
  add a `MARKER_DIR` override table (parallel to batch 2's
  `MARKER_STEM`), keyed per unit, defaulting to `ext/misc/`.
- **`dbdata`**: its commented linkage include names `sqlite3.h`, not
  `sqlite3ext.h` (`dbdata.c` guards its prelude on
  `#if !defined(SQLITEINT_H)` so it can also compile inside the
  amalgamation, and its init never touches
  `SQLITE_EXTENSION_INIT2`/the extension API) — add an `INCLUDE_HEADER`
  override table, one entry (`dbdata = "sqlite3.h"`), default
  `"sqlite3ext.h"` for everything else. **Not** a blanket
  "capture whatever header name the comment names" generalization:
  `fileio.c`'s shell.c section (already landed) also carries an
  unrelated commented `/* #  include "windirent.h" */`
  (shell.c:9820, Windows-only, deliberately never restored) that a
  blanket capture would wrongly try to substitute, breaking the
  currently-green `fileio` extraction.
- **`dbdata`**: two adjacent commented typedef stand-ins
  (`u8` then `u32`, shell.c:19779-19780, one newline apart) expose a
  pre-existing bug in the typedef-restoration rule: its single-pass
  `gsub` consumes the shared newline restoring the first, so the
  second's required leading `\n` is gone and it is never restored
  (confirmed: `gcc -fsyntax-only` on the naively-extracted file fails
  `unknown type name 'u32'`). Loop the typedef-restore `gsub` to a
  fixpoint (`repeat ... until n == 0`). No already-landed unit has two
  typedef-comments this close together, so this is a latent, rule-wide
  bug `dbdata` is the first unit to trigger, not a `dbdata`-only fix.
- **`base64`/`base85`**: `SQLITE_SHELL_EXTFUNCS` is never `-D`'d
  anywhere in this repo (confirmed: zero hits outside shell.c itself,
  and no `BUILD.mk` flag set defines it), so the `#ifndef
  SQLITE_SHELL_EXTFUNCS` (first, non-`static`) branch is always the
  live one in the compiled shell binary, and the ONLY one usable by the
  registry — `extensions.c` is a separate translation unit and cannot
  call a `static` symbol from the `#else` branch. This inverts the
  original candidate framing ("extract only the `#else` branch if it's
  the registry-legal shape"): the `#else static int` branch is the dead
  one. Fix: loosen the test's definition check from an exact literal
  match to a non-greedy pattern, `"\nint " .. inits[i] .. ".-%("` —
  still matches every already-landed unit's plain one-line definition
  unchanged, and now also matches the name landing on its own
  declaration line ahead of `#else`/`#endif`.
- **`base85`**: independently, its commented linkage include is
  `/* # include "sqlite3ext.h" */` (shell.c:7102, note the space after
  `#`) where every other unit (including `base64`) has
  `/* #include "sqlite3ext.h" */` (no space) — the test's
  `INCLUDE_INLINED` literal-string match finds zero matches, failing
  the test's own `assert(n == 1, ...)` before the definition check is
  ever reached. Generalize the include-restore pattern to tolerate
  optional whitespace (`#%s*include`), scoped to the specific header
  name being looked up (paired with the `INCLUDE_HEADER` override
  above, not a blanket "any header" capture, for the same `fileio`
  reason as above).

Once landed, all five units wire in the same way batches 2 and 3 did:
`THIRD_PARTY_SQLITE3_A_SRCS`/`_OBJS`, `extensions.h` inits, registry +
alias entries, size delta reported, green on
`make -j$(nproc) o//tool/lua/test`.

## Non-goals

- Not re-opening batches 2 or 3 (`appendvfs`, `completion` from batch
  1 are unaffected and still land cleanly once this resolves).
- Not deciding whether `dbdata`/`base64`/`base85` get registered by
  any per-connection API — same non-goal as the rest of `h38H_4UJ0`.
- Not fixing `db_register_extension`'s `SQLITE_OK_LOAD_PERMANENTLY`
  handling (see the separate item this research raised, below) — that
  blocks the batch-1 landing PR's own gate but is a distinct defect in
  `tool/net/lsqlite3.c`, not in the extraction rule this item answers.

## Acceptance

- `tool/lua/test_sqlite_extensions.lua` extended per the above:
  `MARKER_DIR` (one entry, `dbdata`), `INCLUDE_HEADER` (one entry,
  `dbdata`), the include-restore pattern generalized to `#%s*include`,
  the definition check loosened to the non-greedy `.-%(` pattern, and
  the typedef-restore `gsub` looped to a fixpoint. Roughly 25 changed
  lines total; the byte-identity invariant itself is untouched.
- `o//tool/lua/lua.dbg tool/lua/test_sqlite_extensions.lua` reports all
  16 rows (11 existing + `appendvfs`, `base64`, `base85`, `completion`,
  `dbdata`) and `PASS` — verified directly on a scratch copy of the
  test file with all five units wired into
  `extensions.c`/`extensions.h`/`definitions.lua`/`BUILD.mk`.
- `make -j$(nproc) o//tool/lua/test` reaches and passes
  `test_sqlite_extensions.ok` on a cold build compiling all five new
  translation units into `libsqlite3.a` — verified directly.
- No already-landed unit's extraction changes shape or regresses (the
  16-row run above is itself the regression check for all 11
  previously-landed rows plus `zipfile`).
- Before the actual batch-1 landing PR: `appendvfs` will still fail
  `tool/lua/test_sqlite_register_extension.lua` at the
  `db:register_extension` assertion, because of the separate
  `lsqlite3.c` defect this research surfaced (see below) — that fix is
  a prerequisite for landing batch 1, not for answering this item's own
  question, and is filed as its own item blocking the landing PR.
