## Goal

G3 — an honest type layer, under `3IOuSKFx` (the dynamic-value
residue). The decidable half: the six `from any` casts whose value
crosses a boundary the code does not own — a `pcall`/`xpcall` result,
a `package.loaded` index taken to avoid a static bind. Outcome, decided
by a type-checked refinement pass: **five casts close outright; the
sixth keeps its cast with a truthful reason**, because its value was
never `any` at all.

## Evidence

Re-measured 2026-08-26 against main `d61b2cc9` (post the three
casts merges #1392–#1394):

| file | `from any` | all casts | lines | baseline row |
| --- | --- | --- | --- | --- |
| `cosmic/_teal_engine.tl` | 1 (`:248`) | 4 | 404 | `= 4` |
| `cmd/cosmic/main.tl` | 2 (`:480`, `:482`) | 3 | 500 (AT the cap) | `= 3` |
| `cosmic/_seal_coverage.tl` | 3 (`:21`, `:22`, `:26`) | 3 | 32 | `= 3` |

(`grep -c -- "-- cast: .*from any" <file>`, `grep -c -- "-- cast:"
<file>`, `wc -l`, and the `[path] = n` rows of
`_build/casts_baseline.tl`.) The repo-wide residue is down to **26**
`from any` lines (`git ls-files '*.tl' | xargs grep -h -- "-- cast: "
| grep -c "from any"`); the only open sibling claiming a named subset
is `3IQREPC5` (the checker-blocked residue).

**Every shape below was applied and type-checked during refinement**
(`o/bin/cosmic --check types` and `--check fmt` on each file, built at
`d61b2cc9`). Two of the original item's shapes were REFUSED by the
checker and are replaced here:

1. `cosmic/_teal_engine.tl:248` — the planned `is TlResult` guard is
   refused: `pcall(tl.process_string, ...)` types slot 2 as **tl's
   nominal `Result`** (not `any`), and the checker reports
   `result_or_err (of type Result) can never be a TlResult`. Aliasing
   the file's mirror records to tl's own (`local type TlResult =
   tl.Result`) is also unavailable: the `require("tl")` is
   deliberately function-local (lazy compiler load), so `tl.Result` is
   un-nameable at file scope, where `TlResult` is used by
   `ProcessResult` and the exported signatures. The original
   `-- cast: from any` reason was itself wrong — same class as the
   pcall-slot finding recorded on the sqlite sibling (#1394).
2. `cmd/cosmic/main.tl:480,482` — a plain
   `local ok, err = xpcall(...)` destructure is refused ("did not
   produce an initial value"): tl types xpcall's extra returns from
   the protected FUNCTION's returns, and the wrapper returns nothing.
   Giving the wrapper a declared `string` return (a dummy `return ""`)
   makes xpcall type as `(boolean, string)` and both casts close, with
   `run.trim_traceback` staying the direct message handler so the
   traceback's frame depth is untouched.

## Change

Three files. Apply exactly these shapes (all validated):

**1. `cosmic/_teal_engine.tl:248`** — keep the cast, replace its
reason. The line becomes a cast under an above-line comment:

```teal
  -- The lazy in-function require keeps tl's own Result record
  -- un-nameable at file scope; TlResult is its structural mirror.
  -- cast: pcall slot 2 is tl's nominal Result, not any
  local result = result_or_err as TlResult
```

(The `-- cast:` marker must sit on the line DIRECTLY above the cast —
the cast-justify lint reads only that line and the cast's own.)

Nothing else in the file moves. Its `from any` count falls to 0; its
total cast count stays 4, so its baseline row stays `= 4`.

**2. `cmd/cosmic/main.tl`** — replace the pack-and-cast block (lines
474–483 today) with:

```teal
    -- run_chunk's wrapper returns a string so xpcall types (boolean, string)
    local ok, script_err = xpcall(function(): string
      run_chunk(table.unpack(args))
      return ""
    end, run.trim_traceback)
    if cov_dump then
      cov_dump()
    end
    if not ok then return 1, script_err end
    return 0
```

(Indentation per `cosmic --fix`; the refinement pass verified the
formatter's output.) The name is `script_err` because `err` shadows an
outer local at `:463` and shadowing is an error. Net −1 line: the file
lands at 499, back under the cap with headroom of 1.

**3. `cosmic/_seal_coverage.tl`** — declare the shape once and guard
once. After the module doc comment, add:

```teal
--- The two entry points seal_coverage() needs from cosmic.coverage,
--- declared here because the module is reached through package.loaded:
--- requiring it would force-load instrumentation a caller is not using.
local record CoverageModule
  is_kept_on_restrict: function(): boolean
  seal: function()
end
```

and the body becomes:

```teal
local function seal_coverage()
  local cov = package.loaded["cosmic.coverage"]
  if cov == nil or not (cov is CoverageModule) then
    return
  end
  local kept = cov.is_kept_on_restrict
  if kept ~= nil and kept() then
    return
  end
  cov.seal()
end
```

All three casts close on one `type(x) == "table"` test; the runtime
`kept ~= nil` check stays (an older loaded module may not carry the
function). The comment at `:5–15` explaining the `package.loaded` read
stays.

**The ratchet.** Run exactly the command the gate's failure message
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and
commit the result. Expected rows:

| file | row today | row after |
| --- | --- | --- |
| `cosmic/_teal_engine.tl` | `= 4` | `= 4` (unchanged — reason edit only) |
| `cmd/cosmic/main.tl` | `= 3` | `= 1` |
| `cosmic/_seal_coverage.tl` | `= 3` | row absent |

## Non-goals

- **No behaviour change.** A script that throws still exits 1 with the
  trimmed traceback on stderr (`run.trim_traceback` remains the direct
  xpcall handler — do not wrap it, which would add a frame to the
  traceback); `cosmic --version`, `-c`, and the REPL paths are
  untouched. The coverage seal still no-ops when `cosmic.coverage` was
  never loaded and still respects `is_kept_on_restrict()`.
- **Do not hoist `_teal_engine.tl`'s `require("tl")` to file scope**
  to enable the alias — the lazy load is deliberate, and restructuring
  the module's type exports is not this slice.
- **`cosmic/coverage/init.tl` is not this slice's** — its casts are
  `3IQREPC5`'s.
- **Do not make `_seal_coverage.tl` require `cosmic.coverage`.** The
  `package.loaded` read is the point of the module.
- **No new public module and no new export.**
  `_build/public_surface_baseline.tl` must not move.
- **Do not touch the other `from any` casts** — 26 lines carry that
  reason today (command in Evidence); only the six above are this
  slice's, and one of them survives with its truer reason.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/_teal_engine.tl cmd/cosmic/main.tl cosmic/_seal_coverage.tl`
  prints `0` for each of the three (today `1`, `2`, `3`).
- `grep -c -- "-- cast:" cosmic/_teal_engine.tl` prints `4` (today
  `4`) — the mirror cast survives, reason changed.
- `wc -l cmd/cosmic/main.tl` reports at most 499 (today `500`).
- `grep -n '"cosmic/_seal_coverage.tl"' _build/casts_baseline.tl`
  prints nothing (today `= 3`).
- `grep -n '"cosmic/_teal_engine.tl"\|"cmd/cosmic/main.tl"' _build/casts_baseline.tl`
  shows `= 4` and `= 1` (today `= 4`, `= 3`).
- `bin/cosmic --make test cosmic/teal_test.tl cosmic/sandbox/init_test.tl`
  ends `test: PASS (2 files)` — neither module has its own test file;
  these are their nearest exercised callers.
- `printf 'error("boom")\n' > o/boom.lua && o/bin/cosmic o/boom.lua; echo "exit=$?"`
  prints `exit=1` and a trimmed traceback naming `boom`.
- `o/bin/cosmic --make coverage` ends `coverage: PASS` — the seal
  still runs under instrumentation.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `git diff --stat origin/main...HEAD` names exactly four files: the
  three sources above and `_build/casts_baseline.tl`.

## Enablement

none needed. Every shape above was applied and passed `--check types`
and `--check fmt` during refinement, so the two checker refusals that
would have bounced this slice are already designed around. Gate with
`bin/cosmic --make ci` (which converges), not a bare `--check types`
after editing `cosmic/**` — the checker otherwise resolves
`require("cosmic")` from the running binary's embedded source.
