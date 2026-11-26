# Comparing artifacts

Boot both worktrees before measurement. Keep one coordinator in charge of the
host: no concurrent builds, test suites, fuzzers or benchmarks. Use the same
optimized target/configuration. Then run from either checkout:

```sh
COSMIC_PERF_BASELINE_COMMIT=<full-parent-commit> \
COSMIC_PERF_CANDIDATE_COMMIT=<full-candidate-commit> \
bin/perf <parent-build-directory>/bin/cosmic <candidate-build-directory>/bin/cosmic /new/result/directory
```

Each executable is a checkout's own tool, in the build directory
`bin/cosmic-bootstrap --standalone build/paths.tl <checkout>` prints, not its
[`bin/cosmic`], which is a script that runs it.

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
fixture builds in a directory beside it (`COSMIC_BUILD_HOME` is `<fixture>-build`),
whose `perf/` holds its logs: `perf/runtime.json` records core, target, configuration and SQLite
identities; `compiler.tsv` records the external artifact's compiler identities
through its SQL command. `perf/setup.json` retains untimed setup command results,
and `query-plan.txt` records a representative reverse-import plan. Raw per-phase
observations, including checked warmups, are saved after every pair under
the `perf/` of `aa-a`'s and `ab-a`'s build directories; `raw.json` combines measured observations only. A failing child is
recorded in its fixture's `perf/failure.json`; the latest completed observation
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
at each workload boundary. The phase logs live in the `perf/` of `aa-a`'s build directory and
of `ab-a`'s, respectively.

Leaf edits use the same content sequence in both phases while retaining
distinct observation pair IDs. With the selected workload's one-based index,
`stride = ((pairs + 4) // 2) * 2`, and iteration starting at one (including
warmups), the recorded `leaf_value` is `1000 + index * stride + iteration`.
The initial value is one. Thus each fixture sees new content each time, never
an earlier content-addressed verdict, and both phases see matching inputs.

The actual fixture lifecycle and old shared-parent regression cases run in
[`ci/fixtures/performance_test.tl`], against the release candidate on each
platform and the checked candidate in the checked job. Their 30-pair runs
ignore elapsed times. CI gives these two cases 60 seconds each (150 seconds
for the phase), while each controller child retains its 30-second bound.
The release suite keeps its 10-second per-test deadline; that deadline had
interrupted these process-heavy correctness cases on Linux and macOS. The
checked suite retains its separate 120-second per-test deadline.

[`bin/cosmic`]: ../bin/cosmic
[`ci/fixtures/performance_test.tl`]: ../ci/fixtures/performance_test.tl

# Finding where time goes

`COSMIC_PROFILE=<path>` makes any cosmic process sample the Lua stack it
stands in every `COSMIC_PROFILE_PERIOD` VM instructions (1000 when unset)
and, at exit, write the stacks to a new file `<path>.<pid>`, in the folded
form flame graph tools read ([`core/profile.h`] says what it does not see).
It never writes over a file that is there, nor through a symbolic link at
the path's last name. A sample counts instructions, not time, so time spent
in C (a SQLite step, a string search) is not seen. `bin/cosmic bench/profile.tl <file>...` prints the functions with
the most samples of their own and in their stack.


[`core/profile.h`]: ../core/profile.h

# Micro-benchmarks

The scripts under `bench/` time small operations: [`bench/runtime.tl`] the
standard library's hot paths (JSON, SQLite, streams, CSV), [`bench/base64.tl`]
MIME base64 decoding, and [`bench/shell.tl`] cosmic.shell's calls against the
commands they are named after. They share one harness, [`bench/harness.tl`]:

```teal
local Bench = require("bench.harness")
local Json = require("cosmic.json")

local bench = Bench.new("runtime")
local small = '{"id":42,"ok":true}'
bench.case("json.decode small", function(n: integer) for _ = 1, n do assert(Json.decode(small)) end end)
return function(argv: {string}): integer return bench.main(argv) end
```

A case's body runs its operation `n` times. The harness doubles `n` until
one batch takes 50 ms (`--target-ms`), then times five batches of that size
(`--rounds`) and prints one line per case: the fastest and the median, in
nanoseconds per operation. A case's options add a `setup` that runs once,
only when the case is selected; a `bytes` count, for a rate in GB/s; and a
`baseline` case, for the ratio of this case's best to that one's. Words
after the options select the cases whose names hold any of them. `--list`
prints the names. A body that ignores its `n` is refused by name.

`--json` prints one JSON object per case, a line each, in place of the
table: `suite`, `case`, `unit`, `best`, `median`, `n`, `rounds` and every
`samples` value, with `gb_per_s` and `baseline_ratio` where the case has
them. A loop, or the evidence of a logged item, can cite a line as it is.

`--against <old-binary>` compares two cosmic binaries on the same cases.
Keep the old tool before a change, then measure after it:

```sh
cp "$(bin/cosmic-bootstrap --standalone build/paths.tl .)/bin/cosmic" /tmp/cosmic-old
# ... edit, then:
bin/cosmic bench/runtime.tl --against /tmp/cosmic-old json
```

Each side first runs the script once with `--list`, untimed, which builds
it and refuses a binary that cannot run it before anything is measured.
This process then sizes each case's batch once, so both sides run the same
batches, and each side runs one untimed child to warm up. Then each of 20 rounds (`--rounds`, at least 6) starts one child of
each binary, the two alternating which goes first, and each child times
every selected case twice and reports the faster. Both children run a copy
of `bench/` in a temporary directory outside the checkout, each building it
into a directory of its own there, so each uses the standard library built
into it, not the checkout's source. Only the script and the harness are
copied, so a script that requires another module of `bench/` has no compare
mode. The table gives each side's best and their ratio (`best`, new over
old: below 1 is faster), the median of the paired per-round ratios
(`paired`), and a 95% sign interval for that median, the method of
[`bin/perf`] on a smaller scale. The verdict is `faster` or `slower` when that band leaves
out 1, and `same` otherwise. With `--json`, each case's record has `mode`
`"compare"`, `old` and `new` objects (each with `binary`, `best`, `median`
and `samples`), `ratio`, `paired`, `low`, `high` and `verdict`. `--binary <path>` replaces the new side, which is by default
the cosmic that runs the script.

Medians on a shared cloud VM swing by half from run to run. Paired rounds
with alternating order cancel most of the drift: an A/A run of
[`bench/runtime.tl`] (one binary on both sides, 20 rounds) gave every case
`same`, with bands within 0.84 to 1.08. A change inside a case's band
cannot be told from noise; more rounds narrow it. The harness measures; it gates nothing, and no
test reads a case's numbers.

[`bench/base64.tl`]: ../bench/base64.tl
[`bench/harness.tl`]: ../bench/harness.tl
[`bench/runtime.tl`]: ../bench/runtime.tl
[`bench/shell.tl`]: ../bench/shell.tl
