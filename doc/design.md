# cosmic

cosmic is a runtime for building correct, self-contained command-line
software. one file holds the language runtime, the compiler and type
checker, the formatter, the test runner, the standard library, and
the documentation, and it works offline on Linux and macOS. programs
written for it ship the same way: one executable, built by cosmic,
that carries everything it needs.

the language is Teal, typed Lua. the runtime is Lua 5.5 in a C core.
the store is SQLite.

## promises

1. **no silent bugs.** types never lie: every fallible signature
   admits failure, the checker has no escape hatch, and untrusted
   data enters through a declared shape. documented behavior is
   verified behavior: every snippet in a doc runs. the parsers that
   face untrusted input are fuzzed.
2. **efficiency.** a builder with only the binary, human or agent,
   completes real work with less friction than on Python, Node, or
   Go. the measure is a fresh agent given the binary and nothing
   else, journaling what slowed it down.
3. **self-sufficiency.** everything needed and nothing to install.
   the same binary builds executables for every supported target,
   offline.

## principles

stated once, applied everywhere. a proposal that violates one of
these argues with the principle, not with the reviewer.

1. **size yields to consistent behavior across targets and to
   performance.** a bigger binary is paid once per download; a
   behavior that differs by OS, or a hot path left slow to save
   bytes, is paid on every run. growth is named in the size report,
   never silent.
2. **position is the manifest.** `*_test.tl` is a test, `cmd/<name>/`
   is a binary, a name that starts with a capital letter is public
   and every other name is private to its tree, the root is the
   module root. no list to maintain, none to go stale.
3. **honest returns.** `T | nil, string` for a value, `boolean,
   string` for an effect, two slots and nothing in a third, a
   structured error record when the failure has shape. a throw or
   exit carries a trailing reason and is exceptional by construction.
4. **no escape hatch in the type layer.** casts are foreclosed;
   `any` lives only where untrusted data enters and a shape validator
   turns it into a record.
5. **the least tree that keeps its promises.** a module exists when
   the tier order pulls it and it earns its place.
6. **`skipped` is reported, never silent.** enforcement is a
   property of the host. anything that can be half-enforced reports
   per section.
7. **no network in a build; one external tool.** every input is in
   the repository. the one thing a fresh clone needs is the pinned
   zig.
8. **docs are always right.** a disagreement between doc and code is
   fixed in the code, and every snippet runs or says why not. tests
   run because they are defined. gates end in a verdict line. an
   error-site hint beats a gotcha doc beats guide prose.

## targets

Linux on x86_64 and aarch64, statically linked against musl. macOS
on aarch64 and x86_64 against libSystem, which cannot be linked
statically but is always present, so the one-file property holds on
both. Windows runs the Linux binary under WSL2.

every cosmic binary carries the core image for all four targets, so
any host builds any target offline with nothing fetched.

## the stack

```
kernel                               Linux; macOS
  libc                               musl, static, from the zig pin (Linux)
                                     libSystem (macOS)
    lua 5.5                          vendored pristine
    sqlite3                          vendored pristine
    mbedtls 3, miniz, argon2,        vendored pristine
    a regex engine
    syscall table                    C, one function per syscall
  cosmic binary
    modules in a sqlite database     the only module source
    teal compiler + checker          vendored tl, carried patches
    cosmic.* stdlib in teal          typed wrappers, honest returns
    docs, records, coverage,         rows in the same database
    the four core images, CA roots
```

### toolchain

the host language is C: Lua, SQLite, and the small libraries are the
C they ship as. one pinned zig is the compiler and the build for the
C core: `zig cc` cross-compiles all four targets from a Linux lane,
and `build.zig` compiles the vendored C. `build.zig` is a source list
and flags, nothing more, so a zig bump costs an hour.

zig's bundled musl is the libc on Linux and its libSystem stubs are
the link target on macOS. the zig pin is therefore the libc pin. a
file names the zig version and the sha256 of each host's tarball; a
tiny POSIX sh `bin/zig` fetches into a cache, verifies, and execs;
`build.zig` refuses any other version by name. CI runs the same
script, so the pinned bytes are the only zig anything runs.


the four shipped images are built ReleaseFast. the Linux lane builds
a fifth core in ReleaseSafe with ASan and UBSan and runs the whole
test suite and the fuzzers under it on every push, so undefined
behavior in C is caught before it ships and nothing sanitized ships.
a `cosmic-debug` asset, the same sanitized build published beside
the release, is added once the fuzzers exist.

the C layer is POSIX plus a declared platform seam: no signalfd,
inotify, epoll, or procfs outside modules guarded as Linux-only.

### the line between C and Teal

the core is a syscall table plus a few vendored libraries; anything
with a policy in it is Teal, stored once in the database and shared
by every target.

native, per target: the Lua VM; SQLite; mbedtls, which also serves
hashing and HMAC; miniz for deflate; argon2; a regex engine; the
syscall table; the database VFS and the entry.

the syscall table is one C function per syscall with the same
signature on Linux and macOS, written by hand in one strict shape in
one annotated header, `core/syscalls.h`. the Teal declaration and the
doc row for each function are generated from that header when the
core first runs over the tree, and the generator refuses any function
whose annotation is incomplete, so a binding cannot exist without its
type and the C surface cannot grow without a diff in that header.
argument-shape errors raise; runtime failures return `nil, err,
errno`.

never borrowed from the libc where semantics are observable: regex,
DNS resolution, anything locale-shaped. musl and libSystem agree on
`open`; they do not agree on `regcomp`'s corners or `getaddrinfo`'s
ordering. the regex engine is a standalone extraction of musl's
TRE-derived one, about 4,300 lines, compiled the same on both OSes.
DNS is a resolver in Teal over UDP and TCP, reading
`/etc/resolv.conf` and `/etc/hosts`, which both OSes have; this also
keeps Mach services out of the macOS sandbox profile.

Teal by default: filesystem policy (walk, find, atomic write), child
processes above spawn and wait, sandbox policy over raw enforcement
syscalls, URL, SSE, tar, the zip directory, the whole build including
the Mach-O writer and ad-hoc signer. C when a benchmark on a real
scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists: JSON both directions and HTTP/1.1 framing
start in C on that rule. the benchmark harness, not taste, moves a
module across the line in either direction.

### the lua surface

the global environment holds Lua's pure libraries and nothing that
reaches outside the process: `string`, `table`, `math`, `utf8`,
`coroutine`, and the base functions minus `dofile` and `loadfile`.
`package` keeps `loaded`, `preload`, and `searchers`, and the one
searcher reads the database; `path`, `cpath`, `loadlib`, and
`searchpath` do not exist. `io`, `os`, and `debug` are not globals.
files, environment, time, and processes are `cosmic.Fs`,
`cosmic.Env`, `cosmic.Time`, and `cosmic.Proc`, all over the syscall
table, so the same call behaves the same on both OSes and the
sandbox has one door. `print` writes through the syscall table.
`debug` is reachable only by the test runner and the coverage
collector through a private binding. a name that is missing errors
with the module that replaces it.

the vendored `tl.lua` uses six `io` and `os` functions. the importer
loads it in an environment that supplies those six over the syscall
table; the compiler is not patched for it.
### the database

`require` reads the database and nothing else; a `.tl` on disk is
input to the build, never to the runtime. one database holds:

- **modules**: import path, source hash, Teal source, compiled Lua
  and bytecode, declaration, kind (module, test, example, benchmark,
  binary entry).
- **docs**: extracted per symbol, queried by `cosmic docs`.
- **records**: test verdicts and coverage keyed by source hash.
- **payload**: for an embed-built executable, the user's files.
- **images**: the core executable for every target.
- **roots**: Mozilla's CA bundle.

all four targets are little-endian 64-bit, so one bytecode column
serves them all, verified by a test that each image loads it. the
core image column is the only per-target data.

the binary carries its database attached to the executable. on ELF
it is appended and located by a trailer at end of file. on Mach-O it
sits inside an extended `__LINKEDIT` segment, followed by a fresh
ad-hoc code signature that covers it, because arm64 macOS refuses a
binary with bytes after its signature. the runtime opens it through
its own small VFS, a ~300-line shim that reads the executable at an
explicit offset; the offset comes from a ten-line locator per
format, the ELF trailer or the Mach-O signature's data offset, and
nothing else in the VFS knows which format it is in. the Mach-O
writer touches `__LINKEDIT`'s size, the signature's offset, and the
signature itself, and nothing else in the file. the last partial
page is hashed over its real length, never zero-padded.

the database is opened read-only with `immutable=1`, so SQLite
never attempts a lock, a journal, or a WAL beside a file it cannot
write. it cannot write it: Linux refuses to open a running
executable for writing, and macOS kills a process whose signed pages
change. mutable state lives in an ordinary file. a program that
ships a dataset it updates copies it out once with `VACUUM INTO`, or
attaches the embedded database read-only beside a writable one and
queries across both.
- **the public namespace**: whether public modules are
  `cosmic.<Name>` under `cosmic/` or `<Name>` at the root.
