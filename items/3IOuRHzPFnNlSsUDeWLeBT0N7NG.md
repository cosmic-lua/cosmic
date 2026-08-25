## Goal
G3 — an honest type layer. The parent is `3IOK4SZH`, the dynamic-value
boundary; this is its first closure: the `cosmic._version` lookup that
five files each re-implement, and the six `from any` casts that pays for.

## Change
Give `cosmic/init.tl` one typed lookup, export it on the `cosmic`
record, and make the other four sites call it. Six files move.

**1. `cosmic/init.tl`** — replace the body of the existing private
`version()` helper's lookup with an exported one. `VersionInfo` is
already declared in this file (lines 10–13) and is not changed. After
the `main` function, `version()` becomes two functions:

```teal
--- The build-injected version stamps, or nil outside a packed binary.
---
--- `cosmic._version` is generated at build time and embedded in the
--- artifact, so it does not exist in the tree and the checker cannot
--- resolve it: the module name is a local rather than a literal
--- argument, and this function is the one place in the repo that pays
--- for that dynamism. `is` narrows the pcall result to the declared
--- record with a table test, so every caller reads typed fields
--- instead of casting a value out of `any`.
--- @return VersionInfo|nil The embedded stamps, or nil when there are none
local function version_info(): VersionInfo | nil
  local mod = "cosmic._version"
  local ok, info = pcall(require, mod)
  if ok and info is VersionInfo then
    return info
  end
  return nil
end

--- The build-injected version string, or "unknown" outside a packed
--- binary (cosmic._version is generated at build time and embedded).
local function version(): string
  local info = version_info()
  if info and info.cosmic then
    return info.cosmic
  end
  return "unknown"
end
```

`info is VersionInfo` is the mechanism that closes the casts: over
`any` it compiles to one `type(info) == "table"` test — the same
narrowing AGENTS.md names ("Use `is` for dispatch past nil … also
dispatch over `any`") and the same shape PR #1381 used for the coverage
walker's `Node`. No cast replaces the six that go.

Then widen the `cosmic` record and the module table it types:

```teal
  --- The build stamps version_info() returns, exported so callers can
  --- annotate what they hold (`v: cosmic.VersionInfo`).
  type VersionInfo = VersionInfo
  …
  version_info: function(): VersionInfo | nil
```

and `version_info = version_info,` in `M`.

**2–5. The four callers** each drop their private `pcall(require, …)`
and read the record.

- `_cli/main_handlers.tl` (`handle_version`, today `:56–70`): the body
  becomes `local v = require("cosmic").version_info()`, the same
  `io.write` on the `v` branch, the same `_VERSION` fallback on the
  `else`. Its inner `local record VersionInfo … end` declaration goes
  with the cast. **The require goes INSIDE `handle_version`, not in the
  file's top-level require block** — this file is on the boot surface
  (`_make/stamp.tl`'s `BOOT_MODULES`), so a top-level require makes
  every spawned cosmic load `cosmic/init.tl` and, through it, the
  generated `cosmic._version`, on a path nothing else at boot needs.
  `_make/stamp_test.tl`'s `test_boot_list_covers_a_live_child` fails
  loudly if you do (`cosmic is loaded at boot but missing from
  BOOT_MODULES; add it in _make/stamp.tl or every stamp
  under-approximates`) — the answer is the lazy require, not an entry
  in `BOOT_MODULES`. Carry the reason as a comment on the line, in the
  wording above; the file already requires `cosmic.fs` inside
  `write_output` the same way.
- `cosmic/_script_cache.tl` (`build_id`, today `:90–97`): `local ver =
  cosmic.version_info()`, then `if ver then local stamp = ver.cosmic`
  and the unchanged `stamp ~= "" and stamp ~= "unknown"` test. Here the
  require IS top-level (`local cosmic = require("cosmic")`, first in
  the block beside `cosmic.fs`/`cosmic.hash`/`cosmic.user`): this file
  is not on the boot surface, verified by `bin/cosmic --make test
  _make/stamp_test.tl` passing with it.
- `_eval/stage.tl` (`collect_meta`, today `:261–270`): top-level `local
  cosmic = require("cosmic")`, then `local v = cosmic.version_info()`
  and `if v then meta.cosmic_version = v.cosmic end`. The four-line
  comment explaining the dynamic require goes with the code it
  explained — the explanation now lives on `version_info`.
- `_perf/run.tl` (`collect_meta`, today `:147–154`): the same, setting
  both `meta.cosmic_version` and `meta.cosmos_version`.

`require("cosmic")` is the package initializer, not a shard, so
`_cli/lint.tl`'s `visibility` rule does not fire on it (it matches
`require("cosmic%.…")` only) — which is what makes one helper reachable
from all five files without publishing a new `cosmic.<name>` module.

**6. A test for the new export.** Add to `cosmic/cosmic_test.tl`,
beside the existing `test_require_cosmic`:

```teal
local function test_cosmic_version_info()
  local cosmic = require("cosmic")
  local v = cosmic.version_info()
  assert(v ~= nil, "a packed binary embeds cosmic._version")
  assert(type(v.cosmic) == "string" and v.cosmic ~= "", "cosmic stamp")
  assert(type(v.cosmos) == "string" and v.cosmos ~= "", "cosmos stamp")
  assert(v.cosmic == cosmic._VERSION, "_VERSION is version_info().cosmic")
end
test_cosmic_version_info()
```

`cosmic/cosmic_test.tl` runs against the built binary (`TEST_BIN`), so
`cosmic._version` is present and `v` is non-nil there.

**7. Regen the cast floor.** `bin/cosmic --make run _build/casts.tl
--baseline`, then commit `_build/casts_baseline.tl`. That is the exact
command the gate's failure message prints; no gate is weakened any
other way. If the coverage ratchet also complains, run the regen
command *that* gate prints and commit its result — nothing else.

**Build before you check.** The checker resolves `require("cosmic")`
through `/zip/.tl` — the source embedded in the RUNNING binary — before
the working tree (`cosmic/_teal_engine.tl`'s `default_include_dirs`), so
a bare `o/bin/cosmic --check types` after editing `cosmic/init.tl`
reports `invalid key 'version_info' in record 'cosmic'` at all four
callers while `cosmic/init.tl` itself passes. `bin/cosmic --make ci`
converges (builds, then re-execs into what it built) and does not show
this; a hand-run `--check types` needs `bin/cosmic --make build` first.

**Measured 2026-08-25 against `46bb698c`**, each with the command that
produced it, and each re-measured with the whole change applied and
`--make ci` green:

| command | today | after |
| --- | --- | --- |
| `grep -c -- "-- cast: .*from any" _cli/main_handlers.tl` | 1 | 0 |
| `grep -c -- "-- cast: .*from any" _eval/stage.tl` | 1 | 0 |
| `grep -c -- "-- cast: .*from any" cosmic/_script_cache.tl` | 1 | 0 |
| `grep -c -- "-- cast: .*from any" cosmic/init.tl` | 2 | 0 |
| `grep -c -- "-- cast: .*from any" _perf/run.tl` | 3 | 2 |
| `grep -n '"cosmic/init.tl"' _build/casts_baseline.tl` | `= 2` | row absent |
| `grep -n '"cosmic/_script_cache.tl"' _build/casts_baseline.tl` | `= 1` | row absent |
| `grep -n '"_cli/main_handlers.tl"' _build/casts_baseline.tl` | `= 1` | row absent |
| `grep -n '"_eval/stage.tl"' _build/casts_baseline.tl` | `= 1` | row absent |
| `grep -n '"_perf/run.tl"' _build/casts_baseline.tl` | `= 3` | `= 2` |
| `bin/cosmic --make run _build/casts.tl --baseline` (its own summary line) | 301 casts in 110 files | 295 casts in 106 files |

`_perf/run.tl` keeps two `from any` casts (`:130`, `:167`) that have
nothing to do with the version lookup — a decoded-JSON read and
`mod as pt.BenchModule`. They are not this slice's, which is why its
row falls to `2` and not to zero.

A row at zero is absent from the floor by construction —
`_build/casts.tl`'s `count` only emits files with at least one cast —
so four of the five rows disappear rather than reading `= 0`.

File lengths, all far under the 500-line cap; the four callers shrink
and only `cosmic/init.tl` grows (`wc -l`):

| file | today | after |
| --- | --- | --- |
| `cosmic/init.tl` | 74 | 96 |
| `cosmic/_script_cache.tl` | 235 | 235 |
| `_cli/main_handlers.tl` | 421 | 418 |
| `_eval/stage.tl` | 408 | 403 |
| `_perf/run.tl` | 394 | 392 |

(`cosmic/cosmic_test.tl` grows by the 10-line test: 130 → 140.)

**Why `require("cosmic")` and not a new public module.** This was the
item's open decision; it is settled, and the constraint it turned on is
real: three of the five callers (`_cli/`, `_eval/`, `_perf/`) live
outside `cosmic/`, and `_cli/visibility.tl` fails `--check lint` on any
`require("cosmic.<shard>")` from outside `cosmic/`. So the helper is
reachable from all five only if it is public. The three candidates:

- **`require("cosmic")`, chosen.** `cosmic/init.tl` already owns this
  lookup, already declares `VersionInfo`, and already publishes the
  cosmic half of it as `cosmic._VERSION`; the four copies exist because
  nothing exported what init.tl already computes. It is inside the
  strip floor, so a STRIPPED artifact still boots. It needs no new
  file, no `_build/public_surface_baseline.tl` row (`is_public` is
  `cosmic%.<name>`, so bare `cosmic` is not in that set — `grep -c
  '"cosmic"' _build/public_surface_baseline.tl` prints `0`), and no
  `--docs` module entry.
- **A new `cosmic.version` module**, rejected: a new public module
  name, a surface-baseline row, a `--docs` entry and a second published
  home for a version number `cosmic._VERSION` already publishes — more
  surface than the six casts are worth, and the least-thing question a
  review would ask of it has no good answer.
- **A private `cosmic/_version_lookup.tl` shard**, rejected: the
  visibility lint refuses it from `_cli/`, `_eval/` and `_perf/`, so it
  would close 3 of the 6 casts and leave three copies of the workaround
  standing.

## Non-goals
- **`cosmic._version` itself does not move.** `cmd/cosmic/embed_gen.tl`
  keeps generating it at `cosmic/_version.lua` inside the module root,
  from `3p/cosmos/cosmos_pin.tl` and `.version`; the record it carries
  keeps its two `cosmic`/`cosmos` fields. This slice changes only who
  reads it and how.
- **`--version` output is frozen.** `cosmic --version` prints
  `cosmic-lua <cosmic> (cosmos <cosmos>, <Lua _VERSION>)` inside a
  packed binary and bare `<Lua _VERSION>` without one;
  `cosmic/version_test.tl` pins both and must pass untouched. Do not
  edit that test.
- **`cosmic._VERSION` keeps its type and value.** It stays a plain
  `string` computed at module load, `"unknown"` outside a packed
  binary — not a `VersionInfo`, not nil-able.
- **No new public module, and no other export on the `cosmic` record.**
  `version_info` and the `VersionInfo` type export are the whole
  widening; `_build/public_surface_baseline.tl` must not move.
- **Do not touch `_cli/visibility.tl`, `cosmic/doc/visibility.tl`, or
  `_build/public_surface.tl`.** The visibility rule is the constraint
  this slice designed around, not something to adjust.
- **`_make/stamp.tl`'s `BOOT_MODULES` does not move.** The boot surface
  is unchanged because the one boot-surface caller requires lazily; do
  not add `cosmic` or `cosmic._version` to that list to make a
  top-level require pass. `git diff origin/main -- _make/stamp.tl` must
  be empty.
- **The other two closures under `3IOK4SZH` are not this slice.** Leave
  every other `-- cast: from any` in the tree alone — 105 lines carry
  that reason today (`git ls-files '*.tl' | xargs grep -h -- "-- cast: "
  | grep -c "from any"`), and only the six in these five files close
  here.
- **Do not edit `docs/design/casts.md`.** Its tables are a snapshot
  dated `d3e59de7`, already stale independently of this slice, and
  refreshing it is its own item (`3IQC4GeO`).

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" _cli/main_handlers.tl _eval/stage.tl
  cosmic/_script_cache.tl cosmic/init.tl` prints `0` for each of the
  four (they print `1`, `1`, `1`, `2` today).
- `grep -c -- "-- cast: .*from any" _perf/run.tl` prints `2` (it prints
  `3` today) — the two survivors are unrelated to the version lookup.
- `grep -c '"cosmic/init.tl"\|"cosmic/_script_cache.tl"\|"_cli/main_handlers.tl"\|"_eval/stage.tl"'
  _build/casts_baseline.tl` prints `0` (it prints `4` today).
- `grep -n '"_perf/run.tl"' _build/casts_baseline.tl` shows `= 2` (it
  shows `= 3` today).
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `bin/cosmic --make test cosmic/cosmic_test.tl` ends `test: PASS (1
  file)` and includes `test_cosmic_version_info`.
- `bin/cosmic --make test cosmic/version_test.tl` ends `test: PASS (1
  file)` with that file unmodified (`git diff origin/main --
  cosmic/version_test.tl` is empty).
- `bin/cosmic --make test _make/stamp_test.tl` ends `test: PASS (1
  file)` — the boot surface did not grow — and `git diff origin/main --
  _make/stamp.tl` is empty.
- `o/bin/cosmic --version` prints one line matching
  `^cosmic-lua .* \(cosmos .*, Lua 5\.4\)$`.
- `wc -l cosmic/init.tl` reports at most 500 (it reports 96 with this
  change applied).
- `git diff --stat origin/main...HEAD` names exactly seven files:
  `_build/casts_baseline.tl`, `_cli/main_handlers.tl`,
  `_eval/stage.tl`, `_perf/run.tl`, `cosmic/_script_cache.tl`,
  `cosmic/cosmic_test.tl`, `cosmic/init.tl`.

## Enablement
none needed. The mechanism is a Teal record plus `is` dispatch over
`any`, both stated in AGENTS.md and already carried by this tree, and
the cast floor's regen command is printed by the gate that fails. The
one non-obvious fact — that the checker resolves `require("cosmic")`
from the running binary's embedded source before the working tree, so
`--check types` must follow a build — is written into `Change` above.
The whole shape was applied and gated during this refinement pass:
`--check types` clean on all five files, `_make/stamp_test.tl` and
`cosmic/cosmic_test.tl` green, and `bin/cosmic --make ci` ending
`ci: PASS (5 stages)` — `fmt: PASS (527 files)`, `check: PASS (527
files)`, `example: PASS (34 files)`, `lint: PASS (624 files)`,
`coverage: PASS (239 files)` with `coverage ratchet ok` and no edit to
`.cosmic-coverage` — with the cast floor regenerated. The two traps
that pass found (the boot-surface require and the checker resolving
`require("cosmic")` from the running binary) are written into `Change`
rather than left for the implementing session to rediscover.
