# Fuzzer effectiveness, usability, and efficiency

Reference plan only. Keep this PR draft and never merge it. Implementation lands through the separate PRs tracked below.

## Baseline and purpose

Reviewed main: e9c56475d7dbbcf2a5574514c85ef9ea90a72878 (2026-10-03).
The prior review used 580598833b0da7f5b0ecb8d6d88a080535cf58b3.
The latest engine still records integer draws, regenerates candidates for reduction,
replays committed byte corpora, checks labels and shares, and runs deep nightly
fuzzing on the checked core. Its existing interface and seed replay are useful and
must remain usable while the engine improves.

The aim is to find more distinct bugs per unit of execution and turn each into a
small, faithful, repeatable regression. Throughput alone is not the objective.
No Python dependency or second testing framework is introduced.

The previous review reproduced six problems:

- Reduction can replace the original failure with another failure.
- Shrink candidates are not saved before checks, so a native crash can leave a
  different input in the advertised crash file.
- Failed input writes are ignored.
- Starting at 1,000,000,000 with failure at >=600,000,000, the integer reducer uses
  all 2,000 attempts and stops at 999,999,500.
- Deletion passes only try widths 8 through 1; a redundant 12-choice unit can survive.
- A well-formed replay selector matching no property can pass with zero checks.

These are testable starting points, not assumptions about the refreshed build.
A fresh boot and focused suite establish the baseline. The prior normal test run
failed with "database disk image is malformed"; do not carry a broken build or its
verdicts into measurements. If reproduced, diagnose the smallest cause separately.

## Contracts

1. Every check runs through one execution path. Before a potentially crashing
   check, its exact input is in the advertised active-case file, or persistence
   failure is reported and that check is not executed.
2. Failure identity is distinct from display text. Explicit stable identity wins;
   the compatibility fallback is conservative. Assertion failures, raised errors,
   budget exhaustion, generator failures, and persistence failures are not conflated.
3. Shrinking preserves the selected failure and uses a strict complexity order.
   Report a best-found counterexample, never promise a global minimum. Bound work
   and report the stopping reason.
4. Exact stored inputs replay without regenerating them. Recorded choices enable
   structural reduction when the generator version is compatible. A mismatch is
   explicit, never silently replayed as the same case.
5. A selected property must exist and match unambiguously. Ordinary test execution,
   nested properties, and multiple properties in one test remain valid.
6. Committed regressions always run. An exploration cache is optional, bounded,
   disposable, and not authority for a passing verdict.
7. Generation and guidance are deterministic given the same version, seed, and
   starting exploration state. Wall-clock exploration may stop at different points;
   every emitted case remains independently replayable.
8. New files, environment settings, and cache inputs obey test declarations and
   verdict keys. Harness behavior changes update its epoch where required.
9. Normal runs retain worker isolation. Native crashes and C hangs require process
   containment; a Lua instruction budget cannot intercept a C call.
10. Add APIs only with real callers and tests. Preserve simple imperative generators.
    Avoid a speculative object hierarchy or automatic inference of semantic constraints.

## PR sequence and tracking

| Step | Scope | Dependencies | Status | PR |
| --- | --- | --- | --- | --- |
| 1 | Faithful failures and saved evidence | baseline | implementation and independent review underway | |
| 2 | Efficient, bounded reduction | baseline | implementation underway | |
| 3 | Structured choices and reusable generators | 2 | implementation underway | |
| 4 | Failure artifacts, exact replay, shrink and promotion commands | 1, 2 | runner integration underway | |
| 5 | Persistent exploration and explicit search guidance | 3, 4 | planned | |
| 6 | Stateful model testing with a real Cosmic target | 3 | planned | |
| 7 | Per-case coverage feedback | 5 | planned | |
| 8 | Cost-aware execution, measurements and CI integration | 4, 5, 6, 7 | planned | |

Independent steps may be prepared in parallel in separate worktrees. Each PR is
rebased/integrated with the current main before final verification and merge.
The plan PR remains draft throughout and is updated with actual scope, evidence,
reviews, deviations, and merged PRs.

## 1. Faithful failures and saved evidence

Refactor generation/check/recheck/reduction so checks share one executor. Save the
candidate before every generated, corpus, replay, confirmation and shrink check.
Keep original failure evidence separate from the active slot and best reduction.
Check every write; report where it failed and never claim a missing file exists.

Introduce a minimal stable failure identity contract without forcing every existing
property to change immediately. A property may identify distinct assertions even
when its explanatory message includes values. Exceptions and budget exhaustion
have separate identities. Confirmation must reproduce the same identity.
Another failure discovered during shrinking must not replace the original; retain
enough evidence to report/replay it, with bounded collection.

Keep generator faults attributable to property, seed and phase; candidate generation
must not erase the original failure. Apply deterministic work bounds to regeneration
where feasible, keeping worker timeouts as the final containment layer.
Review nested runs so labels and budget state cannot leak.

Tests must demonstrate:
- failure A cannot reduce into B, including a false return versus a raised error;
- changing display text with an explicit identity does not prevent useful reduction;
- a check observes its own exact saved bytes during shrinking and confirmation;
- a failed save prevents execution and reports an accurate path/error;
- flaky confirmation does not produce a falsely trusted minimized case;
- original evidence survives a secondary failure or generator error.

Measure passing cheap properties with and without checkpointing. Correct crash
attribution is required even if failure-path writes increase.

## 2. Efficient, bounded reduction

Replace the decrement-dominated integer search with bounded interval probes,
retaining independent passes for nonmonotonic failures. Handle the full signed
integer range without overflow mistakes. Generalize deletion to large chunks,
then refine to small chunks; avoid quadratic table.remove loops where a linear
copy suffices. Deduplicate candidate executions locally, without caching away the
explicit confirmation runs that detect flakiness.

Expose best-found result statistics and a stopping reason. Preserve existing
determinism and strict ordering; no random reduction and no global-minimum claim.
Structured span deletion is added in step 3.

Tests/benchmarks:
- the 1e9 -> 600e6 threshold reaches 600e6 in fewer than 100 checks;
- a redundant 12-choice block is removed;
- full-range signed boundaries and values around zero;
- nonmonotonic/disconnected failure regions still keep a valid failure;
- a changing draw count/range during replay terminates safely;
- existing byte and middle-of-collection reductions remain effective;
- duplicate executions and attempt budgets are checked directly.

Compare fixed-input check counts and elapsed time against the baseline. Report
both input size and draw count; a compact choice sequence is not always fewer bytes.

## 3. Structured choices and reusable generators

Add labeled nested spans to the choice trace, and a preferred simplification target
where the integer primitive needs one. Keep existing raw Source:int behavior
compatible; use new higher-level generators for boundary-biased distributions.

Build a small composable API for booleans, bounded integers, bytes/text, alternatives,
lists, records/composition, bounded recursive structures, and dependent draws.
Prefer plain functions/records already natural in Teal. Collection combinators own
element spans, so callers no longer have to manually reproduce Fuzz.more patterns.
Range endpoints, zero, +/-1 and powers-of-two neighbors receive deliberate attention
while the whole declared domain remains reachable. Document byte strings versus UTF-8.

Migrate representative real properties, including at least one structured recursive
generator or byte-recipe interpreter. Preserve old committed raw-input formats or
provide an explicit versioned reader; never silently invalidate corpus cases.

Acceptance:
- a nested entry/subtree can be removed as a unit;
- signed values simplify toward the declared target;
- dependent draws remain valid after reduction;
- construction stays within the declared domain;
- tests cover replay of changed ranges and branching;
- migrated properties need less manual generation/packing code or expose useful
  structure formerly hidden from the reducer;
- existing seeded raw-int properties keep their replay contract.

## 4. Failure artifacts and commands

Define a versioned, non-executable artifact holding property/test identity, exact
input bytes, original and best cases, failure identity, case seed, choice trace,
generator/schema compatibility information, phase and reduction statistics.
Use Cosmic's existing literal/codec facilities where appropriate; reading an artifact
must never execute arbitrary Lua. Limit malformed sizes/depths and reject unknown versions.

Add a cohesive cosmic fuzz entry point using the existing test discovery/runner:
- run selected property tests;
- replay a stored exact input;
- shrink a compatible recorded case;
- promote verified bytes into the committed corpus.

Precise command grammar is settled against dispatch/help conventions, not invented
in advance. Selection must fail when it matches zero or ambiguously matches several
properties. Keep environment-based FUZZ_CASE for compatibility, with honest unmatched
reporting at the scope where all candidates are known.

Promotion verifies the selected property, uses content-addressed naming, is idempotent,
and cannot escape the intended corpus path. A still-failing input is reported as such;
do not silently label it a fixed regression. Raw crash files remain directly useful.

Acceptance:
- end-to-end fail -> artifact -> exact replay -> shrink -> promote -> corpus replay;
- generator change never silently changes exact replay;
- unknown/duplicate selector rejection, nested runs, multiple properties per test;
- malformed artifacts and path traversal are refused;
- command help includes copyable examples;
- replay checks only the selected case and does not rely on the current seed stream.

## 5. Persistent exploration and explicit guidance

Add an optional bounded exploration cache apart from committed regression inputs.
Retain distinct failures, small representatives of new labels, and improvements of
named finite numeric objectives. Introduce a target/score API with actual callers.
Mutate and splice recorded compatible choices, mixed with fresh generation so search
does not collapse into a narrow local neighborhood.

Start with the simplest storage that satisfies concurrent workers and crash recovery;
SQLite is available if its transactional benefits justify it. Namespace by test and
property, version generation choices, and deduplicate by content. Raw cases may remain
replayable when their trace becomes stale. Promotion is always explicit.

Verdict rules: exploration reads must be declared/keyed or the exploratory invocation
must bypass passing-verdict reuse. Freeze the exploration input snapshot at run start;
newly discovered entries cannot retroactively change the meaning of a cached pass.
Ordinary regression-only test runs must not depend on ambient exploration state.

Acceptance:
- useful cases survive process restarts and are replayed before fresh exploration;
- bounded eviction keeps necessary distinct failure evidence;
- deterministic scheduling with a fixed initial cache and seed;
- no cache means the existing workflow still works;
- a labeled/targeted synthetic deep bug is found more reliably than unguided baseline
  across a fixed multi-seed experiment;
- concurrent writes and partial/stale entries do not corrupt or falsely pass tests.

## 6. Stateful model testing

Provide a small operation-sequence helper based on the structured generator API.
Allow operation applicability, generated arguments, reusable handles/results,
per-step invariants, reset/cleanup, and a readable operation trace. Start with plain
operation lists if that is enough; do not build a full state-machine DSL without need.

Add a real stateful property using a simple independent model. Prefer SQLite
transactions/savepoints or store attachment/lookup depending on current APIs and cost.
Generate useful valid transitions plus deliberate invalid operations with explicit
expected behavior. Each execution starts fresh and closes resources on failures.

Acceptance:
- a deliberately broken implementation is detected;
- a long trace reduces to the essential causative operations;
- dependencies between operations/handles remain meaningful after reduction;
- rollback/commit or attach/detach behavior agrees with the reference model;
- resource cleanup and repeat execution are verified;
- useful operation coverage and costs are reported.

A clean-vs-incremental build model is a later target only if it fits the measured
budget; record any genuinely deferred target explicitly rather than pretending it landed.

## 7. Per-case coverage feedback

Expose narrow per-case feedback over Cosmic's existing Lua/native coverage mechanisms.
Keep whole-test coverage intact, including nested checks and startup collection.
Avoid materializing large Lua tables for every case if a compact fingerprint or
novelty bitmap can serve search. Restrict novelty to the target's execution, not the
fuzzer's own generation or reporting.

Retain small representatives for newly reached behavior, feed them into step 5's
scheduler, and invalidate instrumentation-dependent feature IDs when the core changes.
Labels/targets remain usable without coverage support.

Acceptance:
- an input reaching a new target branch is retained and reused;
- equivalent coverage does not grow the corpus without bound;
- ordinary coverage totals remain correct with feedback enabled;
- Lua and checked-core native behavior are tested where available;
- measured overhead on a cheap target is documented and guidance is opt-in if it
  materially harms ordinary runs;
- novel-behavior discovery improves on a fixed target/seed workload.

## 8. Cost-aware execution, measurements and CI

Add bounded exploration profiles consistent with cosmic test: deterministic smoke,
regression-only, and deeper exploration. Support time/attempt budgets and stable seed
shards without changing exact replay. Reserve time for shrinking/reporting instead of
letting a discovery budget consume the entire worker deadline.

Report generated/checked/duplicate cases, corpus reuse, labels/objectives, generation/
checking/reduction time and reduction stopping reasons. Prefer structured output
using existing report conventions with a compact human summary. Distinguish invalid
generation from a successful check and warn/fail on unusably high rejection rates.

Update nightly CI to restore/save exploration artifacts safely, retain failure metadata,
and exploit existing compatible build caches. Keep gating CI fast: committed regressions
always run; add bounded deterministic generation only for implicated properties when
the runner can do so soundly. Do not simply turn on 10,000 cases in every merge gate.
Honor workflow formatting, CI project typechecks and test input declarations.

Maintain a small effectiveness evaluation set: historical regression inputs and seeded
defects in representative byte, structured and stateful targets. Compare multi-seed
discovery rate/time, reduction calls/time, final counterexample size, and passing-run
overhead. No universal percentage is asserted from a single run.

## Review and merge procedure

For each implementation PR:
1. An implementation agent owns an isolated worktree and records tests/measurements.
2. A separate review agent reads the actual diff, challenges failure preservation,
   replay, cleanup, cache soundness and performance, and runs adversarial cases.
3. Findings are addressed and reviewed; tests must distinguish the bug from the fix.
4. Run the repository-required format/typechecks, focused tests, relevant corpus
   replay, TODO inspection and broad suite/CI gates appropriate to changed scope.
5. Publish the PR with actual evidence and limitations. Enable automerge only after
   independent review is clean; wait for required checks and merge, fixing failures.
6. Update this plan with PR link, merged SHA, evidence and any justified scope changes.

Do not merge this plan. Do not weaken tests, isolation, failure identities, cache keys,
or CI requirements to obtain a green PR.

## References

- Existing engine: build/fuzz/init.tl; reducer: build/fuzz/shrink.tl.
- Runner: build/test.tl and build/test_worker.tl; coverage: core/coverage.c.
- Nightly: .github/workflows/fuzz.yml and ci/cosmic_ci/fuzz.tl.
- Hypothesis typed choice sequence and structural reduction:
  https://github.com/HypothesisWorks/hypothesis/blob/master/guides/internals.rst
- Strategies and dependent draws:
  https://hypothesis.readthedocs.io/en/latest/reference/strategies.html
- Domain versus distribution:
  https://hypothesis.readthedocs.io/en/latest/explanation/domain.html
- Example databases and numeric targets:
  https://hypothesis.readthedocs.io/en/latest/reference/api.html
- Stateful testing:
  https://hypothesis.readthedocs.io/en/latest/stateful.html

## Execution log

- 2026-10-03: plan published as draft #2617; it will not be merged.
- Fresh boot on e9c5647 succeeded, but the normal test command reproduced the working-database corruption. Packaged databases and shared compile cache pass integrity checks. A separate agent is isolating this prerequisite while the first four work packages proceed in separate worktrees.
- Direct baseline reducer probe still ends at 999999500 after 2000 checks for the 600000000 threshold.
- Current main has no cosmic.literal module. Step 4 will use non-executable bounded JSON artifacts with hex-encoded byte inputs; cosmic.json preserves signed 64-bit integer seeds and choices.
