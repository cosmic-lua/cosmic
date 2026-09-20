# Portable artifact implementation plan

Status: implementation of the full ordered plan is authorized. Publication
still follows the sequential author, adversarial review, fast-forward, and CI
gates below; merge remains excluded.

Progress: step 1 is implemented as a local candidate from
`076e55daa98bfcf76e14cbab29528fee5ea895dc`. The non-experimental
`test/portable/` characterization records the packed prototype's build failure,
missing runtime metadata, first test execution, and same-verdict reuse after
target/runtime fixture inputs change. It is also wired after the existing host
smoke on all three experimental workflow hosts. Local Linux x86_64 evidence:
fresh boot passed with 134 files staged and 82 modules compiled; the bounded
ordinary suite passed with 300 ran/0 stood in 9 seconds; the existing host smoke
passed; and the fixture observed build exit 1, test 1 ran then 1 stood, missing
runtime metadata, and an unchanged verdict key. Later steps remain pending.

Step 2 is implemented as a local candidate from
`0a02a14b493230c915f733849ec1891e0243f410`. `build.zig` now owns stable
target/configuration ids and `uname` tuples, emits the one target-record
projection consumed by boot and the prototype packer, and compiles matching
metadata into each core. Native and experimental entries construct the same
validated startup record and call one runtime entry; no translation unit is
included or macro-renamed as an entry substitute. Local Linux x86_64 evidence:
fresh boot passed with 137 files staged and 82 modules compiled; the ordinary
suite passed with 300 ran/0 stood in 10 seconds; the sanitized suite passed
under its existing 90-second bound with 300 ran/0 stood in 25 seconds; all
release cores and the sanitized core carried the expected metadata; a focused
probe rejected mismatched target and configuration records; and the portable
smoke and characterization passed. Cross-host CI and adversarial review remain
the publication gate. Later steps remain pending.

## Goal and evidence

The finished artifact is one unchanged, self-contained file that runs offline on
`x86_64-linux-musl`, `aarch64-linux-musl`, and `aarch64-macos`. Its shell
launcher selects and extracts one native core into a private cache, while all
three raw cores occur exactly once and all targets read the same immutable
SQLite application database. It does not depend on Cosmopolitan/APE,
`binfmt_misc`, a ZIP runtime, a network, or an installed Cosmic.

The current `-Dportable-probe=true` experiment has run the same artifact bytes on
all three real CI hosts, including strict verification of the extracted macOS
core's existing code signature. It proves the loading mechanism, argument and
standard-stream forwarding, a cold publication race, warm read-only-cache use,
and reads from the shared database. It does not yet prove a portable build,
test, rebuild, identity, update, or cache policy.

Two current results must remain visible as fixtures until they are fixed:

* A packed standalone fixture's `build` exits 1, prints `build: FAIL`, and says
  `this binary names no host target`. This is an overt missing runtime-target
  failure.
* The same packed fixture's `test` exits 0 and reports one test ran. Today
  `build/test.tl` uses `Store.meta("runtime") or ""`, so success does not prove
  that the verdict has a valid runtime identity. A regression must demonstrate
  that a verdict cannot be reused across target, core, release/sanitized, or
  runtime-basis changes; expecting `test` itself to fail would miss the bug.

A second, Linux-only experiment has also shown the simplifying construction to
preserve: a reusable runtime prefix containing the shell header, three raw
cores, and their manifest was combined with an application database and a
trailer. A hello program reused Cosmic's cached core. The measured prefix was
5,668,864 bytes, the application database 212,992 bytes, and the complete
artifact 5,881,881 bytes. This is evidence for the layout, not yet a portable CI
result or a size promise.

The shebang is part of the format. A direct `execve` of bytes whose first header
is neither a native format nor a script gets no shell fallback. Some shells and
libraries retry `ENOEXEC` through a shell, but callers that directly execute a
Make target or other output need the kernel-recognized script entry.

## Decisions and boundaries

The plan accepts the review directions to put target and configuration identity
in the C core through `build.zig`, turn raw core ranges into the authoritative
images through a manifest/table of contents, give the artifact a real startup
seam, provide a safe default cache, and execute the real portable build and test
paths in CI.

It defers native assimilation. Rewriting the portable file into a host-native
installation would weaken the unchanged portable default and create a second
artifact/cache lifecycle before that benefit is established. It also defers
gzip-compressed core slices: no size or launch-time saving has been measured,
and adding a decompressor to the bootstrap changes both dependencies and failure
modes. Do not attach an estimate to that option. Custom native loaders and an
attempt to share machine code or bytecode across the three native images are
outside this work.

The digest is an integrity check, not artifact authentication. The design does
not claim to defend against an attacker who can replace the artifact or write
the user's private cache. Quarantine, notarization, and distribution signatures
are separate work.

In-place artifact mutation is unsupported. Keeping an open descriptor prevents
an atomic pathname replacement from switching the bytes underneath a running
process; it does not prevent writes to the same inode. Writers must always
construct a new file and atomically replace the pathname.

## End-state contracts

### Physical layout

One versioned writer produces both Cosmic and application artifacts:

```
fixed-capacity shell header
aligned x86_64 Linux raw core
aligned aarch64 Linux raw core
aligned aarch64 macOS raw core
bounded binary manifest / table of contents
application SQLite database
fixed-size versioned trailer
```

The reusable prefix ends after the manifest. A program is exactly that prefix,
followed by its database and trailer. An application edit changes only the
database/trailer portion and does not create a new cache key. A C/runtime change
changes at least one core digest and therefore the prefix.

Version 1 should use fixed-width integer fields and a stated byte order. The
manifest has a magic, format version, encoded length, prefix length, entry
count, and fixed-size entries containing target id, configuration id, offset,
length, and SHA-256 of the exact raw core bytes. The trailer has its own magic,
version and encoded length plus the manifest and database offset/length needed
to validate the whole file. Set small hard bounds in `core/portable.h` (for
example, at most eight entries and a manifest no larger than one header block),
and reject unknown versions rather than guessing.

The reader validates every addition and conversion before use: manifest and
trailer bounds, offset plus length overflow, ranges outside the retained file,
overlap, duplicate target/configuration entries, missing required entries,
nonzero padding if the format requires zero padding, truncation, database
header, and a selected entry inconsistent with the running core's compiled
target/configuration. Tests must byte-swap, truncate, duplicate, overlap and
overflow individual fields. Do not search for a convenient zero byte in a core
or infer layout from native headers.

The shell case arms and the binary manifest may encode the same facts because
the shell cannot conveniently parse the binary structure, but they must be
generated in one operation from the same records. `build.zig`'s `targets` array
becomes the only target list and gains stable target/configuration ids and the
`uname` tuple. It supplies compile definitions to each core and target records
to the writer. Remove the duplicate list in `build/boot.tl` and the handwritten
case mapping in `experiments/portable/pack.sh`.

### Identity and paths

There are three different identities; code and tests must name the one they
mean:

| Identity | Definition | Use |
| --- | --- | --- |
| Program artifact | The retained portable file and its logical relaunch path | Database reads, `Proc.executable`, rebuild/re-exec |
| Physical core | Target, release/sanitized configuration, exact raw-core length and SHA-256 from the manifest | Cache key, selected-core validation, diagnostics |
| Runtime verdict | A domain-separated hash of target, configuration, exact raw-core digest, and the existing Lua/Teal runtime basis | Test verdict keys |

Never hash the whole currently attached native executable as core identity. Its
bytes include a database and, on macOS, signature changes made by the legacy
per-program attach path. In a portable artifact the core digest is over the
exact manifest slice, including the original macOS core signature and excluding
alignment padding, database, and artifact trailer.

There is no digest self-reference: the digest lives in the generated launcher
and manifest outside the raw core. The core carries only compile-time target and
configuration metadata. Before `exec`, the launcher opens the verified cached
core on a second reserved descriptor and leaves it open across `exec`. Portable
startup obtains the OS's physical executable identity (`/proc/self/exe` on
Linux; `_NSGetExecutablePath` followed by `open` on macOS), compares its
device/inode with that retained core descriptor, and hashes exactly the
descriptor's standalone file length and bytes. That length and SHA-256 must
match the selected manifest entry, and its target/configuration must match the
compiled metadata. Then startup closes the transient core descriptors. This
binds runtime identity to the core that actually executed, including across a
same-target/same-configuration wrong-core substitution; merely trusting a
launcher field would not.

Apply that physical-file check only to a portable startup whose cache entry is a
standalone raw core. Never hash the legacy attached executable: its database and
macOS per-program signature are outside raw-core identity. Cache names include
target, configuration, length and digest, so a sanitized core cannot collide
with a release core even if a later bug mishandles one field.

On Linux, opening `/proc/self/exe` identifies the loaded file. On macOS,
`_NSGetExecutablePath` is a pathname reopen rather than proof of the loaded
vnode, so the descriptor/file-identity comparison binds the core only under the
private immutable-cache contract. A valid published 0500 entry is never mutated
or replaced by Cosmic. A corrupt name may be unlinked and republished before
execution through the race-safe path; a concurrent descriptor/identity mismatch
fails. External replacement or same-inode mutation by the cache owner is outside
that trust boundary. The post-`exec` check catches accidental substitution but
is not authentication and cannot make already-executed bytes safe against a
hostile cache owner.

Keep compiler identity distinct. `work.identities` continues to derive the
compiler identity from the `build.importer` closure and compiler pins/patches.
Add a distinct host-independent `runtime_basis` value, then derive the complete
portable runtime identity at execution from that basis and the validated
physical core. During transition, keep the existing per-host `runtime` derived
from `host_image` for legacy artifacts. The portable encoding is domain
separated and unambiguous; it is never empty and differs across targets and
sanitized/release cores.

During migration, legacy native artifacts continue using their database's
`host`, `host_image`, and `runtime`. Portable startup overlays those values from
validated runtime context. No portable projection stops carrying the old values
until commit 6 has moved every metadata reader (`build/test.tl`,
`build/reboot.tl`, `build/embed.tl`, `build/writer.tl`) to that context. Legacy
projections continue carrying them through the final cutover. This avoids a
transition where missing metadata silently becomes `""`.

`cosmic.sys.executable` is an existing public annotated syscall and
`Proc.executable()` wraps it. Preserve that public binding. Deliberately change
both documented meanings together: in portable mode they return the logical,
directly executable artifact path suitable for relaunch; in legacy/native mode
that logical artifact is the native executable, preserving the current answer.
Update `cosmic/proc.tl`, `core/syscalls.c`, the annotations/declarations from
`core/syscalls.h`, docs and tests in the same commit. Move the OS lookup used to
bind the cached core behind a separately named internal C helper; do not expose
the physical cache path through a new public API.

### Retained artifact and startup

Replace `experiments/portable/entry.c`'s macro rename and inclusion of
`core/main.c` with an explicit seam. A thin native `main` constructs a
`cosmic_startup` record and calls the shared runtime entry. The portable
launcher supplies a documented private startup contract; normal raw-core boot
constructs a native/legacy record. A portable-marked startup that fails
validation exits with a precise error and never falls back into `--boot`.

Reserve an artifact descriptor and a transient cached-core descriptor in the
launcher contract. Before redirecting either, the shell must test whether the
caller already has it open; if so, fail clearly without closing or replacing
it. Do not treat documentation as permission to clobber caller state. The shell
opens the selected artifact once, uses that descriptor for extraction, opens
the verified cache entry on the second descriptor, and executes that path with
only a bounded set of private environment fields naming the descriptors and
selected entry. The core checks both descriptors and clears those fields before
Lua can inspect or propagate the environment. It closes the core descriptor
after binding actual-executable identity and sets close-on-exec on the retained
artifact descriptor so application subprocesses and a relaunch do not inherit
stale state. File descriptors 0, 1 and 2 remain untouched. Tests cover the free
reserved-descriptor path and refusal, without clobbering, when either is already
open.

Validation, manifest inspection, trailer/database location, and the offset VFS
all use that retained open file. Change `cosmic_locate`/`cosmic_vfs_register`
to accept the handle or an owned artifact object, and have VFS `xRead` use
`pread` on it instead of reopening a pathname. Keep exactly one owned artifact
handle through database close. Atomic old/new replacement then selects one
complete file: a replacement before the launcher opens may select the new file;
after it opens, that process remains on the selected bytes. If the launcher
entry, cached core, retained manifest and compiled core metadata disagree,
startup fails. It must not silently open the pathname again or boot against a
different file.

Before any Teal consumer needs to write another program, expose the validated
prefix bytes through a private trusted build API implemented in `core/store.c`
and the startup/artifact context. It reads `[0, prefix_length)` with `pread` from
the retained descriptor. Hand it only to the trusted `build.artifact` module in
the same way raw store capabilities are restricted today; do not add it to the
public `cosmic.store` wrapper. `build/embed.tl` and `build/reboot.tl` request the
prefix from that module and never reopen `Proc.executable()` or the logical
pathname. Rename-over and unlink-after-open tests must still let those consumers
write an artifact from the originally retained prefix.

### Cache

The default cache is per-user and private. On Linux use
`${XDG_CACHE_HOME}/cosmic/cores` when `XDG_CACHE_HOME` is absolute, otherwise
`${HOME}/.cache/cosmic/cores`. On macOS use an absolute `XDG_CACHE_HOME` when
explicitly set, otherwise `${HOME}/Library/Caches/cosmic/cores`. Fail clearly
when no safe absolute home/default can be formed. `COSMIC_PORTABLE_CACHE`
remains an absolute-path override for tests and managed environments.

With `umask 077`, create the managed leaf as mode 0700. Define and implement one
portable `lstat`/ownership/mode policy for existing default and override roots:
reject a symlink leaf, a non-directory, a different owner, or any group/other
permission. Accept owner mode 0700 for cold/warm use and owner mode 0500 for
warm read-only use; a cold start against 0500 fails clearly. Do not follow a
cache-entry symlink. Document which parent is the trust boundary instead of
implying that shell checks secure an already hostile home directory.

Publish cores from a same-directory private temporary entry using an operation
that cannot replace a winning entry. Competing cold launches either publish the
same verified bytes or validate and use the winner. Interrupted writers leave
only removable private temporary names. Write a stage with owner-only access,
then set the finished regular core to mode 0500 before publication. Reject a
non-regular entry, a mode other than 0500, a symlink, a wrong length, or a
digest mismatch and replace it through the same race-safe path when the 0700
directory permits; never overwrite a file another process may be executing.

Cold extraction always checks exact length and digest before publication. A
length check detects truncation; it does not detect equal-length corruption or
the wrong bytes. In the current POSIX `dd | head` pipeline, lack of `pipefail`
also means pipeline success is not evidence that `dd` produced the requested
input, so keep the digest check and a comment explaining both roles. Tests must
cover short output and equal-length corruption.

Version 1 should also hash a warm entry before `exec`, paying one sequential
read plus the digest utility process so malformed/corrupt cache entries fail
before execution. Record cold and warm timing on all three CI hosts so that
cost is explicit; do not set an arbitrary microbenchmark threshold. A future
owner-controlled-cache trust optimization requires its own reviewed change and
must state which corruption detection it gives up. A self-check performed by
the core after `exec` cannot authenticate bytes that have already executed.

A warm start performs no cache writes and works when the validated cache is
read-only. A cold read-only cache and a noexec cache produce useful extraction
or execution errors; the design does not promise to bypass either filesystem
policy. The launcher attempts one `exec`. It never interprets a user's nonzero
program exit or signal as cache corruption and never retries the program.

The launcher must preserve empty and whitespace arguments, current directory,
stdin/stdout/stderr, environment other than the bounded private startup fields,
PID across the shell-to-core `exec`, exit status, and ordinary signal behavior.

## Ordered implementation commits

Each numbered item is one candidate commit. If a step grows beyond the stated
files and contract, split it at a passing compatibility boundary; do not combine
adjacent migrations into one large commit.

### 1. Check in characterization fixtures

**Dependencies:** current PR head only.

Add a small standalone project fixture and an integration driver under a
non-experimental test location (for example `test/portable/`). Refactor reusable
parts of `experiments/portable/check.sh` only as needed. Record the current
`build` failure separately from the successful `test`, and inspect the work
database/verdict keys to expose the empty runtime identity and false-reuse risk.
Add a fixture whose test result or observable counter proves whether it ran, so
later checks can distinguish `ran` from `stood` rather than accepting a PASS
line alone.

Keep the ordinary default build unchanged. This first fixture is allowed to
describe the known gap and must say which assertions flip in commit 6; it must
not encode “portable test must fail.”

**Acceptance:** reproduce the measured `build` exit 1/message and `test` exit
0/one-run result from a fresh temporary project; show the missing runtime value
or same-key reuse directly. Run the existing experimental smoke test on the
host. The adversarial reviewer varies target/runtime fixture inputs and confirms
the fixture would catch a silently reused passing verdict.

**Gate:** no product code changes, and the characterization is deterministic
without sleeps or network access.

### 2. Establish the target authority and startup seam

**Dependencies:** commit 1.

Extend `Target` in `build.zig` with stable format id, shell OS/architecture, and
configuration data. Pass `COSMIC_TARGET_ID`, target name, and release/sanitized
kind as compile definitions in `core()`. Generate or pass this same target list
to `build/boot.tl`; remove its handwritten `targets` list only after the new
input is exercised.

Split `core/main.c` so its current `main` body becomes a named runtime function
accepting a `struct cosmic_startup` declared in new `core/startup.h` (with a
small implementation file if needed). A new normal entry file owns `main`.
Rewrite the experimental entry to construct the same record. Remove all
`#define cosmic_executable_path`, `#include "../../core/main.c"`, and renamed
`main` tricks. At this step startup may still locate by pathname and consume
legacy metadata; behavior is intentionally unchanged.

**Acceptance:** `bin/zig build boot` in a fresh worktree, then
`timeout 30 o/bin/cosmic test`; `o/bin/cosmic fix --check` for changed Teal;
build the sanitized target using its existing separately documented bound. The
probe option still runs on the host. Inspect all core binaries for the expected
target/kind metadata and a single entry point. The adversarial reviewer builds
two targets plus sanitized and tries a deliberately mismatched startup record.

**Gate:** default artifact bytes retain their existing semantics, the target
list has one authority, and no source file includes another translation unit to
replace its entry point.

### 3. Add the bounded format reader and one reusable-prefix writer

**Dependencies:** commit 2.

Define the v1 structures and checked decoder in `core/portable.h` and
`core/portable.c`, sharing generic exact-position reads with `core/locate.c`
where appropriate. Add the corresponding writer in one Teal module, preferably
`build/artifact.tl`, with `prefix(...)` and `program(prefix, database)` as the
only constructors. It generates the shell case data and binary manifest from
the same target records, hashes exact raw core lengths, and writes a fixed-size
versioned trailer. `build/boot.tl` may write an additional non-default portable
output in this transition, but continues to produce legacy outputs.

Use the already-signed raw macOS core unchanged in the prefix. Do not invoke
`build/codesign.tl` for each application and do not pad the extracted slice.
The transitional format fixture contains no second copy of the cores, but its
database may still carry the current per-host metadata: host independence waits
for commit 6's runtime overlay. Keep legacy `images` rows and readers in legacy
artifacts until commits 6–8 complete.

Add `build/artifact_test.tl` for deterministic layout and round trips, plus a
test-only inspector using the production C decoder if necessary. Construct
malformed files for every validation listed under Physical layout. Include
unknown versions and a valid-looking SQLite header at a dishonest offset.

**Acceptance:** two synthetic program outputs made by the writer from one prefix
and two fixture databases have a byte-identical prefix and distinct suffixes;
this does not yet claim `cosmic build` works. Each core range hashes to the
corresponding raw `o/core/.../cosmic-core`; every core occurs once and the
portable format fixture has no compressed image copy. Rebuilding in a second
absolute checkout produces the same prefix bytes. Strictly verify the extracted
macOS range on macOS in CI when that leg is introduced.

**Gate:** format readers reject malformed input before returning any usable
offset, and every producer calls `build.artifact` rather than reproducing the
layout.

### 4. Replace the prototype launcher with the cache contract

**Dependencies:** commit 3.

Move the launcher template to its production location (for example
`build/launcher.sh`) and have `build.artifact` fill only generated target/range
records. Implement default and override cache selection, ownership/mode/symlink
validation, exact-range extraction, cold length and digest checks, pre-exec warm
digest checks, race-safe no-replace publication, cleanup after interruption,
opening the verified core descriptor, and one final `exec`. Keep both explicit
inherited-descriptor numbers and the private environment fields in one
documented block shared with `core/startup.h`.

Add shell integration tests for paths and arguments containing spaces and
empty strings; unset/relative home and override values; symlink cache root and
entry; wrong owner/mode where the runner can create it; truncated and
equal-length-corrupt extraction; corrupt warm entry; two cold publishers; an
interrupted publisher; read-only warm cache; cold read-only cache; and execution
from a noexec mount when CI exposes one. Use FIFOs or an explicit test-only
publication hook generated out of release launchers to synchronize races. Do
not use sleeps.

**Acceptance:** the artifact is unchanged after every run, one cache entry is
published, cold and warm digest failures are reported before `exec`, and a
program that exits nonzero or by signal runs exactly once. Record, without a
pass/fail threshold, cold extraction and warm launch timing on each available
host.

**Gate:** a cache override is optional; the default is private and useful; warm
operation makes no writes; the digest comments and tests cover pipeline failure,
size/truncation, and equal-length corruption distinctly.

### 5. Retain one artifact handle through validation and VFS

**Dependencies:** commits 3 and 4.

Adopt the launcher's inherited descriptors in `core/startup.c`. Validate the
artifact's `fstat`, manifest/trailer, selected target/configuration and raw core
range. Resolve the physical executable through the platform-specific internal
helper, compare its file identity with the inherited core descriptor, and hash
that descriptor's exact standalone length/bytes against the manifest before
closing it. Include a same-target/same-configuration core from another build in
the mismatch tests. Then set close-on-exec on the artifact handle and clear the
private environment fields. This path is portable-only and never hashes a
legacy attached executable.

Introduce an owned artifact context containing logical path, descriptor, file
identity/size, prefix length, selected entry and database range. Convert
`cosmic_locate` to a descriptor decoder. Convert `cosmic_vfs_register`,
`vfs_open`, `file_read`, `file_size` and `file_close` in `core/vfs.c` to borrow
that same retained descriptor and use `pread`; remove pathname reopening for a
portable main database. Add the private trusted prefix reader described above,
implemented over that context and unavailable through `cosmic.store`. Legacy
startup keeps its old path route until the final cutover.

Change `open_attached` in `core/main.c` to consume the context. A malformed or
mismatched portable context is fatal and cannot enter the raw-core boot bridge.
Add precise diagnostics for wrong target, configuration, digest, core length,
artifact identity and database range.

Test atomic replacement with deterministic synchronization: pause after the
descriptor is adopted, rename a complete new artifact over the logical path,
and prove the paused process reads only the old database while a subsequent
process reads only the new one. Also replace an artifact between launcher entry
and selection with an incompatible prefix and require a mismatch error, never a
boot fallback. Document that an in-place writer violates the contract; do not
claim the descriptor makes it safe.

**Acceptance:** trace or instrument opens in the test build and show exactly one
artifact open survives into VFS reads and private prefix reads; the transient
core handles are closed after identity binding. Rename, unlink-after-open, and
paths with spaces work. A test-only trusted caller exercises the private prefix
capability directly after rename/unlink; `build/embed.tl` and `build/reboot.tl`
do not consume it until commits 7 and 8. The VFS continues using the retained
bytes. Standard streams, cwd, environment, PID, exits and signals retain the
behavior listed above.

**Gate:** no validated offset is later paired with a pathname reopen, and old
and new complete files cannot be mixed after descriptor adoption.

### 6. Supply runtime target/core identity at execution

**Dependencies:** commit 5.

Add a private runtime metadata overlay in `core/store.c` or the startup/store
boundary. In portable mode it synthesizes `host`, `host_image`, `runtime` and
logical artifact consistently from the validated context: `host_image` is the
exact standalone raw-core digest, never the whole program. Preserve legacy SQL
lookups when no portable context exists. In `build/work.tl`, keep
`Identities.compiler`, add a distinct host-independent `runtime_basis`, and keep
the existing `runtime` calculation/projection for legacy outputs. Derive
portable `runtime-v2` from the basis and runtime context, with explicit target
and configuration components. Update `build/test.tl` so a missing runtime is an
error instead of `or ""`; update `build/embed.tl`, `build/reboot.tl` and
`build/writer.tl` consumers without yet removing their legacy fallback rows.

The portable projection now carries `runtime_basis` and stops carrying
per-host `host`, `host_image`, and `runtime`; this is the point at which its
database becomes host-independent. Legacy projections continue carrying and
deriving all three old fields until the final cutover.

Deliberately change the existing public `cosmic.sys.executable` implementation
and its `Proc.executable()` wrapper together to return the logical artifact
relaunch path in portable mode. Retain both public functions and align their
annotations, declarations, docs and tests. The separately named physical OS
lookup remains internal to C for core identity/diagnostics; no public physical
cache-path API is added.

Flip the identity parts of commit 1's characterization: portable `build` now
receives a nonempty target but may proceed to the later `image_of` failure until
commit 7 migrates embedding; do not claim it passes here. Portable `test`
receives a nonempty runtime verdict identity. Run a fixture successively under
two target identities and release/sanitized cores against the same `o/build.db`;
each changed identity must run rather than stand. Run it twice unchanged to
prove the second verdict can stand. Substitute a different raw core with the
same target/configuration and require startup to reject it before tests. Keep
compiler identity tests showing a stdlib edit does not move compiler identity
while a compiler patch does.

**Acceptance:** no portable verdict key contains an empty/shared runtime; target
and sanitized/release changes move it; an application-only database change does
not change physical core identity. Compare manifest raw-core hashes directly,
never hashes of legacy attached executables.

**Gate:** all metadata consumers use the overlay in portable mode, the portable
projection is host-independent, and every legacy consumer/projection still
works with the old per-host fields.

### 7. Give application builds a portable-prefix path

**Dependencies:** commit 6.

Before any portable full-suite claim, update `build/embed.tl` to choose by
runtime context. With a validated portable context, obtain the prefix only from
`build.artifact`'s private retained-descriptor API and call
`build.artifact.program`; never reopen `Proc.executable()` and never call
`image_of`. Without a portable context, retain the legacy `image_of` plus
`attach.write` fallback so the unchanged default/legacy build still passes.
Keep `embed.database` focused on the application database and omit portable
`host`/`runtime` rows now that commit 6 supplies them at execution.

Update `build/embed_test.tl` with explicit legacy and portable cases. The
portable case expects a shebang/manifest, exact prefix equality with the
retained Cosmic prefix, no `images` payload, logical executable paths and
executable output mode. Rename and then unlink the running artifact pathname
after startup; the private prefix read must still succeed from the retained
descriptor. Build at least two applications, including hello, and verify both
reuse one target cache entry and an application edit changes only its suffix.

**Acceptance:** a fresh standalone fixture's portable `build` succeeds for the
first time and the produced applications execute through the portable launcher.
The existing legacy build/test suite remains green through its fallback. No
portable application invokes per-program macOS signing, and the raw macOS range
is byte-identical to the signed core.

**Gate:** every portable `embed.tree` path uses the private retained prefix and
the common writer. Legacy `attach.write`/`image_of` callers remain only as the
explicit compatibility fallback; do not delete them yet.

### 8. Make Cosmic boot and self-rebuild use the prefix writer

**Dependencies:** commit 7.

Update `build/boot.tl` to construct one prefix from the three raw cores and call
`build.artifact.program` for the Cosmic database at a staged portable pathname,
for example `o/bin/cosmic-portable`. Stop retagging and rewriting a database per
target for that output. The portable database is immutable and host-independent;
target/core/runtime values come from execution context. Keep the ordinary
legacy `o/bin/cosmic` and per-target outputs unchanged until commit 10.

Update `build/reboot.tl` so a Teal-only self-rebuild obtains the exact validated
prefix through `build.artifact`'s private retained-descriptor API, writes a new
database/trailer through the same writer, and atomically replaces and re-executes
the same logical portable pathname that invoked it (`o/bin/cosmic-portable` in
this staged build). It must not hardcode or replace legacy `o/bin/cosmic`, reopen
the logical pathname for input, or obtain a core by hashing/inflating the current
attached executable. A core-input change still refuses by name and requests
`bin/zig build boot`.

Test self-rebuild from a fresh tree by changing Teal, observing exactly one
re-entry, and comparing prefix bytes and cache-entry count before/after. Pause
after descriptor adoption, rename or unlink the artifact, and prove rebuild
uses the retained prefix. Change a core input and prove it refuses rather than
constructing an artifact with stale cores. Keep legacy boot outputs during this
commit so rollback and comparison remain possible.

**Acceptance:** the portable Cosmic artifact runs the complete
`timeout 30 ... test` suite from a fresh worktree, including the now-dual
`embed_test`, and completes deterministic Teal self-rebuild/re-entry. Its
rebuild remains portable and reuses the cached core; all three raw cores occur
once. The standalone portable `build` fixture from commit 7 remains green.

**Gate:** Cosmic, self-rebuild and portable application outputs share
`build.artifact.program`; no portable consumer reopens the logical path, and
application/database edits do not rewrite or recache the prefix.

### 9. Put real portable behavior in normal CI

**Dependencies:** commit 8.

Integrate portable coverage into `.github/workflows/ci.yml`, or give a separate
workflow path filters that continue to trigger after merge. Remove the
`branches: [explore/portable-launch]` condition; a branch-only workflow is dead
after this PR. Build one canonical artifact, transfer its unchanged bytes to
the three actual runners, and also have each runner independently cross-build
the complete portable Cosmic and fixture applications for provenance
comparison.

On each of the three real targets, run the exact same portable Cosmic artifact
against a fresh Cosmic checkout and execute its complete `test` path, not the
raw normal boot output. Report `ran` and `stood` counts so an empty/shared
identity cannot hide behind PASS. Make a deterministic Teal edit in that
checkout and prove exactly one portable self-rebuild/re-entry. Because Cosmic's
own tree intentionally refuses `cosmic build`, separately run portable `build`
in a fresh standalone fixture, then execute every produced application on all
three hosts from the exact same application bytes.

Also check cold extraction, warm read-only cache, malformed artifact rejection,
equal-length cache corruption, deterministic cold publication and
artifact-replacement races, artifact immutability, target/core identity and
prefix reuse. Repeat cold/mutation scenarios only where they test a different
platform implementation; do not multiply ordinary warm tests.

The provenance job compares byte-for-byte portable Cosmic, prefix, and fixture
applications produced by Linux x86_64, Linux aarch64 and macOS aarch64. The
macOS runner extracts the exact manifest range and runs
`codesign --verify --strict`; all runners compare that range's length and digest
to the manifest. The sanitized job verifies its distinct configuration/cache/
verdict identity and keeps its existing documented timeout bound.

Follow `AGENTS.md`: use `bin/zig`; boot C/build changes in a fresh worktree; run
`o/bin/cosmic fix` on changed Teal; use `timeout 30` for ordinary tests. Before
writing a macOS command, explicitly check the runner's existing `timeout`
availability and use it if present; do not silently substitute a larger bound
or broaden tests. If absent, make the workflow's existing job bound and the
reported limitation explicit in review. Do not raise the sanitized bound.

**Acceptance:** required CI for the exact candidate commit is green on all
three hosts, provenance compares outputs from every host, and the downloaded
canonical artifact hash is identical before and after each execution.

**Gate:** CI would still run on `next` after merge and tests the product paths,
not `-Dportable-probe` substitutes.

### 10. Make portable the default and remove superseded machinery

**Dependencies:** commit 9 green on the exact reviewed candidate.

Change the ordinary `bin/zig build boot` outputs to the portable artifact and
make help/docs describe the default cache and logical executable semantics.
Remove `-Dportable-probe`, `experiments/portable/entry.c`, `pack.c`, `pack.sh`,
`launcher.sh`, `check.sh`, payload/probe programs, and the branch-only portable
workflow. Preserve useful measured conclusions in maintained design docs rather
than retaining executable experiment code.

After `rg` proves there are no users, remove the legacy per-target database
retagging, compressed `images` projection/read paths, legacy attach locator and
`build/attach.tl`. Remove `build/macho.tl` and `build/codesign.tl` only if the
same search proves no remaining core-build or test user; the raw macOS core must
remain signed and CI-verified. Bump the working database schema deliberately if
the `images` table itself is removed. Delete legacy `host_image`/per-host
`runtime` readers only now, after the portable runtime context has passed the
transition tests. Keep a clear raw-core boot path for a fresh checkout.

Run the full fresh-worktree build/test/fix, sanitized build/test at its existing
bound, all format/cache/replacement tests, and all three CI/provenance jobs. The
adversarial reviewer checks the deletion list with `rg`, verifies default build
help/output names, and constructs a fresh checkout with no existing `o/` or
cache.

**Gate:** default and documented behavior is portable, all three cores occur
once, the database is host-independent, every output uses the shared writer,
and no option/script/per-application signer remains without a live caller.

## Per-commit verification discipline

For C, `build.zig`, or format changes, start from a clean independent worktree
and run `bin/zig build boot` before later commands. For each changed Teal file,
run `o/bin/cosmic fix <paths>`, then `timeout 30 o/bin/cosmic test`. Treat a
timeout as its own failure and investigate it; never silently raise it. Use the
existing separately documented sanitized bound only for the sanitized suite.
Generated `o/` output is never committed and `vendor/` remains pristine.

Each commit records:

* parent SHA, candidate SHA and tree SHA;
* exact changed paths and which transition fallbacks remain;
* commands, hosts, exit codes, elapsed time and `ran`/`stood` counts;
* artifact, prefix, raw-core and application-database sizes/digests relevant to
  that commit;
* cold/warm observations without arbitrary timing gates;
* known limitations deferred to a later numbered commit.

## Sequential author, review, and publication protocol

Only one implementation worker acts at a time. For each numbered task, the
coordinator starts a fresh Sol implementer in a fresh worktree at the exact
reviewed parent. The implementer makes one local candidate commit, runs the
task's checks, and does not push. A different fresh Sol reviewer then reviews
the exact `parent..candidate` diff and independently inspects the repository and
evidence. The reviewer does not modify code and does not push.

Blocking findings return to the implementer. Any amended or follow-up commit
creates a new candidate SHA and receives a complete review by a different agent;
approval of an older SHA does not transfer. The coordinator confirms the PR's
remote head has not moved, repeats the required local gates, and binds approval
to the candidate tree before publication. Push only as a fast-forward to
`explore/portable-launch`; never force-push and never merge. Watch all required
checks for the latest published commit, including macOS, before starting a
dependent task. Refresh the PR description and current review feedback before
each chunk. There is no automatic merge.

Git CLI reads are available but authenticated pushes may not be. If the GitHub
connector must publish, use `create_tree`, `create_commit`, and `update_ref`
while preserving executable modes. The connector-created commit SHA will differ
from a local commit SHA: verify its parent and tree equal the reviewed content,
then either bind the review record to that content/tree or have the reviewer
acknowledge the remote candidate before updating the ref. Never claim the local
and remote SHAs are equal. If the remote branch advances concurrently, stop,
integrate that head, rerun tests, and review the new diff; never overwrite it.

### Implementer handoff template

```
Task: portable plan step N — <name>
Base SHA/tree: <sha> / <tree>
Allowed scope: <paths and behavior>
Required compatibility during transition: <legacy/default behavior>
Required tests: <commands and target hosts>
Candidate SHA/tree: <sha> / <tree>
Evidence: <commands, results, artifact identities, ran/stood, timings>
Deferred items: <later numbered steps only>
Push/merge: forbidden
```

### Reviewer handoff template

```
Review: portable plan step N — <name>
Exact range: <parent>..<candidate>
Expected tree: <tree>
Independently inspect: <invariants and adversarial cases from this step>
Reproduce: <minimum commands/fixtures>
Check transition: <old and new paths that must both work>
Findings: <severity, file/symbol, evidence, required correction>
Verdict: APPROVE exact SHA/tree, or BLOCK
Modification/push: forbidden
```

### Publication gate record

```
Remote PR head before publication: <sha>
Reviewed local candidate/tree: <sha> / <tree>
Reviewer and exact approval: <record>
Coordinator rerun: <commands/results>
Published remote commit/tree: <sha> / <tree>
Parent/tree equality check: <result>
Required CI for latest commit: <links/results, including macOS>
Next dependent task authorized only after: all required checks green
```

The final implementation handoff must explicitly state that no optional
assimilation, gzip, custom loader, or machine-code-sharing work was folded into
these commits.
