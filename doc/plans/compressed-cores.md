# Compressed cores

The three cores are about 12.8 MB of a portable artifact: most of a program,
and about half of the tool. This plan weighs ways to store them compressed
and recommends one. It is research and a proposal: nothing here is built.

Figures are marked **measured** (run on this tree, on an x86_64 Linux box with
4 cores, files in the page cache) or **estimated**. Where a figure comes from
the cores of an earlier build, it says so.

## What the artifact does now

A portable artifact ([`doc/design.md`], [the portable runtime guide]) is, in
order:

| Region | Size |
| --- | --- |
| `#!/bin/sh` launcher, padded with a `#` comment | 16 KiB, of which about 13 KB is script (measured) |
| one raw core per target, each starting on a 16 KiB boundary | 4.38, 4.09 and 4.30 MB (measured) |
| manifest: a 32-byte header, then a 56-byte entry per core (target, configuration, offset, length, SHA-256) | 4 KiB |
| the SQLite database | 3.1 MB for a hello-world program, 12.0 MB for the tool (measured) |
| trailer | 48 bytes |

[`build.artifact`] writes it, [`core/portable.c`] decodes it again at startup,
and the launcher template ([`build.launcher`]) gets one `case` arm per target
carrying that target's offset, length and digest. The manifest is the
authority; the arms are generated from the same records.

### Extraction

The launcher runs on a cold start only. Given a `uname -sm` match, it:

1. refuses a CPU below the core's baseline, before it writes anything;
2. opens the artifact once, on a private descriptor in 3 to 9, and keeps it
   open until it executes the core: extraction reads that descriptor and never
   reopens the path;
3. picks the cache leaf (`COSMIC_PORTABLE_CACHE`, else `$XDG_CACHE_HOME`, else
   `$HOME/.cache/cosmic/cores`, `~/Library/Caches` on macOS, else a leaf in the
   temp directory named for the user) and checks it: not a symlink, a
   directory, owned by this user, not writable by group or others;
4. names the entry `core-<target>-<configuration>-<length>-<sha256>`;
5. makes a staging file with `mktemp` (mode 0600) in the leaf, then runs
   `dd bs=16384 skip=<block> count=<blocks> <&fd | head -c <length>` into it;
6. checks the staged size with `wc -c` and its SHA-256 with `sha256sum` or
   `shasum -a 256`, sets mode 0500, and publishes it with `ln -T` (`ln -h` on
   macOS), a hard link that cannot replace an existing entry. A launcher that
   loses the race inspects the winner. The staging file is removed;
7. repairs an invalid entry (wrong kind, owner, mode, length or digest, or a
   symlink) under a hard-link lock, or stops where the cache is read-only.

POSIX has no `pipefail`, so a failed `dd` is caught by the size check, and
equal-length corruption by the digest.

### The warm path

When the entry exists, the launcher does one `stat` for the leaf and the
entry, checks kind, owner, mode 0500 and length, and hashes the entry only if
the stamp beside it (`.verified-<entry>`, written by startup after it hashed
the core) no longer matches the entry's size, inode and times. It then
`exec`s the entry as `<core> --artifact <artifact> ...`, with the
`COSMIC_PORTABLE_*` contract in the environment. Measured on this box with
the host-only tool: a cold start takes 55 to 58 ms and a warm one 38 to 44 ms,
so extracting one raw core costs about 17 ms, with the artifact in the page
cache.

### Startup and the digest

Startup ([`core/startup.c`]) compares the launcher's offset, length and digest
with the manifest's selected entry, checks the retained core descriptor is a
regular file of that length, hashes it unless the stamp holds, and checks it
is the same inode as the physical executable. Everything the runtime says about
the core is the digest of the **raw core**: the cache key and the stamp, the
`host_image` and `runtime` metadata, and a test verdict's key
([`build.core_image`] keys a core that carries DWARF by its mapped image
instead, and a release core by its bytes).

Three readers take the stored bytes rather than running them:

- `trusted_prefix` ([`core/store.c`]) rehashes every core range of the
  artifact before returning the prefix that `cosmic build` copies into a
  program. That is a SHA-256 of about 12.8 MB on every portable build.
- `trusted_core` returns the running core's bytes from the artifact range, for
  `cosmic build --host`, which writes the core at the start of the file with
  the database behind it.
- [`build.artifact.keyed_head`] ([`build.artifact`]) takes a head apart to key a
  verdict, and edits the launcher arms' `cosmic_offset`, `cosmic_block`,
  `cosmic_length` and `cosmic_sha256` fields by text.

### What the launcher holds

These are the properties a change must keep:

- **Digest before execution.** No byte of a core runs before its length and
  SHA-256 match the manifest's, whether extracted now or found in the cache.
- **No reopen by path.** The artifact is read through one descriptor, and
  startup requires the core descriptor to be the physical executable.
- **Leaf ownership and mode.** The leaf is owned by the user and not writable
  by group or others. An entry is a regular file owned by the user with mode
  0500. Nothing is followed through a symlink, and publication cannot replace
  a file. The leaf's parent is the documented trust boundary, not something the
  launcher defends.
- **Atomic, unobservable publication.** A reader sees an absent entry or a
  complete, verified one.
- **No new trust.** The launcher needs only utilities it already needs. A core
  runs only on a CPU that meets its baseline, and a `noexec` cache gets a
  stable diagnostic.

The launcher's utilities are `uname`, `stat`, `id`, `mkdir`, `chmod`, `mktemp`,
`dd`, `head`, `wc`, `ln`, `rm` and `sha256sum` or `shasum`
([`test/portable/README.md`]). `gzip` is not among them.

## What compression would save

Measured on the three release cores of an earlier build, one setting each:

| Core | Raw | zstd -19 | gzip -9 | xz -9e |
| --- | --- | --- | --- | --- |
| x86_64-linux-musl | 4,381,056 | 1,796,276 | 2,056,943 | 1,683,572 |
| aarch64-linux-musl | 4,089,376 | 1,685,953 | 1,941,460 | 1,456,016 |
| aarch64-macos | 4,296,488 | 1,631,170 | 1,900,928 | 1,415,540 |
| **total** | 12,766,920 | 5,113,399 (40.0%) | 5,899,331 (46.2%) | 4,555,128 (35.7%) |
| **saved** | | 7,653,521 | 6,867,589 | 8,211,792 |

The x86_64 core of the current main is 4,571,248 bytes (measured), and
compresses to 1,862,047 (zstd -19, 40.7%), 2,130,132 (gzip -9, 46.6%) and
1,743,068 (xz -9e, 38.1%). `xz --x86` before LZMA2 takes it to 1,680,764
(36.8%). [`cosmic.compress`]'s miniz writes a gzip stream of 2,131,202 at level 9
and 2,130,611 at level 10, within 0.1% of the `gzip` command.

Cores are the bulk of a program. A hello-world built with `cosmic build
--host` is 7,696,432 bytes (measured): the 4.57 MB core and 3,104,768 bytes of
database. A portable one is about 16 MB (estimated: three cores and that
database), so compressing the cores with zstd takes it to about 8.6 MB
(estimated). The tool is about 25 MB (estimated; the host-only tool measured
here is 16.6 MB with two placeholder cores).

A cross-target solid archive does better still (xz -9e of the three cores
joined: 4,061,180, against 4,555,128 apart), but decoding one core would then
mean decoding those before it. That is not worth 0.5 MB.

## Options

Every option but "do nothing" needs the same change to the format. The
manifest entry's offset, length and digest now describe both the stored bytes
and the core, so they must be split: the **stored range** (offset, length, and
optionally a digest) is what the launcher cuts out, and the **core** (length,
digest) is what it publishes, caches and starts. What differs between the
options is how the launcher turns one into the other.

### 1. The host's `gzip -dc`

The launcher pipes the stored range through `gzip -dc` (`zcat` is `gzcat` on
macOS) into the staging file, and keeps its size and digest checks.

| | |
| --- | --- |
| Size win | 6.87 MB of 12.77 (measured, system gzip); the build can write the stream with [`cosmic.compress`] and no outside tool |
| First run | `gzip -dc` of the x86_64 core takes 45 ms (measured, 5-run mean, including the shell and process), against 6 ms for the `dd | head` it replaces |
| Steady state | none: the warm path never reaches it |
| Complexity | smallest: about five lines of shell, one more utility to name |
| Portability | gzip is near-universal but POSIX does not require it, and no minimal container image is guaranteed to carry it. A host without it cannot start the artifact at all, with the raw cores gone, so the failure is new. Not checked here: whether a given minimal image or macOS release lacks it |
| Security | the decoder is a host binary found on `PATH`, as `sha256sum` is. The output is checked by length and SHA-256 before it runs, so a wrong or hostile `gzip` can only fail the launch. Stays inside the trust boundary the launcher already has |

The launcher could fall back to a raw core where `gzip` is missing, but that
means shipping both, and saves nothing.

### 2. A decoder stub per target, stored raw

The artifact carries a small static decoder for each target, as a manifest
entry of its own. The launcher cuts out the stub for the host's target with
`dd`, as it does a core, checks its length and SHA-256, makes it mode 0500,
runs it on the stored range (`dd | head -c <stored> | stub <length> >
"$stage"`), and then checks the output as it does now. The stub is removed
after use; there is nothing to repair.

I built decode-only programs with `bin/zig cc -Os` from the vendored sources,
one per target, linked static (musl on Linux), with dead code stripped, at each
architecture's baseline CPU. Each decoder round-trips a real core byte for byte on this box (the x86_64
builds; the others were built, not run, because the box has no emulator). The
prototypes read stdin and write stdout; they do not yet enforce the output
length the design below asks of the stub.

| Decoder (source) | x86_64-linux | aarch64-linux | aarch64-macos | Total |
| --- | --- | --- | --- | --- |
| deflate (miniz's `tinfl`) | 11,064 | 10,416 | 50,552 | 72,032 |
| zstd (`ZSTD_decompressStream`, no legacy formats, Huffman X1 only) | 81,680 | 52,544 | 103,552 | 237,776 |
| xz (the vendored liblzma decoder subset, LZMA2 and BCJ) | 64,376 | 60,416 | 104,592 | 229,384 |

The macOS builds are carried by Mach-O page alignment and a code signature
(each has an `LC_CODE_SIGNATURE`, which zig's linker writes ad hoc), not by
code. Padding each stub to the core alignment adds at most 16 KiB each.

Decode time of the x86_64 core (measured, 5-run mean, process included):
zstd 18 ms, miniz 22 ms, xz 106 ms. A SHA-256 of the same bytes takes 7 ms.

| | zstd | deflate | xz |
| --- | --- | --- | --- |
| Size win, minus stubs | 7.42 MB | about 6.80 MB | 7.98 MB |
| Cold start | about +18 ms, plus the stub's extraction, hash and `exec` (estimated 2 to 3 ms) | about +22 ms | about +106 ms |
| Warm start | none | none | none |
| Can the build make it with what is in the tree? | yes ([`cosmic.compress`] has a zstd encoder, level 1 to 19) | yes (miniz) | **no**: the vendored xz is decode-only ([`cosmic.compress`] has no xz encoder), and the build may not call the host's `xz` (design.md: no bytes from outside the tree and the pinned zig reach a production output) |

The choice is therefore zstd or deflate. zstd saves 0.6 MB more once the stubs
are counted, decodes about as fast, and uses a library the core already links,
so its decoder is already reviewed and fuzzed with the core. Deflate has a
stub a third the size and the smallest code; it costs the 0.6 MB.

| | |
| --- | --- |
| Complexity | a new stub target in `build.zig` per target, a stub entry kind in the manifest, a second stage in the launcher, and tests for each. The most of any option except 3 |
| Portability | what the cores need already: static musl Linux binaries and an arm64 Mach-O. No host library, no new utility. The stub's CPU baseline is below the cores', so the existing CPU check needs no change |
| Security | a second executable is run before the core is trusted, but the stub is held to the same checks: it is cut from the artifact descriptor, verified by length and SHA-256 against the manifest, and staged in the already-validated leaf. It touches neither the cache nor the network: it reads stdin, writes stdout, and takes the output length as its only argument, refusing to write more. A decoder bug cannot widen what the artifact is trusted to run: the artifact's own author chose the stored bytes, and the output is hashed before it runs. Corrupt stored bytes fail the launch. A `noexec` leaf now fails at the stub, so the diagnostic must keep its stable wording there too |

### 3. A self-decompressing core

The core would carry a small uncompressed loader and its own payload, as UPX
does. The launcher would be unchanged, and a host program (`cosmic build
--host`) would shrink too.

I rule it out; this is an assessment, not a measurement:

- It decodes on **every** start, not once. Its memory is private, not the page
  cache's shared file pages, and every instance pays it: at about 18 ms and
  4.4 MB resident per run.
- On Linux a loader that runs the unpacked image must be an ELF loader of its
  own, or `memfd_create` and `exec` it, which leaves the file the kernel maps
  not the one the startup checks (`/proc/self/exe`, the stamp, the physical
  inode) are about. Every one of those checks is written against the cached
  core being the core.
- On macOS the code signature covers the file's pages. UPX has no arm64 Mach-O
  support, and an in-memory image would need `MAP_JIT` or an entitlement.
- It changes the core's build and its sanitized variant, and weakens "one core,
  one set of bytes to verify".

### 4. Compress the database, or other parts

The cores are the largest part of a program, but not the only compressible one.

- A program's database is 3,104,768 bytes for hello-world (measured). Its
  `modules` table is 1.73 MB of it, holding 0.94 MB of raw bytecode and 0.70
  MB of source that is already raw-deflated. The whole file gzips to 1,655,270
  (53%).
- The tool's database is 11,972,608 bytes: `modules` 6.30 MB (3.73 MB raw
  bytecode, 2.24 MB deflated source), `docs` 1.76 MB, the docs' full-text index
  0.76 MB, `zoneinfo` 0.41 MB. It gzips to 6.27 MB and xzes to 5.20 MB
  (measured).

The runtime reads the database in place through an immutable VFS over the
retained descriptor, so the whole file cannot be compressed without a block
format and a decoding VFS. Per-column compression has a precedent in the
source column, which `inflate(X)` reads back. Compressing the bytecode column
saves about 0.5 MB in a hello-world (estimated) and about 1.8 MB in the tool
(estimated), at a cost on each `require`. That is a separate and smaller win,
with its own cost on every start, and belongs to its own plan. Nothing else in
the artifact is uncompressed: the launcher is 13 KB, the manifest 4 KiB.

### 5. Do nothing

The cache means a host extracts a core once per version. The cost of the raw
cores is not in the run:

- every transfer of the artifact: a release download, the driver pin's fetch,
  a container layer, a CI cache, a copy of a program to a server. A
  hello-world is about 16 MB (estimated), 80% of it cores.
- `cosmic build` rehashes 12.8 MB of core ranges and writes them out for each
  portable program.
- the cache holds one raw core per version and the artifact holds three.

Against that, the change touches the format, the launcher, the decoder, the
startup and the CI fixtures, and adds a second program that runs before the
first is trusted. The size win is 7.4 MB of about 16 MB for a program (estimated) and of
about 25 MB for the tool, roughly 30% of its release asset (estimated).

## What else changes

### The digest and the cache key

Keep the manifest's core length and digest as the digest of the **raw
core**. The cache entry name, the stamp, the launcher's `COSMIC_PORTABLE_CORE_*`
contract (its length and digest), startup's comparison, `host_image`,
`runtime` and a verdict's key then do not change, and a host with a warm
cache from before the change needs no extraction after it. A digest of the
compressed bytes would make the cache entry's name differ from the file's
digest, and startup would have to decode to compare.

The stored range needs a digest of its own for one reader: `trusted_prefix`
rehashes each range before reuse. With a stored digest it hashes 5.1 MB
instead of 12.8 MB. Without one it decodes each core, which the core can do
(it links all three decoders), at about 18 ms each. Add the digest: 32 bytes an
entry in a block with room for 8.

`trusted_core` returns the running core's bytes from the artifact range. With a
compressed range it must decode the range and check the result against the
raw digest, or read the core descriptor startup holds, which it now closes.
Decoding in C reuses the linked zstd and keeps the "no reopen" property.

### macOS: codesign and notarization

This is reasoning from how the files are made, not tested on a Mac.

- The macOS core is an ad-hoc-signed Mach-O (`LC_CODE_SIGNATURE` present on
  every aarch64-macos binary built here). The kernel checks the page hashes
  the signature carries when a page is read in, so one changed byte fails the
  run. Decoding to the raw digest gives back exactly the signed bytes, so the
  signature stays valid and nothing is re-signed on the host.
- [`bin/verify-codesign`] runs `codesign --verify --strict` on the raw core on
  the macOS lane. It sees the raw core when the lane reads it from the
  build's `core/` directory, as now, and the new stub needs the same call.
- Notarization is for a Developer ID signed app. Cosmic's artifacts are a
  shell script with ad-hoc signed binaries inside it, and are not notarized
  now. The files the launcher writes carry no quarantine attribute (a process
  created them), and the compressed ranges are never run, so the change adds no
  Gatekeeper assessment. A stub extracted on macOS is such a file too.
- The macOS stub must carry a signature, or the kernel kills it. zig's linker
  writes one, as the measured binaries show.

### `cosmic build` output and host programs

A program `cosmic build` writes copies the tool's prefix, so it shrinks as the
tool does, with no recompression, and ships the same stored cores. `cosmic
build --host` writes the running core raw, at the start of the file, so the
kernel can run it, and does not change.

### Reproducibility

The four platform lanes build the portable product independently and the
provenance join requires the bytes to agree. The cores are already
reproducible, so the stored ranges are if the encoder is.

- [`cosmic.compress`]'s zstd encoder is the vendored library, built without
  threads and with the assembly decoder and BMI2 dispatch off. Compressing one
  core twice gave the same SHA-256 (measured, x86_64). That the aarch64 lanes
  produce the same bytes is not yet measured; the join shows it.
- Changing the level, the zstd pin or a patch to it changes every artifact's
  bytes and every verdict key built on a head, as any change to a core does.
- Compressing is 2.05 s for the current x86_64 core at level 19 (measured), so
  about 6 s for three. Keyed by the raw digest, it can be cached in the build
  directory. A host-only boot could store its core raw.

### CI fixtures and tests that pin the format

All of these read the launcher arms, the manifest entry or the prefix:

- [`core/portable.c`], [`core/portable.h`] and [`test/portable/format_test.c`]:
  the decoder rejects an entry length other than 56 and a core range that is
  not minimally aligned; both change.
- [`build.artifact`] and its tests (`artifact_test.tl`, `artifact_fuzz_test.tl`),
  `build.launcher` and `launcher_test.tl`, whose header scan reads the fields
  of an arm.
- `ci/fixtures/`: `launcher_test.tl`, `launcher_noexec_test.tl`,
  `runtime_test.tl` (parses `cosmic_offset=`, `cosmic_length=` and
  `cosmic_sha256=` from the header and corrupts core ranges),
  `product_test.tl`, `identity_test.tl`, `self_rebuild_test.tl`.
  The launcher fixture's core is a stand-in; a stub needs its own stand-in
  payload per target, as `launcher_setup.tl` builds the core's.
- [`ci/cosmic_ci/orchestration.tl`] and `fixture.tl`, whose `--inspect` records
  list an entry by target and configuration.
- `keyed_head`'s edits of the arm text.
- The checked artifact's configuration-2 core is 38 to 50 MB with DWARF and
  exists for tests. A per-entry codec lets it stay raw.

Because the format changes, a stale tool cannot rebuild itself into it: the
change needs `bin/zig build boot` (and `-Dboot-cores=all` for the tests that
run the other cores), as [`doc/contributing.md`] already says for the artifact
and launcher. A cosmic release stays the same shape for the bootstrap: the
launcher inside each artifact is its own.

## Recommendation

Do option 2 with zstd. Option 1 saves a little less (6.9 against 7.4 MB) for a
dependency the launcher can't promise, and option 3 is a rewrite. Doing
nothing is defensible for programs but not for the tool's release asset.

Keep one decision open in the format: put a **codec** in each manifest entry
(raw, zstd) so that a core can stay raw (the checked core, a placeholder for a
host-only boot), and so a later codec or a gzip path
needs no new version.

### Stages

Each is its own PR from main and passes CI by itself.

1. **The stub program.** `build.zig` builds a zstd decode-only program per
   target at the baseline CPU, with a test that it round-trips the host's core
   and refuses a short, long or corrupt stream and an output past the length it
   was given. The `macOS` lane runs `bin/verify-codesign` on it. A ceiling on
   its size. No artifact byte changes.
2. **The format.** A version 2 manifest entry carrying the codec, the stored
   range and its digest, and an entry kind for a stub; the Teal writer, the C
   decoder, `format_test.c`, the fuzz tests, `trusted_prefix` over stored
   ranges, `trusted_core` by decoding, and `keyed_head`. The writer emits only
   raw entries here, so the bytes change in header and manifest alone. The
   documents change with it. Measure on the four lanes that the zstd output is
   the same, with a test on the join.
3. **The launcher and the switch.** The second stage in
   `build.launcher`, the stub's extraction, hash and cleanup, and the fixture
   cases: a stored range truncated or corrupted, a stub tampered with, a `noexec`
   leaf (the diagnostic names the stub), a read-only cache, concurrent cold
   starts, a signal during decoding, and the CPU refusal still first. The
   writer then emits zstd for the three release cores. `-Dboot-cores=all`,
   [`ci/run-local`], a Mac check by hand.
4. **Follow-ups.** Move the driver pin once a release has the change
   (`bin/cosmic todos '"cosmic-driver.pin"'`), and plan the database's
   bytecode column apart.

A decision gate sits after stage 1: if the stub on macOS is not accepted by a
real `codesign --verify --strict` run, stop and use deflate.

## Open questions for the maintainer

1. Is 7.4 MB of 16 MB for a program, and about 30% of the tool's release
   asset, worth a second stage in a launcher that today runs nothing it
   did not already have to?
2. zstd (7.42 MB net, 0.24 MB of stubs, a library the core links) or deflate
   (6.80 MB net, 72 KB of stubs, the smallest code)?
3. Should a host-only boot (`bin/zig build boot` without `-Dboot-cores=all`)
   compress its one core, costing about 2 s a boot, or store it raw?
4. Does the manifest version rise for portable and host programs together, or
   only for the portable one? A host program has one core and gains nothing.
5. May the 16 KiB launcher grow to 32 KiB? The script is about 13 KB, a second
   stage and wider arms add about 1.5 KB, and the header is paid by every
   artifact.
6. Is `gzip` a fair thing to require after all for the hosts the project
   supports, which would make option 1 a day's work?
7. Is an xz encoder worth vendoring? It gives 0.5 MB more over zstd, at five
   times the decode time and a larger stub.

[`bin/verify-codesign`]: ../../bin/verify-codesign
[`build.artifact`]: ../../build/artifact.tl
[`build.core_image`]: ../../build/core_image.tl
[`build.launcher`]: ../../build/launcher.tl
[`core/portable.c`]: ../../core/portable.c
[`core/portable.h`]: ../../core/portable.h
[`core/startup.c`]: ../../core/startup.c
[`core/store.c`]: ../../core/store.c
[`doc/contributing.md`]: ../contributing.md
[`doc/design.md`]: ../design.md
[`ci/run-local`]: ../../ci/run-local
[`test/portable/README.md`]: ../../test/portable/README.md
[the portable runtime guide]: ../guides/portable-runtime.md

[`build.artifact.keyed_head`]: ../../build/artifact.tl
[`ci/cosmic_ci/orchestration.tl`]: ../../ci/cosmic_ci/orchestration.tl
[`cosmic.compress`]: ../../cosmic/compress.tl
[`test/portable/format_test.c`]: ../../test/portable/format_test.c
