# Faster independent CI workers

Status: proposed implementation plan; no workflow or product changes yet.
Baseline: `next` at `0ba3835e0da6c938d146decf2a3b7d329d2211b4`.

## Goal and fixed constraints

Reduce end-to-end CI latency by simplifying the work inside each worker.
Keep the existing four-lane matrix: Linux x86_64, Linux aarch64, macOS
aarch64, and Alpine x86_64. Each worker independently builds and tests its
own complete release product. The final provenance job must confirm that
the exact product bytes executed by all four workers are identical.
Alpine continues to build on its Ubuntu worker and execute inside the
offline, unprivileged BusyBox container.

There is no producer/executor handoff, shared build artifact dependency,
or conditional/nightly replacement for per-change reproducibility. A
single producer can avoid the slowest host's compilation, but adds an
upload/download dependency and startup delay. That is a different design
from the one chosen here.

Retain full local, portable, and checked test suites in this work. Retain
the fresh-source portable run, codesign verification, database integrity
and delayed-boundary checks, malformed-format cases, launcher races and
descriptor checks, runtime replacement/unlink checks, self-rebuild and
identity regressions. Do not rename test files to narrow discovery. Do
not cache test verdicts or working databases between CI runs.

## Evidence and uncertainty

The successful [baseline run](https://github.com/cosmic-lua/cosmic/actions/runs/35615656291)
took 5m43s. Its macOS lane determined completion:

| Work | Elapsed |
| --- | ---: |
| Setup and cache restore | about 26s |
| Release build, bootstrap, and local suite | 24s |
| Portable and checked preparation | 198s |
| Fresh-source portable suite | 12s |
| Runtime, launcher, self-rebuild, identity fixtures | 40s |

Within preparation, `format.sh` spans about 156s in the logs; the checked
suite reports 27.3s. These are observed intervals, not isolated compiler
measurements. Instrumentation must distinguish native compilation,
cross-compilation, fixture writing, extraction/comparison, and execution
before attributing the 156s to one cause.

`format.sh` compiles one native decoder and three target decoders.
`launcher.sh` compiles three payloads and three socket helpers. Every
worker does this. `bin/zig` redirects caches under `o/` only for `build`;
the direct `cc` invocations do not use that wrapper configuration. This
is a concrete gap in the scope of the restored CI cache, not proof that
every `cc` invocation is wholly uncached.

The [earlier run](https://github.com/cosmic-lua/cosmic/actions/runs/35610737047)
took 18m29s, with Alpine starting nearly 11 minutes after submission.
Record queue delay separately from execution; do not claim compilation
changes fix runner availability. One warm run is not a latency distribution.

## Sol execution protocol

Use sequential Sol implementation and independent Sol review turns: one
agent at a time, with a fresh reviewer for each stage. Keep implementation
commits in this PR; do not create a PR per stage. Use an isolated worktree
and read `AGENTS.md` before editing. Refresh the base and inspect concurrent
CI changes before implementation; adapt this plan if its baseline is stale.

For each stage:

1. Implement only that stage and record the affected validation obligations.
2. Run its focused checks and capture command, exit status, timing, and
   commit SHA. Use `timeout 30 o/bin/cosmic test` for the ordinary suite;
   do not raise existing bounds to hide regressions. Keep the existing
   separate checked-suite policy and report timeouts distinctly.
3. Commit, then have a fresh Sol agent review correctness, coverage,
   portability, failure propagation, and avoidable complexity.
4. Fix review findings and recheck affected behavior before starting the
   next stage. Push when hosted evidence is required, rather than pushing
   every exploratory edit and filling the queue.

The implementation handoff should include the stage, base/head SHA,
constraints above, files below, and the previous review/evidence. The
review handoff should ask what failure could now pass undetected and
whether the claimed performance improvement is actually measured.
Record progress in this document. Do not merge as part of plan execution
without a subsequent merge instruction.

## Stage 1: expose where time goes

Files: `test/ci/platform.sh`, `test/portable/lib.sh` or a small CI timing
helper, `test/portable/format.sh`, `test/portable/launcher.sh`, and
`.github/workflows/ci.yml` as needed for summary/diagnostic output.

Add lightweight timing around meaningful operations: core build/boot,
local suite, format check, product assembly, each fixture compilation,
format mutation execution, range/prefix verification, checked build and
suite, hook-core build, runtime fixture assembly, portable suite, each
regression script, Alpine execution, and provenance comparison. Avoid
per-assertion logging. Use stable labels and report elapsed time and exit
status. Existing Cosmic verb timings remain useful subordinate evidence.

Keep timing records outside the checkout and product so they cannot alter
module discovery or artifact hashes. Provide readable log lines and a
small table in the job summary, including partial results after failure.
Use existing tools available on all hosts; no Python dependency or package
installation. A coarse portable clock is acceptable if its resolution is
explicit; avoid GNU-only date/time options on macOS and BusyBox.

The timing wrapper must preserve argv, quoting, environment, stdout,
stderr, and the original nonzero status. Beware POSIX shell `set -e`:
calling a shell function in a conditional can suppress failures inside
it. Prefer timing external commands/scripts; do not silently change
failure semantics to collect timing. Cancellation need not fabricate an
end record; mark an unfinished interval if it can be reported.

Acceptance/review:

- Exercise success, a distinctive nonzero exit, and an argument containing
  spaces; ensure instrumentation does not turn an internal failure green.
- Run the instrumented unchanged flow across all four hosted lanes.
- Record both cold and warm fixture behavior with cache provenance.
- Determine how much of `format.sh` is compilation versus byte processing.
  Stop and revise the optimization priority if compilation is not dominant.

## Stage 2: make fixture compilation explicit and cacheable

Files: `build.zig`, `test/portable/format.sh`,
`test/portable/launcher.sh`, `test/ci/platform.sh`, and cache configuration.

Move the format decoder, launcher payload, and socket helper compilation
into named Zig build steps using the repository's pinned compiler and
existing `o/zig-cache` and `o/zig-global`. First preserve the current target
set and flags so cache behavior can be assessed independently of scope
reduction. Keep shell scripts responsible for fixture orchestration and
assertions; do not create a second build system in shell.

Use `build.zig`'s target records as the single target definition. Preserve
target IDs, configuration IDs, required-target mask, optimization,
warnings, include paths, and native-versus-baseline target semantics.
Declare all C/header and generated inputs in the build graph. Install
helpers at deterministic paths under `o/`, outside tracked source.
Keep standalone fixture commands usable: they may invoke the named build
step when inputs are absent, or accept explicitly validated prebuilt paths.
Avoid silently trusting an old prebuilt helper after source changes.

Ensure the cache save happens after every new native compile. Include
fixture source/header inputs in the workflow key so an immutable cache
entry does not permanently miss new fixture outputs. Continue using
per-lane keys and a fallback prefix; Zig must validate restored entries.
Do not add a second cache for direct `zig cc` if the graph migration removes
those calls. Audit remaining direct compiler calls before claiming closure.

Acceptance/review:

- Cold build succeeds; immediate unchanged rebuild reuses compilation.
- A fixture C edit and a consumed header edit each rebuild affected output.
- A fresh checkout with restored compile caches succeeds without restored
  `o/build.db`, verdicts, fixture outputs, or product artifacts.
- Existing format and launcher assertions still run and pass. A deliberate
  malformed fixture is still rejected; remove the mutation afterward.
- Hosted Linux and macOS evidence demonstrates restored-cache reuse, not
  merely a warm cache inside one job. Review cache inputs and stale-output
  failure modes before proceeding.

## Stage 3: compile only the fixture variants each worker needs

Files: the Stage 2 files, plus `test/portable/runtime.sh` and consumers if
their prebuilt contracts require adjustment.

Build the format decoder for the worker's execution target rather than
all three targets. Determine whether the native decoder and target decoder
can share a binary by inspecting their compile-time branches and tests;
keep both if they establish different properties. Always retain the full
three-target manifest and malformed-field validation.

Build only the worker's socket helper. Inspect the launcher payload's use
in the fixture: a launcher artifact that requires real payloads for all
three targets must keep them unless a smaller fixture demonstrably tests
the same selection and manifest contract. Do not insert empty foreign
entries merely to satisfy the writer. Small necessary cross-target builds
are preferable to a complicated fixture redesign.

Apply the same consumer audit to hook cores. Keep all three release cores
on every worker: those are the actual cross-platform product. Retain all
hook cores required by complete runtime artifacts. Reduce hook-core scope
only if consumers permit it without weakening selection/identity tests;
otherwise record why it stays. No product or fixture downloads from other
workers are introduced.

Acceptance/review:

- Document a short mapping of each helper to its consumers and required
  targets. Show exactly which compiler invocations disappeared.
- Run format, launcher, runtime, self-rebuild, identity and product checks
  on the relevant real hosts, including Alpine's BusyBox execution.
- Verify macOS codesign and architecture selection still exercise the real
  selected product core; unsupported selections must still fail.
- Compare timings with Stage 1, separating cache benefit from fewer builds.
- Full suites still report actual execution (`0 stood` where required),
  and all four independently produced release artifacts compare equal.

## Stage 4: cancel superseded runs without coupling branches

File: `.github/workflows/ci.yml`.

Add workflow-level concurrency keyed by workflow and full ref, with
`cancel-in-progress: true`. Scope cancellation to successive runs on the
same branch; separate branches must not cancel one another. Keep the
existing push and manual triggers; do not add duplicate PR-triggered runs
or change failure collection (`fail-fast: false`) in this work.

Inspect how a canceled worker interacts with cache saves, diagnostics,
uploads, and the provenance dependency. A canceled or partial matrix must
never produce a passing provenance result or reuse attestations from an
earlier run. Continue treating cache restoration as optional acceleration.

Acceptance/review:

- Validate workflow syntax and inspect the evaluated group shape.
- Use two harmless successive pushes on this PR branch while the first
  run is active; verify the older run is canceled and the latest finishes.
- Confirm another branch has a distinct group; do not cancel unrelated
  work to test this. Record run IDs and conclusions.
- Ensure the final evidence run is completed, not a superseded run.

## Stage 5: integrated review and latency comparison

Run the complete unchanged validation contract with all optimizations.
Capture at least one cold-cache and one restored-cache hosted run. Use
additional samples only if noise leaves the result unclear. A workflow
rerun is not necessarily equivalent to a fresh warm run: record cache keys,
hits, runner images, commit SHA, and actual build reuse.

Report per lane: queue/start delay, setup/cache overhead, release build,
fixture build, test execution, upload/post steps, and end-to-end completion.
Report the final provenance job and total workflow duration separately.
Compare like-for-like conditions with Stage 1; never compare only the
slowest cold baseline to the fastest warm result. The first success criterion
is removing measured redundant work while preserving validation, not an
unmeasured promise of a particular minute count.

Have a final independent Sol review check:

- Four independent complete builds and executions still occur.
- SHA evidence covers the exact executed, unchanged product on every lane;
  missing, mismatched, failed, or canceled lanes cannot pass the join.
- No test discovery, assertion, bound, or diagnostic was quietly weakened.
- Cold checkout and warm restored-cache behavior are both correct.
- Shell portability, failure propagation, and cache invalidation are sound.
- Complexity added is justified by measured savings. Revert optimizations
  with no useful benefit rather than accumulating optional modes.

Update the PR description with measurements, remaining bottlenecks, review
outcomes and limitations. Leave the PR ready for user review; do not claim
tests ran on a platform based solely on cross-compilation.

## Progress

- [x] Inspect baseline and agree on independent-worker architecture.
- [ ] Stage 1: timing implementation and independent review.
- [ ] Stage 2: cacheable fixture builds and independent review.
- [ ] Stage 3: minimum required fixture targets and independent review.
- [ ] Stage 4: superseded-run cancellation and independent review.
- [ ] Stage 5: integrated hosted evidence and final independent review.
