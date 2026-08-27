## Goal

The release compare step's bare-load skew class fails the PR that
introduces it, not the release lane days later. Third sighting in
24h: run.tl's version_info (killed 08-26's run; #1415),
literal_bench's two-arg literal.format (would have killed 08-27's;
#1420), gate.tl's triage_many (inert only because gate.tl never runs
bare).

## Change

`_perf/skew_test.tl` — one test that type-checks every non-test
`_perf/**/*.tl` under the pinned bootstrap binary
(`o/bootstrap/cosmic`), in ONE `--check types` invocation (the check
verb fans out over every file named and exits with the worst result).

Why the bootstrap is the right bar: `bin/cosmic.pin` only ever trails
published releases, so the bootstrap is at least as old as the
previous release the compare step downloads — bootstrap-clean implies
prev-release-clean. Verified mechanics (2026-08-27, by hand):
- an old release binary's `--check types` resolves `cosmic.*` from
  its EMBEDDED declarations even from the repo root (a typed two-arg
  `literal.format` probe fails under the 08-23 release, passes under
  the tree binary), and resolves `_perf.*` from the tree at cwd —
  exactly the compare step's bare-load resolution.
- the pre-#1420 literal_bench (14ff1d1d) FAILS the sweep at its line
  140; the landed capability-probe version PASSES. Both directions
  reproduce in-tree.

Shape:
- collect via `fs.find("_perf", {glob = "*.tl"})`, drop `*_test.tl`,
  sort; assert non-empty (a sweep that found nothing is a gate that
  lies).
- assert `o/bootstrap/cosmic` exists, message naming the remedy (run
  bin/cosmic once); never silent-skip.
- `child.run` with `env.list({set = {COSMIC_COVERAGE = "0"}})` so the
  bootstrap child never dumps .cov files for its embedded sources
  into the per-test coverage directory.
- failure message names the class and the remedy — reach a new cosmic
  API from `_perf/**` through a tolerant map view + capability probe
  (pattern: _perf/bench/literal_bench.tl) — quoting the child stderr.

## Non-goals

Option 2 from the capture (measure the previous release with its own
embedded scenarios — self-consistent but loses like-for-like) and
option 3 (a lint taxing new API uses — noisy, version-blind). No
change to gate.tl's triage_many: the sweep covers it. No release.yml
change.

## Acceptance

`--make ci` PASS with the new test in the suite. The sweep passes on
today's tree under bootstrap afad5b5. A deliberate two-arg
literal.format planted in a scratch copy of a bench file fails it
(verified once by hand, not committed). Cost: one child process,
~30 files, seconds added to `--make test`.

## Enablement

None: the bootstrap already lands on every `bin/cosmic` entry and
survives `--make clean`; the test needs no new mechanism, no pin, no
network.
