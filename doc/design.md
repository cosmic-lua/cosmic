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
   is a binary, a leading `_` is internal, the root is the module
   root. no list to maintain, none to go stale.
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
binary with bytes after its signature. the runtime opens it
read-only with `immutable=1`, so SQLite never attempts a lock, a
journal, or a WAL beside a file it cannot write. it cannot write it:
Linux refuses to open a running executable for writing, and macOS
kills a process whose signed pages change. mutable state lives in an
ordinary file. a program that ships a dataset it updates copies it
out once with `VACUUM INTO`, or attaches the embedded database
read-only beside a writable one and queries across both.

the build database on disk, `o/cosmic.db`, and the shipped one share
a schema; shipping is a `VACUUM INTO`.

sqlite is load-bearing at boot, so its sharp edges are the runtime's
problem and are fixed first: a typo'd or overlong parameter table
never binds NULL silently, TEXT and BLOB are distinguishable at the
Lua boundary, and a closed handle fails the same way from every
method. the build is single-threaded, so SQLite compiles with
`SQLITE_THREADSAFE=0` and without extension loading, shared cache,
double-quoted strings, or deprecated interfaces.

### the build

the build is a cosmic program reading the tree by position into the
database: compile, check, record, embed. the tool that runs the gate
is not the artifact under gate, so there is no fixpoint to prove.

`build.zig` owns the C. `zig build` produces the patch applier, the
patched vendor tree under `o/vendor/`, and the core for each target.
`zig build boot` bridges once: it runs the fresh host core over
`_build/` to compile the importer with the vendored `tl.lua`, writes
`o/cosmic.db`, and attaches it as `o/bin/cosmic`. a fresh clone and
CI run `boot`; a developer runs `o/bin/cosmic build` the other
hundred times a day, and touches `build.zig` only when C changes.

the build is fast, incremental, and reproducible, all three at once:

- *incremental*: a module row is keyed by the content hash of its
  source plus the hashes of its import closure; an unchanged key is a
  stat, a changed one recompiles and re-records only what depended on
  it. tests, coverage, and docs share the keys.
- *fast*: one process, one transaction, no subprocess per file; the
  checker and compiler run in-process against declarations already
  in the database.
- *reproducible*: the database bytes are a pure function of the
  tree. rows are written in a fixed order, no row carries a timestamp
  or an autoincrement counter, the database is built fresh in memory
  and never in WAL mode, and the shipped file is produced by `VACUUM
  INTO` with the header's change counter and version fields
  normalized. a second build of the same tree is byte-identical, and
  CI's repro lane asserts it.

`cosmic build` and `cosmic test` fence themselves with the sandbox
core, so a build cannot read outside its tree and a test cannot reach
the network by accident. CI's profile requires the fence; a laptop
reports it.

### vendored sources

`vendor/<name>/` is the extracted upstream tarball, never edited,
with a `PIN` file naming version and hash. `patches/<name>/` holds
records, each an exact `find`, a `replace`, and a `note` saying why
it exists. a ~200-line C applier that zig builds first writes the
patched copy to `o/vendor/<name>`; a record whose anchor no longer
matches fails the build by name. repo size is a one-time clone cost,
the cheap kind under principle 1.

vendored: Lua 5.5, the SQLite amalgamation, mbedtls 3.6, miniz,
argon2's reference implementation built without threads, the regex
engine, and tl.

### teal

tl vendored, carried patches, upstream-first and fork-if-blocked.
casts are foreclosed: `x as T` type-checks only from `any`, from a
userdata record declared in a `.d.tl`, or from the enclosing
generic's type variable. `any` is legal only where untrusted data
enters and a shape validator turns it into a record by construction.
no justification comments, no ledger.

the spirit is consistent, strong, explicit typing, the same shape the
languages that hold it converged on: the top type inert until
narrowed (Go, Luau's `unknown`), casts confined to subtype moves or
runtime-checked (Luau, Kotlin), the escape hatch in one greppable
region (Rust's and Go's `unsafe`), boundaries decoded through
declared shapes (serde, `json.Unmarshal`, Elm's decoders). a
runtime-checked cast is closed to Teal because Lua erases record
types, so shapes construct their records rather than asserting them.

two rules follow: `any` narrows only through `is`, a shape, or an
explicit `as`, never by assignment into a typed slot; and an
unannotated parameter or return is an error, never an implicit
`any`. the per-release report names the modules that cast from
`any`; the expected list is the shape module, the codec decoders,
and the C declaration layer.

### the runtime

one Lua state, one thread, coroutines over `poll`. every blocking
binding takes a timeout and can be driven from one event loop, which
is Teal over the `poll` binding; `http.serve` and `fetch` are
coroutine-driven; CPU parallelism is by process through `child`.

the C layer is re-entrant, which costs discipline, not code: no
static buffers, no process-global state outside the entry, every
binding takes its context explicitly, SQLite opened per connection
and never shared across a boundary that could later be a thread. one
state per OS thread with message passing stays open as a later
addition that rewrites no bindings.

### tls

mbedtls 3.6: TLS 1.2 and 1.3, one configuration, hashes and HMAC
from the same library. Mozilla's root bundle is stored in the
database, identical on every machine, moved only by a pinned bump;
an environment variable adds a certificate for the corporate-proxy
case without making per-machine trust the default.

### the sandbox

an opt-in library and the toolchain's own fence. default-deny for
user scripts is not promised; hard containment of a script is the
host's job, and the module makes it one call when a caller wants it
in-process.

the policy model is the intersection of Landlock plus seccomp and
Seatbelt: read, write, and exec under paths; network none, loopback,
or all; TCP connect and bind by port; spawn allowed or denied;
inherited by children and never liftable. per-host network rules are
an egress proxy on loopback on both OSes, the process allowed only
that port.

Linux extensions (seccomp syscall lists, a private network or mount
namespace, abstract socket scoping) may only deny what the core
allows, never allow what the core denies; macOS reports them
`skipped` by name. every section reports `full`, `degraded`, or
`skipped`: a Landlock ABI below 3 cannot restrict truncate, gVisor
has no Landlock at all, and neither is an error.

one conformance matrix (read inside and outside, create, unlink,
rename across the boundary, symlink escape, truncate, allowed and
denied ports, bind, spawn) runs under the same declared policy on
both CI lanes and fails on any cell that differs. equivalence is a
test, not a claim.

### the command line

verbs, with a bare path meaning run: `cosmic build`, `cosmic test`,
`cosmic check`, `cosmic fmt`, `cosmic docs`, `cosmic embed`; `cosmic
file.tl` runs a file; `-e` stays as Lua's one-liner idiom. every verb
takes paths to narrow it, ends in a verdict line and an exit code,
and `cosmic help <verb>` is the whole discovery surface. no other
stock-interpreter flags, no argv[0] personality.

### the repository

```
bin/zig             POSIX sh: fetch, verify, exec the pinned zig
bin/zig.pin         version and per-host sha256
vendor/<name>/      pristine upstream, never edited, with a PIN file
patches/<name>/     exact find/replace records, each with a note
core/               C: entry, VFS, the syscall table, build.zig
core/syscalls.h     the annotated header the .d.tl and doc rows derive from
cosmic/             the public API: cosmic.<name>, no leading _
cmd/cosmic/         the binary's entry
_build/             the importer, checker driver, embed (Teal, internal)
doc/                prose
o/                  output; o/cosmic.db; never committed
```

### the surface

the tier order is a reading order for what to write, not a size
target:

- **core**: `check`, `fs`, `child`, `env`, `proc`, `hash`, `sqlite`,
  `json`, `time`, `rand`, `flags`, `string`, `errno`, `errors`,
  `log`, `teal`, `format`, `test`, `coverage`, `doc`, `embed`,
  `shape`.
- **second**: `http`, `fetch`, `net`, `dns`, `re`, `zip`, `tar`,
  `compress`, `codec`, `url`, `ip`, `uuid`, `ksuid`, `sse`,
  `sandbox`, `signal`, `poll`, `fd`, `tty`, `ansi`, `user`, `sys`,
  `stream`, `deep`, `graph`, `fuzzy`, `literal`, `ast`.
- **later, if pulled**: namespaces and egress proxying beyond what
  the sandbox core needs, `shm`, `template`, `instrument`, `html`,
  `css`, `js`.

## sequencing

1. **hello from the database.** zig builds the applier, patches,
   builds the core; the core runs `tl.lua` to compile the importer;
   the importer writes `o/cosmic.db` with one module; the build
   attaches it; `cosmic hello.tl` runs on all four targets from
   byte-identical databases. proves boot, store, `require`, attach
   on ELF and Mach-O, cross-build, reproducibility. review.
2. **self-check.** `cosmic check` and `cosmic test` gate cosmic's
   own tree, incrementally, under the foreclosed-cast checker, with
   records in the database. proves the type layer, the build's
   incrementality, and that the tree can gate itself. review.
3. **the core tier**, then the second, each module earning its place.
4. **release**, when three things hold: cosmic builds and tests the
   work board, gitboard, from its own tree; the agent evaluation
   suite scores at or above its recorded baseline; the release job
   produces all four targets and the repro lane proves them
   byte-identical.

## open

- **the database VFS**: whether the runtime opens the attached
  database through its own ~300-line VFS given an explicit offset,
  with a per-format locator (the ELF trailer; the Mach-O signature's
  data offset), or through SQLite's `appendvfs` carrying a patch.
- **host language and toolchain**: Rust as the host was weighed and
  deferred; zig as the language was set aside. revisit against the
  design as a whole.
- **tl's `any` semantics** and implicit `any`: verify before
  milestone 2, patch if needed.
- **the core budget**: measure the per-target image after milestone
  1 and set the per-component line the size report carries; decide
  FTS5 on that number.
