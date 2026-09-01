## Finding

`make`'s dependency tracking for this repo does not know that a `.c`
translation unit `#include`-ing a `.inc` file depends on that `.inc`
file's content — editing a `.inc` file and rebuilding a target that
`#include`s it silently reuses the stale `.o`, reporting the OLD
behavior with no error, warning, or rebuild.

## Symptom

Discovered while building item `3IiEMurI` (handle «YmGK_2Sei»,
"cosmo.Fetch: too_large error's %I format specifier never renders the
byte limit", PR #310): `tool/net/lfetch.c` does `#include
"tool/net/fetch.inc"`, and `LuaFetchError`'s format-string bug lives in
`fetch.inc`. After editing `fetch.inc` and rerunning `make -j$(nproc)
o//tool/lua/test`, the fix appeared not to work — the OLD, buggy
message (`"max I bytes"`) still came out of a fresh test run. `make`
had not recompiled `o/tool/net/lfetch.o` at all, because its dependency
graph tracks `lfetch.c` but not `fetch.inc`. Only running `rm
o/tool/net/lfetch.o` and rebuilding forced the real object to regenerate
and the fix to take effect.

This is silent and general: any edit to a `.inc` file `#include`-d by a
`.c` file anywhere in this tree risks the same stale-object problem for
any contributor (human or agent) who edits the `.inc` and trusts a
green `make` run as proof the change took effect.

## Provenance

Surfaced 2026-09-01 while building `3IiEMurI` under an orchestrated
wave. Reported out-of-scope per that item's own builder brief (fixing
the `%I` bug was in scope; the build-dependency gap was not) — filed
here as its own item per that brief's "if you notice a real defect
outside this item's scope... report it; the orchestrator files it"
rule.

## Change

To be scoped at refinement. Candidate directions, not yet chosen:

- Have `make`'s dependency generation include `.inc` files in the
  header-dependency scan it already does for `.h` (check how the
  existing `.d`/dependency-file generation works for this tree's C
  build — if it already scans `#include` lines for `.h` but excludes
  `.inc` by extension filter, this may be a one-line fix).
- Alternatively (or additionally), a repo-level linter/gate that flags
  a `.inc` file `#include`-d without a corresponding entry in the
  target's dependency file, so a future gap in whatever fix lands here
  is caught rather than silently reintroduced.

## Non-goals

- Not fixing the `%I` bug itself — that shipped separately as PR #310.
- Not a general audit of every `.inc`/`.h` dependency edge case in this
  large, long-established build system — scoped to making `.inc`
  changes trigger a rebuild of everything that includes them,
  specifically.

## Acceptance

To be written at refinement. Should include a regression check:
touch/modify a `.inc` file included by some `.c` translation unit,
rebuild its target WITHOUT `make clean`, and assert the resulting
object/binary reflects the change (e.g. by embedding a string literal
that changes, then grepping the rebuilt binary or object for it).
