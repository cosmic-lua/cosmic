# Build-facing API roadmap

Planning snapshot: `9ac37cba3b2d626b79d7c217329b2020d76bccb6`, the final build-simplification queue tree. This is a new implementation series; the completed build reference remains separate. Keep this plan on the same never-merge draft PR #2521 and update its ledger as actual API names, release boundaries and validation settle.

## Objective and boundaries

Resolve the eleven pin-dependent workarounds identified by the build review, implementing the capabilities actual consumers need and correcting assumptions disproved by review. Include the related cancellable SQLite busy wait and macOS storage flush. Preserve public compatibility, warm build/cache behavior, failure cleanup and independently verified publication. This is not a general error framework, new task runtime, cache-policy redesign or wholesale shell elimination project.

All runtime spans are nanoseconds. Convert at raw interfaces that still count milliseconds; SQLite PRAGMA busy_timeout and sys.flock remain such interfaces. Elapsed_ms reports and workflow epoch-second cache cutoffs retain their separate units.

Repository contracts require an existing fallible public API to return exactly `(value, string)` or `(boolean, string)`. A code added as a third result, or a record replacing the existing reason, is incompatible. Where callers need machine-readable outcomes, add a concrete operation result record returned as one value; retain existing convenience functions and their behavior. Do not add a generic Result type or diagnostic-text parser. Programmer errors still raise; operating failures are results. Preserve the recent error-prefix and argument-validation conventions.

No standalone bootstrap or CI consumer may call a new API until ci/cosmic-driver.pin names a downloaded, digest-verified, executed release containing it. Each pin advance rechecks every literal pin-dependent TODO, not only this plan's list. Include every item the selected release unblocks. Existing source-tree consumers may migrate with their API. Keep existing convenience wrappers on the shared implementation. The public-export rule requires a caller outside the module or a runnable standard-library worked example; an internal wrapper alone does not earn an API. Use a meaningful source-tree consumer where available, otherwise document the intended typed classification in a runnable example under the existing rule. Do not invent dummy callers, compatibility casts, or export-check exceptions to make an unused API pass.

## Sequence

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
| C7 | Verified release and remaining consumers | C1/C2/C4–C6 published; C3 decision recorded; resolves four remaining pin dependencies |
| D1 | Final API/build audit and documentation | All preceding PRs merged |

Preparation can overlap on disjoint files. Publish serially against actual merged main. If a sensible reviewed slice can land earlier, split it and update this table before implementation; do not combine unrelated new C mechanisms merely to reduce PR count. Release waves avoid repeated pin churn while keeping each consumer transition reviewable.

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

Add a narrow `Test.needs { noexec = true }` capability with one documented writable scratch location supplied by the harness (provisional `$COSMIC_TEST_NOEXEC`). Keep normal scratch executable. Provide a private tmpfs at the fixed sandbox path `/noexec`, with no host-backed executable alias, and corresponding narrow noexec mount support inherited by descendants; all declaration parsing, effective inputs, key material, host capability and worker environment paths must agree. A changed policy bumps the harness epoch and updates acknowledgments.

Prove writing and reading succeed there while executing an executable file fails with EACCES; prove normal scratch still executes and escaping through a bind/symlink cannot turn the declared directory executable. Probe native execution refusal at the actual worker identity only for requesting modules; include the effective grant in keys and scrub the reserved environment variable when not granted, even under wildcard environment declarations. Unsupported hosts count a clear skip with no cached verdict where permitted and fail held-sandbox runs; never substitute an executable directory or disable ordinary sandboxing because this optional grant is unavailable. C7 migrates the noexec launcher fixture to the declared capability, removes broad environment/host-mount discovery, and preserves native macOS coverage according to its supported sandbox contract.

## Release waves, reviews and acceptance

A4, B5 and C7 each name the exact green release SHA and verified asset digest, inventory all pin TODOs, execute the selected binary, and exercise both standalone bootstrap and separate CI project. Never merge an API consumer first and hope a later release repairs the pin. Each API PR has an implementation agent and a different adversarial reviewer; changes to C identity/signal/mount behavior need an independent security/lifetime review. Root verifies exact tree/SHA and green required branch/merge-queue checks before auto-merge.

Run AGENTS formatting/type/whole-tree gates, appropriate focused tests and the required 30-second full-suite attempt. Core changes build native/checked/all release targets and run allocation tests. Fixture changes require run-local plus remote unprivileged/native/sandbox fixtures. Record local namespace/UID/socket limitations without weakening tests. Keep performance evidence on identical-source checkouts: warm zero compiles/reads, fresh shared-cache reuse, exact artifact equality across matching trees, unchanged cache-hit paths, and targeted syscall/throughput measurements for changed hot operations.

D1 verifies all nine groups/eleven pin TODOs and both related waits/flush needs are either implemented and migrated or explicitly re-scoped with evidence. Check command help, API docs, contract exemptions, public export allowlist, pin, CI and comments together. Run integrated lock/cancellation/cache/durability/noexec scenarios and retain the plan as a living reference. Report remaining unrelated TODOs without treating them as unfinished work in this series.

## Concurrent source changes

PR #2543's codec and Stream.transform changes are already included in 9ac37cba. PR #2544 inspected at a6c6ce32 renames Reader.read's max argument to max_bytes across stream/HTTP/child/net/archive surfaces and updates child validation wording and harness acknowledgment. It merged as 7f35550d and does not remove the sticky guard cancellation in Child.pipe_reader, so B2 remains necessary. Preserve max_bytes and incoming acknowledgments. Do not reapply either external API cleanup under this roadmap.

## Execution ledger

| Step | Implementation PR | State | Evidence |
| --- | --- | --- | --- |
| A1 | [#2545](https://github.com/cosmic-lua/cosmic/pull/2545) | merged | 338a8e25; reviewed tree ef80637e; branch 36955108004 and queue 36955383885 green |
| A2 | [#2546](https://github.com/cosmic-lua/cosmic/pull/2546) | merged | 143b9926; reviewed tree f1a68e18; branch 36956411363 and queue 36956779031 green |
| A3 | [#2550](https://github.com/cosmic-lua/cosmic/pull/2550) | merged | b951ab95/tree02802767; incoming Stream retained; branch 36957749478 and queue 36957951958 green |
| A4 | [#2552](https://github.com/cosmic-lua/cosmic/pull/2552) | merged | 3511e6cd/tree0c00b3b3; branch36959640308 and queue36959944853 green; verified release and four consumer migrations complete |
| B1 | included in B2a | scope corrected by independent review | Recipient scope cannot be inferred; preserve behavior and explain policy, no speculative public API |
| B2a | [#2554](https://github.com/cosmic-lua/cosmic/pull/2554) | CI running | 20569b76/tree5fd49ed6; exact reviewed patch on actual A4; incoming acknowledgments retained; auto-merge enabled; epoch13 |
| B2b | pending | locally approved on A4/B2a | 3a2a6c6e/tree3ed45698; incoming #2551 preserved; 124 related and 45 independent integration tests passed; epoch14 |
| B3 | pending | locally approved on A4/B2b | 7aa69c15/tree2093cb5d; 90 native, 53 checked and 17 independent integration cases pass; only the combined SQLite acknowledgment changed |
| B4a | pending | locally approved | 6d1d3232/tree9f54b268; native/checked lifetime and default compatibility reviewed; special SQLite paths retain their existing behavior |
| B4b | pending | local preparation | Command follows B4a; conservative file retention, format ownership and independent dispatch |
| B5 | pending | planned | Independent design review completed; implementation and exact-tree review required |
| C1 | pending | locally approved | 668ef813/treed5981b64; independent native/checked allocation and concurrency review passed; publication after B5 |
| C2 | pending | locally approved | 6345c513/tree789e747a; independent native/checked review passed; actual Darwin execution remains a CI gate |
| C3 | pending | measurement-gated; API held | Overlay benchmark found no demonstrated benefit; prepare a small disk-backed CI diagnostic before deciding whether the API/consumer should ship |
| C4 | pending | locally approved | 73ae44e0/tree1a99265a; independent native/checked allocation, bounded growth and account-service failure review passed; publication after B5 |
| C5 | pending | exact-candidate review pending | 08a1d96c/treea28a267e; local native/checked/analyzer checks pass; actual privileged CI proof required |
| C6 | pending | local preparation | Private noexec tmpfs and declaration/keying design reviewed; native sandbox CI proof required |
| C7 | pending | planned | Independent design review completed; implementation and exact-tree review required |
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
  This makes seventeen implementation/migration PRs plus D1's final audit.
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
