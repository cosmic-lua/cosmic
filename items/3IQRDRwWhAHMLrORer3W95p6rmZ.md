## Goal
G3 — an honest type layer, under `3IOuSKFx` (the dynamic-value residue).
This is the decidable half: the six `from any` casts whose value crosses a
boundary the code does not own — a `pcall`/`xpcall` result, a
`package.loaded` index taken to avoid a static bind — and where the type
the code wants is already written down one line later. Each closes by
guarding or by capturing the call honestly, with no new API and no
signature moved.

## Change
Measured 2026-08-25 against `47adef2c` with `git ls-files '*.tl' | xargs
grep -n -- "-- cast: .*from any"`, per-file totals from `grep -c --
"-- cast:" <file>` and lengths from `wc -l`.

**1. `cosmic/_teal_engine.tl:248` (404 lines, 96 of headroom; 1 `from any`
of 4 casts).** `local result = result_or_err as TlResult` follows a
successful `pcall(tl.process_string, ...)`, and the next lines already
handle a falsy result with `process_error(name, "processing failed")`.
Replace the cast with `if result_or_err is TlResult then` around the
success return, and let the existing `process_error` line be the negative
branch. `TlResult` is the record the file already names; over `any`, `is`
compiles to one `type(x) == "table"` test.

**2. `cmd/cosmic/main.tl:480,482` (500 lines — AT the cap, zero headroom;
2 `from any` of 3 casts).** The script path packs `xpcall` into `local
results: {any} = table.pack(...)` and then casts `results[1]` to `boolean`
and `results[2]` to `string`. Capture the two values directly instead —

```teal
local ok, err = xpcall(function()
      run_chunk(table.unpack(args))
    end, run.trim_traceback)
if cov_dump then
  cov_dump()
end
if not ok then
  if err is string then
    return 1, err
  end
  return 1, tostring(err)
end
return 0
```

— which removes the `{any}` table along with both casts. `run.trim_traceback`
returns a string, so the `is string` branch is the live one and
`tostring(err)` is the guard's floor. **The file is exactly at the 500-line
cap, so this change must not add a net line**; the shape above is shorter
than what it replaces, and `Acceptance` measures it.

**3. `cosmic/_seal_coverage.tl:21,22,26` (32 lines; 3 `from any` of 3
casts).** `seal_coverage()` reads `package.loaded["cosmic.coverage"]`
rather than requiring it — deliberately, so the seal never force-loads
instrumentation a caller is not using (the comment at `:5–15` says so and
stays) — and then casts the module to `{string: any}` and each of its two
functions to a function type. Declare the shape once at file scope:

```teal
--- The two entry points seal_coverage() needs from cosmic.coverage,
--- declared here because the module is reached through package.loaded:
--- requiring it would force-load instrumentation a caller is not using.
local record CoverageModule
  is_kept_on_restrict: function(): boolean
  seal: function()
end
```

and guard once — `if cov is CoverageModule then` — reading `cov.is_kept_on_restrict`
and `cov.seal` through the narrowed value. All three casts close on one
`type(x) == "table"` test. The runtime `kept ~= nil` check stays: `is`
tests table-ness, not fields, and an older loaded module may not carry the
function.

**The ratchet.** `_build/casts_baseline.tl` rows count every cast in a
file, not only `from any` ones. When the gate complains, run exactly the
command its failure message prints — `bin/cosmic --make run
_build/casts.tl --baseline` — and commit the result. Expected rows:

| file | row today | row after |
| --- | --- | --- |
| `cosmic/_teal_engine.tl` | `= 4` | `= 3` |
| `cmd/cosmic/main.tl` | `= 3` | `= 1` |
| `cosmic/_seal_coverage.tl` | `= 3` | row absent |

## Non-goals
- **No behaviour change.** A script that throws still exits 1 with the
  trimmed traceback on stderr; `cosmic --version`, `-c`, and the REPL
  paths in `cmd/cosmic/main.tl` are untouched. The coverage seal still
  no-ops when `cosmic.coverage` was never loaded, and still respects
  `is_kept_on_restrict()`.
- **`cosmic/coverage/init.tl` is not this slice's.** Its six `from any`
  casts are the sibling's (`3IQREPC5`, the stdlib-patch and thread-boundary
  half); do not touch the file.
- **Do not make `_seal_coverage.tl` require `cosmic.coverage`.** The
  `package.loaded` read is the point of the module.
- **No new public module and no new export.**
  `_build/public_surface_baseline.tl` must not move.
- **Do not touch the other `from any` casts** — 99 lines carry that reason
  today across 41 files (`git ls-files '*.tl' | xargs grep -h -- "-- cast: "
  | grep -c "from any"`), and four open siblings claim named subsets of
  them (`3IQQeXC3`, `3IQQf63I`, and `3IQREPC5`). Only the six
  above close here.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/_teal_engine.tl
  cmd/cosmic/main.tl cosmic/_seal_coverage.tl` prints `0` for each of the
  three (today `1`, `2`, `3`).
- `wc -l cmd/cosmic/main.tl` reports at most 500 (today exactly `500`).
- `grep -n '"cosmic/_seal_coverage.tl"' _build/casts_baseline.tl` prints
  nothing (today `= 3`).
- `grep -n '"cosmic/_teal_engine.tl"\|"cmd/cosmic/main.tl"'
  _build/casts_baseline.tl` shows `= 3` and `= 1` (today `= 4`, `= 3`).
- `bin/cosmic --make test cosmic/teal_test.tl cosmic/sandbox/init_test.tl`
  ends `test: PASS (2 files)`. Neither module has a test file of its own
  (`ls cosmic/_teal_engine*_test.tl cosmic/_seal_coverage*_test.tl` finds
  nothing); these two are their nearest exercised callers —
  `cosmic/teal.tl` drives `_teal_engine`, and `cosmic/sandbox/**` calls
  `seal_coverage()`.
- `printf 'error("boom")\n' > o/boom.lua && o/bin/cosmic o/boom.lua; echo
  "exit=$?"` prints `exit=1` and a trimmed traceback naming `boom` — the
  throwing-script path still reports through the guard. (`o/` is build
  output, not committed.)
- `o/bin/cosmic --make coverage` ends `coverage: PASS` with `coverage
  ratchet ok` — the seal still runs under instrumentation.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `git diff --stat origin/main...HEAD` names exactly four files: the three
  sources above and `_build/casts_baseline.tl`.

## Enablement
none needed. `is` narrowing over `any` is AGENTS.md's stated mechanism and
was demonstrated end to end by PR #1382; the ratchet's regen command is
printed by the gate that fails. The one trap from #1382 worth restating:
the checker resolves `require("cosmic")` from the RUNNING binary's
embedded source before the working tree, so gate with `bin/cosmic --make
ci` (which converges) rather than a bare `--check types` after editing a
`cosmic/**` file.
