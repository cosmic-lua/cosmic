# Comparing artifacts

Boot both worktrees before measurement. Keep one coordinator in charge of the
host: no concurrent builds, test suites, fuzzers or benchmarks. Use the same
optimized target/configuration. Then run from either checkout:

```sh
COSMIC_PERF_BASELINE_COMMIT=<full-parent-commit> \
COSMIC_PERF_CANDIDATE_COMMIT=<full-candidate-commit> \
bin/perf /absolute/parent/o/bin/cosmic /absolute/candidate/o/bin/cosmic /new/result/directory
```

[`bin/perf`] uses the pinned bootstrap as one fixed controller. It copies and hashes
both executables, creates four independent fixture trees, and retains all
inputs. The output directory must be new. Allow room for the binaries, working
databases and test closure stores. `COSMIC_BOOTSTRAP` can select a different
controller explicitly; keep it identical throughout a comparison series.

Each workload first compares the parent with itself under labels A/A, then the
parent with the candidate under A/B. Each phase discards three checked warmups
and retains 200 pairs, alternating which side runs first. A fourth argument can
choose a fixed count from 30 through 2000 before measurements begin. Counts below
200 are exploratory and cannot pass. There are no adaptive repeats or early stops. Startup/load samples
batch five fresh processes. This measures warm filesystem caches; cold I/O and
peak RSS are explicitly unmeasured. Child supervision is included identically
on both sides; there is no subtraction of estimated overhead.
An optional fifth argument selects one exact workload name, such as
`embed_portable`; the selection is recorded. Use this to resolve a specific
inconclusive workload with a larger, predeclared sample, keeping the earlier run.

Workloads cover portable/native application and tool startup, first require,
require closure, exact docs, uses, reverse imports, outgoing uses, application
projection/packaging, no-change builds, and a two-test fixture. Full fixture
execution deletes only the working database's `verdicts` rows before timing;
staged inputs stay. Leaf-edit samples use new content each time and require only
the dependent test to rerun. Full repository execution remains a separate gate.
Fixtures deliberately run unsandboxed, with shared compile/verdict caches off;
these measurements establish no sandbox correctness. Automatic boot is disabled.

`metadata.json` identifies retained artifact bytes and host conditions. Each
fixture's `o/perf/runtime.json` records core, target, configuration and SQLite
identities; `compiler.tsv` records the external artifact's compiler identities
through its SQL command. `o/perf/setup.json` retains untimed setup command results,
and `query-plan.txt` records a representative reverse-import plan. Raw per-phase
observations, including checked warmups, are saved after every pair under
`aa-a/o/perf/` and `ab-a/o/perf/`; `raw.json` combines measured observations only. A failing child is
recorded in its fixture's `o/perf/failure.json`; the latest completed observation
and build counters are retained beside it. Generated files stay outside Git.

The report gives medians, p95s, sample counts, reason codes and uncertainty
intervals. Median bounds use the exact binomial sign ranks with 95% coverage.
Each p95 uses a 97.5% order-statistic interval; subtracting opposite endpoints
of the two intervals gives a conservative joint 95% interval for the p95
change, by Bonferroni. This does not require independence between the two sides
of a pair. Binomial masses are normalized from their mode, so large sample
counts do not underflow at `2^-n`. A missing finite endpoint is encoded as JSON
`null` with an explicit bounded flag; it is never replaced by the sample maximum.

A/A must include zero in both its median and p95-change intervals. Each
statistic has its own A/A resolution (the larger absolute interval endpoint).
A wholly positive candidate interval for either statistic prevents a pass:
its lower bound beyond that statistic's A/A resolution means regression;
otherwise it means inconclusive. The empirical p95 difference alone is not a
veto and is never compared with median uncertainty. A centered-deviation
noise check can also make a comparison inconclusive; it is a heuristic, not
an exact confidence interval for population dispersion.

The sample count is fixed before collecting any observations. The classifier
runs once after each complete A/A and A/B phase; it neither adds samples on a
nonpass nor pools later selected runs into a new nominal confidence claim.
Independent paired observations are assumed. Alternating order reduces drift
but does not prove independence. Confidence applies to each reported statistic,
not jointly to every workload or decision in a suite.

Exit 0 means at least 200 pairs, finite tail bounds, unbiased calibrations and
no detected slowdown at the published resolutions. It does not establish
equivalence or prove zero regression. The candidate-independent numerical,
null and detection validation protocol is in [validation.md](performance/validation.md).
Exit 2 means regression or unresolved measurements; exit 1 means an invalid
command, output or counter. An inconclusive result is not permission to merge:
investigate it and, if another comparison is needed, declare its protocol before
collecting data and retain the earlier result. Do not rerun until a favorable
result appears. Artifact
size growth is recorded and does not fail the gate.

[`bin/perf`]: ../bin/perf

The `fixed-sample-v3` fixture manifest names `aa-a`, `aa-b`, `ab-a`, and
`ab-b`, in that order. A/A and A/B have separate parent trees, so each fixture
belongs to one phase and receives the same warmup and sample commands as its
partner. Reusing the A/A parent for A/B
would append twice as many build-history rows, including through `docs` and
`uses`, despite zero source reads and compilations. This is a logical-state
matching requirement; it does not establish the cause of any past timing.

Every observation, including warmups, records `before` and `after` counters
outside the timed region (including the additional history-count query): compiled, cached, read, verdict, run, and total
build-history rows. Building commands must advance both history counters
exactly once; other commands must leave all counters unchanged. No-op builds
must read and compile zero modules and reuse all six fixture modules. Histories
must match within each pair and across all four trees before A/A and after A/B
at each workload boundary. The phase logs live in `aa-a/o/perf` and
`ab-a/o/perf`, respectively.

Leaf edits use the same content sequence in both phases while retaining
distinct observation pair IDs. With the selected workload's one-based index,
`stride = ((pairs + 4) // 2) * 2`, and iteration starting at one (including
warmups), the recorded `leaf_value` is `1000 + index * stride + iteration`.
The initial value is one. Thus each fixture sees new content each time, never
an earlier content-addressed verdict, and both phases see matching inputs.
