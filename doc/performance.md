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
both executables, creates three independent fixture trees, and retains all
inputs. The output directory must be new. Allow room for the binaries, working
databases and test closure stores. `COSMIC_BOOTSTRAP` can select a different
controller explicitly; keep it identical throughout a comparison series.

Each workload first compares the parent with itself under labels A/A, then the
parent with the candidate under A/B. Each phase discards three checked warmups
and retains 30 pairs, alternating which side runs first. A fourth argument can
choose 30 through 200 pairs before measurements begin. Startup/load samples
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
`a/o/perf/`; `raw.json` combines measured observations only. A failing child is
recorded in its fixture's `o/perf/failure.json`; the latest completed observation
and build counters are retained beside it. Generated files stay outside Git.

The report gives medians, p95s and exact sign-based 95% intervals for paired median
differences. A/A's median interval sets the reported practical resolution. A
biased calibration, a wholly positive candidate interval inside that resolution,
or demonstrably noisier candidate observations are inconclusive. A repeatable positive
interval beyond the resolution is a regression. A slower empirical p95 can veto
a median pass; 30 pairs do not establish a precise tail confidence interval.
The median sign interval assumes independent paired observations; alternating
order reduces drift but does not prove independence. The centered absolute
deviation intervals are a conservative noise diagnostic, not exact confidence
intervals for population dispersion.

Every nonpass gets one complete new A/A and A/B reading; both readings remain in
the output. The final classification uses all first and repeat observations
together. Different empirical tail verdicts also set `needs_review` and print a
warning for the reviewer; pooling must not make that evidence disappear.
Exit 0 means no
detected slowdown at the published resolution, not proof of zero regression.
Exit 2 means regression or unresolved measurements; exit 1 means an invalid
command, output or counter. An inconclusive result is not permission to merge:
resolve it on a quieter host or through a larger, predeclared comparison. Artifact
size growth is recorded and does not fail the gate.

[`bin/perf`]: ../bin/perf
