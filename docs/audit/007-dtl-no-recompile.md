# 007 — `.d.tl` contract changes never recompile importers

severity: medium
type: bug (staleness)
area: `_make/deps.tl`, `_make/graph.tl`

## issue

the generated per-source dependency closures (`srcdeps_*`) exist to force
recompilation of importers when a module's contract changes — the exact bug
2b found and `build_test.tl:276` proves for `.tl` modules. but the closure
builder excludes `types` files from resolution, so for the sanctioned
`.d.tl`-beside-`.lua` pattern (which `_make/validate.tl:76-83` explicitly
protects), the type checker resolves `require("foo")` to `foo.d.tl` while
the closure lists only `foo.lua`. editing the declaration changes the
contract without touching any listed prerequisite's mtime — importers are
not re-checked. a `.d.tl` with no implementation beside it produces no edge
at all.

## where

- `_make/deps.tl:24-29` — `resolvable` excludes kind `types`.
- `_make/graph.tl:132-150` — `srcdeps_*` built from that closure.
- `_make/validate.tl:76-83` — the pattern the model sanctions.

## failure scenario

1. project has `ffi.d.tl` beside `ffi.lua`; `app.tl` imports `ffi`.
2. a function signature in `ffi.d.tl` changes incompatibly.
3. incremental `--make build` says up to date; `app.lua` still type-checks
   against the old contract in the cache. a clean build fails check.

this is precisely the "incremental build keeps output a clean build rejects"
class the facts mechanism was introduced to kill.

## suggested fix

include `.d.tl` files in the closure as prerequisites (they need not be
compiled — only listed as srcdeps so their mtime schedules a re-check of
importers). when both `foo.lua` and `foo.d.tl` exist, list both.

## test to add

mirror `build_test.tl:276` for the declaration case: build, edit the
`.d.tl` to remove a function an importer uses, rebuild incrementally, assert
the check fails (today it passes).
