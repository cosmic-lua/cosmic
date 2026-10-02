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
| 1. Compiler and analyzer boundary | [#2522](https://github.com/cosmic-lua/cosmic/pull/2522) | merged | a6d458c9; final and queue CI green; independent approval |
| 2. Writer identity boundary | [#2531](https://github.com/cosmic-lua/cosmic/pull/2531) | merged | 09240c31; branch and integrated queue36941246664 green; independent approval |
| 3. Build phase and cleanup ownership | [#2532](https://github.com/cosmic-lua/cosmic/pull/2532) | merged | e75cee04; branch and queue36942878305 green; independent approval |
| 4. Reporting outside the acknowledged runner | [#2533](https://github.com/cosmic-lua/cosmic/pull/2533) | merged | 56637153; branch and queue36944097828 green; independent approval |
| 5a. Bootstrap lock ownership preparation | [#2534](https://github.com/cosmic-lua/cosmic/pull/2534) | merged | 44518e84; branch and queue 36945326385 green; independent approval |
| 5b. Pin, flock/scratch and obsolete adapters | [#2535](https://github.com/cosmic-lua/cosmic/pull/2535) | CI running | 569b0d44; final tree a8f5780f approved by both reviewers |
| 6a. CI cache-name policy | pending | integrated approval | 4d5d5e95; unchanged patch, 38 workflow tests pass |
| 6b. CI operation recording | pending | integrated approval | ad3d2f4d; phase contracts independently checked; runner/parser tests pass |
| 7. Zig graph construction | pending | integrated approval | 5743c2e2; exact original patch and graph context preserved |
| 8. Documentation and integrated audit | pending | integrated approval | ae320349; final warm/fresh/byte-equality audit passed; remote CI pending |

## PR 1: isolate the compiler and analyzer's semantic inputs

Problem: importer mixes derivation, parsing, dependency keys, compilation,
diagnostic presentation, cache transport and pruning. Its entire source is in
compiler identity, but its imports require exceptions to avoid pulling in the
rest of the build. A hint or cache-plumbing edit can invalidate every compile.

Extract a small, coherent semantic boundary for the code that determines
analysis rows, dependency keys, generated Lua/bytecode and acceptance. Leave
coordination, cache lifetime and diagnostic presentation outside that boundary.
Keep diagnostic classification, warning suppression and rejection inside the
semantic boundary. Rendering an empty message must never turn a refusal into
a successful compile. Respect the repository's positional module rules. Reuse existing schema and
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
- Update ci/fixtures/fixed_point_test.tl: it textually mutates compiler_roots
  and tool_files in work.tl. Follow moved definitions, retain the combined case
  and edited-then-undone byte equality, and run ci/run-local for fixture edits.
- Preserve the analyzer identity's current inclusion of compiler identity in
  this series; removing that dependency is a separate semantic change. This
  extraction does not promise that compile-only edits stop reparsing.

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
effect. Old-tool rebuilds across a fingerprint-definition change still settle. Update
and execute the fixed-point fixtures when their textual mutation targets move.

Implementation preflight: use one build.identity module taking Sqlite.Handle,
not work.Handle (even type imports enter identity walks). Move pure file/tool
classification and hashing/identity definitions together; retain scans, transactions
and generated-header discovery in work. Redirect writer's identity/hash calls;
its remaining work.commit edge needs a narrowly justified root-edge exclusion,
not a global exception. Move both fixed-point mutation targets to the same new
identity file, preserving the combined case, and add work-only non-settling
coverage. Avoid widening consumer closures through a heavyweight type alias.

## PR 3: give phase ordering and cache cleanup one owner

Problem: boot/reboot/project paths repeat derive → identity → compile → project
sequencing. Callers open a shared cache but compile finishes it, leaving earlier
failures to clean it up themselves. Some paths derive before compile derives
again. These contracts require tracing across modules.

Preflight favors unifying preparation/compilation inside importer rather than
adding a general coordinator. Keep ordinary compile and add a narrowly scoped
self-build entry point only if justified. Both can call a private compile_derived;
no public prepared boolean. The self-build path derives, records tree identities,
then lets boot/reboot select the proper compiler key in their existing order.

Derive borrows the shared cache. Each public compile operation consumes it and
finishes exactly once after success or any failure, preserving successful offered
rows and cache-write fallback. Keep analyzer stabilization/reparse inside derive;
remove only the redundant outer derivation and count parse work once.

Leave work.Handle, transaction ownership and publication in their current callers.
Keep writer's commit-before-attach/vacuum boundary, boot/reboot's distinct compiler,
zone and executable-prefix sources, reboot's unjudged settling, and ordinary
projects' use of the running compiler. Writer's later identity calculation still
belongs at its projection-signing boundary. A cache flush is not publication.

Acceptance: focused resource tests cover finish exactly once after derive,
identity-choice and compile failures. Shared-row fallback, analyzer stabilization,
unjudged cache behavior, fixed-point edit/undo, writer failure/commit and rebuild
locks remain correct. Compare no-op and fresh-shared counts without extra compiler
initialization. Run the existing fixture path for the boot/reboot boundary;
run-local is required wherever AGENTS.md's entry/artifact/fixture trigger applies.

## PR 4: separate reporting from the acknowledged runner

Problem: the harness holds build.test whole, including reporting. Formatting
edits require acknowledgment and cause merge-queue full-suite invalidation.

Extract presentation into build.test_report (or a comparably clear module):
failure/skip rendering, build statistics, census, coverage text and summaries.
Pass reporting snapshots, never mutable jobs, Recording, writable databases,
caches or verdict state. Keep outcome and exit-code decisions with the runner;
reporting return values must not decide acceptance. Pure selector spelling/help
can move if useful, but policy defaults and option interpretation remain trusted.

Keep build.test acknowledged through the existing key_own model. Preserve all
keying, eligibility, effective declarations, closure/name allowlists, scheduling,
timeouts, worker construction, held-sandbox skips, input rechecks, persistence,
failure eviction, shared updates and cleanup in that runner. Preserve the epoch
protocol, explicit library boundary, local bindings, lazy program identity and
coverage replay. Update acknowledgments for motion; retain the epoch only if
judgment and policy are unchanged.

Acceptance: presentation-only edits move no acknowledged harness digest; edits
to runner judgment still require acknowledgment. Existing output-parser,
runner/key/worker/isolation tests and CI pass. Review the reporting interface
itself: the current own-root exception does not comprehensively classify the
runner's imports. Add a focused check for report exclusion and runner inclusion.

A new trusted-session interface and transitive harness root were considered and
are unnecessary for this step. They would complicate environment helpers and
closure-store salt ownership. Revisit only for a concrete unmet requirement or
soundness defect; line count and removal of the build.test filename from the
acknowledged set are not goals by themselves.

## PRs 5a–5b: prepare ownership, then advance bootstrap atomically

Use an already-published, digest-verified green release. Recheck every literal
pin-dependent TODO against that release and resolve all newly unblocked items.
The latest preflight selects next-a6d458c9ebf85f5ec6a4180f15ce78a8343c0878,
published 2026-10-01T22:13:26Z, asset SHA-256
7d27d9b235f8efcee6fa84bf1faafb78d87784770c1ade306098ef321a009410
(14,811,184 bytes). Publish run 36933674400, main CI 36933528196 and queue CI
36932275052 passed. Download, hash and execute the asset before changing the pin.

5a gives the current SQL-only rebuild lock explicit scoped ownership and one
close/handoff path, including watched-build exceptions. Keep compatibility with
old b8b4a46b; no flock calls, feature detection or cast bridges in preparation.
Prove exclusion using independent SQL-only processes in both directions.

5b atomically advances the pin, activates flock and both scratch ownership
protocols, and retires every unblocked adapter. Review lock, scratch and API/time
slices independently. Separate scratch-preparation PRs were considered and
rejected: current functions do not need temporary lifecycle layers before the
real protocol, so those layers would add churn without durable clarity.

Fresh inventory at a6d458c9: 29 literal pin-dependent TODOs, 18 unblocked:

- build/zig: Fs.cache_dir options, native Time constructors, flock ownership,
  writable SQLite adapter.
- build/zig_fetch: scratch ownership and native HTTP nanosecond options.
- build/patch: scratch ownership.
- vendor and verify_codesign: Flags.help API.
- build/test and CI orchestration: retire COSMIC_TEST_KEY; keep COSMIC_CI_DECLARED_KEYS.
- CI sqlite_open and eval/check/notes: native SQLite options.
- CI report: native Zip.Reader.entries with error handling retained.
- CI plural: String.counted; keep noun if callers need it.
- CI suite_output/state/parser: remove assumed-verdict fields.
- CI pin_time: remove compatibility module/callers/tests.
- CI runner: migrate timeout API/CLI/fixture constants to nanoseconds, preserving
  durations and keeping elapsed-reporting units distinct.

Remove obsolete casts exceptions for zig cache_dir/open_writable, ZigFetch.limits
and notes.open_writable. Raw sys.flock still takes milliseconds: convert explicitly
at that boundary rather than changing waits by a millionfold.

Bootstrap locking follows rebuild_lock: flock first, SQLite only when flock_kind
reports apart, one elapsed budget, cleanup on every failure/handoff, retained
held descriptor/device-inode identity. Keep the SQL half permanently for older
branches and bisect. Never close a second same-inode descriptor while relying on
process-wide fcntl locks. Use independent child processes for interoperability.

Each scratch cache needs a persistent gate covering sweep plus unique wrapper
creation/owner-lock acquisition. Release the gate before expensive work; hold only
the owner lock during download/patch/fsync/publication. Sweep only existing owner
files that can be locked, without creating missing metadata. Put the owner beside
a payload subdirectory and publish payload alone. Use names outside legacy PID
patterns, and leave legacy PID-only directories alone because their owner cannot
be proved dead across namespaces. Preserve digests/modes/durability/concurrent
winner behavior. Test creation/sweep overlap, live/killed owners, missing owner
files, concurrent installs and namespace behavior where supported.

Eleven pin TODOs remain blocked: structured Proc.find/SQLite/HTTP failures;
guard signal origin; URL-neutral HTTP errors; syncfs/sync; username lookup for
run-local; noexec scratch declaration; cache-maintenance verb; Fs.append; child
streams after cancellation. The newer stream implementation still checks the
persistent cancelled guard and caches failure. fcntl(F_FULLFSYNC) remains absent
as well, outside the literal pin-TODO count. Recheck on the final integrated base.

Acceptance: verified-release execution, pinned-driver self-check, fresh bootstrap,
standalone help/notes, concurrency tests, root/CI formatting/type checks, run-local
attempt and real remote platform checks. Timeout migration touches fixtures, so
run-local is required. Local UID restrictions never justify weakening CI checks.

## PR 6: consolidate CI policy and operation recording

Split into two narrow PRs. First extract the two identical cache-name steps
into a cache-names action with leg input and vendor/core/compiles/image/since
outputs. Retain id: names and every downstream reference. Keep exact hashFiles
input/exclusion expressions in action metadata, evaluated before relocation;
keep since before restores/builds. Use explicit host shell and a short script.
Include the new action in both passing-driver marker hashes and update README.

Keep restore/save steps explicit in the workflow. Platform/checked pinned-Zig
saves, fallback precedence, light/full verdict restores, scheduled macOS saves,
first-shard branch saves and queue-seed trust are intentionally different. No
additional network requests, job dependencies, YAML generator or generic action
interpreter. Adapt the focused naming assertions and preserve comparison tests.

Second move Orchestration.logical into a concrete Runner.phase sharing operation
recording. Preserve integer phase exit codes (including nonzero23 and timeout
return124), durable exit_code on exceptions, nested child-operation rows, full
raised detail and the existing logging/timestamp contracts. Do not simply use
Runner.step: its boolean results, truncation and Child.Result-derived exit code
are different. Do not fabricate child results for in-process phases. Runner
owns recording; orchestration retains environment/dispatch/provenance policy.

Test callback success/nonzero/long exception, nested phase/child timeout, rejected
candidate-local operation DB, retained-output-open failure and existing durable
provenance/suite-summary behavior. Run driver tests and CI project checks.

Cache maintenance should ultimately belong to the code owning its formats;
retain the current trim/merge implementation in this series. Main supplies no
cache-maintenance verb, so moving it would add a new API and another pin lifecycle
instead of merely simplifying existing ownership. The existing TODO remains
the place for that separate feature. Never require a successfully built candidate just to clean
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
also checking that transition invalidation is safe. A source refactor changes
embedded source and fingerprints: do not demand whole-product equality across
that edit. Compare unaffected generated module code, graph parameters, and
identical-source reproduction across locations and boot/rebuild paths; demand
final equality in edited-then-undone fixed-point fixtures.

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

- 2026-10-01: independent plan review incorporated: rejection separated from
  rendering; fixed-point mutation targets move with identities; trusted runner
  inputs and verdict persistence remain acknowledged; lock/scratch preparation
  split from pin retirement; new actions enter driver-marker identity. Analyzer
  compiler-dependence is preserved and a new cache-maintenance verb is out of
  scope. Exact current-main release next-0471146c is published and verified by
  GitHub asset digest metadata; recheck the selected release at step 5.

- 2026-10-01: bootstrap preflight expanded step 5 into compatible preparation
  and one atomic pin/API transition. Thirteen TODOs are unblocked by the inspected
  release; missing APIs remain explicitly deferred. Scratch sweeping requires a
  creation/ownership handshake, not merely a unique name and an internal lock.
- 2026-10-01: step 1 validation observed another malformed local build database
  with workspace synchronization active. Causality is not established. Move
  build worktrees outside that synchronized directory and exclude affected runs
  from correctness/performance evidence.

- 2026-10-01: step 4 narrowed after dependency review to presentation extraction
  with the existing acknowledged runner retained. This earns narrower reporting
  invalidation without a new trust model or mutable judgment interface.
- 2026-10-01: step 1 published as #2522 at
  `689760249f52418500654f4ddee7c7143e0606eb`, tree
  `ebfad92405b9b94d48cbcf963680367e096dcc9b`. Independent review caught
  and resolved vendor-bytecode and projected receiver-identity omissions. A clean
  reviewer boot reused 490 parses and 476 compiles (0 fresh, 3.343 s phase).
  Focused exact-tree repeat: 0 ran/50 stood, 1.136 s, 0 compiled/476 cached/0 read.
  The required 30-second full-suite run expired during setup before verdicts;
  local full-suite coverage remains incomplete. CI and fixed-point fixtures are
  pending; auto-merge is not yet enabled.

- 2026-10-01: step 1 final tree
  `53f242e2d61d713281e7a443fb5a2deb717df5ec`, remote head
  `35b3c6b7c2c301a07aa5a3a106d41441ae2e648e`, has independent approval.
  Six fixed-point fixtures passed; the final shared-record extraction removes
  compiler coupling from test closures. Final implementer suite: 80 passed,
  repeat 0 ran/80 stood in 1.199 s, 0 compiled/477 cached/0 read. All 465
  unchanged-source modules retain byte-identical bytecode. Baseline cold full
  setup also exceeds 30 s before verdicts, so that timeout predates this work.
  Initial CI was green on every platform; final-head CI remains pending.
- 2026-10-01: corrected bootstrap inventory arithmetic: thirteen literal TODOs
  unblocked and eleven still blocked, twenty-four pin-related comments total.

- 2026-10-01: step 1 namespace/export correction fully gated and independently
  approved at tree `b68f416885bd6c08028e7092250a73d352e93252`, remote head
  `f453e5a8dafefeeafbf0d5331b931cb3082772d0`. Whole-tree check: 629 files,
  zero findings; 80 focused tests passed; no new TODOs. Final CI run 36883812425
  passed every platform. Auto-merge requested; integrated queue run 36932275052
  is in progress. No implementation has merged yet.
- 2026-10-01: step 2 preparation started from the integrated step 1 queue commit.
  Publication remains serial: confirm the preceding merge and exact resulting
  base before publishing the next implementation PR. Preparation may overlap
  the preceding queue to avoid idle time; no check or review is skipped.
- 2026-10-01: step 3 narrowed after call-graph review: unify cache-consuming
  compile paths, preserve caller-owned transactions and publication. Step 4/8
  should also update declared_key's receivers_identity comment to compilation.

- 2026-10-01 22:11 UTC: step 1 #2522 merged as
  `a6d458c9ebf85f5ec6a4180f15ce78a8343c0878` after all checks in integrated
  queue run 36932275052 passed. Step 2 is already based on that exact commit.
- 2026-10-01: step 2 review found vendor compiler-input row construction must
  also leave work; move it to existing compiler-covered derivation. Local
  run-local cannot drop to nobody: the container maps only UID/GID0 and chown
  fails EINVAL. Preserve that failure; direct-driver root/unsandboxed fixtures
  provide narrower transition evidence, while required CI covers unprivileged
  operation. Do not relax repository checks to accommodate the host.
- 2026-10-01: step 6 preflight narrowed extraction to duplicate cache names and
  a separate phase-recording PR. Restore/save policy remains visible because
  its apparent duplication encodes important platform/queue distinctions.

- 2026-10-01: step 2 locally complete and independently approved at ef7fe613,
  tree f0f7129af92e6c01d57cea9001291e36ac80f209. Independent fresh boot
  reused 492 parses and 478 compiles, 70 focused tests passed, warm repeat
  922 ms with zero compiles/reads. Seven exact-commit fixed points passed in
  190.456 s. Independent products and both projections were byte-identical.
  No new TODOs. Remote publication was blocked when GitHub create_tree returned
  'user rejected MCP tool call'; do not retry without clarification. This update
  is prepared locally while external writes are paused.
- 2026-10-01: step 3 prepared locally at c70ce491 on step 2 candidate ef7fe613.
  Seventy-six focused tests and seven exact fixed points passed; full-tree
  check has zero findings. Independent adversarial review is underway. It must
  rebase onto the actual merged step 2 before publication. Full-suite local
  limits include timeout and Unix-socket EPERM independently reproduced without
  cosmic; remote checks remain required.

- 2026-10-01: step 3 independently approved at c70ce491, tree
  ed01d73c6e239a7e46d6abd8ee64c2164bdbde32. Reviewer fresh boot reused
  492 parses/478 compiles; 76 tests passed and warm repeat stood all 76 in
  1.055 s. Whole-tree632files zero findings and allDB integrity checks passed.
  No outstanding local review blockers in steps 2 or 3. External writes remain
  paused pending clarification of GitHub's rejected publication call.

- 2026-10-01 23:08 UTC: user explicitly authorized resuming after clarification
  of Git tree publication. Step 2 is open as #2531 at remote commit
  6dcd015a3ef2aa3a9d3fce4f3595591e8ff19dfb, exact reviewed tree f0f7129.
  Step 4 preparation has started from the locally approved step 3 candidate.
  Step 5 inventory is being rechecked against main's newer time/stream/fs APIs
  and an actually published release. Prior publication block is resolved.

- 2026-10-01: #2531 branch CI36939374373 passed every leg and auto-merge was
  enabled. Concurrent main #2529 adds shape_specs to compiler semantics; resolve
  its root addition in build.identity before updating the PR, with fresh review
  and checks. Preserve the independent main feature in every later rebase.
- 2026-10-01: bootstrap recheck updates inventory to 18 unblocked/11 blocked
  comments and selects verified published a6d458c9. Step5 narrowed to useful lock
  ownership preparation plus one atomic complete API transition. Step7's separate
  preparation/review compares actual compiler commands and artifact hashes while
  earlier PRs pass CI; publication remains serial.

- 2026-10-01: step 2 shape integration independently approved at local fe3721c0,
  remote cf1e2777, exact tree5d15a0e4. All133 focused tests and whole-tree635
  checks pass. Branch CI36940909057 passed every leg; queue36941246664 includes
  preceding external error-consistency PR2530. Step4/5a/7 local candidates are
  independently approved, pending serial rebase/publication. Step6a is in review.
- 2026-10-01: selected step5b release was downloaded, SHA256 verified and
  executed successfully. Separate implementation agents own bootstrap locking
  and CI/API retirement; their changes will enter one atomic pin-transition PR.

- 2026-10-01: step2 #2531 merged as09240c31856f88ccdcf26f76424ce1427910c43b
  after every check in queue36941246664 passed, including Alpine. Independent
  queue review confirms preceding PR2530 keeps all writer/compiler boundaries
  and step2 harness acknowledgments. Step3 rebase is patch-identical at6a04d5a6.

- 2026-10-01: step 3 opened as #2532 at remote 6f5e6861, identical reviewed
  tree 834eedd7. Integrated checks: 122 tests passed, repeat 122 stood in 1.217 s
  with zero compiles/reads; whole-tree 635 files and CI 60 files passed. Branch
  CI 36942604690 is green; queue 36942878305 is running. No new TODOs.
- 2026-10-01: step 4 rebase is independently approved at 0364d170; 83 focused
  tests and 11 CI parser tests passed, full-tree 637 files has zero findings.
  Step 5a rebase is patch-identical and undergoing final integration checks.
  Both still require alignment with the actual preceding merge before publication.
- 2026-10-01: step 5b scratch ownership stays local in both standalone scripts:
  they can import only modules carried by the pinned release. A new checkout
  helper would break standalone bootstrap. The small duplicate protocol avoids
  a new public API and pin cycle. Independent locking and API reviewers are active.
  Removing COSMIC_TEST_KEY changes possible worker inputs, so this transition
  conservatively retires the current harness epoch rather than reusing verdicts.

- 2026-10-02: step3 #2532 merged as e75cee041324637dd131aed40f3146f1fa77e146
  after queue36942878305 passed. Step4 #2533 then merged as
  5663715344acbb69f2807f56ffde7d6db6a04b14 after queue36944097828 passed.
  Both merged trees exactly match independently reviewed candidates.
- 2026-10-02: step5a opened as #2534 at e534d545, reviewed tree5d4f9098.
  Actual-base alignment changed only its parent. Independent old-pin boot and
  39 lock tests passed; implementer61 tests and whole-tree638 files passed.
  Final mandatory full-suite attempt hit the established socket EPERM limitation
  and 30-second timeout. Auto-merge enabled subject to required checks.
- 2026-10-02: both step5b review slices approved c5ae41c9. Bootstrap reviewer
  required a deterministic pause after scratch creation, before owner acquisition;
  regression now passes for both caches. API reviewer verified durations, error
  handling and selected-release execution, and corrected stale switch comments.
  Rebase onto integrated5a conflicts only in the expected runner acknowledgment;
  recompute it for combined reporting extraction and worker-input change.

- 2026-10-02: step5a #2534 merged as
  44518e84bf497b7e756ead8c0fd315ed34a1648c after queue36945326385 passed.
  Step5b is published as #2535 at569b0d44, exact reviewed treea8f5780f,
  with auto-merge enabled subject to required checks. Final local mandatory
  run timed out after3163 declared tests without a reported assertion failure.
- 2026-10-02: final prepared steps6a/6b independently approved at4d5d5e95
  andad3d2f4d. Patch IDs unchanged; integrated boot,38workflow,11parser and
  8runner tests passed. Step7 integration is also approved: its patch and
  upstream build.zig context are byte-identical to the original graph audit.
  Actual preceding merge alignment and remote CI remain required.
- 2026-10-02: step8 implementation ae320349 documents actual owners, identities,
  bootstrap seeds, self-rebuild eligibility, scratch/SQL compatibility and CI
  phase contracts.81 focused tests and root636/CI56 checks passed. Removed one
  resolved generated-doctest confinement TODO; no new TODOs. Independent final
  review and the focused warm/fresh shared-cache audit are in progress.

## Integrated audit on the prepared final tree

Independent reviewer approved step8 commit
`ae320349210479fd5fe44f3493169bb0285ca255`, tree
`ca53a1141927d05f2ced717d1327091fd95f51d9`. All preceding implementation
changes are present. Actual preceding merge alignment and final platform/queue
fixed-point coverage remain required before declaring execution complete.

| Scenario | Final local result |
| --- | --- |
| Fresh matching worktree | 499 parses and485 compiles reused; zero fresh; boot phase3.440s |
| Focused build boundary suite | 124 tests ran and passed in11.412s |
| Warm repeat | 0 ran,124 stood in1.100s; build371ms,0 compiled,0 read |
| CI runner/parser | 19 tests ran and passed in1.807s; warm19 stood in372ms |
| Fresh CI project | 47 parses and47 compiles reused; zero fresh |
| Cross-worktree products | Executable, carried projection and full projection byte-identical |
| Unchanged-output behavior | All three output hashes unchanged after focused tests and warm repeats |
| Database health | All three root databases in both trees and CI build database pass quick_check |

The final focused suite covers importer dependency/declaration invalidation,
writer test-only projection behavior, compiler/diagnostic boundaries, harness
acknowledgments and reporting. Existing final CI fixtures supply the seven
edit/undo fixed points for staging, writer, compiler and fingerprint definitions.
Step7's original19-artifact/590-dependency-line graph comparison remains valid:
its complete patch and upstream build.zig context are unchanged through integration.
No additional mutation framework or repeated graph experiment was needed.

Final prepared SHA256 values:

- Executable: `0d8480b5dbc9f1ab9e3da0e4db5829e3f885a78e363d7cbf08cfc29e1a83e635`.
- Carried projection: `f0bb1754b5c07d37c72cb2a79e945dbe886879988632d0b16b0e319a7db0102f`.
- Full projection: `0cecd9772e27efeca163698826fc9613b6b2ef65e48ec5f179754c372f6bcf27`.

The initial and final focused suites contain different numbers of tests, so their
wall times are not a controlled speedup claim. The important retained properties
are zero warm compilation/reads, complete shared-cache reuse in a fresh checkout,
identical output bytes and the preserved C graph. Local sandbox, UID and socket
restrictions remain explicit; remote native/checked/sandbox/queue gates must pass.
