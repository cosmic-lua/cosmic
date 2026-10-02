# Explanatory and transformable artifacts

This is a reference plan, maintained on a **draft PR that must never merge**.
Implementation lands through separate, sequential PRs. Keep this document and
its execution ledger up to date as evidence changes the design. Do not enable
auto-merge, mark ready, or merge the reference PR.

The goal is a Cosmic executable that can explain its contents and derivation,
and a small set of operations that can produce another valid executable from
it. Inspection must work without executing the inspected program or adding
its modules to the inspector's loader. Transformation must preserve the
performance, reproducibility, and precise cache boundaries already earned by
the build system. Increased artifact size is acceptable; runtime performance
regressions are not.

## Scope and observable results

At completion, a Cosmic tool can open two artifacts simultaneously, including
an artifact for another target; inspect their source, declarations, references,
dependencies, licenses, and derivation facts; explain why a module is included;
and compare their meaningful contents. It can project explicitly selected roots
from compatible inputs into a validated artifact through the same machinery
used by existing project, carried, application, and test-closure writers.

An application can retain the metadata that makes Cosmic itself inspectable.
Readers distinguish missing retained information from an empty answer. They
distinguish structurally readable artifacts from executable, compatible ones.
Composition accepts identical duplicate providers and rejects conflicting ones
with a useful explanation. Every required runtime edge of a standalone output
is satisfied, including any explicitly declared dynamic dependency set.

This plan does not implement a package registry, arbitrary stack persistence,
runtime state migrations, captured-process replay, application dataset APIs, or
mutable executables. It does not claim that matching signatures prove behavioral
compatibility, that a content digest authenticates a publisher, or that passing
tests establish properties outside their declared inputs and execution scope.

## Starting evidence and things to remeasure

The implementation baseline is `origin/main` at
`a08b16a2196e5d4ed8209be88ebe208ac3cf572e` (2026-10-02 UTC), refreshed after the
earlier assessment of `b951ab9`. Fresh reads at this baseline confirm:

- `core/vfs.c` registers one path, retained descriptor, offset, and length.
  Ordinary callers cannot supply arbitrary embedded-database offsets.
- `build/artifact.tl` splits an executable supplied as a complete string.
  `cosmic.store` describes the running loader's databases, not an independent
  inspection session.
- `build/writer.tl` retains imports only when their targets are in the plan.
  `build/schema.tl` stores neither import roles/providers nor import spans.
- `docs.id` is an insertion-assigned FTS rowid. `uses` has a line but no column,
  and its key collapses repeated same-line references.
- `bound(path, name, requires)` already retains qualifier bindings, including
  providers outside a project projection. Preserve this recent work and the
  qualified-type documentation behavior added in #2548.
- `writer.carried`, `embed.database`, and `closure_store.write` contain separate
  copying and retention policies. Some copies use `insert or ignore`.
- `build/work.tl` has working-schema version 27; the shipped schema has fixed
  reproducibility settings but no explicit application/schema version contract.
- SQL hash/compression functions are registered with `SQLITE_DIRECTONLY` in
  `core/sqlite.c`; stored views cannot simply invoke them.
- Closure-store addressing deliberately separates writer/compiler identities
  from the bytes tests observe. A compiler edit producing unchanged closure
  contents need not rerun those tests. This is a requirement, not incidental
  implementation detail.

The earlier assessment reported measurements of a **pinned bootstrap artifact**,
not this baseline: approximately 5 MiB of SQLite data, 173 modules, approximately
2.94 MiB in `modules`, 64-byte hexadecimal digests stored as BLOBs, and full
scans for exact docs lookup, reverse imports, and outgoing uses. Four candidate
indexes occupied 188 KiB. A storage-only experiment with SQLite 3.53.1 reported
an ordinary rowid module table about 5% smaller, split source about 4% larger,
and separated metadata/code/source about 1.5% smaller. It also found duplicate
`(module, symbol)` groups. Those figures motivate experiments; they are not
fresh measurements or runtime evidence. Reproduce relevant findings on the
baseline and the pinned Cosmic SQLite before making a physical-layout decision.

The first fresh baseline boot completed, but subsequent own-tree commands met
corrupt working-database symptoms while the filesystem was full. That run is
invalid for performance evidence. Preserve diagnostics, recover space from
regenerable completed-work outputs, then perform a fresh boot and rebaseline.
Do not report this environmental failure as a confirmed defect in main.

A clean worktree at `8e4a899230c24ddd90a52d00be2abd3375dfd546` subsequently
booted and answered own-tree documentation queries with a valid 29.7 MB working
database and no rollback journal. The earlier corruption's exact cause remains
unproven. The execution baseline is the published release for this exact commit:
14,995,504 bytes, SHA-256
`6b0484154389a4b603b9c1021f5be3eca9055c6b753f56c81a6afbbd3042272d`.
The harness retains independent copies and hashes before measurement.

The first valid harness reading guards warm-cache fixture workloads. Cold I/O,
peak RSS, isolated projection latency, generated artifact page counts, and full
repository execution remain separate evidence requirements. Do not describe the
fixture's two-test execution as a measurement of the complete repository suite.

## Architecture decisions

### Three independent responsibilities

1. **Artifact handle:** owns a validated immutable file descriptor and ranges,
   exposes read-only structural/database access, and has an explicit lifetime.
2. **Runtime store:** holds the databases from which the process may load code
   and the trusted mapping between native bindings and their wrappers.
3. **Projection workspace:** reads selected artifact handles, builds a fresh
   writable database, validates it, and publishes a new file atomically.

An inspection handle confers no module-loading or raw-binding authority.
Closing it, collecting it, replacing its pathname, or opening another artifact
must not redirect an existing connection. Multiple handles can be attached to
one query connection for joins, with collision-free opaque registrations and
ownership that outlives every SQLite consumer. Public APIs accept validated
handles, not caller-invented descriptor/range URIs. Reads are bounded by the
validated range, including short reads, overflow, and malformed headers.

An externally opened artifact must remain unchanged in place for the handle's
lifetime. Retaining its descriptor protects rename/unlink identity, not against
writes to that inode. A mutable input requires an explicit snapshot before it
is treated as immutable.

Structural decoding must enumerate cores without requiring a core matching the
host. Execution selection performs that separate compatibility check. Share the
decoder/invariants rather than proliferating slightly different C and Teal
parsers. Preserve native and portable startup behavior and retained-descriptor
protections, including the test-worker restrictions in `core/check.h`. Descriptor
checks alone are insufficient: reopening the runtime by path, a registered VFS
URI, inspection queries and SQLite attachment must all respect `Store.hold` and
the worker's declared `store`/file capabilities, including unsandboxed workers.
Exercise those boundaries across handle close, collection and reattachment.

### Authoritative facts and derived indexes

Retain imports as facts about source and resolution, even if a projection omits
the provider. Preserve importer, requested name, role, source span, resolution
status, resolved provider, and provider identity. A type-only dependency is not
a runtime dependency. A declaration's dependencies and the `bound` relation
remain available to checking and explanation.

Model roots and policies explicitly. A project database may depend on a named
runtime provider; a sealed standalone artifact must resolve its required runtime
closure. Dynamic/indirect requires must be detected where analysis can detect
them and represented conservatively. Closed projection either has an explicit
complete provider set or fails with a location and remedy. It must never trim
on the unsupported assumption that literal imports are the complete graph.
A declared dynamic provider set is an author-supplied contract bounded and
enforced by projection/runtime policy, not proof that arbitrary Lua indirection
has been analyzed completely. Existing broad application inclusion can remain during rollout while the new
sealed policy is proven; the final implementation must support safe root closure.
Do not switch every graph consumer to runtime-only edges: checking/compiler,
writer, harness and test closures have different existing semantics. Keep a
conservative legacy relation while consumers migrate individually.

Give declarations identities distinct from physical FTS rowids. Identity must
include module, scope, declaration kind, and a deterministic distinguishing
component when the language permits repeated declarations. Exported names are
bindings to declarations. Do not impose `unique(module, symbol)`. Define what
stays stable across row reordering and unrelated edits; do not promise identities
survive every rename or scope restructuring. Do not use line numbers or source
digests as cross-release identity. Anonymous/repeated locals use explicitly
occurrence-scoped identities when a stable language identity is unavailable.
References retain occurrence spans
and kinds. Documentation links and qualified type bindings retain their current
meaning. Text mentions, resolved references, and observed example executions are
different relations, not interchangeable evidence.

Use natural-key relations where they express identity; retain integer rowids for
FTS external-content joins. Rebuild FTS in canonical order after authoritative
rows are copied. A projection that intentionally omits analysis declares that
capability absent instead of silently presenting an empty complete graph.

### Identity and cache boundaries

Keep distinct:

| Identity | Meaning and consumers |
| --- | --- |
| Derivation | Recipe, source and resolved inputs, compiler/analyzer identity; explains and invalidates derivations |
| Content | Precisely specified canonical observable contents; semantic comparison and existing closure/verdict reuse |
| Artifact bytes | Digest of the complete physical artifact; transport, exact reproduction, external evidence association |

Define serialization and domain separation for new identities, including absent
versus empty values and embedded NULs. Never concatenate ambiguous fields. Do
not introduce a self-referential whole-file digest stored inside that same file.
Standardize digest representation as raw bytes internally and hexadecimal at
text interfaces where compatible; migrate every producer, reader and cache
boundary together rather than changing a cast in isolation.

Retain source origin and generation relationships already present in working
`derived` records. Preserve enough structured compiler/input/resolution facts to
explain a derivation digest. Deterministic build facts belong in the artifact;
timestamps, runner state, and later test observations do not. Define external
evidence association by identity and scope without making it a new mandatory
CI service or making build outputs depend on the most recent CI execution.

Adding provenance must not turn every metadata edit into a runtime or verdict
invalidation. Preserve selective compiler readers, worker store restrictions,
declared inputs, table digests, harness epochs, and the distinction between a
closure-store address and its actual byte digest. When observable retained
contents change, invalidate exactly the consumers allowed to read those contents.

### Schema contract and projection

Assign a documented `application_id` and shipped `user_version`; use metadata for
runtime/bytecode compatibility, roots, provider requirements, and retained
capabilities. Keep outer framing version, database schema version, and runtime
compatibility separate. Define an explicit reader range and unsupported-version
errors. Legacy version-zero inputs get a narrowly identified reader path with
facts marked unknown; a random SQLite database is not a legacy Cosmic artifact.

Expose a small versioned query contract independent of physical layout. Start
with reader-owned queries or temporary views over vetted tables. Decompression
and direct-only functions remain explicit top-level reader operations; do not
weaken `SQLITE_DIRECTONLY` or trust supplied schema code for convenience. Inspect
with read-only connections, conservative SQLite configuration, no extension
loading, and only the expected schema capabilities.

One projection implementation accepts inputs, roots, dependency policy,
retention policy, and required output capabilities. It resolves, selects, copies,
indexes, validates and seals. Policies are explicit ordinary code, not a new
configuration language. Share copying primitives without salting unrelated test
keys with the whole build tool's implementation closure.

Identical module duplicates can collapse only after comparing the relevant
identity/content contract, including source/docs facets that retention exposes;
matching bytecode alone does not establish an identical duplicate. Conflicting names fail with both providers identified.
An explicit existing precedence rule must be represented and explained, never
smuggled in through `insert or ignore`. Metadata cannot grant trusted native
binding authority. Full validation runs at sealing/explicit verification;
ordinary startup keeps cheap checks and lazy reads.

## Performance and verification gate

Step 0 establishes a reusable harness and archived raw observations. Every PR
uses the same parent/candidate method, with additional workloads appropriate to
the changed code. The coordinator owns the measurement window: no parallel
builds, test suites, fuzzers, or benchmarks in any agent worktree. Agents may
read/review source during a window. A disturbed run is discarded with its reason.

1. Record full commit and artifact hashes, target/configuration, bootstrap pin,
   compiler and SQLite versions, host/kernel/CPU, cache mode, and command lines.
   Boot parent and candidate worktrees before timing; verify neither command can
   trigger an automatic build. Compare the same optimized target/configuration.
2. Run an A/A calibration using identical parent artifacts under separate labels.
   Use at least 30 paired observations per microbenchmark after warmup; batch
   submillisecond operations within a sample. Calibrate process/timer overhead.
3. Run alternating paired A/B and B/A observations, retaining raw timings,
   medians, p95, paired changes and uncertainty. Avoid all-parent then
   all-candidate ordering. Repetition and batch sizes are fixed before reviewing
   candidate results. Do not choose favorable subsets or average away a tail
   regression. Extend only to resolve a concrete noisy/inconclusive comparison.
4. Measure process startup with a minimal native `-e ''` command and portable launcher
   (not a version command that hashes the whole artifact),
   first module load and a representative dependency closure, exact symbol
   lookup, reverse imports/outgoing uses, projection, application packaging,
   no-op/incremental rebuild, and warm/full test execution. Initially missing
   reader/query workloads are added when their APIs exist. Record peak RSS and
   size/page counts separately from latency.
5. Fail workload command errors and incorrect counters independently of timings.
   Distinguish warm page cache, fresh process, fresh build/cache, and genuinely
   cold filesystem measurements. A fresh process is not a cold page cache. Use
   only supported reproducible cold-cache controls; otherwise report cold I/O as
   unmeasured and obtain a supported runner before claiming it is guarded.
6. Establish the practical resolution from A/A observations and publish it. A
   repeatable candidate slowdown beyond that noise band blocks merge. A wide
   interval is inconclusive, not a pass. There is no blanket allowed startup
   regression percentage. Resolve noise on a stable runner, fix the regression,
   or revise the implementation. Size growth is reported but does not block.
7. Repeat against the original step-0 baseline at steps 7, 10, and 13 so small
   cumulative losses cannot disappear in successive parent comparisons.

Use the repository's prescribed full-test measurement: remove only `verdicts`
rows from `o/build.db`, set `COSMIC_VERDICT_CACHE=0`, preserve staged inputs,
and report ran/stood/skipped counts. Do not confuse a cached pass with executed
coverage. Keep correctness tests out of the timing loop. New parser paths get
seeded fuzz properties and corpus regressions as `AGENTS.md` requires; core
changes get allocation-failure coverage and sanitizer/static-analysis coverage.

Before each implementation PR: boot the fresh worktree, format changed paths,
run focused meaningful regressions, `timeout 30 o/bin/cosmic test`, and
`o/bin/cosmic fix --check .`. Investigate a timeout rather than increasing it
silently. Run `ci/run-local` for startup, artifact-format, launcher, or fixture
changes, and the prescribed `ci/` checks when that tree changes. Required remote
CI and merge queue remain the final gate, including actual target coverage.

## Execution and release discipline

For each step, start from newly fetched merged `origin/main` in a fresh worktree.
Assign implementation and adversarial review to different agents. The reviewer
must inspect the resulting diff, challenge authority/lifetime/cache assumptions,
and propose failure cases rather than only repeat the author's tests. Fix all
blocking findings, then have the reviewer inspect the fixes. If code changes
after review or measurement, rerun the affected gate on the actual proposed head.

Open a separate implementation PR with the problem, resulting behavior,
validation, baseline/candidate measurements, and all introduced `TODO:` entries
from `o/bin/cosmic todos <changed-paths>`. Enable auto-merge only on reviewed
implementation PRs, monitor required CI/queue to actual merge, and repair failures.
Do not begin the next implementation against an unmerged predecessor. Update
this reference PR's ledger after each merge and whenever a split/order changes.

The bootstrap pin is a real boundary. Land new core capabilities with tests and
without requiring them in bootstrap-executed Teal until a published verified
release supplies them. Where a transition adapter is necessary, leave a precise
`TODO:` naming the release/pin prerequisite. Advance `ci/cosmic-driver.pin` only
to a real published artifact with verified identity, then remove every workaround
that pin unblocks, as `AGENTS.md` requires. Never point a permanent pin at a local
binary or assume the current tree is what bootstrap/CI runs. Use explicit
`COSMIC_BOOTSTRAP` only for controlled bootstrap validation, not to hide a broken
normal bootstrap. If a release is an external blocker, record its exact state and
continue only independently valid work; do not mark dependent goals complete.

## Sequenced implementation PRs

The numbered sequence is the execution order. Dependencies name technical
requirements so an unexpected release delay can be handled explicitly. Each
step includes its acceptance criteria; splitting a step is allowed if its
acceptance criteria and ledger remain complete.

### 0. Baseline and reproducible performance harness

Inventory existing benchmarks and add the smallest repository-native extension
needed for paired measurements. Record the baseline artifacts and fixture
definitions, fresh query plans and duplicate declaration cases. Keep generated
timings out of source unless a concise checked-in fixture/result is intentional.
Publish raw measurements as PR/CI artifacts with stable identifiers.

Acceptance: A/A calibration and initial A/B smoke comparison complete without
concurrent workloads; commands demonstrably exercise the stated paths; baseline
startup, require, packaging, rebuild, test and size results recorded. Reviewer
checks that cache hits and auto-rebuild do not distort the measurements.

### 0.5. Close the existing runtime database reopening capability

Read-only preparation for independent artifact handles confirmed that the
runtime VFS registration can currently be reused by raw SQL after `Store.hold`
has denied a module read. Repair this before adding new inspection capabilities.
The reviewed design consumes the trusted registration after a successful VFS
open copies its validated descriptor/range into the SQLite file; existing file
ownership stays unchanged. No pathname or URI becomes a reusable capability.

An independent reviewer accepted the design. Required regressions include the
actual raw-SQL reopening attempt, repeated attempts, successful attachment of a
test-owned ordinary database, authorized/denied store reads, host and portable
startup, descriptor lifetime, rename/unlink behavior, and refusal of supplied
offset parameters. Explain any harness-epoch decision against the runtime/core
identity already present in verdict keys.

The assigned implementation agent was stopped by an automated cybersecurity
check while preparing this step. No implementation changes were made, and the
blocked action has not been retried through another agent or mechanism. This
prerequisite is unresolved; the remaining architecture series must not be
reported complete. The user has authorized proceeding with independent work.
Step 1 changes only parsing and host-selection factoring; it neither retries
this blocked action nor adds access to databases. Step 2 remains gated on 0.5.
Later schema-only changes may be split out after their independence is reviewed
and this dependency map is updated explicitly.

### 1. Structural artifact decoder independent of host selection

Factor validated framing/range/core enumeration from host/configuration
selection. Support both currently accepted native and portable shapes, preserve
their errors and startup selection behavior, and eliminate redundant parsing
where practical. Dependencies: 0.

Acceptance: inspect a valid artifact without a matching host core; reject
truncated/overlapping/overflowing ranges and malformed records; retain startup
and descriptor invariants. Add meaningful fuzz labels, failure corpora and CI
fixtures across supported formats/targets. Startup A/B and `ci/run-local` pass.

### 2. Independent read-only artifact handles and multi-attachment

Introduce ownership-safe descriptor/range handles and read-only SQLite access
without registering modules. Allow two independent artifacts to be attached to
one query connection. Keep the running store's path separate. Dependencies: 1 and 0.5.

Acceptance: join rows from two different artifacts, open the same file twice,
close handles in different orders, collect an owner while consumers remain,
replace/unlink paths after open, and exercise open/close/allocation failures.
No stale registration, use-after-close, descriptor leak or module shadowing;
held test workers cannot recover omitted store contents by reopening the program
or attaching an artifact URI, on either sandboxed or unsandboxed runs;
untrusted path/range inputs cannot expose the running artifact or escape worker
read restrictions. Startup/load A/B and relevant sanitizers pass.

### 3. Versioned shipped schema and compatible reader contract

Add format identification, database version, compatibility facts, roots/provider
requirements, and retained-capability metadata. Expose the minimal supported
reader query surface, including legacy identification and explicit unknowns.
Connect an existing inspection command to the handle so the API has a real
caller. Dependencies: 2 and any required release/pin handoff. Implement the reader/version recognition
before switching producers; incompatible old readers must reject the new format
clearly rather than guessing its columns. Validate old/new driver and produced
artifact combinations before activating the writer.

Acceptance: new reader handles current and narrowly identified legacy inputs;
unknown newer schema and incompatible execution have distinct useful errors;
foreign valid SQLite is refused as an artifact. Inspection works for a target
that cannot execute locally, does not evaluate hostile views/triggers, and does
not weaken direct-only SQL functions. Existing startup remains cheap. Document
reader/writer/runtime compatibility separately and test the bootstrap matrix.

The independent review identified this delivery split:

- **3a, recognition (requires 0):** a small reader accepts an already-open
  SQLite handle and recognizes a narrowly supported legacy shipped layout,
  the working database, unrelated SQLite, or an unsupported marked version.
  Its first consumer is the existing `cosmic db` command. Inspect schema
  metadata and required column contracts without evaluating supplied views,
  generated expressions, or triggers. Do not change generic `sql --db`, open
  executables, or add startup queries. Focused fixtures cover each category,
  missing relations, and malformed contracts; measure inspection latency.
- **3b, additive identification (requires 3a):** stamp the current compatible
  shipped layout with documented `application_id` and `user_version` values.
  Existing writers state output kind and what analysis they actually retain;
  an empty retained relation differs from omitted information. Cover project,
  carried, application and closure outputs, deterministic `VACUUM INTO`, old
  pinned drivers, and closure identity calculations. Measure packaging and
  repeated projection; report the one-time cache refresh separately.
- **3c, complete artifact integration (requires 2 and 3b):** independent
  executable inspection and runtime compatibility enforcement remain gated.
  Old binaries ignore schema versions; additive version-1 metadata cannot
  retroactively make them reject a future incompatible format. Original
  step-3 acceptance remains open until this integration lands.

Proceed with 3a and 3b after step 1, as separate reviewed PRs. This changes
sequencing only where the work is independent of the blocked access capability.

The reviewed 3a entry point is `cosmic db --format`, a metadata-only mode.
It must bypass dispatch's ancestor-tree discovery as well as the command's
stale/rebuild, module-discovery and ordinary reporting paths. Ancestor discovery
itself queries `files`; ordinary reporting evaluates table counts and `dbstat`.
Preserve caller-relative paths, and prevent dispatch's usage-error fallback from
starting a rebuild. Exercise this through real CLI dispatch from a subdirectory.

Read fixed `main.sqlite_schema` queries and `PRAGMA main.application_id` /
`main.user_version` on an ordinary already-open SQLite handle. Borrowed runtime
store handles deny these header queries; report that denial as an error and
leave their authorizer unchanged. Do not use `table_list` or `table_xinfo` as a
first filter: the pinned SQLite may initialize supplied views while answering
them. Match frozen canonical ordinary-table DDL for `meta`, `modules`, `imports`
and `decls`, including known production-writer forms. Unfamiliar equivalent SQL
remains unrecognized; do not introduce a SQL normalizer. A matching legacy base
layout establishes neither producer authenticity nor complete integrity or
metadata retention. Keep working-database recognition separate. Required-name
view/virtual-table/generated-column substitutions must fail recognition, while
unrelated schema objects must never be evaluated. Cover project, carried,
application and closure outputs, shadowing by temporary/attached objects,
foreign headers, future versions, malformed declared versions and query errors.

### 4. Lossless imports, provider resolution, and safe closure policy

Extend analysis, working storage and shipped storage together with edge roles,
spans, requested names, providers/identities and status. `Ast.all_requires` currently deduplicates names; extract occurrences
before deduplication instead of reconstructing facts from that result. Update
analysis schema, serialized parse records, shared-cache layouts and working
version together wherever their contracts change. Retain unresolved and
external edges; preserve `bound` and declaration dependencies. Record roots and
explicit dynamic dependency policies. Dependencies: 3.

Acceptance: project-to-stdlib edge survives projection; type-only edges differ
from runtime edges; cycles terminate; same-line imports preserve occurrences;
missing providers and computed imports produce precise diagnostics. A sealed
closed projection cannot silently omit a runtime provider. Test indirect forms
and builtin/special loader behavior used by the actual tree. Measure graph
derivation, no-op and incremental rebuild, and closure computation. Verify cold,
warm and shared-parse-cache paths produce identical complete facts.

A further independent slice is **4a, working import occurrences (requires 0;
execute after 3b)**. Preserve literal requested names, spans and type/runtime
roles before `Ast.all_requires` deduplicates them. Record supported computed
forms as unknown rather than falsely resolved. Keep `all_requires` ordering,
shipped imports, provider selection and closure behavior unchanged. Evolve the
analysis relation, working schema and shared parse serialization together.
Two imports on one line remain separate; comments and strings are not imports;
fresh/local/shared parsing produces identical facts. Avoid a second full AST
walk and measure parse misses, shared-cache hits, no-op and leaf-edit builds.
`sql --build` provides an existing consumer of the additional facts.

The remaining **4b** retains original provider/linking/shipped-store acceptance
and depends on completed 3c plus 4a. Completing 4a does not complete step 4.

### 5. Declaration identity, exports, and precise references

Separate declaration identity from FTS rowids, represent export bindings, and
retain scoped reference occurrences/spans/kinds. Evolve existing docs instead of
creating an overlapping symbol registry. Dependencies: 3; integrate 4's spans.

Acceptance: same display symbol for local record/export remains unambiguous;
two uses on one line survive; unrelated insertions and reordered input do not
renumber logical identities; qualified types, docs links and FTS search still
resolve. Examples distinguish mentions from resolved references. Projection
rebuilds FTS deterministically. Measure analysis and exact lookup.

### 6. Structured derivation and content identities

Retain source/generation origin, compiler/analyzer inputs, dependency providers
and projection recipe facts. Define canonical domain-separated identities and
digest storage, with the complete affected producer/consumer migration. Provide
an external evidence association contract without embedding variable run data.
Dependencies: 4 and 5.

Acceptance: explain which input/recipe fact changed a derivation; same output
under a changed compiler preserves content-based reuse; changed source/provider
or retained analysis invalidates the proper consumers. Verify source origins for
generated declarations/guides and absence of absolute build paths/timestamps in
deterministic outputs. Review closure, compiler-reader, table-digest and harness
keys adversarially. Measure incremental/no-op builds and verdict reuse counts.

### 7. Shared projection, validation, and seal primitives

Implement explicit selection/closure/retention/provider policies, canonical
copying and FTS rebuild, program validation, and atomic publication. Migrate the
ordinary project and carried writers first while holding behavior constant.
Dependencies: 4, 5, 6.

Acceptance: byte-identical repeated projections from identical inputs; relation
ownership and retention are accounted for; identical duplicate providers collapse,
conflicts fail without partial publication. Validation checks roots, required
runtime edges, retained reference status, capabilities and compatibility.
Injected failure leaves the previous artifact intact. Recompare baseline and
parent for packaging, no-op rebuild, RSS and startup.

### 8. Application and test-closure projection migration

Move application embedding and test stores onto shared primitives with distinct
policies. Applications support safe entry-point closure and retain requested
inspectable metadata, including licenses and error guidance. Keep test-store
identity and authority boundaries narrow. Dependencies: 7.

Acceptance: an application reports its own source/docs/uses and why selected
modules are present; omitted metadata is declared; cross-artifact composition
obeys provider and native-wrapper authority rules. Existing tests demonstrate
unrelated edits do not rerun unaffected closures, compiler-only changes with
identical outputs preserve reuse, and metadata a worker may read is keyed. Every retained new relation participates
in `closure_store.basis` or its replacement; every excluded provenance relation
is inaccessible to a consumer whose key excludes it.
Remove obsolete copy paths instead of maintaining two implementations. Measure
all four projection policies, application startup and full/warm tests.

### 9. Artifact inspection, explanation, and public queries

Extend existing source/docs/uses/BOM/SQL affordances with explicit artifact
selection through the reader; add the smallest coherent command for inclusion
and derivation explanations. Final command spelling follows existing CLI style
and is documented in its PR. Dependencies: 8.

Acceptance: investigate an executable in an empty directory with no checkout;
follow source span to reference/declaration, root-to-module inclusion chain and
generated origin; inspect two providers and a foreign-target artifact; render
missing capability as unknown/unavailable. Normal inspection runs no supplied
module. Query contracts have version/compatibility tests. Measure cold-open,
warm lookup, traversal and source decoding independently.

### 10. Semantic artifact comparison and transformation interface

Compare canonical contents through attached handles: modules/source/bytecode,
contracts/exports, runtime/type dependencies, origins, bundled data/components,
and retained metadata. Expose root selection and compatible-input composition
through the unified projection entry point with reproducible recipe output.
Dependencies: 9.

Acceptance: metadata-only, compiler-only/same-output, public contract, provider,
dataset and actual module changes produce distinct honest reports; unavailable
analysis stays unknown; diff ignores physical rowids/page layout. A composed
small artifact runs, can explain each included provider and can be reconstructed
from its recorded roots/policy and pinned inputs. No behavioral equivalence
claim comes from hashes/signatures alone. Benchmark joins/diff/projection and
repeat original baseline comparisons.

### 11. Targeted indexes and transfer optimization

Use real command query plans/timings to choose indexes for exact docs identity,
reverse dependencies and outgoing references. Benchmark SQL attachment/copying
and descriptor-range streaming against whole-file strings/row-by-row copying;
replace expensive paths where results support it. Dependencies: 10.

Acceptance: representative large fixture and actual Cosmic artifact show useful
latency/RSS improvements without startup or projection regressions; indexes
match real predicates and FTS still serves text search. Serialization and file
publication remain reproducible. Report index/storage cost without rejecting a
useful optimization merely for size growth.

### 12. Physical-layout experiment and justified implementation

Compare current modules layout, ordinary rowid storage, and separated compact
metadata/code/source using Cosmic's pinned SQLite, same inputs and settings.
Preserve bytecode-before-source behavior unless the measured alternative removes
its need. Mmap, prepared-statement caches and content-addressed blob storage
require independent demonstrated bottlenecks; do not add them speculatively.
Dependencies: 11.

Acceptance: record size/page counts, startup/load, metadata traversal, projection
latency and RSS for each candidate. Land only a layout with a demonstrated
workload benefit and no performance regression. If current layout wins, close
the experiment with evidence and retain it; completing this step does not require
changing storage. Update schema/compatibility and deterministic serialization
tests for any adopted change.

### 13. End-to-end adversarial audit, bootstrap cleanup, and documentation

Run the complete inspect/explain/compare/project workflow on native/portable
artifacts, legacy/current schemas, multiple providers, and at least one
non-host artifact. Exercise malformed metadata/format and worker authority
boundaries. Verify fresh bootstrap and published pin, remove obsolete adapters
and copying logic, and document supported contracts and worked examples in
normal repository docs. Dependencies: 12 and all release handoffs.

Acceptance: separate final reviewer audits retained information, schema evolution,
cache soundness, raw-binding authority, resource lifetime and cumulative
performance. Repeat step-0 workloads against initial baseline and final head;
all required CI is green; skipped/host-blocked tests are reported as such and
never counted as passed coverage; every criterion above is met or explicitly remains
open with its concrete blocker. The reference PR stays draft and unmerged with
the final ledger and links; it is not a vehicle to merge documentation or code.

## Dependency map

| Step | Requires |
| --- | --- |
| 0 | Baseline access |
| 1 | 0 |
| 0.5 | 0; execution-service block unresolved |
| 2 | 1, 0.5 |
| 3a | 0; execute after 1 |
| 3b | 3a |
| 3c (completes 3) | 2, 3b; release/pin if bootstrap calls the new API |
| 4a | 0; execute after 3b |
| 4b (completes 4) | 3c, 4a |
| 5 | 3 and span integration with 4 |
| 6 | 4, 5 |
| 7 | 4, 5, 6 |
| 8 | 7 |
| 9 | 8 |
| 10 | 9 |
| 11 | 10 |
| 12 | 11 |
| 13 | 12; outstanding release/pin handoffs |

## Execution ledger

Update each row with implementation PR/head/merge commit, separate reviewer,
correctness/CI result, raw performance evidence and conclusion, introduced
temporary gaps, and any plan change. A review or queued auto-merge is not a
merged step. The reference PR's own number is recorded here after creation.

Reference PR: [#2556](https://github.com/cosmic-lua/cosmic/pull/2556); **draft, never merge**.

| Step | Status | PR / merge | Review and evidence |
| --- | --- | --- | --- |
| 0 Baseline/harness | Merged | [#2563](https://github.com/cosmic-lua/cosmic/pull/2563), merge `c41d73db391fef74518ebb93e9cc05902e154ca2` | Separate code and raw-evidence reviews approved. Seven focused tests and 641-file whole-tree check pass. All push and merge-queue CI legs pass. Initial 14/15 readings pass; predeclared 100-pair packaging follow-up resolves the remaining uncertainty. Local full suite timed out during preparation; remote CI provides full correctness gate. |
| 0.5 Runtime VFS capability | Blocked before implementation | — | Reproduced on baseline; separate design review accepted one-shot registration. Implementation agent stopped by automated cybersecurity check; no retry or workaround. |
| 1 Structural decoder | Draft; performance blocks merge | [#2566](https://github.com/cosmic-lua/cosmic/pull/2566), head `40203127ca9f7ee4668eceb8e85bdec2cc11a9d6` | Independent code review approved local `1c091ee` (identical tree). All required push CI passed, including checked/Linux/macOS legs. Fifteen-workload measurements, five follow-ups and the final eight-invocation pinned crossover round are retained. Startup's cumulative paired median remains +0.036 ms, interval [+0.018, +0.051] ms; calibration/tail/noise issues also remain. The predeclared protocol stopped unresolved. No auto-merge or further discretionary local reruns. No VFS, store authority or new artifact-access changes. |
| 2 Artifact handles | Pending | — | — |
| 3 Schema/reader contract | Pending; split below | — | Original acceptance remains open until 3c. |
| 3a Existing database recognition | Planned independent work | — | Read-only dependency review complete; no new access APIs. |
| 3b Additive format metadata | Planned independent work | — | Reader-first rollout; existing compatible table layout. |
| 4 Dependencies/providers | Pending; split below | — | Original acceptance remains open until 4b. |
| 4a Working import occurrences | Planned independent work | — | Retain existing dependency/closure semantics; preserve richer facts in analysis. |
| 5 Declarations/references | Pending | — | — |
| 6 Derivation/identities | Pending | — | — |
| 7 Projection/sealing | Pending | — | — |
| 8 Applications/test stores | Pending | — | — |
| 9 Inspection/explanations | Pending | — | — |
| 10 Diff/composition | Pending | — | — |
| 11 Indexes/transfers | Pending | — | — |
| 12 Layout experiment | Pending | — | — |
| 13 Final audit | Pending | — | — |

Plan changes: the initial corrupt-working-database run is excluded. The valid
execution baseline is the exact published `8e4a899` artifact above. The harness
uses a fixed bootstrap controller, exact sign-based paired median intervals,
predeclared A/A calibration and one complete repeat for nonpassing workloads.
Initial and repeated samples and summaries remain available; the combined
estimate cannot erase conflicting tail evidence from human review. Size growth
remains advisory. Missing measurement dimensions are listed above.

Step-0 retained evidence: [step-0-performance.tar.gz](evidence/step-0-performance.tar.gz),
SHA-256 `995a8ccd3028ee71b5e2a5413c3a5b0b40c79fb81f70de253ed074469c9c4b0f`.
The archive includes raw timings, warmups, counters, identities, query plans,
fixtures and a README. It preserves the initial inconclusive reading and the
predeclared follow-up. Baseline/candidate artifact sizes are 14,995,504 and
15,024,176 bytes (+28,672). The packaging follow-up's paired median difference
is -0.691 ms, 95% interval [-2.116, +0.387] ms, with p95 126.575 -> 119.218 ms.
The comparator is the published `8e4a899` release, not relabeled as the moving
main branch; the implementation source parent was `3f239b1`. The archive records
the precise source/script limitations of the first run. Cold I/O, peak RSS,
isolated projection and complete-repository performance remain open evidence
dimensions. There are no new code TODOs in step 0.

Step-1 evidence archive prepared locally: `step-1-decoder.tar.gz`.
SHA-256 `6b43c859ee8e0bc03af99e07ba8b46c5b48959c5f1f072d92316271b80a3bbb6`
(654,605 bytes; 16,080 measured observations plus checked warmups).
Automatic approval review rejected uploading this raw archive to GitHub because
explicit authorization to disclose its fixtures, logs, host metadata and
validation records was not established. The archive is not in this branch;
upload awaits the user's review and authorization. This summary can be published
independently. The rejected upload has not been retried through another mechanism.
The archive preserves all raw samples and checked warmups, exact identities,
counters, fixtures, query plans, validation logs, remote CI results and diagnostic
sources. The implementation tree is `ffee49b92914a969fe43c4053ca589772f121ee0`,
based on merged `c41d73d`; its local and published commit identities differ only
because publication used the GitHub API. Artifact sizes are 15,040,560 and
15,061,040 bytes (+20,480), an allowed increase.

The final predeclared round used the unchanged controller, comparison code and
artifacts, 200 pairs per invocation, the existing automatic repeat only, inherited
CPU-0 affinity, and both artifact assignments for four unresolved workloads.
Reversed A/A and A/B labels are remapped to candidate-minus-parent before judgment.
All eight invocations had valid outputs/counters and zero recorded cgroup
throttling increments. Pinning does not establish exclusive host ownership.
Earlier observations and pinned/unpinned strata remain visible. No workload met
all criteria of the resolution protocol; the source was not changed during it.

| Workload | All-retained pairs | Paired median difference, ms | 95% interval, ms | Remaining issue |
| --- | ---: | ---: | --- | --- |
| Tool startup | 960 | +0.03611 | [+0.01819, +0.05101] | Positive median interval; tail and orientation warnings |
| Portable packaging | 560 | +0.06656 | [-0.22039, +0.47716] | Tail +1.734 ms exceeds existing A/A resolution 0.452 ms |
| Reverse imports | 1,060 | -0.07767 | [-0.10096, -0.04581] | Biased calibration and cumulative tail disagreement |
| Outgoing uses | 860 | -0.06562 | [-0.09394, -0.02223] | Dispersion and retained repeat-tail warning |

Untimed instrumentation of both parsers on both exact artifacts found identical
readsets for a given input. The candidate requires 11 reads / 25,018 bytes versus
the parent's 12 / 29,802. Added decoder I/O therefore does not explain the shift;
CPU/layout cost and controller/scheduling effects have not been separated.
Proceed only with a concrete implementation investigation or a more controlled
runner, not repeated local sampling until a favorable result appears.

A separate statistical review found two generic harness concerns. The empirical
p95 veto uses a median-confidence radius; its null false-inconclusive probability
need not disappear with more samples. Also, the binomial recurrence underflows
at 1,075 samples; cumulative evaluation here explicitly refuses more than 1,074
and the largest retained comparison has 1,060. Neither finding waives a positive
startup interval. A harness correction requires a separate reviewed change with
candidate-blind null/detection and coverage validation, stable large-sample ranks,
honest finite-sample tail bounds, and assessment of automatic repetition. No
comparison thresholds were changed for this candidate.
