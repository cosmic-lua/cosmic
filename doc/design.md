# cosmic

cosmic is a runtime for building correct, self-contained command-line
software. one file holds the language runtime, the compiler and type
checker, the formatter, the test runner, and the standard library,
and it works offline on Linux and macOS. programs written for it ship
the same way: one executable, built by cosmic, that carries
everything it needs.

the language is Teal, typed Lua. the runtime is Lua 5.5 in a C core.
the store is SQLite.

this doc says what cosmic is and how it is built today. what is
decided but not yet built, and what is still open, is in
[roadmap.md](roadmap.md).

## promises

1. **no silent bugs.** types never lie: every fallible signature
   admits failure, the checker has no escape hatch, and untrusted
   data enters through a declared shape. documented behavior is
   verified behavior: every example in a doc runs. the parsers that
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
   is a binary, the root is the module root, and whether a file can
   be reached from outside its own directory is a question of
   position, not of its name: a directory's own entry file is the
   one path outside code may import, and every sibling beside it is
   reachable only from within that directory. no list to maintain,
   none to go stale.
3. **honest returns.** `T | nil, string` for a value, `boolean,
   string` for an effect, two slots and nothing in a third, a
   structured error record when the failure has shape. a throw or
   exit carries a trailing reason and is exceptional by construction.
4. **no escape hatch in the type layer.** casts are foreclosed;
   `any` lives only where untrusted data enters and a shape validator
   turns it into a record.
5. **the least tree that keeps its promises.** a module exists when
   the tier order pulls it and it earns its place.
6. **status comes from running the check, never from a version
   number.** enforcement is a property of the host. anything that can
   be half-enforced reports per section as `full`, `degraded`, or
   `skipped`, and the report is what a conformance cell observed, not
   what an ABI probe returned.
7. **no network in a build; one external tool.** every input is in
   the repository. the one thing a fresh clone needs is the pinned
   zig.
8. **docs are always right.** a disagreement between doc and code is
   fixed in the code, and every example runs or says why not. tests
   run because they are defined. gates end in a verdict line. an
   error-site hint beats a gotcha doc beats guide prose.
9. **obviously simple, correct, and essential.** a reader sees it,
   never derives it: a line of code proves itself on sight and a
   sentence of prose is believed on the first read. something that
   is merely true but needs tracing to trust has not met the bar,
   in code or in prose, and is a thing to rewrite, not to comment
   further.

## targets

Linux on x86_64 and aarch64, statically linked against musl. macOS
on aarch64 against libSystem, which cannot be linked statically but
is always present, so the one-file property holds on both. Windows
runs the Linux binary under WSL2. Intel Macs are not a target: Apple
has named macOS 26 the last release for them, and no runner can test
them without Rosetta.

every cosmic binary carries the core image for all three targets, so
any host builds any target offline with nothing fetched.

a target exists when zig links it and a CI lane runs its full suite
on it. nothing ships that nothing has run. a BSD that meets both is
a target; the syscall table is POSIX and the attach is plain ELF, so
the work is the lane, not the code.

## the stack

```
kernel                               Linux; macOS
  libc                               musl, static, from the zig pin (Linux)
                                     libSystem (macOS)
    lua 5.5, sqlite3, miniz          vendored, unedited
    syscall table                    C, one function per syscall
  cosmic binary
    modules in a sqlite database     the only module source
    teal compiler + checker          vendored tl, carried patches
    cosmic.* stdlib in teal          typed wrappers, honest returns
    the three core images            rows in the same database
```

### toolchain

the host language is C: Lua, SQLite, and the small libraries are the
C they ship as. one pinned zig is the compiler and the build for the
C core: `zig cc` cross-compiles all three targets from a Linux lane,
and `build.zig` compiles the vendored C. `build.zig` is a source list
and flags, nothing more, so a zig bump costs an hour.

zig's bundled musl is the libc on Linux and its libSystem stubs are
the link target on macOS. the zig pin is therefore the libc pin. a
file names the zig version and the sha256 of each host's tarball; a
tiny POSIX sh `bin/zig` fetches into a cache, verifies, and execs.
`build.zig` compares `builtin.zig_version` against the pin at
comptime and refuses any other version by name; the `.zon` manifest's
minimum-version field is not enforced for a root package and is not
relied on. CI runs the same script, so the pinned bytes are the only
zig anything runs.

the three shipped images are built ReleaseFast with `.strip = true`,
which is what makes a build byte-identical across build paths on ELF
and Mach-O alike; debug info carries the absolute path and a
content-derived Mach-O UUID follows it. the Linux lane builds a
fourth core in ReleaseSafe with `sanitize_c = .full`, which is
undefined-behavior checking with a message and a trace rather than a
bare trap, and boots the whole build under it on every push.

the C layer is POSIX plus a declared platform seam: no signalfd,
inotify, epoll, or procfs outside modules guarded as Linux-only.

### the line between C and Teal

the core is a syscall table plus a few vendored libraries; anything
with a policy in it is Teal, stored once in the database and shared
by every target.

native, per target: the Lua VM; SQLite; miniz for deflate; SHA-256,
about two hundred lines, for record keys and the Mach-O signer; the
syscall table; the database VFS and the entry. measured stripped on
x86_64 musl: Lua 360 KB, SQLite with the flags below 1.1 MB, miniz
98 KB; Lua and SQLite together in one static binary 1.4 MB.

the syscall table is one C function per syscall with the same
signature on Linux and macOS, written by hand in one strict shape in
one annotated header, `core/syscalls.h`, each entry naming its
arity. the annotation grammar is LuaCATS, `---@param`, `---@return`,
`---@class`, `---@field`, the grammar the cosmopolitan fork's
`definitions.lua` proved on this exact job. the Teal declaration for
each function is generated from that header when the core first runs
over the tree, and the generator refuses, by name, any function whose
annotation is incomplete, whose parameter count disagrees with the
arity, or whose returns are not one value or the fallible three, so
a binding cannot exist without its type and the C surface cannot
grow without a diff in that header. argument-shape errors raise;
runtime failures return `nil, err, errno`, plain values, the
convention the fork already uses at over a hundred sites.

Teal by default: filesystem policy, the whole build including the
Mach-O writer and ad-hoc signer. C when a benchmark on a real
scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists. the benchmark harness, not taste, moves a
module across the line in either direction.

### the lua surface

the global environment holds Lua's pure libraries and nothing that
reaches outside the process: `string`, `table`, `math`, `utf8`,
`coroutine`, and the base functions minus `dofile` and `loadfile`.
`package` keeps `loaded`, `preload`, and `searchers`, and the one
searcher reads the database; `path`, `cpath`, `loadlib`, and
`searchpath` do not exist. `io` and `os` are never opened, and
`debug` is not a global. files, standard streams, environment, time,
and processes are `cosmic.fs`, `cosmic.env`, `cosmic.time`, and
`cosmic.proc`, all over the syscall table, so the same call behaves
the same on both OSes and the sandbox has one door. `print` writes
through the syscall table, and `fs` writes to a stream without a
newline. `cosmic.errors` exposes a traceback for error reporting; the
coverage collector reaches `debug`'s hook functions as
`cosmic.internal.debug`. a name that is missing errors with the
module that replaces it.

the vendored `tl.lua` reaches outside the pure libraries in five
places: `io.open` and the file handle it returns, `os.getenv`,
`package.path`, `package.searchers`, and `load`. it ships as a row
in the database and is loaded with its own environment that supplies
those over the syscall table. the checker resolves the types of a
`require` through tl's own path search over the tree, which is a
build reading its inputs; tl's loader, the part that would compile
and run a module, is never called, and `package.path`'s absence in
the runtime is never observed. the compiler is not patched for any
of this. before Teal exists, at boot, a short Lua bridge held as
text in the C core supplies the same environment.

Lua is built with `LUA_USE_POSIX` on both OSes and no compatibility
defines, so assigning an undeclared global is a compile error and
nothing can `dlopen`.

the raw C modules behind `cosmic.internal.store`,
`cosmic.internal.sqlite`, and `cosmic.internal.debug` have no
requireable name for anything outside them. the searcher hands each
to its Teal wrapper, `cosmic.store`, `cosmic.sqlite`, and
`cosmic.coverage`, as the loader's second argument, and only when the
wrapper is loaded, trusted, from the binary's own database; nothing
else ever calls `require` and gets an answer. `cosmic.internal.errors`
is the same shape behind `cosmic.errors`, unconditionally preloaded
rather than argument-passed, since a traceback carries less risk than
a raw database handle. `internal` is a reserved name: a path under
`cosmic.internal.` never satisfies an ordinary `require`, for any
caller, which is stronger than positional privacy and is where every
raw C binding that is not itself the public surface belongs.

### the database

`require` reads the database and nothing else; a `.tl` on disk is
input to the build, never to the runtime. one database holds:

- **modules**: import path, source hash, Teal source, compiled Lua
  and bytecode, kind (module, test, example, main), and the test
  names the compile step found.
- **imports**: which module requires which.
- **images**: the core executable for every target, deflated at
  rest; two of the three are inert on any host.
- **the compiler**: `tl.lua`, one row, loaded with its own environment.
- **meta**: the boot hash and the main module.

every table is `WITHOUT ROWID` on a natural key. records, meaning
test verdicts, the paths each test opened, and coverage, live in a
second database beside it, `o/records.db`, and never ship: they move
by host, and a shipped file must not.

all three targets are little-endian 64-bit, so one bytecode column
serves them all, and it keeps line information so a runtime error
names its line; the bytecode header check is the safety net. the
core image column is the only per-target data.

the binary carries its database attached to the executable. on ELF
it is appended and located by a trailer at end of file. on Mach-O it
sits inside an extended `__LINKEDIT` segment, followed by a fresh
ad-hoc code signature that covers it, because arm64 macOS refuses a
binary with bytes after its signature. the runtime opens it through
its own small VFS, a ~300-line shim that reads the executable at an
explicit offset; the offset comes from a ten-line locator per
format, the ELF trailer or the Mach-O signature's data offset, and
nothing else in the VFS knows which format it is in. the VFS honors
exactly that one path, offset, and length, registered once at
startup, and refuses any other open. the executable
is opened once, its size taken, and the handle cached. the Mach-O
writer touches `__LINKEDIT`'s size, the signature's offset, and the
signature itself, and nothing else in the file. the last partial
page is hashed over its real length, never zero-padded.

the database is read-only, and the runtime never writes it: Linux
refuses to open a running executable for writing, and macOS kills a
process whose signed pages change. it is opened with `immutable=1`
so SQLite skips locks and staleness checks on a file no one else can
change. mutable state lives in an ordinary file. a program that
ships a dataset it updates copies it out once with `VACUUM INTO`, or
attaches the embedded database read-only beside a writable one and
queries across both.

a project's own build database, `o/cosmic.db`, is read ahead of the
binary's: when cosmic runs or tests a project, `require` answers from
the project's database first and the binary's second, except for
`cosmic.*`, which the binary answers first. the importer refuses a
project tree that holds a `cosmic/` directory or an import path
under `cosmic.`, naming the path, so a project cannot shadow the
standard library by accident or on purpose. that is how the tool
builds and tests a tree other than its own.

sqlite is load-bearing at boot, so its sharp edges are the runtime's
problem and are fixed first: a typo'd or overlong parameter table
never binds NULL silently, TEXT and BLOB are distinguishable at the
Lua boundary, and a closed handle fails the same way from every
method. the build is single-threaded, so SQLite compiles with
`SQLITE_THREADSAFE=0` and without extension loading, shared cache,
double-quoted strings, or deprecated interfaces.

### the build

the build is a cosmic program reading the tree by position into the
database: compile, check, record. `build.zig` owns the C. `zig build`
produces the patch applier, the patched vendor tree under
`o/vendor/`, and the core for each target. `zig build boot` bridges:
it runs the fresh host core over `build/` to compile the importer
with the vendored `tl.lua`, writes `o/cosmic.db`, and attaches it as
`o/bin/cosmic`. a fresh clone and CI run `boot`; after that,
`cosmic test` and `cosmic <file.tl>` rebuild the tree's database
before they run anything.

cosmic builds itself, so the tool is also an artifact of the tree,
and a stale tool is the bug to design against. `boot` stores a hash
of `build/` and `core/` in the binary it produces. every run inside
cosmic's own tree hashes the same trees first; on a mismatch it
refuses with `the tool is stale; run bin/zig build boot` and exit 3.
that hash is also part of every record key, so a row compiled by an
older importer is never mistaken for a current one, and a re-import
over the boot database carries the images and the compiler row
forward unchanged.

the C stage is hermetic and checked. `build.zig` runs with both of
zig's caches under `o/`, and `o/` is the only thing to delete. the
applier's output replaces the vendor directory the core compiles
from, whole, never one file beside an unpatched tree, because a
quoted `#include` finds the neighbor first and a half-applied patch
builds green. the trust chain has exactly two seeds that nothing in
the repository built, and they are named here: the POSIX sh
`bin/zig` and the zig tarball its pin verifies. everything else is
vendored or built from it.

the build is incremental and reproducible:

- *incremental*: a module row is keyed by the content hash of its
  source, the hashes of its import closure, and the boot hash. an
  unchanged key is a stat; a changed one recompiles only what
  depended on it.
- *reproducible*: the shipped database is a pure function of the
  tree. it is built in one transaction, every table is `WITHOUT
  ROWID` on a natural key so insertion order cannot reach the bytes,
  and the file is produced by `VACUUM INTO`. CI's repro lane builds
  the tree again at a different path and asserts the database and
  all three binaries are byte-identical.

tests run in the build's own process, each handed a fresh temp
directory, and every path a test opens through the syscall table is
recorded beside its verdict.

one Linux lane builds every image; three lanes run the full suite on
the real thing: Linux x86_64, Linux aarch64 on an arm runner, macOS
aarch64 on an arm Mac runner.

### vendored sources

`vendor/<name>/` holds the files the build reads from the upstream
archive its `PIN` names, unedited. `PIN` gives the version, the url,
the archive's sha256, and which of its files are kept; `bin/vendor`
fetches the archive and runs `vendor.tl` under the bootstrap cosmic,
which verifies the hash and rewrites the tree to exactly the kept
files. `patch/<name>/` holds records, each an exact `find`, a
`replace`, and a `note` saying why it exists. a ~200-line C applier
that zig builds first writes the patched copy to `o/vendor/<name>`; a
record whose anchor no longer matches fails the build by name.

vendored: Lua 5.5, the SQLite amalgamation, miniz, and tl.

### teal

tl vendored, carried patches, upstream-first and fork-if-blocked.
the carried patches narrow nil unions under a truthiness guard, a
comparison against nil, and `assert`, and keep the comments the
lexer would otherwise drop at the end of input or in front of a
`--#` run.

### the runtime

one Lua state, one thread. the C layer is re-entrant, which costs
discipline, not code: no static buffers, no process-global state
outside the entry, every binding takes its context explicitly,
SQLite opened per connection and never shared across a boundary that
could later be a thread.

### the command line

verbs, with a bare path meaning run: `cosmic test`, `cosmic fix`,
`cosmic help`; `cosmic file.tl` builds the tree the file sits in and
runs it. `fix` takes paths to narrow it. every verb ends in a verdict
line and an exit code, and `cosmic help` is the whole discovery
surface. no stock-interpreter flags, no argv[0] personality.

`fix` rather than `format`, because there is one verb and not two: it
parses, applies whatever structural rewrites the lint has earned, and
renders the result rather than splicing it, so a fix reads the same as
source nothing touched. `--check` writes nothing and fails on anything
it would have changed.

### the repository

```
README.md           what cosmic is and the one command to build it
bin/zig             POSIX sh: fetch, verify, exec the pinned zig
bin/zig.pin         version and per-host sha256; build.zig reads it
bin/vendor          POSIX sh: fetch the archives vendor.tl unpacks
vendor.tl           rewrite a vendor tree from its verified archive
build.zig           the C build; build.zig.zon names the package
vendor/<name>/      the upstream files the build reads, with a PIN
patch/<name>/       exact find/replace records, each with a note
core/               C: entry, locator, VFS, store, sqlite, surface, boot
core/syscalls.h     the annotated header the .d.tl derives from
core/bridge.lua.h   the boot environment for tl.lua, Lua text in C
cosmic/             the standard library; entry files are public, siblings not
cmd/cosmic/         the binary's main
build/              the importer, checker driver, test runner, fix (Teal, private)
test/               tests of the tree as a whole
doc/                prose
o/                  output; o/cosmic.db, o/records.db; never committed
```

every directory name is singular: `doc`, not `docs`; `patch`, not
`patches`. the rule reaches module paths too, since a module that
grows past one file becomes a directory of the same name.

every module path is lowercase; no name is spelled differently
because of what it is. reachability is a question of position
instead: a directory's own entry file is the one path outside code
may import, and every sibling beside it is reachable only from
within that directory. `cosmic/fs.tl` is `require("cosmic.fs")`,
public. a module too large for one file becomes a directory of the
same name with an `init.tl` as its entry, the ordinary way Lua
already resolves `require("cosmic.fs")` to `cosmic/fs/init.tl`; a
sibling beside it, `cosmic/fs/walk.tl`, compiles as `cosmic.fs.walk`
and the checker refuses an import of it from any file outside
`cosmic/fs/`. the same rule applies everywhere in the tree, not only
under `cosmic/`. a project tree may hold no `cosmic`-prefixed path
at all unless it is cosmic's own tree, so a project can never place
itself as a false sibling to claim another module's private surface.
positional reachability is a compile-time check over statically
written imports; it says nothing about a value already held by a
script that walks a table's fields at runtime, which is why
`cosmic.sqlite` and `cosmic.store` keep their own stronger mechanism,
no requireable name at all, on top of this rule rather than instead
of it.
