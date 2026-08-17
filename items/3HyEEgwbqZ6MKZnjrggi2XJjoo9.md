## Goal

G1 — the agent-eval instrument (docs/goals.md), via epic #1126. This item WAS the
epic container; its board-tracked children (#1147 manifest+stage, #1179
score+checks+verdict) both landed, so it returned to `plan` and is refined here into
the epic's next follow-up: "a history format and release-asset retention of
journals." The remaining follow-ups — per-release cadence wiring, the comparison/
ratchet gate, peer sandboxes, folding the round-4 backlog into task selection — are
NOT this item; file them as new children once `plan`'s WIP has slack.

## Change

The retention mechanism this item defines is: `_eval/score.tl`'s existing
`results.json` output is uploaded as a release asset AS-IS (no format change needed —
it already carries `bin_sha`/`suite_version` identity via `eval_types.ResultMeta`),
fetched back for a future release the same way perf/size already do it —
`_perf/baseline.tl --repo OWNER/NAME --out PATH --asset eval-results.json` — because
`_perf/baseline.tl` already takes `--asset NAME` generically (default `"perf.json"`,
already reused for `size.json`; see facts). **No new fetch code is needed.** The one
real gap is retaining the raw per-task journals (`NOTES.md`/`final.txt`), which
`_eval/stage.tl` places under `<run-dir>/<task-id>/` but nothing ever collects or
uploads — they are lost once the operator's run directory is cleaned up.

1. **`_eval/bundle.tl`** (new, ~90 lines) — a `--make run`-able CLI mirroring
   `_eval/stage.tl`'s doc-comment and `cosmic.flags`/`proc.is_main()` shape:
   - `bundle_journals(run_dir: string, out_path: string): integer | nil, string` —
     for each of the seven task ids in `_eval/suite.tl`'s manifest (read via
     `require("_eval.suite")`, not a directory listing — a run dir may hold extra
     scratch entries), check `<run_dir>/<id>/NOTES.md` and `<run_dir>/<id>/final.txt`
     with `fs.is_file`; for each that exists, `zip.open(out_path)` (first call) then
     `Archive:add_file("<id>/NOTES.md", "<run_dir>/<id>/NOTES.md")` (and likewise for
     `final.txt`) via `cosmic.zip`'s `Archive:add_file(name, source, opts?):
     boolean, string`. A task directory missing both files is skipped, not an error
     (an incomplete/failed run still bundles what exists). Returns the count of files
     written, or `nil, string` on a zip-open/add failure.
   - `main(...): integer` — flags `--run-dir DIR` (required) and `--out FILE`
     (required), calls `bundle_journals`, prints the verdict line
     `eval-bundle: OK <out> (<n> files)` on success or
     `eval-bundle: FAIL (<reason>)` on failure (mirroring `_perf/baseline.tl`'s
     verdict-line doc-comment style), exit 0/1 respectively.
   - Doc comment states the two asset names this item settles as the release-asset
     naming convention for a later cadence-wiring child to use verbatim:
     `eval-results.json` (score.tl's output, uploaded unmodified) and
     `eval-journals.zip` (this tool's output).
2. **`_eval/bundle_test.tl`** (new) — a fixture run-dir under `TEST_TMPDIR` with three
   task subdirectories: one with both `NOTES.md` and `final.txt`, one with only
   `NOTES.md`, one with neither file present (and no directory at all, to prove a
   wholly-missing task is not an error). Assert `bundle_journals` returns `3` (two
   files from the first task, one from the second), and that `zip.open` (extract mode)
   on the produced archive lists exactly `<id1>/NOTES.md`, `<id1>/final.txt`,
   `<id2>/NOTES.md` as entry names.

```facts
$ git show origin/main:_eval/score.tl | wc -l
434
$ git show origin/main:_eval/stage.tl | wc -l
379
$ git show origin/main:_perf/baseline.tl | grep -n 'ASSET_NAME <'
49:local ASSET_NAME < const > = "perf.json"
$ git show origin/main:.github/workflows/release.yml | grep -n 'baseline.tl --repo\|--asset size.json'
158:            o/bin/cosmic --make run _perf/baseline.tl --repo ${{ github.repository }} \
203:            o/bin/cosmic --make run _perf/baseline.tl --repo ${{ github.repository }} \
204:              --asset size.json --out o/perf/prev/size.json | tee o/perf/size_baseline.txt
```
confirms `_perf/baseline.tl` is already reused unmodified for a second, non-perf
asset name (`size.json`) — the precedent this item's Enablement relies on.

## Non-goals

No change to `_eval/score.tl` or `_eval/stage.tl` — `results.json`'s shape and the
run-dir layout are both already sufficient; this item only adds the journal bundler.
No change to `_perf/baseline.tl` — it is already generic via `--asset NAME` and needs
no eval-specific fork or wrapper. No `.github/workflows/release.yml` changes and no
actual eval-run invocation from repo tooling — wiring an upload/fetch step into a
release, and deciding whether tooling may invoke the agent CLI, is the next follow-up
("per-release cadence wiring"), a separate child. No comparison/ratchet gate. No
`cosmic/zip.tl` changes — `Archive:add_file` already covers this use.

## Acceptance

- `bin/cosmic --make test _eval/bundle_test.tl` ends `test: PASS`.
- `bin/cosmic --make run _eval/bundle.tl --run-dir <a staged _eval/stage.tl output
  with fixture NOTES.md/final.txt files dropped into two task dirs> --out
  $TMPDIR/eval-journals.zip` prints `eval-bundle: OK $TMPDIR/eval-journals.zip (<n>
  files)` and `unzip -l $TMPDIR/eval-journals.zip` lists the expected entries.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — `cosmic.zip`'s `Archive:add_file` and `cosmic.flags` are landed and
already used in this exact style by `_eval/stage.tl`; `_perf/baseline.tl`'s
`--asset` generality (confirmed reused for `size.json` in
`.github/workflows/release.yml`) means the fetch half of retention needs no new
code at all, only the naming convention this item's `_eval/bundle.tl` doc comment
records.
