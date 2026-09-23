# portable runtime implementation

Cosmic ships one file that starts on every supported host. An ordinary release
artifact contains a POSIX shell launcher, three release cores, a manifest, a
SQLite database, and a fixed trailer. A checked artifact adds one
configuration-2 core for its build host. This guide follows those bytes from
the build graph to a running program. [The design](../design.md) defines the
format and trust rules; this guide explains where the implementation enforces
them.

The implementation passes control through four narrow stages:

1. Zig builds the native cores and Teal boot assembles the portable artifact.
2. The shell launcher selects and caches one core without reading the database.
3. C startup validates the artifact and retains its descriptors before Lua runs.
4. The immutable SQLite VFS exposes the validated database to the module store.

Each handoff limits what the next stage must trust. The build graph produces raw
inputs. Teal assembles the format. C checks the shell's selection against the
artifact. SQLite reads only the validated database range.

## build the raw inputs

[`build.zig`](../../build.zig) owns native compilation. Its `cores` step builds
the same C sources for `x86_64-linux-musl`, `aarch64-linux-musl`, and
`aarch64-macos`. It also writes `o/targets.tsv`. Each record gives a stable
numeric identity, configuration, target name, and `uname` pair.

The generated records are the authority shared by Zig, the artifact writer,
the launcher, and tests. A release build requires all three release records.
The `sanitized` step adds one configuration-2 core for the build host. That
checked core is a test artifact, not a fourth shipped target.

The `boot` step runs the new host core in bridge mode. The C bridge loads the
vendored Teal compiler from the staged tree, then calls
[`build.boot`](../../build/boot.tl). This is the path that works when no older
Cosmic executable exists.

## separate working and shipped state

Boot opens `o/build.db` through [`build.work`](../../build/work.tl). This is a
mutable working database. It holds staged source, parsed forms, compiled
modules, test verdicts, coverage, and recent build records. Raw cores remain
files under `o/core`; they are never database rows.

[`build.importer`](../../build/importer.tl) derives generated modules and
compiles the staged tree. [`build.writer`](../../build/writer.tl) projects the
result into `o/cosmic.db`, a fresh host-neutral database. The projection has a
smaller schema, deterministic insertion order, natural keys, and no working
history.

The writer hashes the planned modules, declarations, build identities, main
module, and format name. It stores that signature inside the projection. A
later write skips work only when the file at the output path carries the same
signature. A side record in `o/build.db` cannot make a replaced output look
current.

The running projection exposes its identities through
[`cosmic.store`](../../cosmic/store.tl). This example runs with the guide:

```teal
local Store = require("cosmic.store")

assert(Store.meta("compiler") ~= nil)
assert(Store.meta("runtime_basis") ~= nil)
assert(Store.meta("projected") ~= nil)
print("projection identities: present")
```

```output
projection identities: present
```

The database stays host-neutral. The selected system and core identity come
from the validated manifest. `runtime_basis` comes from the projection and
covers the Lua and Teal pins and patches. Together they prevent a test verdict
from one runtime context from standing in another.

## write the portable layout

[`build.artifact`](../../build/artifact.tl) parses `targets.tsv`, reads each raw
core, and renders launcher arms with
[`build.launcher`](../../build/launcher.tl). It aligns every core range, hashes
the exact bytes, and writes one fixed-size manifest entry per target and
configuration. Unused manifest space is zero.

`artifact.program` appends a projected database and fixed trailer to the shared
prefix:

The regions appear in this order; their sizes are not to scale:

| Region | Role |
| --- | --- |
| Shell launcher | Select a generated target and prepare a verified core. |
| Aligned core ranges | Hold the exact native bytes named by the manifest. |
| 4 KiB manifest | Bind identities to core offsets, lengths, and digests. |
| SQLite database | Hold the host-neutral module projection. |
| Fixed trailer | Locate the manifest and database and bind the file size. |

Manifest and trailer offsets are relative to the whole file. Integer range
checks happen before addition. Core ranges cannot overlap. Identities must be
unique. The database must begin with the SQLite header.
[`core/portable.c`](../../core/portable.c) checks these rules again before the
runtime trusts a range.

The running build receives a private capability for its validated artifact.
`build.artifact.trusted_prefix` reads the reusable prefix through that
capability and never reopens the executable pathname. This tested example
observes the prefix's shell header and manifest marker:

```teal
local artifact = require("build.artifact")

local prefix = assert(artifact.trusted_prefix())
assert(prefix:sub(1, 10) == "#!/bin/sh\n")
assert(prefix:find("CosmicM1", 1, true) ~= nil)
print("retained portable prefix: valid")
```

```output
retained portable prefix: valid
```

The stronger retention guarantee comes from
[`core/store.c`](../../core/store.c), which rehashes every manifest core range
before returning retained prefix bytes. `runtime_test.tl` and
`self_rebuild_test.tl` exercise that guarantee across rename, unlink,
replacement, and database-only rebuilds.

## select and cache one core

The generated shell in [`build.launcher`](../../build/launcher.tl) maps
`uname -sm` to a generated release record. It opens the artifact
before changing the cache. It validates the cache leaf's kind, owner, mode,
and contents. The cache parent is the user's trust boundary.

On a cold start, the launcher copies the selected manifest range to a private
temporary file, verifies its length and SHA-256 digest, sets its mode, and
publishes it atomically. A symlink, unexpected entry, wrong owner or mode, or
short core is repaired, or stops the launch when the cache is read-only.

A warm core is hashed until it has been verified and left alone: once startup
has hashed an entry and a second has passed since the entry last changed,
startup writes `.verified-<entry>` beside it, recording the entry's size,
inode, and modification and change seconds. While the entry still answers the
same, neither the launcher nor startup hashes it. Any write to the entry moves
its times, so a core damaged in place is hashed by the launcher before it
runs, and repaired. A core that startup still finds different from the
manifest is refused with `executing core digest differs from manifest; remove
<entry> to extract it again`.

A warm start with a verified stamp runs two utilities and no other child:
`uname` and one `stat` for both the cache leaf and the entry, and hashes
nothing. The descriptor probes run
in the shell itself, ownership is the shell's own `test -O`, and the umask
changes only in the child that creates the cache leaf.

On supported hosts the launcher also checks whether the verified cache entry
is executable before invoking the shell's `exec` builtin, so a noexec cache
gets a stable portable diagnostic. The final `exec` failure remains a backstop
for other denials; the preflight does not claim to predict every `execve`
failure.

The launcher reserves two unused descriptors: one for the complete artifact
and one for the selected core. It passes their numbers, the selected identity,
ranges, and digests in a bounded `COSMIC_PORTABLE_*` environment.
`COSMIC_PORTABLE_CACHE` is the only public setting in that namespace.

## validate before Lua starts

[`core/startup.c`](../../core/startup.c) consumes the private launch contract.
It rejects a missing, partial, or malformed field, then clears the private
environment names before Lua runs. The manifest decoder separately rejects
duplicate target and configuration identities.

Startup decodes the trailer and complete manifest from the retained artifact
descriptor. It proves that the selected entry matches the core compiled for
this process. It hashes the retained core descriptor and compares its device
and inode with the executing image. The shell's choice is a request, not
authority.

Startup keeps the artifact descriptor for the process lifetime. Rename,
unlink, or atomic replacement of the logical pathname cannot change the bytes
used by this process. Editing the same inode in place is unsupported. Failures
name the violated contract, close adopted descriptors, and exit before the
module store opens.

A running program can start itself again without its launcher.
`Proc.relaunch` describes the exact process: the physical core it is running,
`--artifact` with its logical path, its retained artifact descriptor and a new
descriptor on its core, and the private contract naming both, filled from the
manifest entry startup already validated. The child's startup checks that
contract like any other, so a relaunch cannot land on a different core: a
checked build relaunches as a checked build, and `cosmic test` workers run
under the runtime identity their verdicts are recorded for.

## expose one immutable database

[`core/vfs.c`](../../core/vfs.c) registers a small SQLite virtual file system.
Its only main file is the validated database range on the retained artifact
descriptor. Reads outside that range fail. The logical executable path is an
opaque SQLite key; the VFS never reopens it.

SQLite opens the range read-only with `immutable=1`. The runtime creates no
journal beside the artifact. [`core/store.c`](../../core/store.c) installs the
database as the last module source and derives runtime metadata from validated
startup context plus the projection's `runtime_basis`.

This immutable shipped database is distinct from `o/build.db`. The latter is
ordinary mutable developer state and can have SQLite journals. Investigation
of delayed cold-journal materialization for that working database remains a
follow-up. It has no established cause or fix, and does not change the
portable artifact's immutable database contract.

## build a project with the same prefix

`cosmic build` enters [`build.embed`](../../build/embed.tl). It stages and
compiles the project into the project's `o/cosmic.db`. The projection copies
needed standard-library modules, then adds project modules, files, and a main
entry.

The output database contains no raw cores. `embed.tree` obtains the exact
retained prefix and calls `artifact.program` for each application. Applications
built together share launcher, core, and manifest bytes while their database
suffixes differ. Output appears only after the complete database and program
are written. A library tree with no `cmd/<name>/main.tl` produces no executable.

`cosmic build --host` writes a host program instead: the running core's exact
bytes at the start of the file, zero-filled to the core alignment, one manifest
entry naming that core at offset 0, the database, and a trailer whose magic is
`CosmicH1`. The kernel executes it directly. At startup the core finds its own
trailer through its executable, checks the same structure the portable decoder
does, and opens the database range; no launcher, cache, or private environment
is involved. It hashes its own core only when something asks for the runtime
identity that digest is part of, and reports none if the manifest names another
digest: the kernel ran these bytes, so a check at startup would prove nothing a
changed image could not also claim. A host program runs only where its core
does, and cannot supply the portable prefix, so `cosmic build` from one writes
host programs only.

## rebuild without replacing cores

Two own-tree paths compare fingerprints through
[`build.reboot`](../../build/reboot.tl): `cosmic test` and direct execution of a
Teal source file. A Teal-only change can reuse the validated prefix. The
rebuild projects a new database, combines it with that prefix, atomically
replaces the logical artifact, and re-executes the original arguments and
environment once.

The logical artifact is the path returned by `Proc.executable()`. Running a
copy outside the checkout rewrites that copy; it does not redirect the rebuild
to `o/bin/cosmic`. A read-only logical path therefore fails. Rename and unlink
remain supported because the running process reads the retained descriptor.

A marker rejects a second rebuild loop. A core-input change cannot reuse the
prefix and exits with the instruction to run `bin/zig build boot`. This keeps a
database-only rebuild fast without claiming old native code matches new C,
Zig, or vendor inputs. Retained-descriptor access also lets a database-only
rebuild finish after the starting artifact is renamed or unlinked.

## test identity and transport

[`build.test`](../../build/test.tl) keys a verdict by the compiled test, runtime
identity, and supported observations. Those observations include file contents,
stat results, directory listings, and environment reads. A test that spawns a
process, or reads outside the tree beyond its temporary directories, is not
answered from a stored verdict. An unchanged application database cannot hide a
changed core or runtime basis. Verdict and coverage history live only in
`o/build.db` and are bounded.

The fixtures under [`test/portable`](../../test/portable/) and the pinned CI
driver's isolated fixture projects (`ci`, see its own README)
divide the runtime contract into observable boundaries:

- `format_test.tl` and `format_test.c` reject malformed lengths, offsets,
  identities, overlap, padding, and database headers.
- `launcher_test.tl` covers cache policy, digest failures, descriptor
  pressure, signals, and publication races.
- `runtime_test.tl` covers retained descriptors, replacement and unlink,
  immutable database reads, and mismatch rejection.
- `self_rebuild_test.tl` proves one re-entry, exact prefix reuse, and
  core-change refusal.
- `identity_test.tl` moves one working database through release and
  checked contexts and proves which verdicts run or stand.
- the pinned CI driver's own snapshot and boundary checks
  (`ci/cosmic_ci/orchestration.tl`) snapshot the raw working database
  immediately and across a workflow boundary. Integrity checks use
  disposable copies, so inspection cannot recover or alter captured bytes.

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) builds and tests
the release product independently on Linux x86-64, Linux ARM64, macOS ARM64,
and Alpine x86-64 -- the last running as a job container on an Ubuntu runner,
building and testing natively on musl/BusyBox like every other leg. Every
matrix leg runs the checked core, runtime fixtures, identity proof, and
delayed database boundaries. Each producer records the product hash before
and after execution; the provenance join requires all four uploaded `cosmic`
files to match those attestations and each other.

These lanes express the support rule: a target exists only when Zig builds it,
its native runner executes the suite, and the portable boundary tests pass.

## trust boundaries and limits

- Generated target records authorize identities. Host strings alone do not.
- The cache parent belongs to the user. The cache leaf is checked every start.
- C validates the shell handoff against retained bytes and compiled identity.
- A retained descriptor, not a pathname, identifies the running artifact.
- The VFS exposes only the validated database range and never writes it.
- The working database is mutable local state. It never ships.
- Atomic replacement after adoption is supported. In-place mutation is not.
- Release artifacts select configuration 1. Checked artifacts select their
  single configuration-2 host entry and exist for tests.

These divisions keep failures local. The shell can refuse an unsafe cache
without parsing SQLite. Startup can reject a forged handoff without trusting
the shell. SQLite can read an immutable range without knowing the portable
format. The build can replace a database suffix without rebuilding native
cores.

## check the contract from inside

The contract above is observable from any program the artifact runs, so
the guide checks it here rather than only in shell fixtures. Every
identity key answers from the validated startup context, the artifact
path is the one the launcher was given, and none of the private launcher
names survive into the environment:

```teal
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")

for _, key in ipairs({ "host", "host_image", "runtime", "runtime_basis" }) do
  assert(Store.meta(key) ~= nil and Store.meta(key) ~= "", key)
end
assert(Store.meta("runtime_context") == "portable-v1")
assert(Store.meta("artifact") == Proc.executable())
for _, name in ipairs({ "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
                        "COSMIC_PORTABLE_CORE_SHA256" }) do
  assert(Env.get(name) == nil, name .. " escaped startup")
end
print("identity: from the validated artifact")
```

```output
identity: from the validated artifact
```

The manifest entry selected for this host names exactly the bytes this
process runs. `host_image` is the digest of the running core, so the
entry carrying that digest is the selected one, and hashing its range
back out of the artifact file gives the same answer:

```teal
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local fixture = require("test.portable.artifact_fixture")

local path = assert(Proc.executable())
local artifact = assert(fixture.read(path))
local running = assert(Store.meta("host_image"))
local selected: fixture.Entry = nil
for _, entry in ipairs(artifact.entries) do
  if Hash.hex(entry.digest) == running then
    assert(selected == nil, "two manifest entries carry the running digest")
    selected = entry
  end
end
assert(selected ~= nil, "no manifest entry carries the running digest")
local bytes = assert(Fs.read(path))
local range = bytes:sub(selected.offset + 1, selected.offset + selected.length)
assert(Hash.hex_sha256(range) == running)
print("manifest: names the running core")
```

```output
manifest: names the running core
```
