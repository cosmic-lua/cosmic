# Build simplification without performance regression

This is a living execution reference, held on a draft PR. **Do not merge this
PR.** Implementation lands through the separate PRs below; this branch records
their decisions, reviews, measurements, and merge commits.

Requested 2026-10-01. Initial review: main at
`0471146cbb468f1771c117570baef3cd59d26776`.

## Goal and constraints

Make the build easier to understand and change by giving each responsibility
one owner and making invalidation boundaries explicit. Preserve the optimized
build, rather than replacing it with a new build framework or cache design.

The user authorized independent implementation and adversarial-review agents,
separate implementation PRs, and automatic merging after review and green CI.
Land one implementation PR at a time, based on the preceding merged result.
The reference PR remains draft and never enters auto-merge.

Preserve:

- Stable, shared C source paths across checkouts, including per-source copies
  of the core and the headers they need; vendor libraries reused by variants.
- SQLite and the other long vendor compiles starting early, existing flags,
  include order, target IDs, coverage instrumentation and two-link construction.
- Distinct compiler, analyzer, writer, runtime, and harness identities. A single
  broad build hash is not a simplification that meets the performance goal.
- Shared parses and compiles, lazy compiler setup and program hashing, short
  batched shared-cache writes, and intentional SQL query plans.
- Deterministic projection bytes, unchanged-output avoidance, and the carried
  subset that leaves tests and private documentation out of the shipped tool.
- Correct self-rebuild and settling across changes to compiler, writer and
  fingerprint definitions, including an older tool's unjudged intermediate build.
- Declared-input verdicts, closure stores, worker isolation, harness epoch
  acknowledgment, failed-verdict handling, and platform distinctions.
- Bootstrap independence from potentially broken tree modules; the pinned
  driver stays distinct from the candidate it checks.
- CI job parallelism, branch cache isolation, restore precedence, queue reuse,
  failure diagnostics, cache bounds and publication of the bytes actually tested.
- Rebuild-lock handoff and old-tool interoperability, including the reason the
  flock/SQLite combination remains. A pin bump alone does not retire bisect support.

## Initial evidence

The reviewed tree had 2,284 lines in build/importer.tl, 1,816 in build/work.tl,
3,206 in build/test.tl, 1,642 in build.zig, 1,501 in CI orchestration and 1,558
in ci.yml. Counts locate mixed responsibilities; reducing line count by itself
is not an acceptance criterion.

On this execution host, a clean second worktree boot took 9.598 s wall time:
488 sources taken from the shared parse cache, 474 modules taken from the
shared compile cache, zero sources parsed and zero modules compiled. The
boot's own reported phase took 3.885 s. All three databases passed quick_check.

The importer, writer, shared compiles, shared parses, Zig cache-location and
declared-key-pin test modules passed: 56 tests ran in 10.854 s wall time. The
repeat took 1.137 s, with 0 ran and 56 stood. The build reported 0 compiled,
474 cached and 0 staged files read (377/382 ms). This host refuses user
namespaces, so these were unsandboxed and shared no verdicts. CI must cover
the sandbox and other native platforms.

An earlier interrupted bootstrap left a malformed o/build.db. Its figures are
excluded. It was not diagnosed as a repository defect; measurements used the
clean second worktree instead. Preserve this distinction in later reporting.

## Execution ledger

| Step | Implementation PR | State | Review and evidence |
| --- | --- | --- | --- |
| 1. Compiler and analyzer boundary | pending | planned | see acceptance below |
| 2. Writer identity boundary | pending | planned | depends on 1 |
| 3. Build phase and cleanup ownership | pending | planned | depends on 1–2 |
| 4. Test judgment boundary | pending | planned | depends on 1–3 |
| 5. Bootstrap compatibility retirement | pending | planned | verified published pin required |
| 6. CI policy and recording | pending | planned | depends on 5 |
| 7. Zig graph construction | pending | planned | preserve exact graph semantics |
| 8. Documentation and integrated audit | pending | planned | depends on all earlier steps |

## PR 1: isolate the compiler and analyzer's semantic inputs

Problem: importer mixes derivation, parsing, dependency keys, compilation,
diagnostic presentation, cache transport and pruning. Its entire source is in
compiler identity, but its imports require exceptions to avoid pulling in the
rest of the build. A hint or cache-plumbing edit can invalidate every compile.

Extract a small, coherent semantic boundary for the code that determines
analysis rows, dependency keys, generated Lua/bytecode and acceptance. Leave
coordination, cache lifetime and diagnostic presentation outside that boundary.
Respect the repository's positional module rules. Reuse existing schema and
compiler abstractions; do not create a generic pipeline framework. The exact
module split should follow dependencies discovered during implementation.

Acceptance:

- Compiler/analyzer closure guards explain every dependency; no newly excluded
  dependency can affect stored rows or whether a compile is accepted.
- A change confined to diagnostic presentation or cache plumbing moves neither
  semantic identity; changes to generation, acceptance, dependency keys, parse
  row encoding or analysis schema still invalidate the affected work.
- Preserve shared-row digest validation, judged/unjudged behavior, generated
  test tails, declaration cycles and transitive type-only dependencies.
- Preserve the reference-pruning query-plan regression check.
- Existing importer/shared parse/compile tests pass; add focused boundary cases
  that would fail if an identity were either too broad or unsoundly narrow.

## PR 2: isolate fingerprints and writer identity from staging

Problem: work owns filesystem scanning, TODO/link indexing, transactions,
records, schemas and identity calculations. Its whole source enters writer
identity, making unrelated maintenance trigger another settling rebuild.

Extract fingerprint and identity computation over staged data, with narrow
inputs that do not import staging back into the identity closure. Keep the
distinct hashes and their meanings. Leave transactions, scans and build history
with the working database. Share file classification only where the two callers
actually require the same rule; bootstrap watches may legitimately be broader.

Acceptance: staging/reporting-only changes do not move writer identity;
fingerprint or output-affecting identity changes do. Fresh and warm identities
agree. Source additions/removals and test-only edits still have the intended
effect. Old-tool rebuilds across a fingerprint-definition change still settle.

## PR 3: give phase ordering and cache cleanup one owner

Problem: boot/reboot/project paths repeat derive → identity → compile → project
sequencing. Callers open a shared cache but compile finishes it, leaving earlier
failures to clean it up themselves. Some paths derive before compile derives
again. These contracts require tracing across modules.

Introduce the smallest coordinator justified by the actual common sequence,
with explicit phase results and one cache-cleanup owner. Retain separate input
preparation and publication where boot and stale-tool rebuild differ. A prepared
compile must have an enforceable precondition, not a boolean that silently skips
required work. Preserve analyzer identity stabilization; a second pass that
establishes correctness is not redundant just because it resembles the first.

Acceptance: failure at each meaningful phase closes owned resources, preserves
reusable successful compiles where intended, and cannot publish a partial tool.
Keep transaction/lock ordering, no-op projection avoidance, stale-tool settling,
and output bytes. Run boot/rebuild/lock and relevant fixture coverage; run-local
is required where the entry/launcher/artifact boundaries are touched.

## PR 4: isolate the runner's trusted judgment

Problem: the harness holds build.test whole, although it also implements CLI,
scheduling, census and reporting. Reporting edits then require acknowledgment
and cause the merge queue to run the full suite.

Extract key/eligibility and worker-access decisions into a narrow module or
small set of modules closed under the harness rules. Keep CLI and presentation
outside. Retain the epoch protocol, explicit library boundary and local binding
of replaceable library functions. Do not widen workers' access or weaken the
store hold to make extraction easy.

Acceptance: reporting-only edits require no semantic harness acknowledgment;
every decision that can change pass/fail or permit reuse remains guarded.
Review the epoch choice explicitly; a semantic change requires a fresh epoch,
not merely new acknowledged digests. Run harness/key/worker/isolation tests and
full CI, including sandboxed runs. Preserve lazy program identity and cached
verdict coverage replay.

## PR 5: advance the bootstrap pin and delete obsolete adapters

Choose an already-published, digest-verified green release carrying the APIs
needed for the cleanup. Inventory every TODO naming cosmic-driver.pin, and
resolve every one the selected release actually unblocks, as AGENTS.md requires.
Do not update a pin to an unverified artifact or assume a main commit has a release.

Expected candidates: writable SQLite cast adapters, retired COSMIC_TEST_KEY
plumbing, legacy assumed-verdict fields, and duplicated plural helpers. Verify
the release's actual capabilities before deleting each. Other TODOs may be
unblocked; expand this step or split it into smaller PRs if the inventory calls
for it, recording the adjustment here. Retain standalone-script independence
and old-tool lock interoperability.

Acceptance: pinned-driver self-checks, source-tree checks, bootstrap tests and
run-local pass against the actual selected release. No compatibility adapter
remains for an API this release supplies. Remaining pin dependencies name their
unmet prerequisite precisely.

## PR 6: consolidate CI policy and operation recording

Extract repeated cache naming/restore/save mechanics into a few concrete local
actions or helpers. Keep event/leg policy reviewable, including main vs branch,
light vs full, checked vs release, shard, merge queue and scheduled behavior.
Preserve hashFiles timing before checkout relocation. Do not introduce a YAML
generator, new DSL, serial coordinator job or additional critical-path network
round trips merely to remove repeated text.

Consolidate Orchestration.logical and Runner's repeated operation recording.
Keep phase/child operation identity, timeout vs exit status and retained
diagnostics. Separate into two PRs if doing both obscures either review.

Cache maintenance should ultimately belong to the code owning its formats;
inspect whether moving trim/merge behind a pinned command now deletes enough
code to justify it. Never require a successfully built candidate just to clean
up a failed run. Record a reasoned scope decision rather than force an abstraction.

Acceptance: workflow/queue/cache tests cover policy outcomes rather than just
the old layout. Cache scoping, failure paths, queue seeds, attestation and job
parallelism are unchanged. Run formatting and workflow checks and the CI driver
self-tests; observe real branch and merge-queue CI before marking complete.

## PR 7: simplify Zig graph construction locally

Reuse Sources in analyze rather than a long list of paths. Factor repeated
fixture executable/install/step construction and target-record formatting only
where the operations match. Keep explicit vendor source lists and flags useful
to a reader. Keep Own's per-source copies and all target/configuration identities.

Acceptance: the resulting graph builds the same outputs with the same flags,
include/source order, instrumentation and dependencies. A new Zig source file
must enter tool fingerprints, race watches and CI cache keys. Compare warm and
fresh-worktree builds, one core-source edit and a core-header edit. Check native,
checked and all shipped targets, analyzer, fixture and cross-host byte identity.

## PR 8: documentation and integrated audit

Update comments beside each preceding implementation as it lands. This last PR
removes any residual descriptions of the old system and makes the architecture
traceable from entry point to output without duplicating the whole implementation.

Known stale descriptions: invoke says process-starting tests never stand;
build.zig describes boot as host-core-only although the artifact needs all release
cores; design describes Zig's file as source lists/flags only and the fresh-clone
prerequisite as only Zig. Preserve useful hazard/performance explanations.

Acceptance: AGENTS.md, design, CI README, command help and code agree. Record
final measurements, each merged PR, review outcomes, remaining limitations and
resolved/added TODOs in this reference. Leave the reference PR open in draft.

## Validation and review protocol

Each implementation agent owns an isolated worktree and a single scoped PR.
A different agent reviews the exact resulting diff adversarially. Reviewer
findings go back to the implementer; substantive fixes are reviewed again.
Neither agent merges. The coordinator checks the final SHA, review state and CI,
then enables auto-merge. Resolve human/bot review findings too. Never bypass a
required check; watch the merge queue and fix failures before advancing.

Run focused existing tests first, add regression tests only for concrete
remaining risks, and satisfy AGENTS.md's format/type/whole-tree gates. Measure
the same scenario before/after on the same host. Record compiled/parsed/reused,
ran/stood, file reads, output digests and elapsed time, not elapsed time alone.
Refactors may invalidate caches once; compare steady state after warming, while
also checking that transition invalidation is safe.

The integrated scenario set is: no-op project; fresh worktree on shared caches;
leaf implementation edit; declaration edit; test-only edit; diagnostic/report
edit; core-source/header edit; compiler/writer/harness semantic edit. Verify
both the work that must run and the work that must remain cached. Use existing
fixture tests for concurrency and failed/interrupted publication, then broaden
only for a concrete uncovered risk.

No local benchmark substitutes for Linux sandbox, macOS, aarch64, checked-core
or merge-queue coverage. Report unavailable validation honestly. If evidence
changes the design, update this plan before proceeding and explain the decision.

## Decisions and completion notes

- 2026-10-01: initial plan created from detailed source review and local baseline.
  Start with the two identity boundaries. Compatibility retirement precedes CI
  consolidation so new helpers need not preserve already-obsolete interfaces.
