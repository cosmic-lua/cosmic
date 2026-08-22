## Goal

G6 — measurement you can trust. `_perf/gate.tl compare BASE CUR SELFB`
presents all three paths as inputs and silently re-measures through
one of them, so a second gate call over the same paths compares the
current binary against a file the first call replaced.

## Measurement (2026-08-22, main `aaf4af95`)

Read from `_perf/gate.tl` rather than inferred. `gate_inner` calls the
injected `measure(out)` exactly twice, and `measure` is
`run.main("--out", out, …)`:

- `opts.measure(opts.current)` — the retry ("regression flagged;
  re-measuring once to filter noise"). **Argument 2 is overwritten.**
- `opts.measure(opts.selfcheck_b)` — the A/A control ("regression
  persists; running A/A self-check…"). **Argument 3 is written**, which
  is what that argument is for.

`opts.baseline` is never passed to `measure`, so **argument 1 is not
overwritten** — the capture in this item's original Evidence showed
`base` changing too, and that is not something `compare` does. Either
the same path was passed twice or another `run.tl --out` in the same
loop wrote it. The correction matters for the fix: only CUR is the
silent one.

So the real defect is one argument, not three, and it is the one the
caller cares most about: after a flagged regression, `CUR.json` no
longer holds the run the verdict was computed from. The gate's own
identity guard ("measured the SAME binary … a clean result says nothing
about your change") fires only when two arguments end up identical, so
a partial clobber changes the noise floor with no symptom.

The release workflow runs into the same thing:
`.github/workflows/release.yml:163` gates with
`o/perf/prev/perf.json o/perf/perf.json o/perf/selfcheck.json`, so a
release whose first pass flags a regression rewrites `o/perf/perf.json`
before publishing it.

Headroom for the change, measured now:

```
wc -l _perf/gate.tl        -> 287   (213 under the 500-line cap)
wc -l _perf/gate_test.tl   -> 337   (163 under)
```

`_perf/gate_test.tl` already injects `measure`, so a test asserting
that `CUR.json` is untouched needs no real benchmark: the fake measure
writes only where it is told, and the test reads `CUR.json` back.

## Change

In `_perf/gate.tl`, give the retry its own output path and leave the
gate's arguments alone.

- Add a small local that derives the retry path from the current one:
  strip a trailing `.json` and append `-retry.json`
  (`o/perf/current.json` → `o/perf/current-retry.json`). Beside the
  caller's own output, not in a temp dir: the directory is already one
  the caller writes to, there is nothing to clean up, and a failed gate
  leaves the run that failed it available to read.
- In `gate_inner`, replace the three uses of `opts.current` that follow
  the first `compare_once` with that retry path: `opts.measure(retry)`,
  the post-retry `identity_refusal(opts.baseline, retry, false)`, the
  second `compare_once(opts.baseline, retry, opts.threshold)`, the A/A
  `identity_refusal(retry, opts.selfcheck_b, true)`, and the triaged
  `compare_once(opts.baseline, retry, opts.threshold, retry,
  opts.selfcheck_b)`. The first `identity_refusal` and the first
  `compare_once`, both before any measurement, keep reading
  `opts.current`.
- Print the retry path when the retry runs, on the existing
  "re-measuring once to filter noise" line, so the file the verdict
  came from is named in the output.
- Rewrite the `usage` string to mark each argument, since two of the
  five paths across the two modes are outputs:
  ```
  usage: gate.lua compare BASE.json CUR.json SELFB.json [--threshold PCT] <run args...>
           BASE, CUR: read; SELFB: written by the A/A pass
           a flagged regression re-measures into CUR's sibling CUR-retry.json
         gate.lua selfcheck A.json B.json [--threshold PCT] <run args...>
           A, B: both written — selfcheck's job is to measure twice
  ```

In `_perf/gate_test.tl`, add `test_retry_does_not_overwrite_current`: a
flagged regression whose injected `measure` writes a quiet result to
whatever path it is handed; assert the gate passes, that the path it
was handed ends in `-retry.json`, and that reading `CUR.json` back
returns the original 1300 `wall_ns` unchanged. Model it on
`test_flagged_regression_retries_then_passes` (`:54`), which already
has the shape.

In `skills/optimize/SKILL.md`, at the `gate.tl compare` snippet
(`:73`) and in the paragraph at `:83` that explains the retry and A/A
triage, say which paths the gate reads and which it writes, and that
the retry lands in `CUR-retry.json`. Same one-line note in
`skills/optimize/measurement.md` beside its `gate.lua selfcheck`
mention (`:56`), that selfcheck writes both its arguments.

## Non-goals

- the CLI's shape does not change: `compare` keeps three positional
  paths and `selfcheck` two, so
  `.github/workflows/release.yml:163` and every documented invocation
  keep working untouched. Do not edit the workflow.
- `SELFB.json` stays an output. It is the A/A control's destination and
  always was; the fix is to SAY so, not to move it.
- no change to `_perf/compare.tl`, `_perf/run.tl`, or the
  `perf-compare: PASS`/`FAIL` verdict line format — the release
  workflow greps it.
- no new temp-directory machinery, and no deleting the retry file: a
  failed gate's evidence is worth keeping.
- `AGENTS.md`'s Performance section lists the two commands without
  argument semantics; leave it — the usage line and the skill are where
  that belongs.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test _perf/gate_test.tl
bin/cosmic --make run _perf/gate.tl
```

- `ci: PASS`, quoted in the PR description.
- `_perf/gate_test.tl` passes, including the new
  `test_retry_does_not_overwrite_current`; the new test fails against
  `main`'s `_perf/gate.tl` — show both runs in the PR description.
- the bare `gate.tl` invocation (no mode) prints the rewritten usage;
  quote it. (Read the printed text, not the status: `--make run` is the
  wrapper here and the pipe would launder it anyway.)
- `wc -l _perf/gate.tl` stays under 500.
- the diff touches only `_perf/gate.tl`, `_perf/gate_test.tl`,
  `skills/optimize/SKILL.md`, and `skills/optimize/measurement.md`.

## Enablement

none needed — the five call sites to change are named by expression,
the test to model on is named by line, the injected `measure` makes the
new test cheap, and the fix needs no real benchmark run.
