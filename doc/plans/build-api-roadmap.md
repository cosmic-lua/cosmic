# Build-facing API roadmap

Planning snapshot: `9ac37cba3b2d626b79d7c217329b2020d76bccb6`, the final build-simplification queue tree. This is a new implementation series; the completed build reference remains separate. Keep this plan on the same never-merge draft PR #2521 and update its ledger as actual API names, release boundaries and validation settle.

## Objective and boundaries

Resolve the eleven pin-dependent workarounds identified by the build review, implementing the capabilities actual consumers need and correcting assumptions disproved by review. Include the related cancellable SQLite busy wait and macOS storage flush. Preserve public compatibility, warm build/cache behavior, failure cleanup and independently verified publication. This is not a general error framework, new task runtime, cache-policy redesign or wholesale shell elimination project.

All runtime spans are nanoseconds. Convert at raw interfaces that still count milliseconds; SQLite PRAGMA busy_timeout and sys.flock remain such interfaces. Elapsed_ms reports and workflow epoch-second cache cutoffs retain their separate units.

Repository contracts require an existing fallible public API to return exactly `(value, string)` or `(boolean, string)`. A code added as a third result, or a record replacing the existing reason, is incompatible. Where callers need machine-readable outcomes, add a concrete operation result record returned as one value; retain existing convenience functions and their behavior. Do not add a generic Result type or diagnostic-text parser. Programmer errors still raise; operating failures are results. Preserve the recent error-prefix and argument-validation conventions.

No standalone bootstrap or CI consumer may call a new API until ci/cosmic-driver.pin names a downloaded, digest-verified, executed release containing it. Each pin advance rechecks every literal pin-dependent TODO, not only this plan's list. Include every item the selected release unblocks. Existing source-tree consumers may migrate with their API. Keep existing convenience wrappers on the shared implementation. The public-export rule requires a caller outside the module or a runnable standard-library worked example; an internal wrapper alone does not earn an API. Use a meaningful source-tree consumer where available, otherwise document the intended typed classification in a runnable example under the existing rule. Do not invent dummy callers, compatibility casts, or export-check exceptions to make an unused API pass.

## Sequence

### Follow-up approved 2026-10-03: SQLite failures and cache cleanup

The original A–D series below is complete. This follow-up was approved after
D1; it does not reopen C3's deferred syncfs experiment. Starting source is
`e9c56475d7dbbcf2a5574514c85ef9ea90a72878` on current main. Preserve incoming
work, including #2614's Zig maker pruning, and coordinate with the separate
artifact/schema PRs rather than duplicating them.

Two independent source reviews found that typed errors alone do not make
cache retirement safe. Online recovery currently renames the database and
its WAL/SHM without owning every connection's lifetime; even a genuine
CORRUPT result cannot establish that no other checkout still uses those
paths. Diagnostic matching is worse: a path or SQL error containing
"malformed" can authorize a rename. Maintenance also recognizes retired
siblings by prefix alone, encompassing names it never created.

| Step | Separate production PR | Dependency and acceptance |
| --- | --- | --- |
| E1 | Capture SQLite open, prepare, bind and step outcomes; expose the query helpers actual consumers need | Existing APIs preserve their exact two-result contract and allocation behavior. New operations capture codes, reason and cancellation before cleanup can change them. |
| E2a | Stop online whole-file retirement | Independent correctness fix. Optional caches close and fall back without renaming active files; no new per-hit work. |
| E2b | Use captured outcomes for WAL retry decisions and correct retirement prerequisites | E1 and E2a. No message parsing or retry after captured cancellation; retirement also needs lifetime ownership/identity. |
| E3 | Restrict cleanup to recognized retired regular files | Independent of E1/E2; may land first. Exact numeric historical names, optional WAL/SHM suffix, lstat without following symlinks; all other siblings retained. |
| E4 | Integrate release-dependent consumers if required and audit the final tree | Verify and execute a published release before any standalone consumer uses new APIs. Compare warm reuse and artifacts between fresh checkouts; record native branch and queue results. |

E1 uses concrete operation records, following ExecResult, rather than a
generic result framework or a third return value. Successful low-level steps
must not allocate a record for every row. Existing wrappers share mechanics
without routing their success paths through new record allocation. Capture
primary and extended codes and owned diagnostic text before another SQLite
operation, Lua allocation/finalizer, rollback or close; retain busy-handler
cancellation independently. Programmer errors raise on the new surface;
existing argument behavior remains compatible. Add only named codes used
by real callers or runnable examples. Review prepared-statement tail checks,
parameter validation, partial query failures and allocation-failure cleanup.

E2 removes the now-unused corruption-text and set-aside wrappers throughout
compile and verdict cache consumers. Preserve one diagnostic, close-once
ownership, uncached progress and all successful cache behavior. Use BUSY and
LOCKED codes explicitly in the WAL transition, retain its total monotonic
budget, and stop when cancellation is captured. Add the missing recovery
prerequisite at the code site: safe automatic retirement requires a
cache-wide lifetime/identity protocol. Maintenance continues retaining
unreadable active databases and omitting their save digest. Existing
writer-quiescence requirements do not establish that all readers are gone.
Harness changes receive acknowledgements and an epoch bump whenever their
semantics can affect a verdict; the merge queue must execute the full suite.

E3 recognizes only `<basename>.corrupt-<digits>` and the same name with
`-wal` or `-shm`. It unlinks only regular files, never directories, symlinks,
special nodes, other basenames or active sidecars. Preserve unrelated
`.corrupt-notes`, empty/nonnumeric stamps and trailing extensions. Report
genuine cleanup failures as incomplete and issue no digest; disappearance
by a concurrent remover is harmless. Tests cover actual files and node
types, retained target bytes and meaningful failure paths. Existing unknown
schema, rollback, cancellation, checkpoint and digest tests continue to gate.

Do not prune old patch trees or Zig installations automatically in this
phase: neither records the lifetime of readers in other checkouts. An age
cutoff, newest-entry rule or reference from this checkout is insufficient.
Their existing TODOs remain, naming the ownership work needed. No new lock,
retention policy, cache format or scanning work belongs on a healthy hot path.

Each step has a separate implementation agent and adversarial reviewer.
Review the exact tested tree, update for incoming main changes, and enable
auto-merge only after review and required green branch checks; the normal
merge queue remains mandatory. Keep #2521 draft, open and never merged.
For each production PR record the changed-path TODO inventory, actual test
execution/standing/skips, failure corrections and merge receipt here.
Use the repository's 30-second full-suite command without silently raising
its deadline; a timeout is not a passing suite. Native CI supplies platform
evidence unavailable locally. Performance acceptance is preservation of
successful legacy allocations, warm cache reuse and deterministic artifacts,
not an unsupported speedup claim.

Execution status: E3 #2619 merged as `a1dd0d43` at 15:30:35 UTC.
E2a #2626 merged as `e94a155d`, tree `0cd14e1f`, at 15:50:35 UTC after
green branch `37132821965` and queue `37133600063`. Independent review
confirmed identical patch content over incoming E3 and fuzzer #2618.
E1 #2624 merged corrected queue `4926dbe1`, tree `2e78c672`, at
16:26:14 UTC after green branch `37135224719` and full queue `37135708678`.
E2b is now PR #2631, head `2dc12e57`, tree `14ba1237`, based on that exact
actual merge. Independent review and narrow integration checks are complete;
native branch and queue gates remain. Three follow-up production PRs merged.
E4 will pin a verified published release containing all four changes,
so standalone CI maintenance executes the corrected code, then audit reuse.

Review separated E2a's independent removal of unsafe mutation from E2b's
new-API consumption. E2a may land before E1; its success-path behavior,
test keys, worker constraints and verdict criteria are unchanged, so
the reviewed harness update acknowledges source digests without an epoch
bump. Its queue still runs the full suite when the harness file changes.

E3 branch CI `37131539984` passed all five platform jobs and aggregate.
Native suite logs plus base-verdict lineage establish the new regression
cases executed; the checked-named branch job performed formatting and
tree checks, not a checked-core suite. Independent review approved queue
`a1dd0d43`, tree `5ab1027a`, over incoming #2592 and #2616 with an identical
patch and unchanged shared-cache formats. Local recovered boot, formatter
and all 26 focused tests passed; changed-path TODO inventory found one
existing entry and none added. Local whole-check hit the journal issue,
and full30 exited124 with read-only child-start failures before cancellation.
These are explicit local limits, not passing full checks. Queue CI
`37132247460` passed all required gates, including the checked-core suite.
Actual merge `a1dd0d4368171fbc87ff851f7be42249339bf249` has the exact
reviewed queue tree `5ab1027a38fd73e8032f6108c147d80cf86746d1`.

E1's focused validation ran and passed all 25 tests across four modules;
independent direct-native probes cover legacy lifecycle, captured errors,
parameter validation and same-statement finalizer reentry. Eight paired
legacy prepare/step benchmarks produced overlapping timings (medians
40.844 ms baseline, 39.407 ms candidate): no regression observed, no speedup
claim. Legacy statements gain one reference slot; no guard is allocated on
their legacy path. A reviewed follow-up preserves the existing ExecResult
table's four-field allocation capacity. Current corrected core separately
passes eight API regressions and its worked example. The required full30
attempt was blocked by the local malformed-database/auto-boot condition and
exited3; it is not a full-suite pass. Changed-path TODO inventory found only
two existing core entries and none added. Native CI remains mandatory.

E1 branch run `37133041078` found ten missing public row-result field
comments and one missing cosmic.sqlite harness acknowledgement. All three
failed native legs reported only the acknowledgement failure; the remaining
native shard passed. Correction `c4dd34b1` adds those comments and the
independently recomputed `d5293d78` acknowledgement, with no epoch change.
Existing verdict criteria are unchanged and C changes alter runtime identity.
The latest local guard rerun was blocked before tests by the database issue;
the corrected native branch passed. Both x86 shards, ARM and Darwin ran
all native cases (3602 total; only three Darwin Linux-noexec skips).
The light branch's checked-named job only formatted and checked the tree;
actual checked-core allocation-failure execution remains a queue gate.

Full queue `37134615585` caught a static-analyzer failure on Linux and
Darwin at `core/sqlite.c:103`: the new void error-capture helper calls
`luaL_error` after allocation failure without an explicit return, so the
analyzer follows a possible null destination into memcpy. Regular native
suites passed first (3617 cases on the integrated tree), but checked tests
did not execute because sanitized construction failed. Author and reviewer
are correcting the control flow without suppressing the analyzer. A new
reviewed head, analyzer proof and native branch/queue gates are required;
E2b publication stays on hold until the actual corrected E1 merge.

Correction `3bbb6ec4`, tree `17757401`, explicitly returns after the
allocation-error raise. Independent review found only four added/one removed
C lines, no ownership or successful-path change and no analyzer suppression.
The pinned `bin/zig build analyze` passed locally. Corrected branch run
`37135224719` passed all required jobs. The author and reviewer verified
four unchanged SQLite allocation test bodies on actual sanitized core
`76adc02b`: ten exhaustive walks and 67 forced allocation refusals, exit0,
with leak assertions retained. Local sanitized packaging still failed on
the generated database, so this is bounded checked evidence, not a full
suite. New queue `4926dbe1`, run `37135708678`, includes incoming Zig #2628
and must execute all native gates. E2b absorbed the same reviewed C fix;
its separately approved five-file consumer delta remains unchanged.

E1's final native queue passed every required job. Independent log review
verified the actual checked suite ran all 3617 tests, zero stood or skipped,
and entered all 439 checked C functions (15 exemptions). ARM also ran all
3617, and all runtime/portable/self-hosting fixture jobs passed. The actual
merge is `4926dbe1b1d6768ea2ba1e3650f9ad9807d3b206`, exact approved tree
`2e78c6729db6a533593f97b9dfc125ec90df353e`, preserving incoming Zig #2628.

E2a boot, formatting, whole-tree checks and focused validation passed. The
final integrated focused run executed all 53 cases; 17 pre-existing nested
sandbox cases were explicitly skipped on this host and no new regression
was skipped. The required full30 attempt exited124 after clean cancellation,
without assertion failures, and is not a passing full suite. Independent
review confirmed unchanged verdict inputs and criteria and the three exact
acknowledgments. New TODOs at `build/shared_compiles.tl:536` and
`build/test.tl:1329` name lifetime ownership and identity checks as the
prerequisites for safe automatic recovery; E2b retires the narrowed existing
busy-code TODO and corrects maintenance's incomplete retirement prerequisite.

E2a's merged queue ran all 3604 tests on ARM and checked Linux, zero stood
or skipped; Darwin ran all with only three Linux-noexec skips. All required
jobs passed. The actual merge retains exact reviewed tree
`0cd14e1fad541d8cdd5428dcdd88f4e03dc99c70`.

E2b checkpoint `8db2ef38`, tree `705bdd85`, passed all 32 focused tests
with no skips, whole-tree checks across 692 files and its TODO inventory.
The required full30 exited124 after keying 3605 tests and clean cancellation,
without an assertion failure; this is not a suite pass. Tests use actual
SQLite BUSY and LOCKED failures and a real pending cancellation guard.
The initial zero-wait custom handler observes cancellation when SQLite calls
it; no universal promise is made for paths where SQLite bypasses the handler.
Only captured cancellation stops retries; the existing total deadline stays.
Publication must first preserve E3's maintenance changes from actual main.

Final E2b integration `07ab3490`, tree `14ba1237`, preserves E3, the
reviewed E1 allocation correction and incoming Zig root-path changes.
Its five-file consumer patch is byte-identical to the earlier approved
patch. Own boot and all 55 cache/harness/Zig integration tests passed,
zero stood or skipped. No additional broad full-suite attempt was needed.
Published #2631 uses this exact tree on the actual E1 merge; native CI
and normal queue remain mandatory before auto-merge.

Local validation found the same generated working-database failure in fresh
unchanged main and independent changed checkouts. A successful boot leaves a
valid large database; a historical hot rollback journal appears again after
an execution boundary, causing a later opener to roll it back to a small,
invalid file. Traces, original database/journal bytes and valid snapshots
are retained separately. A recovered unchanged baseline passed all 32
focused cache tests. The execution-boundary behavior is still under
investigation; no repository fix or unsupported root-cause claim is made.
Validation uses a bounded evidence-preserving recovery procedure and still
requires native branch and merge-queue CI. No shared cache is deleted to
hide a failure and no timeout is extended.

The execution ledger below is the sole status record.

| PR | Scope | Dependency / release boundary |
| --- | --- | --- |
| A1 | Structured executable lookup | Independent; bootstrap consumer waits for A4 |
| A2 | Snapshot SQLite execution outcomes | Independent; native rebuild/work consumers migrate now |
| A3 | Structured HTTP download outcomes with URL-neutral reasons | Preserve incoming stream surface; bootstrap consumer waits for A4 |
| A4 | Verified release and structured-failure consumer migration | A1–A3 published; retires four pin TODOs |
| B1 | Correct the overstated SIGINT provenance requirement | Preserve runtime policy; comment correction included in B2a |
| B2a | Preserve genuine streamed I/O failures and document signal policy | Existing behavior correction; harness epoch update |
| B2b | Explicit bounded draining after child cancellation | B2a; preserve Reader contract; CI consumer waits for B5 |
| B3 | Interruptible SQLite busy waits | A2 outcomes; use existing guard notification |
| B4a | Existing-only writable SQLite open | Small prerequisite for safe maintenance without CREATE |
| B4b | Tool-owned cache maintenance command | B4a; supported formats retained, unknown/unreadable caches kept conservatively |
| B5 | Verified release and cancellation/cache consumer migration | B2a/B2b, B3 and B4a/B4b published; retires two pin TODOs plus SQL wait workaround; B1 corrected as policy |
| C1 | Fs.append | Independent additive operation |
| C2 | Explicit macOS full storage flush | Narrow platform binding + typed wrapper if needed |
| C3 | Measure filesystem-wide flush before adding its API or consumer | Preserve fallback durability; disk-backed evidence required; defer if unjustified |
| C4 | Username lookup | Independent typed system binding |
| C5 | Child credentials without a filesystem sandbox | C4 enables consumer; security-sensitive primitive |
| C6 | Declared writable noexec scratch | Core mount support + harness declaration/keying |
| C7 | Verified release and remaining consumers | C1/C2/C4–C6 published; C3 decision recorded; five post-B5 pin TODO sites across four groups, plus Context/Darwin consumers |
| D1 | [#2590](https://github.com/cosmic-lua/cosmic/pull/2590) | merged; final audit complete | 437ecf40/tree94fd94f9, sole parent8f43b4d7; independently audited exact source, branch37051449851 and queue37051743944 all green; selected roadmap complete with explicit C3 deferral |

Preparation can overlap on disjoint files. Publish B steps serially against actual merged main. After B5's verified release and consumer migration merge, C1/C2/C4 may publish as three separately reviewed PRs from that same actual merged base. C2 shares no changed paths with the other two; C1/C4 touch separate Fs and Proc acknowledgment entries in the harness file, with no epoch change or API dependency. Preserve independent exact-tree reviews and every branch/queue gate, and review each cumulative queue candidate. Resolve and re-review any integration conflict before landing. Join after all three merge, then keep C5 and C6 serial. C3 retains its independent measurement decision; C7 retains the actual published-release barrier. This overlaps CI waiting without claiming faster builds or reduced runner work. If another sensible reviewed slice can land earlier, update this table before implementation; do not combine unrelated new C mechanisms merely to reduce PR count. Release waves avoid repeated pin churn while keeping each consumer transition reviewable.

## A1: executable lookup with an explicit outcome

Add `Proc.find_result(name, path?) -> Proc.FindResult`, with a closed kind `resolved`, `not_found`, or `not_executable`, a path when resolved (or the first non-executable candidate when relevant), and a human reason for refusal. `resolved` means a selected executable spelling, not a guarantee that a slash-containing path exists or can execute. Use this operation-specific record name and one flat discriminant.

Keep Proc.find as the existing `(string | nil, string)` convenience wrapper over the same search implementation. Preserve PATH ordering, empty elements/current directory, unset versus explicitly empty PATH, permission checks for the running user, and the current behavior that an input containing `/` is passed through rather than checked at lookup time. Do not change this search behavior while exposing its existing classification. Allocation on the legacy hot path should not grow unnecessarily; share search mechanics rather than materializing redundant records.

Tests distinguish missing, inaccessible/non-executable, directories, a later executable candidate after an unusable one, explicit paths, empty names and PATH edge cases. Keep exact legacy diagnostics tests. A4 changes Zig's shell-status decision to kind, retaining 126/127 and removing the Proc.find text workaround.

## A2: SQLite result codes attached to the operation

Add `handle:exec_result(sql) -> Sqlite.ExecResult`: a single immutable snapshot containing primary SQLite code, extended SQLite code and human reason. `code == Sqlite.OK` is success; do not duplicate that as an ok boolean. Expose the few named codes actual consumers need, rather than forcing numeric literals or publishing an unused full constant catalog. Keep handle:exec's exact boolean/reason contract and cheap success path; both enter the same C execution operation.

Capture codes and text before another SQLite call can overwrite them. A mutable `last_error()` accessor is insufficient: work.begin_waiting currently sets a new busy timeout immediately after failed BEGIN, and cleanup/finalization may also change the connection's error. Do not parse sqlite3_errmsg or manufacture a code for an ordinary Lua validation error. Preserve raw extended detail without confusing SQLITE_BUSY and SQLITE_LOCKED; BUSY_SNAPSHOT can require rollback. Document and test retry policy separately from exposing codes. Never automatically retry arbitrary multi-statement exec: earlier statements may already have committed effects.

Migrate build.work.begin_waiting and build.rebuild_lock's BEGIN decisions in this PR. The standalone build.zig consumer waits for A4. The existing shared-cache query/corruption classification is a related actual consumer, but an exec-only API does not solve failures of prepare/step/open. During API review, either add the smallest query outcome operations needed by those callers as a separate A2b, or explicitly keep their existing TODOs; do not claim that every SQLite text classifier disappeared. B4 must not delete unknown/busy databases based on guessed text.

Use independent connections/processes for busy exclusion; cover LOCKED separately where reproducible, malformed database, invalid SQL, read-only denial, success after failure, and a captured failure surviving later successful PRAGMA/finalization. Exercise checked-core allocation paths and ensure C-owned error memory is released even when Lua allocation fails.

## A3: HTTP download classification and URL ownership

Add `Http.download_result(url, path, options?) -> Http.DownloadResult` as one flat record. Its kind is `downloaded`, `http_status`, `digest_mismatch`, or `failed`; the reason is empty on success, status is present only on HTTP rejection, and algorithm/expected/actual only on digest mismatch. These are the classifications the consumer actually needs. Do not also add an ok boolean, generic nested Error, or a catalog of curl codes. Compute the outcome at its failure site, never by parsing old diagnostic wording. Other transport, storage and cancellation failures retain their reason under `failed`; broader classification requires an actual caller and an available typed source.

Make the new result's reason URL-neutral: this operation adds no caller URL prefix. This is not a promise to redact arbitrary underlying curl diagnostics. The caller already owns each mirror URL; status and digest fields carry machine data. Preserve existing Http.download's boolean/reason surface and legacy formatting through a compatibility wrapper. Do not silently remove useful URL context from every old caller. Both APIs share the actual streaming/download implementation, keeping bounded memory, hash verification, modes, atomic rename, abort cleanup and concurrent publishers.

Tests cover status rejection, both digest algorithms, malformed digest options, transport failure, output open/write/sync/rename refusal, cancellation, existing target preservation and zero temporary litter. Prove that changing diagnostic wording cannot change mirror retry classification. A4 migrates ZigFetch to result.kind and URL-neutral reason, removing both its digest parser and URL-prefix stripping/contracts exception. Existing mirror budget, fallback retry policy and native-nanosecond limits stay unchanged.

## A4: first release boundary

Select a green published release containing A1–A3, download/hash/execute it, then update the pin and all newly unblocked consumers atomically. Retire the four pin TODOs in Zig lookup, Zig's SQLite lock, ZigFetch digest classification and URL stripping. Run real standalone bin/zig, cold/missing-digest fetch paths, native help/notes and CI driver checks on the selected binary. Recheck the inventory before pinning: unrelated newly published APIs can enlarge this migration.

## B1: document the actual signal-delivery limit

Independent design review found that the original pin TODO promises a distinction
that signal-origin metadata cannot supply. The same sender can call kill with a
single PID or a negative process-group ID; si_code identifies kill-origin and
si_pid/si_uid identify the sender, not the recipient set. Both deliveries can
produce the same metadata and a clean child exit. See the primary
[POSIX kill contract](https://pubs.opengroup.org/onlinepubs/009604499/functions/kill.html)
and [signal metadata definition](https://pubs.opengroup.org/onlinepubs/009696699/basedefs/signal.h.html).

Do not add a public SignalEvent API without a concrete consumer. Replace the
misleading Zig TODO with an explicit explanation of the conservative existing
policy, preserving runtime behavior. Include this comment correction in B2a.
No selected release can make the promised recipient inference sound. This is an
evidence-backed scope correction, not an unimplemented API hidden by deleting a
TODO. The current guard already has a repeat-sensitive private stamp; B2b may
use it for event freshness without exposing origin metadata.

## B2a: retain actual streamed I/O failures

The drain design found that the current child pipe pump can treat genuine
read/poll failures as EOF. Correct that first, keeping private typed provenance
for genuine I/O failure versus guard interruption. Ordinary Reader failures
remain sticky; do not make unrelated reads ignore cancellation. Preserve queued
bytes and make error/EOF precedence explicit. Preserve the scheduler's existing
global error semantics rather than converting unrelated task failures into a
child result. This can change a pass/fail and requires a harness epoch update.
Use deterministic regressions for real failure, queued data, guard interruption,
and cleanup; independent review must check every affected capture/stream path.

## B2b: drain final child output after cancellation

Keep ordinary Stream.Reader failures sticky, as documented. Do not make every read ignore a caught guard. Add a child-owned, explicitly bounded drain operation (provisional `handle:drain(options)`) that can consume already queued and subsequent shutdown output under a monotonic timeout and byte limit after cancellation. Its callback/sink and result must remain concrete and small; the result says EOF/limit/timeout and bytes copied, while genuine I/O failure remains distinguishable. Resolve the exact surface in a design review before editing. The reviewed direction uses borrowed per-stream Writer sinks and explicit eof/limit/timeout/interrupted/failed outcomes. A newly pending signal at entry must be returned as interrupted, not adopted as an ignored baseline; preserve same-number freshness without consuming the guard. Specify zero-time behavior, concurrent consumption, guard closure and coroutine cleanup before implementation.

The drain must service stdout and stderr fairly, avoid deadlock at capture_limit, preserve ordering within each stream, avoid replaying already delivered bytes, and stop when an escaped descendant merely holds a pipe open. It must not resurrect a closed handle or hide a real sticky read error. Only transient guard interruption may be bypassed, within the explicitly selected shutdown scope. Child.wait(timeout) kills/reaps on expiry; wait_any(timeout) does not—tests must use the right primitive.

Test a child trap that prints a final line after SIGTERM; a guard-cancelled read before the drain; both streams filling; cancellation before any output; child exit versus inherited open pipe; byte/time limits; callback failure and descriptor cleanup. B5 replaces CI fuzz's output-file polling with this bounded pipe lifecycle while retaining its saved log, tail, fair signal checks and final report. Do not add a public abstraction only to reconstruct the old polling loop.

## B3: cancellable SQLite busy wait

Add `handle:busy_timeout(timeout_ns)` (or an equally small documented method) installing a core busy handler that checks the existing innermost guard signal notification without consuming it, sleeps in bounded intervals, and honors one monotonic budget. Keep the old PRAGMA surface and default behavior compatible; document that setting PRAGMA busy_timeout replaces SQLite's handler and callers selecting cancellation must use the new method afterward.

Expose cancellation accurately through the operation outcome from A2. SQLite's busy callback stopping can return SQLITE_BUSY, so preserve a separate internal cancellation flag for the current operation instead of relabeling every BUSY as interrupted. Do not allow an old operation's cancellation flag to contaminate the next one. A signal remains available to the caller's guard. Roll back/close correctly on every path; never release another process's lock.

Migrate source-tree rebuild waits with the API, and Zig's standalone wait in B5. Tests use a real lock holder and delivered signal; assert prompt interruption well inside the configured long wait, ordinary busy timeout, eventual acquisition, nested guard handling, and successful subsequent statements. Avoid brittle exact-millisecond assertions.

## B4a/B4b: tool-owned cache maintenance

B4a adds only `OpenOptions.create = false` to writable SQLite opens, omitting CREATE while preserving existing defaults and read-only behavior. Test missing paths, disappearance before open and existing-file access under the raw and public APIs. This capability is independently reviewed before the command consumes it.

B4b adds a build-owned command, provisionally `cosmic cache trim compiles|verdicts PATH --since-ns N --json`. It runs from explicit paths without discovering/staging/rebuilding the candidate project. Its implementation belongs beside shared_compiles/shared_verdicts/shared_sqlite and uses their format definitions. It must be callable from the pinned driver even when the candidate build fails or has no executable.

Return structured counts, bytes, reached/untouched state and unknown formats; keep CLI failure status truthful. CI's current best-effort policy (report failed maintenance without failing an otherwise good leg) remains in CI orchestration. Preserve exact trim semantics: since threshold, whole-unless-reached distinction, compiled/parsed versus verdict/store tables, unknown/unstamped tables kept, writer-versus-trim concurrency, WAL handling, set-aside cleanup and stable row digest independent of used_ns. Do not trim arbitrary SQLite databases merely because they contain a used_ns column. An older pinned tool encountering a newer unknown schema must retain it and explain that decision. Open existing files without CREATE to avoid a pre-stat/open race. Reject schema shapes whose triggers or foreign keys could mutate unknown tables. Require stopped writers from the caller and inspect checkpoint results; successful close alone does not prove WAL readiness.

Move only ownership of trim/format knowledge in this first command PR. Cache restore/save/merge-queue precedence, source attestation and candidate-local database rejection remain unchanged. If digest/fresh-count outputs depend on format details, expose the smallest companion inspect operation rather than leaving CI to reconstruct those schemas. Merging caches is not implicitly in scope. For ambiguous unreadable files, retain the file, report incomplete/failure state and omit digest/fresh outputs so CI does not save it. This intentionally tightens the old text-classified corruption cleanup policy; it avoids guessing or adding broad query/open result APIs solely to delete a disposable cache. Preserve the query/open-code TODO for a later concrete need. Existing-only writable open is the small additional capability this command genuinely needs.

Test missing files, empty and used caches, old/current/unknown schema, busy/read-only/corrupt files, interrupted trim, repeated identical results and exact current CI golden-policy outcomes. Measure both no-op command startup and substantial-cache trim. Prove execution from a directory with a deliberately unbuildable candidate and no candidate o/bin/cosmic. B5 advances the pin, replaces CI's direct trim schema access and removes the pin TODO.

## C1–C3: append and durability

C1 adds `Fs.append(path, bytes, mode?) -> boolean, string`, matching Fs.write's argument style. Use O_APPEND, handle short writes, always close, preserve the first failure, and apply mode only on creation. Do not promise whole-record atomicity for arbitrarily large writes split across syscalls. Test missing/existing files, binary data, permission failure, partial writes/close failure and concurrent appenders with bounded records. C7 migrates Images.append and the driver's whole-file summary rewrite where semantics match.

C2 adds a narrowly named raw macOS full-flush operation (for example sys.full_fsync(fd)), with normal effect/error/errno shape and explicit unsupported behavior elsewhere. Avoid exposing generic untyped fcntl solely for one command. Use it at the typed durability boundary when requested; existing Fs.fsync retains its contract. Test dispatch/error propagation on macOS and checked allocation/descriptor handling. A test can prove the required syscall was selected and its failure propagated, not simulate physical power-loss durability.

C3 first measures the proposed filesystem-wide flush on representative storage. A local API candidate may enable the experiment, but publish sys.syncfs(fd) only when a concrete consumer is justified by the evidence; do not add an otherwise unused public API merely to satisfy the original list. If justified, use Linux syncfs with explicit ENOSYS on unsupported hosts and no silent machine-wide sync() substitute, whose scope and error reporting differ. If not, retain the existing per-file path and record the measured deferral. Keep per-file/directory fsync fallback and C2's macOS full-flush requirement. Benchmark representative cold patched-tree misses on the same host before deciding whether to activate the fast path: syncfs may flush unrelated dirty work on the filesystem and can lose the intended performance advantage. Flush data/modes and containing directories before publishing payload; keep the final cache-directory rename persistence step. Failure before publication leaves no final tree. Retain gate/owner lifecycle and digest identities. Do not change warm-hit work or vendor cache names.

## C4–C5: identity lookup and unrestricted credential drop

C4 adds typed username lookup, e.g. `Proc.user(name) -> Proc.User | nil, string`, using getpwnam_r where available, with uid/gid and only fields the consumer needs. Missing account is nil with empty reason, lookup failure is nil with reason, malformed input raises. Perform lookup before entering any filesystem sandbox, because NSS may need system files or services. No shell invocation. Bound buffer growth, handle NSS errors, copy data before temporary buffers disappear, and test real known/missing users plus controlled error cases.

C5 adds `Child.Options.credentials = { user = uid, group = gid }` for launching with the ordinary filesystem and no supplementary groups. Existing Sandbox.user/group require unveil and retain their meaning; reject ambiguous combinations. Require explicit nonzero user/group IDs. Reject offline and unveiled sandbox combinations, whose namespace IDs have different meanings. On Linux, set no_new_privs, clear supplementary groups, set all real/effective/saved GIDs and UIDs, and clear effective/permitted/inheritable capabilities. Keep the default spawn path unchanged and the post-clone path allocation-free. Report child credential-setup failure through the existing status pipe before exec; never fall back to root. Because CLONE_VM shares dumpability state, check its capture and restoration in the parent. A failed restoration must report failure and terminate/reap the owned child, but the child may already have executed. Do not promise a cleared bounding set; no_new_privs prevents exec from granting new privilege. Fail closed on unsupported Darwin mechanisms. Document inherited environment/cwd/fd authority explicitly. Test actual uid/gid/groups, inability to regain root, inaccessible files, malformed/missing options, failed drop with no child program execution, and interaction with process groups/guards. CI must include a suitable privileged job; an unprivileged test cannot prove a root-to-user transition by simulation alone.

C7 ports run-local only after both APIs are in the pin. Keep snapshot, ownership, cache seeding and phase behavior; preserve proper failure on this session's restricted UID mapping. The current shell uses a mixture of source-tree driver and pin mechanisms: document the chosen launcher explicitly rather than changing that boundary accidentally. Dropping root must be available on supported platforms or fail clearly; do not turn missing support into a green privileged run.

## C6: noexec scratch as a declaration

Add a narrow `Test.needs { noexec = true }` capability with one documented writable scratch location supplied by the harness (provisional `$COSMIC_TEST_NOEXEC`). Preserve ordinary scratch policy; an externally noexec host cannot be promised execution. Provide a private tmpfs at the fixed sandbox path `/noexec`, with no host-backed executable alias, and corresponding narrow noexec mount support inherited by descendants; all declaration parsing, effective inputs, key material, host capability and worker environment paths must agree. A changed policy bumps the harness epoch and updates acknowledgments.

Prove writing and reading succeed there while executing an executable file fails with EACCES; preserve ordinary scratch behavior, testing execution where the host permits it, and prove escaping through a bind/symlink cannot turn the declared directory executable. Probe native execution refusal at the actual worker identity only for requesting modules; include the effective grant in keys and scrub the reserved environment variable when not granted, even under wildcard environment declarations. Unsupported hosts count a clear skip with no cached verdict where permitted and fail held-sandbox runs; never substitute an executable directory or disable ordinary sandboxing because this optional grant is unavailable. C7 migrates the noexec launcher fixture to the declared capability, removes broad environment/host-mount discovery, and preserves native macOS coverage according to its supported sandbox contract.

## Release waves, reviews and acceptance

A4, B5 and C7 each name the exact green release SHA and verified asset digest, inventory all pin TODOs, execute the selected binary, and exercise both standalone bootstrap and separate CI project. Never merge an API consumer first and hope a later release repairs the pin. Each API PR has an implementation agent and a different adversarial reviewer; changes to C identity/signal/mount behavior need an independent security/lifetime review. Root verifies exact tree/SHA and green required branch/merge-queue checks before auto-merge.

Run AGENTS formatting/type/whole-tree gates, appropriate focused tests and the required 30-second full-suite attempt. Core changes build native/checked/all release targets and run allocation tests. Fixture changes require run-local plus remote unprivileged/native/sandbox fixtures. Record local namespace/UID/socket limitations without weakening tests. Keep performance evidence on identical-source checkouts: warm zero compiles/reads, fresh shared-cache reuse, exact artifact equality across matching trees, unchanged cache-hit paths, and targeted syscall/throughput measurements for changed hot operations.

D1 verifies the original nine groups/eleven pin TODOs, both related waits/flush needs, and any additional consumer gaps recorded during execution are either implemented and migrated or explicitly re-scoped with evidence. Check command help, API docs, contract exemptions, public export allowlist, pin, CI and comments together. Run integrated lock/cancellation/cache/durability/noexec scenarios and retain the plan as a living reference. Report remaining unrelated TODOs without treating them as unfinished work in this series.

## Concurrent source changes

PR #2543's codec and Stream.transform changes are already included in 9ac37cba. PR #2544 inspected at a6c6ce32 renames Reader.read's max argument to max_bytes across stream/HTTP/child/net/archive surfaces and updates child validation wording and harness acknowledgment. It merged as 7f35550d and does not remove the sticky guard cancellation in Child.pipe_reader, so B2 remains necessary. Preserve max_bytes and incoming acknowledgments. Do not reapply either external API cleanup under this roadmap.

## Execution ledger

| Step | Implementation PR | State | Evidence |
| --- | --- | --- | --- |
| A1 | [#2545](https://github.com/cosmic-lua/cosmic/pull/2545) | merged | 338a8e25; reviewed tree ef80637e; branch 36955108004 and queue 36955383885 green |
| A2 | [#2546](https://github.com/cosmic-lua/cosmic/pull/2546) | merged | 143b9926; reviewed tree f1a68e18; branch 36956411363 and queue 36956779031 green |
| A3 | [#2550](https://github.com/cosmic-lua/cosmic/pull/2550) | merged | b951ab95/tree02802767; incoming Stream retained; branch 36957749478 and queue 36957951958 green |
| A4 | [#2552](https://github.com/cosmic-lua/cosmic/pull/2552) | merged | 3511e6cd/tree0c00b3b3; branch36959640308 and queue36959944853 green; verified release and four consumer migrations complete |
| B1 | included in #2554 | completed as policy correction | Recipient scope cannot be inferred; preserve behavior and explain policy, no speculative public API |
| B2a | [#2554](https://github.com/cosmic-lua/cosmic/pull/2554) | merged | 8e4a8992/treeecc23d74; branch36961017020 and queue36961286634 green; incoming #2548/#2553 preserved; epoch13 |
| B2b | [#2559](https://github.com/cosmic-lua/cosmic/pull/2559) | merged | f4c30c3d/tree0a398186; branch36962413125 and queue36962779158 green; incoming #2557/#2558 preserved; epoch14 |
| B3 | [#2564](https://github.com/cosmic-lua/cosmic/pull/2564) | merged | 3fbe396a/tree8e9b37a8; branch 36964006809 and merge queue 36964406073 green |
| B4a | [#2573](https://github.com/cosmic-lua/cosmic/pull/2573) | merged | 55724526/treeb3c0574f; branch36977328228 and queue36977805814 green; exact queue tree independently approved; native80 and checked56 pass |
| B4b | [#2578](https://github.com/cosmic-lua/cosmic/pull/2578) | merged | 79c38a7a/tree44c25249; branch36979110720 and queue36979424775 green; exact queue tree independently approved; native63/checked35 pass; matching three artifacts |
| B5 | [#2579](https://github.com/cosmic-lua/cosmic/pull/2579) | merged | 46e71ef1/tree26150b97; corrected branch36982541211 and queue36982884252 all green including nativeDarwin; actual release/pin and independently reviewed live-waiter cleanup proofs complete |
| C1 | [#2580](https://github.com/cosmic-lua/cosmic/pull/2580) | merged | 957147ab/treef08d1667; branch36984019009 and queue36984430825 green; exact approved tree, native60/independentchecked20 and whole654 zero |
| C2 | [#2581](https://github.com/cosmic-lua/cosmic/pull/2581) | merged | 004331f1/tree2e95771b; branch36984107521 and cumulative queue36984579239 green; independently verified actual native Darwin full_fsync success; exact C1/C4/C2 union |
| C3 | [#2584](https://github.com/cosmic-lua/cosmic/pull/2584) | deferred; experiment closed unmerged | sole confirmation37040643348 stopped before measurements on unrecognized Runner.Worker installation path; verified artifact11242461886; zero timing observations; no retry under declared policy, no unused API or fast path shipped |
| C4 | [#2582](https://github.com/cosmic-lua/cosmic/pull/2582) | merged | b5349e2c/tree02eed572; branch36984198489 and cumulative queue36984578014 green; exact approved union with C1; local full30 retained inherited Unix-socket EPERM/timeout |
| C5 | [#2583](https://github.com/cosmic-lua/cosmic/pull/2583) | merged | actual0b111618/tree19b9b089; branch36988568683 and queue36989013309 all green; independently verified all eight privileged modes and database boundary on x86/ARM/Alpine |
| C6 | [#2585](https://github.com/cosmic-lua/cosmic/pull/2585) | merged | c6e5966d/treeeec1975c; corrected branch37041482218 and full queue37041999545 green; all3380 native tests ran without skips on x86/ARM/Alpine and checked, including3 noexec cases; all8 credential proof modes passed on all3 Linux legs |
| C7 | [#2586](https://github.com/cosmic-lua/cosmic/pull/2586) | merged | 8f43b4d7/tree560056cc, parent1eb04d80; corrected branch37047803289 and queue37048258849 green; all3 Linux real root/credential/heldnoexec and Darwin flush/patch proofs verified; incoming four PRs preserved/reviewed |
| D1 | pending | planned | Independent design review completed; implementation and exact-tree review required |

- 2026-10-02 UTC: build series completed at `9ac37cba`; user authorized API execution. A1/A2/A3 are being prepared independently and will publish/merge serially. Incoming #2544 merged as `7f35550d`; preserve its max_bytes surface and harness acknowledgment during integration.

- 2026-10-02 UTC: A1 published as #2545 at `acfc8a77`, exact reviewed tree
  `ef80637e`, based on merged main `7f35550d`. Independent fresh boot reused
  499 parses and 485 compiles with zero fresh work; 25 forced review tests
  passed. Implementer 58 focused tests and whole-tree 636-file check passed.
  Required full-suite attempt timed out at 30 seconds without an assertion
  report, so remote CI remains required. No new TODOs. A runnable Proc example
  earns the export and teaches kind-based 126/127 handling. Legacy lookup adds
  one result allocation in command setup, with no extra filesystem calls.
- 2026-10-02 UTC: A3 adds a meaningful source-built Fetch consumer: file-output
  status failures now use the same redacted status formatter as stdout/head,
  independent of diagnostic wording. Standalone ZigFetch still waits for A4.
  Candidate `055c9b41`, tree `9e2d5056`, independently approved; 112 focused
  tests passed and then all stood in 818 ms with zero build compilation/reads.
  Whole-tree check passed across 635 files. Independent review also compared
  nine legacy scenarios exactly and proved repeated callback exceptions leave
  no temporary files or descriptors. Required full-suite attempt timed out
  without a final summary; it is not counted as a pass. No new TODOs.

- 2026-10-02 UTC: independent B1 review disproved the promised recipient-scope
  inference, so no public provenance API will be added without a real caller.
  B1's runtime behavior stays; its inaccurate TODO becomes policy documentation
  in B2a. B2 is split into the real I/O-failure correctness prerequisite and the
  later bounded drain. The private existing stamp supports freshness.
- 2026-10-02 UTC: B4 review requires existing-only writable open, safe schema
  recognition, explicit checkpoint results and stopped writers. Ambiguous
  unreadable caches are retained with no save digest, an explicit conservative
  policy adjustment. Broad typed query/open APIs are not prerequisites for this
  useful safe command and will not be added solely to preserve deletion behavior.

- 2026-10-02 UTC: A1 merged as `338a8e25` after green branch and queue checks.
  A2 published as #2546 at `147a4569`, exact approved tree `f1a68e18`; all
  74 focused integration tests passed, whole-tree check covered 637 files with
  zero findings, and checked allocation/GC cases were independently reviewed.
  A3 integrated tree `37787864` is independently approved: 121 implementation
  and 117 independent HTTP/Fetch cases passed; all four A3 blobs are unchanged.
- 2026-10-02 UTC: refined B2 design approved after resolving the fresh-signal
  entry race, captured-guard closure, parked Reader exclusion, valid-prefix
  error ordering and bounded zero-time behavior. Local B2a/B3 preparation may
  overlap A-wave CI; publication still follows A4. B2b waits for B2a's private
  ownership foundation and earns its export with a useful runnable child example.

- 2026-10-02 UTC: B2a candidate `3f10d7da`, tree `4a438ebc`, independently
  approved. 195 implementation tests and 73 independent cases passed; real
  closed-descriptor failures remained sticky outside and inside Poll.run.
  Whole-tree check passed; full-suite attempt hit the known host Unix-socket
  refusal and 30-second timeout, so it is not a pass. Publication waits for A4.
- 2026-10-02 UTC: split B4 into B4a's small existing-only open option and
  B4b's command. Schema recognition, WAL readiness, digest framing and bare
  dispatch deserve a focused command review separate from the C open flag.
  With C3 explicitly deferred, this makes sixteen implementation/migration PRs plus D1's final audit.
  C1/C2 local preparation may overlap CI, with their publication still after B5.

- 2026-10-02 UTC: A2 merged as `143b9926` after green branch and queue CI.
  A3 published as #2550 at `476924d8`, exact reviewed tree `37787864`, and
  auto-merge is enabled. Actual-parent local alignment `eac856b2` has the same
  tree. B3 is independently approved at `f13f2725`/`8efd806e`: native and checked
  operation/lock/allocation cases passed; interleaved default-path timing ranges
  overlap baseline, with no clock reads added to uncontended operations.
- 2026-10-02 UTC: concurrent #2547 changes Stream object representation while
  preserving its interfaces; #2548 changes analyzer/docs binding resolution and
  HTTP option-refusal caller locations. Preserve their actual merged changes and
  review integration, including both download entry points. These are not API
  roadmap implementations; pending external heads are not copied into ours.

- 2026-10-02 UTC: A3 queue candidate `b951ab95`, tree `02802767`, includes
  merged Stream #2547 and no other delta beyond the four unchanged A3 files.
  Independent fresh boot, 197 HTTP/Fetch/Stream tests and 20 late callback
  failures with GC stopped passed without resource leaks. Queue CI remains
  the merge gate.
- 2026-10-02 UTC: B2b review reproduced and fixed three defects before
  publication: missing stdout incorrectly selected the stderr sink, a Reader's
  early pipe abandonment looked like real EOF, and a mutated byte limit could
  bypass the original bound. Corrected `b48168c6`/`d4522aad` is approved; 86
  independent focused tests passed. Synthetic queued 64-byte reads add about
  65–75 ns/call; real 64-MiB transfer ranges overlap baseline. This is a bounded
  safety cost, not a zero-overhead claim.
- 2026-10-02 UTC: C3 overlay experiment used six alternating rounds on the
  same runtime: 12 real vendor trees (1,354 files, 90 directories, 24,586,523
  bytes) took median 419.971 ms with per-file fsync versus 424.654 ms with
  syncfs; 2,001 small files took 187.495 versus 205.933 ms. Every payload hash,
  mode and name matched; warm hits made no flush/write calls. Flush work was
  already under 1 ms on this overlay host, whose mount uses `fsync=volatile`,
  so this does not establish real-disk
  benefit or harm. Keep the API candidate and production fast path on hold.
  A narrow temporary diagnostic on an already-required native CI run can
  provide disk-backed evidence; remove diagnostic workflow changes before any
  production merge. If no consumer is justified, document deferral instead of
  shipping an unused capability.

- 2026-10-02 UTC: A3 merged as `b951ab95` after green branch and queue CI.
  A4 #2552 publishes exact independently approved tree `683dcc50`. The actual
  immutable release binary is 14,901,296 bytes with SHA256
  `24c8dacbbd42eef3dd2a923fa4f9761e5d1aab293666e564a3ddce53a3eac7b5`;
  both manifests, executed version, tag and main/publisher provenance agree.
  Independent actual-pin boot and 153 native tests passed; the selected release
  checked the separate CI project and passed 62 tests. Real empty-cache Zig
  installation took 23.970 s; warm reuse 30 ms; missing digest refused before
  transfer. Whole-tree check covered 637 files with zero findings. The required
  30-second suite attempt timed out without a final verdict. Matching-source
  artifacts are byte-identical across independent worktrees; seven pin TODOs
  remain after the four intended retirements. The selected release includes
  #2547 and excludes the still-open #2548.
- 2026-10-02 UTC: B4a review clarified that `create = false` refuses missing
  named files; SQLite's empty and `:memory:` special paths keep their existing
  transient-database semantics. Corrected `6d1d3232`/`9f54b268` is independently
  approved with native and checked regression coverage.

- 2026-10-02 UTC: incoming #2551 merged as `e2451ed3`, converting HTTP,
  SQLite, filesystem and JSON object internals to shared methods. A4 queue
  `3511e6cd`/`0c00b3b3` preserves all five incoming files and all six unchanged
  A4 files. Independent actual-pin boot and 233 focused API/consumer tests
  passed. The selected release stays `b951ab95`; #2551 adds no capability that
  unblocks another pin TODO. Its new Fs/SQLite acknowledgments must survive
  every later integration.

- 2026-10-02 UTC: A4 merged as `3511e6cd`, tree `0c00b3b3`, after branch
  `36959640308` and queue `36959944853` passed every required check. This
  completes the first actual-release checkpoint. B2a and B2b have independently
  approved integrations on the new pin and now align to this merged parent,
  preserving #2551's acknowledgments before serial publication.

- 2026-10-02 UTC: B2a published as #2554 at `20569b76`, exact approved tree
  `5fd49ed6`, based on actual A4 merge `3511e6cd`. All nine final harness guards
  passed. B2b's corresponding reviewed integration is `3a2a6c6e`/`3ed45698`;
  124 related tests and 45 independent cases passed, followed by 37 final
  harness/drain checks after retaining incoming #2551. Its mandatory full
  attempt timed out after keying 3,251 tests and is not counted as passing.

- 2026-10-02 UTC: concurrent #2548 merged as `73ccf140` and #2553 as
  `a08b16a2`. Their analyzer/catalog binding changes and archive/codec object
  representation changes are retained in B2a queue `8e4a8992`/`ecc23d74`.
  Independent review confirmed the four-file B2a patch and full harness epoch
  are unchanged; a fresh boot plus 15 source-failure/harness cases passed.
- 2026-10-02 UTC: C3's temporary CI measurement is independently approved
  after separating timing-only comparisons from per-flush instrumentation,
  verifying direct block-device backing and protecting existing outputs.
  Script SHA256 `9dededf1c632ed8842490d7c69ee5d5ab061d42626b37f733108c4673f3ba6ee`;
  temporary patch SHA256 `95fd8f219de26c68683695a4a41f11e9aee26158c82c20bb84f4e331d55ad6d2`.
  Nothing is applied or published; production API approval still requires
  representative native measurements at the C3 step.
- 2026-10-02 UTC: B5's concrete migration design is independently approved.
  Cache maintenance needs an outer signal guard spanning restored-snapshot
  cleanup before redelivery, exact ordered result paths and alias checks before
  deleting a snapshot. Fuzz capture uses bounded pipe draining, preserves known
  child status and saved bytes on output failure, and never replays a chunk
  partly delivered to its sinks.

- 2026-10-02 UTC: B2a merged as `8e4a8992`/`ecc23d74` after every required
  branch (`36961017020`) and queue (`36961286634`) check passed. B2b proceeds
  onto that actual parent.
- 2026-10-02 UTC: C5 and C6 exact local candidates are independently
  approved. C5's native/checked tests cannot establish a privileged transition
  on this host; its narrow root fixture must pass in CI. C6's three actual mount
  tests are honestly skipped here and must execute under held Linux CI. C6's
  temporary epoch is replaced during integration after B2/C5, preserving all
  incoming analyzer metadata. C5 adds one explicit TODO at `core/syscalls.c:2722`
  for the pre-existing unchecked namespace-drop dumpability restoration and
  required ownership-preserving cleanup; its new ordinary credential path
  checks restoration and cleanup now.

- 2026-10-02 UTC: B2b published as #2559 at `fd834a8e`, exact independently
  reviewed tree `668c3b95`, based on actual B2a merge `8e4a8992`. Both original
  patches are unchanged and all 27 incoming #2548/#2553 files are preserved.
  Final nine harness checks passed; auto-merge waits for required branch and
  queue CI.
- 2026-10-02 UTC: B4b candidate `79d84149`/`35024802` is independently
  approved. Real cancellation returns incomplete JSON/exit1 cooperatively;
  mixed healthy/unreadable sets suppress aggregate outputs. A 64.5-MiB,
  1,024-row cache trim/vacuum/digest took 0.531 s with 16,244 KiB peak RSS;
  absent-cache startup ranged 9.58–23.15 ms across five runs. These describe
  this host, not a cross-host speedup. One new TODO at
  `build/cache_maintenance.tl:245` retains unreadable caches until typed SQLite
  open/prepare/step failures can justify automatic corruption retirement.
- 2026-10-02 UTC: C7's consumer design is independently approved. Keep the
  existing Git, POSIX checksum and symlink-safe recursive ownership boundary;
  use the pin for the standalone launcher and the checkout tool for phases.
  Schedule noexec fixtures explicitly on Linux because current CI phase
  records cannot represent a skipped fixture; retain ordinary native macOS
  coverage. This does not change the harness's honest unsupported-host skips.

- 2026-10-02 UTC: extend the existing preparation overlap to C7's disjoint
  consumer files. A separate local driver can combine reviewed C-wave APIs for
  development, with no C3 fast path and no pin change. This avoids idle time
  during serial CI. It is not release evidence: actual merged-base integration,
  published-asset verification, native privileged/mount tests and independent
  final review remain mandatory before the consumer PR is published.

- 2026-10-02 UTC: B4a `7e24382e`/`ea9d1654` and B4b
  `bbc82140`/`d98c1d87` are independently approved on the coherent A4/B2/B3
  preparation base. B5 source preparation starts there, retaining the old pin.
- 2026-10-02 UTC: B2b queue candidate `f4c30c3d`/`0a398186` is independently
  approved subject to queue CI. All four B2b blobs and its combined patch are
  unchanged; incoming #2557 argv documentation and #2558 old `_inputs` refusal
  removal add five preserved files. The separate #2555 child-object refactor
  is not present; its overlap has been inspected for later integration.

- 2026-10-02 UTC: B2b merged as `f4c30c3d`/`0a398186` after required
  branch `36962413125` and queue `36962779158` passed. B3 now aligns to this
  actual parent for publication.
- 2026-10-02 UTC: local C7 preparation driver `726572ca`/`faef5ef5` is
  independently approved for development only. It combines reviewed C1/C2/C4/C5/C6
  APIs with no C3 and an unchanged pin. Fresh boot reused 516 parses/502
  compiles with zero new compilation; 34 focused cases passed. Independent
  worktrees produce identical executable, carried and projection bytes and six
  clean database checks. Native credential/noexec proof and published-release
  verification are still required; its provisional epoch is not a production
  integration token.

- 2026-10-02 UTC: B3 published as #2564 at `9d5dc39b`, exact approved
  tree `589e1f47`, based on B2b merge `f4c30c3d`. Static independent review
  verified unchanged patches and the five preserved incoming files; final
  harness checks passed 9/9 with zero warm compilation/reads. Auto-merge is
  enabled, subject to required branch and queue checks.

- 2026-10-02 UTC: B3 merged as `3fbe396a` after successful branch and
  merge-queue CI. B4 integration now targets actual main `58059883`, preserving
  the subsequently merged child/net/poll object refactor, HTTP request API and
  parser correction. Implementation and independent review have resumed in
  separate worktrees. B5 and C7 consumer migrations remain in preparation;
  their local drivers are not published-release evidence. C3 remains held
  pending a useful real-filesystem performance result.

- 2026-10-02 UTC: B4a published as #2573, remote `c8b310c0`, independently
  approved tree `08e1e7b2` on actual main `58059883`. Native 83 and independent
  checked 51 cases passed; whole-tree check found no fixes in 645 files.
  Warm build performed zero compiles and staged reads. Required full-suite
  attempt timed out at 30 seconds and is not a pass; platform CI gates merge.
  Independent integration checks also passed 104 child/drain/guard/poll cases.
- 2026-10-02 UTC: B5 review identified an inherited read/rewrite of
  GITHUB_OUTPUT in CacheTrim.output. Record a precise Fs.append pin dependency
  there and migrate it in C7 alongside Images and Context. The expected
  post-B5 literal pin inventory becomes five sites; this adds a consumer of an
  already planned API, not another API. C7 also adds a narrow real privileged
  runner proof to cover ownership, symlinks and unchanged source state; local
  UID-mocked plumbing tests do not establish credential-transition success.

- 2026-10-02 UTC: B4a branch CI passed. Queue candidate `8cbd12d3` retained
  all six approved feature blobs and added only #2571's four CSV files.
  Four queue platforms passed; the checked core failed only
  `build.teal_test:test_a_keyword_named_variable_costs_what_it_reads`, which hit
  its 30-second deadline (3306 tests, no infrastructure errors). The queue
  removed auto-merge; #2573 remains unmerged. Investigate unchanged-test
  behavior on the exact parent and candidate before a correction or requeue.
  Pending external #2568 changes timing retries but does not establish a fix
  for this deadline failure; #2569 does not touch this test.
- 2026-10-02 UTC: B5 and C7 source preparations now have independent exact-tree
  approval. Pins remain unchanged. C7 review fixed bounded error-log streaming,
  default-state-directory symlink handling and an inherited snapshot omission
  of tracked or force-staged files matching ignore rules. Actual credentials,
  noexec and Darwin flush success remain native CI gates. B5's concurrent-host
  timing samples are diagnostics only, not performance conclusions.

- 2026-10-02 UTC: the parser queue failure is addressed separately in #2577,
  remote `600558c0`, independently approved tree `04eee27f`. Exact parent and
  SQLite candidate workers took 18.136s and 18.167s in isolation. Eight named
  workers retain every original input, syntax assertion, 20x-plus-50ms ratio
  and 30-second deadline. The largest checked worker now takes about 7s;
  separate initialization adds about 1.3s of aggregate worker time in the
  measured run. A real quadratic token-copy mutation still fails the ratio
  assertion (20.975s against a 0.737s control). No production code changes.
  Whole-tree checks passed; mandatory full attempt timed out honestly. #2577
  has auto-merge enabled; #2573 needs fresh integration and CI after it merges.
  This is an additional infrastructure prerequisite, not another API.
- 2026-10-02 UTC: C1/C2/C4/C5/C6 source integration is independently statically
  reviewed at `80ea4f72`/`a595af10` on `cfb0e8fb`. Incoming shared Child methods,
  drain ownership, raw spawn argument 11 and analyzer bound metadata are
  preserved. This is preparation only: no builds ran during parser timing,
  the C6 epoch remains deliberately bare, and final-base acknowledgments,
  runtime checks and native security/durability proofs remain mandatory.

- 2026-10-02 UTC: concurrent #2575 independently added a four-worker split
  preserving all original parser workloads and bounds. It merged as
  `c0a55b1b` after green queue `36975678700`, including the previously failing
  checked suite. Close our duplicate #2577 unmerged; its eight-worker
  measurements remain evidence of the diagnosis, not measurements of the
  incoming four-worker grouping. #2572's one-shot artifact VFS change then
  merged as `eb8ea8cc` after green queue `36975680153`. Independent interaction
  review found ordinary cache-file opens and existing borrowed store handles
  compatible. B4a now integrates both actual merges before fresh CI; no
  failing checks were bypassed or blindly retried.

- 2026-10-02 UTC: B4a refresh published at `f1d75a60`, exact independently
  approved tree `b3c0574f`, preserving both old PR head and actual-main parents.
  All six feature blobs are unchanged. Native 80 and independent checked 56
  integration cases passed, including executed VFS refusal/ordinary-attach
  assertions and the incoming four parser workers. Whole-tree check passed;
  warm build did zero compiles/reads. Full 30-second attempt timed out without
  reported assertions and is not a complete-suite verdict. Auto-merge is
  enabled for fresh branch and merge-queue checks.

- 2026-10-02 UTC: B4a refreshed branch run `36977328228` passed all five
  platform jobs and entered queue run `36977805814` at candidate `55724526`.
  C1/C2/C4 publication may overlap after actual B5 merge, following independent
  path-overlap and dependency review. Their only shared path contains distinct
  Fs/Proc acknowledgments that merge cleanly; C2 has no overlap. Keep separate
  exact-tree and cumulative queue reviews, join before C5, and retain C5/C6
  sequencing and C7's release verification. No runtime or test gate is removed.

- 2026-10-02 UTC: B4b merged as `79c38a7a`/`44c25249` after green branch
  `36979110720` and queue `36979424775`; main CI `36980359851` and publisher
  `36980439643` also passed. Author and adversarial reviewer separately
  downloaded all three assets of immutable release `401625559`,
  `next-79c38a7a3bba6bdabdb6515853c23ffa61456598`. The 15,175,728-byte binary
  has SHA256 `97387765bb99f736dca1cf96fe62c20ae45c85fa30c423379c18c563cb0a2ab8`,
  matching GitHub's digest and both manifests. Tag/ancestry and actual publisher
  source provenance match. Both executed the binary's B APIs and bare cache/help
  in a broken project. B5 may now advance the pin atomically with every unblocked
  consumer, subject to final actual-pin tests and independent exact-tree review.

- 2026-10-02 UTC: B5's first branch run `36981599603` passed four Linux
  jobs but exposed a macOS cancellation-test assumption. Darwin shares flock
  and SQLite's fcntl lock space, so the separate older SQL holder correctly
  blocked the final flock probe. Reviewed correction `988a3cce`/`26150b97`
  changes only the test, follows the actual filesystem lock relationship and
  retains the cancelled waiter alive until both locks are proved free. This
  also prevents process exit from masking a descriptor leak. Native44 and
  checked44 passed; independent9 lock tests passed. No production, pin, timeout
  or platform-skip change; fresh required CI must verify the Darwin path.

- 2026-10-02 UTC: C1/C4/C2 merged after independent exact-tree and cumulative
  queue review, with all branch and queue checks green. Actual joined main is
  `004331f1`/`2e95771b`. C2's native macOS job exercised positive F_FULLFSYNC,
  descriptor lifetime and closed-descriptor rejection; this is syscall evidence,
  not a power-loss durability claim. Thirteen API production PRs are merged.
  C5 published as #2583 on that exact parent, approved tree `587341de`, with
  privileged Linux proof required before automatic merge. C6 preparation has
  independent source/native/checked approval and fresh epoch `15-e83f51b3`, but
  must align after actual C5 merge and execute native mount proofs in CI.

- 2026-10-02 UTC: C3 published as draft experiment #2584, auto-merge disabled,
  approved tree `a566529e` on actual joined main. Its temporary instrumentation
  must never merge. Six-pair timing is only a pilot: positive results require
  reviewed A/A calibration and at least 30 A/B pairs plus real consumer/error
  scope review; invalid, noisy or unhelpful evidence means explicit deferral.
  Current production patch synchronization and bootstrap pin are unchanged.

- 2026-10-02 UTC: C5's first CI run `36986815659` passed macOS/checked
  but all three Linux credential proofs stopped before the driver: the root
  launcher correctly refused the ordinary runner's cache owner. Reviewed
  correction `106323cf`/`5a6b438f` gives only the proof a private root-owned
  XDG/portable cache; no launcher rule, API or assertion changed. Workflow38
  and independent eight-mode launcher/filter smoke pass; real transitions
  remain native CI gates. The required local full30 still times out and its
  inherited Unix-socket EPERM assertion remains explicitly recorded.

- 2026-10-02 UTC: C3 pilot branch `36986823523` passed, including native
  measurement job `110773641557`. Artifact `11218161072`, ZIP SHA256
  `abada3e8e2f70e8bd97e5d3dc5c30987b178ba46bf770f7026dd8d42bbc8ab13`,
  has independently checked 24 timing and eight diagnostic rows, exact keys,
  modes and payload manifests, and zero warm writes/flushes. The observed
  direct Azure ext4 disk uses nobarrier/data=writeback/journal_async_commit;
  results describe this configuration and imply no physical durability.
  All six pairs favor syncfs: median paired difference -428.237ms for vendors
  and -620.003ms for many small files. This is promising pilot evidence only.

  **Explicit plan adjustment:** the native pilot now justifies one additional
  bounded confirmation push on draft #2584. This changes our earlier runner-
  efficiency rule; it is a benchmark-motivated run, not an already-required
  event. No matrix expansion, workflow dispatch, automatic retry or auto-merge.
  Independent protocol approval is recorded at SHA256
  `fae3d5a17a1880dd81ad7518ef8da1814cc7e2e8b1b9038d5caa4f0f923524ce`.
  Final measurement implementation still needs separate adversarial approval.

  The existing first x86 Linux leg retains its five-minute cap and an inclusive
  internal 280-second stop. Fixed per-dataset A/A then A/B calibration each
  has three warmup pairs and 30 measured alternating pairs: 240 measured,
  24 warmup and eight separate diagnostic executions overall. Preserve every
  observation and independent manifest, with no outlier removal, replacement,
  sample reduction or partial acceptance. Require 6GiB/750k inode headroom,
  immutable optimized tool/core/source/pin/configuration identities, matching
  native storage facts and monitored quiet guest execution. Monitoring stays
  outside child decision timing; missing visibility, interference, deadline,
  mismatches or incomplete persistence invalidate the attempt.

  Both datasets must have unbiased A/A calibration; the entire paired median
  interval for A/B must exceed the A/A practical resolution in the beneficial
  direction. Use existing perf definitions, dispersion and empirical p95
  vetoes, plus chronological/order/drift review. Incomplete, noisy, conflicting
  or confounded results mean explicit deferral, without another automatic run.
  Positive confirmation remains limited to the measured filesystem/workload;
  adoption separately requires consumer/error-scope and generalization review.
  Remove all temporary measurement code before any production merge, then
  require fresh ordinary CI and merge queue checks. Production patch behavior
  and the pin remain unchanged throughout this experiment.

- 2026-10-02 UTC: C5 cache correction proved all eight actual privileged modes
  on x86 and ARM, then the existing delayed database boundary caught proof
  dispatch writing project metadata between snapshots. Reviewed placement fix
  `95e804da`/`19b9b089` moves helper/proof after the unchanged boundary, matching
  existing Darwin/format phases. Workflow39 and whole657 checks pass; an
  independent regression enforces ordering and required Linux/root execution.
  All branch checks passed in `36988568683`; queue `36989013309` candidate
  `0b111618` exactly matches the approved tree and actual parent. C6 preparation
  `2bfa8674` retains both fixture corrections with runtime/epoch unchanged.

- 2026-10-02 UTC: C3 confirmation protocol refinement SHA256
  `d66147e2d4d279b97e8cc617be5c3b9213e748bda008be9b86a30e1d9955ed70`
  is independently approved for implementation preparation. It specifies
  verified process/service identity and activity bounds, monitoring-gap
  refusal, coordinator-only observation and bounded child/helper cleanup.
  A narrow read-only privileged metadata helper may read fixed process
  identity/accounting fields when the ordinary runner cannot; benchmark
  execution stays unprivileged. Exact implementation review remains pending.

- 2026-10-02 UTC: C5 merged as `0b111618`/`19b9b089` at09:32UTC after
  branch and full queue passed; actual privileged success and all seven
  injected refusal modes were independently verified on x86, ARM and Alpine.
  Fourteen API production PRs are now merged. External timing PRs #2568,
  #2569, #2570 and #2576 subsequently advanced main to `0ec53d35`; preserve
  their ratio/event-based tests and CI timeout behavior during integration.

- 2026-10-02 UTC: execution stalled at the C6 tree publication handoff.
  During the pause the transient workspace was recycled, removing unpublished
  checkouts and local logs. Merged PRs, CI evidence and this reference remain
  intact. Retained complete C6 file contents reproduce exact approved tree
  `430eccbe`, now checkpointed remotely at `5e5c1312`. Its current-main merge
  `979c0262`/`63ea479d` is being independently reviewed and freshly checked.
  C3 confirmation source is being reconstructed from deterministic retained
  operations and must match its approved blobs/tree before the sole run.
  C7 retains substantial literal source and its contracts, but missing portions
  require reconstruction and fresh review; prior approval is not carried over
  to different bytes. Checkpoint coherent source remotely before long waits.

- 2026-10-02 UTC: C3 confirmation was recovered byte-for-byte as approved
  tree `9aa63759` and published once as `b4e0b936`. Run `37040643348`
  stopped before any benchmark at an unexpected hosted Runner.Worker path.
  Artifact `11242461886` has verified ZIP SHA256
  `a43e988c7b9d1e16aea87f3095a6b2d350159ba6b9e2ef6c02e4e9024fa21921`;
  completion is false with zero observations. This is a monitor coverage gap,
  not evidence of a performance regression/noisy host. Per the declared rule,
  C3 is deferred without retry. #2584 is closed unmerged, auto-merge off;
  retain current fsync and precise follow-up, with no unused syscall shipped.

- 2026-10-02 UTC: C6 #2585 branch exposed deterministic nested fixture setup:
  absent cwd inherited `/tree`, which that narrower sandbox does not expose.
  Reviewed one-line correction `8a849f07`/`eec1975c` chooses `/`; runtime and
  assertions are unchanged. Corrected x86 shards ran all3380 tests without
  skips under held sandboxing, proving the three mount cases; branch/queue
  completion is still required. A malformed local staging DB was preserved
  and its cause remains unassigned; a fresh same-source worktree plus shared
  compile cache passed integrity checks. Host-only raw socket/process failures
  remain explicit, not reported as suite passes.

- 2026-10-02 UTC: C7 recovery is complete and checkpointed in draft #2586.
  Combined tree `d63d40c1` has byte-identical blobs from three newly reviewed
  subsets: append/README28 independent tests, runner15, patch21 and
  orchestration35. Review caught and repaired missing test grants/scheduling
  and cleanup-before-append coverage. The combined tree retains all current
  APIs, epoch, incoming timing fixes and C6cwd correction. No old approval was
  carried over different source. Final integrated checks, actual immutable C
  release double verification, pin update and native platform proofs remain.

- 2026-10-02 UTC: C6 merged at17:50:28UTC as `c6e5966d`, exact
  reviewed tree `eec1975c`, parent `0ec53d35`. Corrected branch
  `37041482218` and queue `37041999545` passed every required check.
  Independent logs show all3380 native tests ran, zero stood/skipped on
  x86, ARM, Alpine and checked; Alpine portable also ran all3380. All three
  noexec mount cases actually executed, and all eight credential proof modes
  passed on each Linux release leg. Fifteen API production PRs are merged.
  C7 now waits on actual main CI/publication and two independent release
  downloads, provenance checks and executions before atomically moving its pin.

- 2026-10-02 UTC: integrated C7 preparation `a95f3d4e`/`d63d40c1`
  passed78 CI and60 patch/workflow tests, with zero whole-tree findings across
  63 CI and663 root files. All12 vendor keys and1354 output files match the
  C6 parent by name, bytes and mode; warm manifests/mtimes stay unchanged.
  These are equivalence diagnostics, not a speedup claim. Exact20path TODO
  inventory has21 entries in6 files: rewritten syncfs dependency, relocated
  state-pruning follow-up and19 inherited entries. Only syncfs remains in the
  literal pin selector. Required full30 exits124 after3386 declarations,
  with no assertion before clean cancellation; local credential refusal is
  explicitly not native proof. The final actual-pin candidate still needs
  independent exact-tree approval and ordinary branch/queue native gates.

- 2026-10-02 UTC: author and reviewer separately downloaded all three
  assets of immutable release `402035640`, tag
  `next-c6e5966d48ccafa7c5f509a8ecb8a87e6d61ec7d`. Binary asset `606163036`
  is15228976 bytes, SHA256
  `dfbe3401dd5c8a543e9d0f412f1ff3ac84e723da197768c2e2d0e0a18b9654c8`.
  SHA256SUMS asset `606163082` and source.json `606163100` match metadata,
  binary and source. Both checked tag/required ancestry, publisher
  `37043593175` attempt1/job `110959411144`, actual source CI `37043438754`
  and same-commit queue reuse `37041999545`. Four separately downloaded
  native products and executed-byte attestations equal the released binary.
  Both executed downloaded APIs; local ENOSYS/EPERM/noexec refusal are
  recorded honestly and do not substitute for native consumer proofs.

- 2026-10-02 UTC: final C7 published as `7a56246a`, exact independently
  approved tree `4e8b93a0`, preserving checkpoint and actual C6 parents.
  The only source delta from approved preparation is the verified three-line
  pin. Author and independent reviewer each passed78 CI and60 root cases.
  Fresh actual-pin boot reused518 parses/504 compiles; whole663 root/63 CI
  checks and supported-path formatting pass. Full30 exits124 without an
  assertion before cancellation. TODO queries completed:21 entries/6 files,
  including two updated/relocated follow-ups and19 inherited; exactly one
  literal pin dependency remains. Actual-pin parent/final cold/warm vendor
  checks preserve12 keys/1354 files, with raw manifests retained. #2586 is
  ready, auto-merge enabled only through required branch/queue CI. Native
  root runner, credential, Linux noexec and Darwin flush proofs remain gates.

- 2026-10-02 UTC: C7 branch `37045199979` passed macOS and checked,
  but all three Linux legs failed the required root-runner proof at
  `ci/run_local.tl:141` with EACCES. Native suites and all eight credential
  API proof modes passed first. `Proc.relaunch` supplies the physical cached
  core path, whose root-owned0500 file/private parent cannot be executed
  after dropping credentials; handed descriptors alone do not grant path
  access or executable mode. This is a real root-runner integration issue.
  A separately reviewed consumer-only correction will grant one read-only
  runtime copy per credentialed invocation, retain the same artifact and
  startup identity checks, and clean up under the existing cancellation
  guard. Ordinary unprivileged runs do no staging. Root cache permissions,
  native proof and merge gates remain unchanged; no blind retry.

- 2026-10-02 UTC: independently reviewed C7 correction published as
  `1ab64010`/`e5356823`, parent `7a56246a`. Only the runner, its tests and
  native proof change. Credentialed root invocations copy the3,212,656-byte
  actual native core once in64KiB chunks into root-owned0711 scratch with
  a0555 executable; all probes reuse it. The copied core's descriptor and
  executable inode agree; original artifact/database/startup metadata and
  cached relaunch tables are preserved. Normal unprivileged runs do no
  staging. Cleanup remains inside the cancellation guard. No zero-cost claim,
  shared-cache permission change, new API or pin change.
  Author and reviewer each ran all19 focused tests, including actual copied
  core startup, descriptor/cache preservation, read-failure and cancellation
  cleanup. Native proof additionally checks target access/nonwritability,
  one-copy reuse/removal and unchanged original cache. Fresh boot, formatting,
  root663/CI63 whole checks pass; full30 exits124 without assertion after
  clean cancellation. Exact changed-path TODO query finds only the retained
  state-pruning follow-up, now `ci/run_local.tl:112`; none added. Required
  native root success and branch/queue checks still gate automatic merge.

- 2026-10-02 UTC: C7 merged at18:46:10UTC as `8f43b4d7`, exact
  reviewed queue tree `560056cc`, parent `1eb04d80`. Corrected branch
  `37047803289` and queue `37048258849` passed all required gates.
  Linux x86/ARM/Alpine each ran all3397 native tests without skips and
  passed all eight credential modes plus the real root-runner proof. Held
  launcher-noexec fixtures actually ran on both architectures. Darwin ran
  all3397 with only three expected Linux-only noexec skips, exercising full
  flush and empty/nonempty patch publication; checked ran all3397 unskipped.
  Incoming #2587 compiler hints, #2588 statistical gates, #2589 Fs/build
  docs/acknowledgment and #2566 structural decoder are preserved. Two
  independent reviews verified exact patch parity and compatible startup
  selection/digest/length/inode semantics. Sixteen API production PRs merged.

- 2026-10-02 UTC: D1 now audits a narrow documentation correction aligned
  after actual C7 merge. Incoming patch/tl inputs make the older C6-to-C7
  vendor receipt historical rather than final-input evidence. Independently
  approved bounded adjustment: retain two fresh same-D1 source/build trees
  and their cold/warm full manifests, plus one source-only checkout of actual
  C7 first parent materialized cold with the identical verified C6 bootstrap.
  Require unchanged vendor/patch inputs, compare complete keys/names/bytes/
  modes against final A, and stop on unexpected input deltas. No parent
  bootstrap build, warm repeat, broad API suite or new benchmark is needed.
  Retain raw identities/manifests, treat timings as diagnostic and keep C3's
  explicit deferral. Reference #2521 remains open/draft/unmerged/auto-off.

- 2026-10-02 UTC: D1 #2590 published at `b064b895`, independently
  approved tree `94fd94f9`, parent actual C7 `8f43b4d7`. Only the roadmap's
  stale Shape/JSON adoption claim and unused link definition change (+5/-7).
  The initial docs audit caught that unused definition; its initialization
  logs remain separate. The final audit uses corrected source `632c91eb`
  in two fresh checkouts, both on the actual verified C6 bootstrap.
  Each reused519 parses/505 compiles with zero new, staged654 files; root665
  and CI63 checks passed. Each ran30 identity/writer/cache cases, then stood
  on all30 in a warm repeat with zero compilation/parsing/staged reads.
  Declared-key hashing separately read6/8 inputs. All three executable/
  projection/carried artifacts match across four snapshots; six readonly
  DB quick_checks passed. Final A/B and actual-parent vendor outputs match
  all12 keys/1354 files, names/types/modes/bytes; final warm metadata and
  maps are unchanged. A separate reviewer rehashed artifacts, all retained
  vendor trees/manifests and repeated readonly DB checks.
  Exact TODO queries:0 changed,216 repository entries in109 files,1 pin
  dependency (deferred syncfs). Full30 exits124 after3397 keyed tests,
  no assertion before clean cancellation; it is not a full-suite pass.
  Preservation/determinism evidence is not a speedup claim. D1 is approved
  for required green branch/queue auto-merge; reference #2521 stays unmerged.

- 2026-10-02 UTC: D1 merged at19:13:37UTC as
  `437ecf40f4c5b74187ebe00ee8f4dd55d0ca2363`, exact independently audited
  tree `94fd94f99680c1f0cf212bc4d8f11c87a2ff6d2b`, sole parent actual
  C7 `8f43b4d751da5635b9902ee89e94ea2e4603467e`. Branch `37051449851`
  and queue `37051743944` passed every required platform and aggregate
  check. No incoming source change moved the audited endpoint. Independent
  Git and GitHub merge receipts agree. All selected API implementation and
  consumer steps plus final audit are complete: sixteen production PRs plus
  D1, following the ten completed original build-system PRs. C3 remains an
  explicit evidence-based deferral, with the experiment closed unmerged and
  current fsync behavior retained; unrelated follow-ups remain named TODOs.
  #2521 was verified open, draft, unmerged and auto-merge off, and stays the
  living reference. No further implementation or validation gate is pending
  for the selected roadmap.
