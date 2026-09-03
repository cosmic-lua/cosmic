## Goal

Follow-up to `3IYMLDfXlYFaD39TtrxlT1AfWo4` («lT1A_fWo4», "tl: publish
AST node types"), split out by a cold-build failure a builder session
hit trying to land both halves in one PR.

That item curates `tl.Env` into `_types/gentl.tl` (`NAMED` +
`RECORD_FIELDS` + `PRELUDE`) so `tl.new_env`'s generated return type
carries real fields instead of erasing to `any`. This item is the
OTHER half: switching the three actual cast sites —
`cosmic/_teal_ast.tl`'s `teal_ast.new_env` (both the `record
teal_ast` field and the function's declared return, `any, string` →
`tl.Env | nil, string`) and `cosmic/_teal_engine.tl`'s `build_env`
(same return-type change, dropping its `env as {any: any}` cast) and
`process_source` (its `env_cache` from `{string: any}` to `{string:
tl.Env}`, dropping two more `as {any: any}` casts) — to actually
consume the new curated type.

## Prerequisite

**Do not pull this before `bin/cosmic.pin` points at a release built
from a tree that already carries `3IYMLDfXlYFaD39TtrxlT1AfWo4`'s
`_types/gentl.tl` curation.** A builder session (2026-09-03) tried
landing both halves together and hit a reproducible cold-build
failure:

```
$ rm -rf o && bin/cosmic --make fetch && bin/cosmic --make build
generate _types/tlast_gen.tl
generate _types/types_gen.tl
.../o/bootstrap/cosmic: /zip/cosmic/_teal_engine.lua:165: error loading module 'cosmic._teal_ast' from '.../cosmic/_teal_ast.tl':
.../cosmic/_teal_ast.tl:22:49: error: unknown type tl.Env
...
build: FAIL (generate failed)
```

Mechanism: `_types/types_gen.tl` (the generator that would write the
fresh `o/_types/types_gen/tl.d.tl` carrying `Env`) is itself a `.tl`
file that must be compiled before it runs; compiling it (and any
`.tl` file) recurses through `cosmic._teal_engine.build_env` →
`require("cosmic._teal_ast")`, which on a cold tree isn't compiled
yet either — `cosmic/searcher.tl`'s re-entrancy guard
(`cosmic/searcher.tl:266-272`) makes that inner require fall back to
the PINNED release's embedded `/zip/cosmic/_teal_ast.lua`, but the
type-CHECK of the tree's edited `_teal_ast.tl` source still resolves
`tl.Env` against the pinned release's `/zip/.types/tl.d.tl`, which
predates the curation and has no `Env`. `_types/types_gen.tl` never
gets far enough to run, so the fresh type never gets generated, and
the failure doesn't self-resolve on retry (reproduced twice from a
fully wiped `o/`).

This is exactly the class CLAUDE.md's "cold-build rule" names: a
source needing the tree's own generator output passes the converged
`--make ci` (which re-execs into what it just built) but fails
generation 1 of a cold build, which compiles under the CURRENT
`bin/cosmic.pin`. `3IYMLDfXlYFaD39TtrxlT1AfWo4`'s "No pin bump"
non-goal is correct for `3p/tl/tl_pin.tl` (the tl compiler pin — the
`Env` record already exists in the pinned tl 0.24.8, no bump needed
there) but does not hold for `bin/cosmic.pin` (cosmic's own
self-hosting bootstrap pin): THIS item's consumer-side change needs
that pin to already carry the `Env` curation.

Landing order: `3IYMLDfXlYFaD39TtrxlT1AfWo4` alone first (curates
`Env` with no consumer yet, so nothing in the tree type-checks
against it during generation 1 — no cold-build hazard) → a
cosmic-lua/cosmic release cut from a tree carrying that curation →
`bin/cosmic.pin` bumped to that release → only then pull this item.
Check `bin/cosmic --version` / `bin/cosmic.pin`'s date against
`3IYMLDfXlYFaD39TtrxlT1AfWo4`'s merge date before pulling.

## Change

- `cosmic/_teal_ast.tl`: change `teal_ast.new_env`'s declared return
  from `any, string` to `tl.Env | nil, string` (both the `record
  teal_ast` field and the function signature), and its two `@return
  any` doc comments to `@return tl.Env | nil`.
- `cosmic/_teal_engine.tl`:
  - `build_env`'s declared return changes from `any, string` to
    `tl.Env | nil, string`; drop its `env as {any: any}` cast and
    write `env.report_types = true` directly.
  - `process_source`'s `env_cache` changes from `{string: any}` to
    `{string: tl.Env}`, and its local `env` from `any` to `tl.Env |
    nil`; drop the two `as {any: any}` casts and write
    `env.loaded[name] = nil` directly.
- `_build/casts_baseline.tl`'s `cosmic/_teal_engine.tl` row moves from
  `4` to `1` — run `bin/cosmic --make run _build/casts.tl --baseline`
  and commit the result.
- `docs/design/cast-sites.tsv` drops its three now-gone rows
  (`cosmic/_teal_engine.tl` 175, 231, 232) — run `bin/cosmic --make run
  _build/cast_sites.tl --reconcile` and commit the result.
- `bin/cosmic --make ci` passes.

Re-verify these line numbers and the exact cast text against the tree
at pull time — `3IYMLDfXlYFaD39TtrxlT1AfWo4`'s merge may have shifted
them slightly from what its own spec measured.

## Non-goals

Same walls as `3IYMLDfXlYFaD39TtrxlT1AfWo4`: no other `Env` field, no
attempt at the other 15 `tl compiler surface` sites, no upstream tl
PR, no `3p/tl/tl_pin.tl` touch.
