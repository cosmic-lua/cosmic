# Portable launch experiment

Started from `next` at `af40d2cef939b8ecee3f5380ff7fb2566b4ba7f8`.
This is an experiment, not the release format. The default build and runtime
are unchanged. `-Dportable-probe=true` substitutes a small entry wrapper that
lets the existing core find its database in a separately named artifact.

## Questions and measurements

Can shell `exec` select a native image inside a larger file without copying?
`probe.c` uses direct exec calls (no shell fallback) to distinguish:

- ordinary native execution;
- an executable embedded at offset 16384;
- seeking a regular descriptor before execution;
- executing a pipe descriptor;
- Linux `memfd_create` followed by copying and `fexecve`;
- a Mach-O fat header that describes a native slice at offset 16384.

A payload exits 42; a returned exec error exits 111. Unexpected signals fail.
The native-descriptor path on macOS is observed without requiring success:
macOS does not supply Linux's fexecve path, so the probe uses `/dev/fd`.

Linux locally: only the native file, the seeked native-file descriptor, and
copied memfd execute. The seek does not move the loader's origin. The prefixed
image is ENOEXEC, including through a seeked descriptor; a pipe is EACCES.
macOS results are recorded by the `portable experiment` workflow.

A shell exec supplies a pathname, not an offset. A native executable needs a
recognized header at the loader's origin. Linux checks ELF magic and machine;
macOS understands fat Mach-O slices, but that header is not an ELF header or a
shell shebang. A stock shell cannot invoke arbitrary embedded machine code.
A memory-backed copy avoids a disk cache on Linux but still needs a native
helper and still copies. It does not solve the initial helper bootstrap.

References:

- [Linux ELF loader](https://github.com/torvalds/linux/blob/master/fs/binfmt_elf.c)
- [Apple exec](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
- [APE startup](https://github.com/jart/cosmopolitan/blob/master/ape/ape.S):
  its shell stub explicitly extracts a loader or rewrites the executable
  header. Neither technique requires ZIP; ZIP is a separate payload choice.

## Shared-database prototype

```
bin/zig build boot -Dportable-probe=true
experiments/portable/pack.sh
experiments/portable/check.sh "$PWD/o/portable/cosmic"
```

The file consists of a 16 KiB shell header, three aligned native cores, one
SQLite database, and the existing Cosmic trailer. The cores are uncompressed,
each present once. A copy of the normal database is vacuumed after deleting
its redundant compressed core rows and host-specific runtime metadata.

The launcher copies only the selected core, once per core hash, to an explicitly
provided private cache. Atomic hard-link publication handles competing first
launches without replacing an executing core. The selected core reads the
shared database through Cosmic's existing offset VFS. No database extraction,
Cosmopolitan, APE, binfmt_misc registration, ZIP runtime, or network is used.
macOS core bytes retain the linker's signature exactly: padding between cores
is not extracted. The system verifies the extracted signature in CI.

The workflow builds ONE artifact on Linux and downloads those identical bytes
onto Linux x86-64, Linux ARM64, and macOS ARM64. Each host runs loader probes,
cold concurrent launches, docs lookup, warm launch with a read-only cache,
renaming, and compilation/execution of Teal with whitespace/empty arguments,
stdin, and a nonzero exit. Artifact and core checksums must remain unchanged.
The regular suite also runs against the experimental native entry before
packing; that is not a claim that the portable build pipeline is complete.

## What can be shared

All Teal source, bytecode, docs, compiler, and assets are shared physically in
one database. The native sources and build recipe are shared, but there are
three machine-code images. x86-64 and ARM64 need different instructions;
ARM64 Linux and macOS also have different executable formats, startup,
relocations, libc references, and OS interfaces. Sharing their instruction
bytes would require a deliberate common ABI and custom linking/loading,
not just combining today's ELF and Mach-O outputs.

A smaller extracted loader could map a larger shared payload in place. That
trades copying a roughly 2 MB core once for maintaining a loader (mapping,
relocations, TLS, libc initialization, macOS signing and dyld interactions).
Measure before taking that trade. APE's lesson is the separation between
bootstrap, loading, and libc portability; these are distinct problems.

## Deliberate limits

- Cache root is supplied and trusted. Ownership checks, cache corruption repair,
  cache cleanup, default locations, noexec handling, and authenticated artifact
  distribution remain design work. A checksum here detects a bad extraction;
  it does not authenticate an artifact or defend against its owner.
- Startup still locates then reopens a pathname, like today's core. A final
  design should retain one artifact handle and require atomic replacement,
  never in-place mutation. These update races are not solved by this probe.
- Proc.executable names the actual extracted native core. Program-artifact
  identity and re-execution deserve a separate explicit interface.
- Build output and self-rebuild are not adapted. Host-specific metadata is
  removed rather than falsely reporting the Linux packer's identity on Mac.
  Portable cross-build and test-verdict identities remain follow-up work.
- The source artifact must remain available for database reads. A cache alone
  is not a copy of the program.
- The launch protocol is experimental, not a public --artifact CLI commitment.
- Shell and baseline host utilities are dependencies. No compiler or SQLite
  CLI is required on a machine that only runs the portable artifact.
- macOS ad-hoc signature validation does not establish Gatekeeper/notarization
  behavior for downloaded programs; CI does not emulate a quarantined download.
