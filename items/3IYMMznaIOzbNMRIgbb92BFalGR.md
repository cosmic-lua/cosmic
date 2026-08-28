## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **runtime capability probe** class, 10
sites. Files: `_perf/bench/literal_bench.tl` 3; `cosmic/sandbox/init.tl`
3; `_perf/run.tl` 2; `cosmic/quicksand/box/init.tl` 1;
`cosmic/stream.tl` 1. The shape is code asking at runtime whether a
surface exists, because the answer depends on the runtime or on which
binary is loaded rather than on the types: whether this platform's
`proc` carries `pledge`, whether `fs` carries `deny`, whether a reader
implements the delimiter capability, whether an older embedded copy of
`cosmic.literal` predates a function the benchmark wants to time. The
census verdict is **why it is a floor**: the question is unanswerable
at check time by construction, since a type says what a value is in the
tree being checked and the probe exists precisely because the value may
come from a different tree. It compresses, though. The boolean presence
checks — `(proc as {string: any}).pledge ~= nil` and its four
neighbours — all want one shared helper taking a module and a name and
answering whether the field is there, which removes the per-site map
view. What survives is one cast per probed SHAPE, to name what the
probe found: five today. Reducing 10 to 5 lowers the affected
`_build/casts_baseline.tl` rows; the residual five is the expected end
state, not a failure. Do not fold this into the test-probe class — these
are library and harness sites, and the tie-break in the census is that a
probe in a test defeating its own API is the other class. The class
description and exemplar citation are the
`### runtime capability probe` section of `docs/design/casts.md`; the
per-site list is `docs/design/cast-sites.tsv`.
