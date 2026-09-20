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

every cosmic binary carries the raw core for all three targets, so any
host builds any target offline with nothing fetched. the POSIX launcher selects
one by `uname`, verifies its exact range and digest, retains the artifact
descriptor, and executes a cached copy. a program `cosmic build` writes has the
same portable prefix and its own database suffix.

a target exists when three things hold: zig links it, a CI lane runs
its full suite on it, and the sandbox conformance matrix runs on it.
nothing ships that nothing has run. a BSD that meets the three is a
target; the syscall table and launcher are POSIX, so the work is the lane, not
another executable format writer.

## the stack

```
kernel                               Linux; macOS
  libc                               musl, static, from the zig pin (Linux)
                                     libSystem (macOS)
    lua 5.5                          vendored pristine
    sqlite3                          vendored pristine
    mbedtls, miniz, argon2,          vendored pristine
    a regex engine
    syscall table                    C, one function per syscall
  cosmic binary
    modules in a sqlite database     the only module source
    teal compiler + checker          vendored tl, carried patches
    cosmic.* stdlib in teal          typed wrappers, honest returns
    docs, CA roots                    rows in the same database
    three raw cores                  manifest ranges before the database
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
bare trap. `bin/zig build sanitized` boots with that core and embeds
it in `o/sanitized/bin/cosmic`; CI verifies the embedded core bytes
and runs the whole test suite under `timeout 90` on every push, with
full undefined-behavior checking and coverage collection enabled. zig
ships no address sanitizer runtime for any target;
an address-sanitized job on a real clang, outside the pinned
toolchain and with that caveat stated, is a later addition. a
`cosmic-debug` asset, the sanitized build published beside the
release, is added once the fuzzers exist; being unstripped, it takes
prefix-map flags to keep the build path out of its bytes.

the C layer is POSIX plus a declared platform seam: no signalfd,
inotify, epoll, or procfs outside modules guarded as Linux-only.

### the line between C and Teal

the core is a syscall table plus a few vendored libraries; anything
with a policy in it is Teal, stored once in the database and shared
by every target.

native, per target: the Lua VM; SQLite; mbedtls, which also serves
hashing and HMAC; miniz for deflate; argon2; a regex engine; the
syscall table; the database VFS and the entry. measured stripped on
x86_64 musl: Lua 360 KB, SQLite with the flags below 1.1 MB, FTS5
another 222 KB, miniz 98 KB; Lua and SQLite together in one static
binary 1.4 MB. three carried cores plus mbedtls is on the order of
6 MB per shipped binary before any Teal, and the size report carries
that per component.

the syscall table is one C function per syscall with the same
signature on Linux and macOS, written by hand in one strict shape in
one annotated header, `core/syscalls.h`, each entry naming its
arity. the annotation grammar is LuaCATS, `---@param`, `---@return`,
`---@class`, `---@field`, the grammar the cosmopolitan fork's
`definitions.lua` proved on this exact job. the Teal declaration and
the doc row for each function are generated from that header when
the core first runs over the tree, and the generator refuses, by
name, any function whose annotation is incomplete, whose parameter
count disagrees with the arity, or whose returns are not one value
or the fallible three, so a binding cannot exist without its type
and the C surface cannot grow without a diff in that header.
argument-shape errors raise; runtime failures return `nil, err,
errno`, plain values, the convention the fork already uses at over a
hundred sites. one trace point at the table's dispatch gives a
syscall log for every call uniformly when asked.

`posix` is a reserved name of a different kind: not privacy, but
scope. a module lives under `cosmic.posix.` when its whole job is
exposing a POSIX standard's own vocabulary directly, names and
numeric codes, rather than presenting cosmic's own abstraction over
it. `posix.errno` and `posix.signal` are the first two; a module
that instead builds an abstraction on top of a standard call, `fs`
over `open`, `poll` over `poll(2)`, stays where it is.

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
syscalls, URL, SSE, tar, the zip directory, JSON, and the whole artifact build.
C when a benchmark on
a real scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists. HTTP/1.1 framing starts in C on the second
half of that rule, a fuzzed implementation existing; JSON starts in
Teal and is measured against a C implementation on the harness when
its tier lands, and the numbers pick. the benchmark harness, not
taste, moves a module across the line in either direction.

### the lua surface

the global environment holds Lua's pure libraries and nothing that
reaches outside the process: `string`, `table`, `math`, `utf8`,
`coroutine`, and the base functions minus `dofile` and `loadfile`.
`package` keeps `loaded`, `preload`, and `searchers`, and the one
searcher reads the database; `path`, `cpath`, `loadlib`, and
`searchpath` do not exist. `io`, `os`, and `debug` are not globals.
files, standard streams, environment, time, and processes are
`cosmic.fs`, `cosmic.env`, `cosmic.time`, and `cosmic.proc`, all
over the syscall table, so the same call behaves the same on both
OSes and the sandbox has one door. `print` writes through the
syscall table, and `fs` writes to a stream without a newline.
`cosmic.errors` exposes a traceback for error reporting; the test
runner and the coverage collector reach the rest of `debug` through
a private binding. a name that is missing errors with the module
that replaces it.

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

the raw C modules behind `cosmic.internal.store` and
`cosmic.internal.sqlite` have no requireable name for anything
outside them. the searcher hands each to its Teal wrapper,
`cosmic.store` and `cosmic.sqlite`, as the loader's second argument,
and only when the wrapper is loaded, trusted, from the binary's own
database; nothing else ever calls `require` and gets an answer.
`cosmic.internal.errors` is the same shape behind `cosmic.errors`,
unconditionally preloaded rather than argument-passed, since a
traceback carries less risk than a raw database handle. `internal`
is a reserved name: a path under `cosmic.internal.` never satisfies
an ordinary `require`, for any caller, which is stronger than
positional privacy and is where every raw C binding that is not
itself the public surface belongs, not only these three.

### the database

`require` reads the database and nothing else; a `.tl` on disk is
input to the build, never to the runtime. one database holds:

- **modules**: import path, source hash, Teal source, compiled Lua
  and bytecode, declaration, kind (module, test, example, main), and
  the test or example names the compile step found.
- **docs**: one row per symbol a module declares at its top level --
  the module itself, each function, each record, enum or alias and
  every field and value under it, and each documented value -- with
  its kind, its declaration as the source wrote it, its doc comment
  (the run of comment lines directly above it, leaders stripped),
  and where it sits. every function is here, documented or not, so
  `cosmic docs` can always say where one lives. an FTS5 index,
  `docs_fts`, answers `cosmic docs` when the query is words rather
  than a name.
- **uses**: one row per place a module refers to another module's
  symbol through a top-level require alias (`Fs.read(...)` under
  `local Fs = require("cosmic.fs")`), resolved against the name the
  other module returns. `cosmic uses Fs.read` lists them.
- **examples**: one row per worked example, a `kind = "example"`
  module's own top-level `function Example.<name>()` -- found the same
  structural way `docs` finds `function Fs.read(...)`, shipped against
  only the module its file name pairs with (`cosmic/fs_example.tl`
  ships against `cosmic.fs`). `<name>` is a free label, not a symbol:
  which real symbol an example is FOR is never decided here, or even
  at ship time. `cosmic docs Fs.read` answers that at read time, over
  `examples_fts`, an external-content FTS5 index the same shape as
  `docs_fts` -- an example calls the real function it demonstrates, so
  the symbol's own name is already in its code, tokenized the same way
  a query for it is, and a phrase match finds it (narrowed by a
  boundary check afterward, since FTS5 splits `_`, and `Fs.hex` would
  otherwise also match an example that only ever calls
  `Fs.hex_sha256`). This is looser than a build-time join on purpose:
  more than one example can be FOR one symbol, in whatever order its
  file declares them, and one example that calls two functions
  together answers for both, without either needing to name the
  other. An example is documentation twice over: its own doc comment,
  read the same way `docs` reads one, says what it is for, and its
  body, which compiles and runs like any other test, says how -- one
  assertion mechanism for code, not a second, output-diffing one only
  doc guides need.
- **payload**: for an embed-built executable, the user's files.
- **roots**: Mozilla's CA bundle.
- **the compiler**: `tl.lua`, one row, loaded with its own environment.
- **decls**: every declaration the tree holds, generated or written,
  so a checker building another tree against this binary can type
  what it requires.
- **catalog**: the errors a program can meet, one row per literal
  `return nil, ...` or `return false, ...` message under a top-level
  function, naming that function, plus hand-authored rows for the
  `strerror()` messages a syscall can raise. an FTS5 index over it,
  `catalog_fts`, is what an uncaught error's message is looked up
  in. the guidance that prints is the doc comment of the function
  the message came from, joined from `docs` by symbol -- there is no
  second place to write it, so documenting a function is documenting
  its failures. the runtime also prints the Teal line the error was
  raised on: tl's generated Lua keeps the line numbers of the Teal it
  came from, so the line a Lua error names is a line of the module's
  own source, read straight out of `modules`.

every table is `WITHOUT ROWID` on a natural key, except `docs` and
`catalog`, which FTS5's external-content mode joins by rowid and
which are therefore keyed on an integer assigned in one deterministic
insertion order instead. everything a build
does on one host lives in a second database beside it, `o/build.db`,
the working database: the tree as it was last read, staged whole
before anything transforms it; what a stat said about each file, so
an unchanged file is never read again; one row per run saying what
was staged, read, and compiled; and records, meaning test verdicts
and coverage. it never ships: it moves by host, and a shipped file
must not.

all three targets are little-endian 64-bit, so one bytecode column serves them
all, verified by a test that each raw core loads it, and it keeps line
information so a runtime error names its line; the bytecode header check is
the safety net. target-specific bytes live only in manifest ranges, outside
the database.

the binary is a versioned portable artifact: a POSIX shell launcher, aligned
raw core ranges, a fixed manifest, one SQLite database, and a fixed trailer.
the manifest is the sole authority for target/configuration, byte range, and
sha256. the launcher retains an open descriptor before executing the selected
core; startup validates the complete manifest and trailer against that same
descriptor. the runtime's VFS reads only the validated database range from the
retained descriptor. it never reopens the logical pathname, so rename, unlink,
and atomic replacement after adoption cannot mix files. the last partial range
is hashed over its real length, never zero-padded.

the database is read-only, and the runtime never writes it. it is opened with `immutable=1`
so SQLite skips locks and staleness checks on a file no one else can
change. mutable state lives in an ordinary file. a program that
ships a dataset it updates copies it out once with `VACUUM INTO`, or
attaches the embedded database read-only beside a writable one and
queries across both.

the launcher's cache leaf is untrusted until its owner, mode, and contents
meet the cache policy, and the core's length and digest match the manifest. its
parent directory is
the user's trust boundary. a cold launch writes and publishes a verified core
atomically; a warm launch repeats the complete hash before execution. the
launcher uses POSIX utilities available on the supported systems and reserves
`COSMIC_PORTABLE_*` for its descriptor handoff. startup requires the complete
set, validates it, adopts the descriptors, and clears those names before Teal
runs. `COSMIC_PORTABLE_CACHE` alone is public configuration.

ordinary artifacts have exactly three release entries and select configuration
1. the checked artifact retains those required release entries and adds one
configuration-2 entry for the real build host; its private launcher selects
only that entry. target/configuration pairs are unique across the manifest and
system identities are unique in the selected configuration. the production
decoder's required-release mask is unchanged.

a project's own build database, `o/cosmic.db`, is read ahead of the
binary's: when cosmic runs or tests a project, `require` answers from
the project's database first and the binary's second, except for
`cosmic.*`, which the binary answers first. the checker is answered
the same way while the project builds: a `cosmic.*` name the
project's stage does not hold is typed from the source and the
declarations the binary carries as rows, so a project imports the
standard library with its types and nothing of cosmic's tree on
disk. the importer refuses a
project tree that holds a `cosmic/` directory or an import path
under `cosmic.`, naming the path, so a project cannot shadow the
standard library by accident or on purpose. that is how the tool
builds and tests a tree other than its own.

inside cosmic's own tree, every run first compares the boot hash with
the one the running binary carries: a fingerprint of everything the
tool is made of, `build/`, `core/`, `cosmic/`, `cmd/`, `patch/`, each
vendored tree's `PIN`, `build.zig` and the zig wrapper. a vendored
tree is a function of its pin and its patch records and is never
edited in place, so those are its inputs and the tree is not walked.
on a mismatch the tool refuses with `the tool is stale; run bin/zig build
boot` and exit 3. raw cores remain build outputs under `o/core`; the working
database carries the compiler source needed for a later database-only rebuild.

sqlite is load-bearing at boot, so its sharp edges are the runtime's
problem and are fixed first: a typo'd or overlong parameter table
never binds NULL silently, TEXT and BLOB are distinguishable at the
Lua boundary, and a closed handle fails the same way from every
method. the build is single-threaded, so SQLite compiles with
`SQLITE_THREADSAFE=0` and without extension loading, shared cache,
double-quoted strings, or deprecated interfaces, and with the
`dbstat` virtual table, so `cosmic db` can say what every table in
both databases costs in rows, pages, and bytes.

### the build

the build is a cosmic program reading the tree by position into the
database: compile, check, record, embed. `build.zig` owns the C.
`zig build` produces the patch applier, the patched vendor tree
under `o/vendor/`, and the core for each target. `zig build boot`
bridges: it runs the fresh host core over `build/` to compile the
importer with the vendored `tl.lua`, writes `o/cosmic.db`, and writes one
portable `o/bin/cosmic`. a fresh clone and CI run `boot`; a
developer runs `o/bin/cosmic build` the other hundred times a day.

cosmic builds itself, so the tool is also an artifact of the tree,
and a stale tool is the bug to design against. `boot` stores two
fingerprints in the binary it produces: one over everything the tool
is made of, one over what the C core is built from. every run in
cosmic's own tree fingerprints the tree first. when only Teal
differs, the tool rebuilds itself -- compiles the tree, projects the database,
combines it with the exact retained portable prefix -- and
re-execs into the result, once, refusing a second round by name;
when the C core's inputs differ, only zig can build it, and the tool
says so. the binary also carries two identities: the compiler it is,
over the build's own modules in the importer's closure and the Teal
compiler's and Lua's pins and patches, which every module key
carries; and the runtime it is, over its host image and the same
pins, which every test verdict carries. the standard library the
importer runs on is in neither, so an edit there reaches what
imports it and nothing more. a row compiled by another compiler is
never mistaken for this one's.

the C stage is hermetic and checked. `build.zig` runs with both of
zig's caches under `o/`, and `o/` is the only thing to delete. the
applier's output replaces the vendor directory the core compiles
from, whole, never one file beside a pristine tree, because a quoted
`#include` finds the neighbor first and a half-applied patch builds
green. a provenance gate in CI asserts that no bytes from outside
the tree and the pinned zig reach any output, checked by building on
three hosts with different kernels and system libraries and
comparing every byte of the three shipped binaries; zig opens a few
host paths to probe the native target even for a cross build, so the
gate judges outputs, not opens. the trust chain has
exactly two seeds that nothing in the repository built, and they are
named here: the POSIX sh `bin/zig` and the zig tarball its pin
verifies. everything else is vendored or built from it.

the target build architecture is fast, incremental, and reproducible.
today a module whose key stands is read back from the working
database rather than compiled again, the shipped database is a
projection of that one, written only when what it is a function of
moved, and a test whose verdict stands -- its module's key and the
hash of every file it was observed to read -- is not run again. the
runner still executes what does run in-process; child-process
isolation is planned below, not implemented:

- *incremental*: a module row is keyed by the content hash of its
  source, the hashes of its import closure, the boot hash, and, for
  a test, the set of files it was observed to read. an unchanged key
  is a stat; a changed one recompiles and re-records only what
  depended on it. observed reads come free: every file a test opens
  goes through the syscall table, and the runner records the paths.
- *fast*: compile and check run in one process, one transaction,
  against declarations already in the database. tests run in a
  child process each, for a fresh temp directory, a deadline, and
  captured streams; a child never opens a database, it reports its
  result over a pipe and the one build process writes it.
- *reproducible*: the shipped database is a host-neutral projection of the
  working database into a fresh schema, filled in one transaction, with every
  table `WITHOUT ROWID` on a natural key and the file produced by `VACUUM
  INTO`. target identity comes from the selected, validated manifest entry;
  it is absent from database rows. `bin/zig build cores` cross-compiles every
  target from any host, so the complete artifact, its database and both test
  applications are byte-identical regardless of which host produced them.
  CI asserts that with three unrelated kernels and system libraries agreeing,
  then runs one transported artifact unchanged on all three targets.

three lanes, one per target -- Linux x86_64, Linux aarch64 on an arm
runner, macOS aarch64 on an arm Mac runner -- each independently
cross-compile every image and run the full suite on the real thing;
a fourth job only diffs what the three already produced. the sandbox
conformance matrix runs on all three.

`cosmic build` and `cosmic test` fence themselves with the sandbox
core, so a build cannot read outside its tree and a test cannot reach
the network by accident. CI's profile requires the fence; a laptop
reports it.

### vendored sources

`vendor/<name>/` is the extracted upstream tarball, never edited,
with a `PIN` file naming version and hash. `patch/<name>/` holds
records, each an exact `find`, a `replace`, and a `note` saying why
it exists. a ~200-line C applier that zig builds first writes the
patched copy to `o/vendor/<name>`; a record whose anchor no longer
matches fails the build by name. repo size is a one-time clone cost,
the cheap kind under principle 1.

vendored: Lua 5.5, the SQLite amalgamation, mbedtls, miniz,
argon2's reference implementation built without threads, the regex
engine, and tl.

### teal

tl vendored, carried patches, upstream-first and fork-if-blocked.
the planned cast restriction would allow `x as T` only from `any`, from a
userdata record declared in a `.d.tl`, or from the enclosing
generic's type variable. `any` is legal only where untrusted data
enters and a shape validator turns it into a record by construction.
no justification comments, no ledger in the target policy. this cast
restriction is not implemented. record-field narrowing has landed as
carried patches; container covariance was dropped (see the roadmap).
there is no planned `cosmic check` verb: compilation performs checking,
while `cosmic fix` currently operates on syntax and has no production
rewrite rules.

the spirit is consistent, strong, explicit typing, the same shape the
languages that hold it converged on: the top type inert until
narrowed, casts confined to subtype moves or runtime-checked, the
escape hatch in one greppable region, boundaries decoded through
declared shapes. a runtime-checked cast is closed to Teal because
Lua erases record types, so shapes construct their records rather
than asserting them.

the target type policy adds three rules. `any` never assigns into a
typed slot; tl already refuses that on assignment, argument, return, index, and
call. an unannotated parameter is an error, never an implicit `any`,
which tl does not enforce and a planned lint would. `v is R` for a
record `R` would be refused on an `any` or a union of records by lint,
because it compiles to a table check that cannot tell two records apart; the
shape module is the way in. the checker's own hint on an `any`
index points at a shape, not at a cast. the per-release report
names the modules that cast from `any`; the expected list is the
shape module, the codec decoders, the C declaration layer, and the
build step that loads the compiler chunk.

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

mbedtls 4.1, vendored as one tarball with its crypto subtree
included, whose support runs to 2029. today only the crypto subtree
is built, and only for digests and HMAC: MD5, SHA-1, the SHA-2 and
SHA-3 sizes, through the PSA API, with randomness from the OS rather
than the library's own entropy and DRBG modules. `cosmic.hash` is
the Teal face of it, the syscall table's `digest` and `hmac` the
bindings, and every SQLite handle knows the same functions, so a
query hashes in place. TLS 1.2 and 1.3 come from the same library,
one configuration, when the `fetch` module is pulled. Mozilla's
root bundle is stored in the database, identical on every machine,
moved only by a pinned bump; an environment variable adds a
certificate for the corporate-proxy case without making per-machine
trust the default.

### the sandbox

an opt-in library and the toolchain's own fence. default-deny for
user scripts is not promised; hard containment of a script is the
host's job, and the module makes it one call when a caller wants it
in-process.

the policy model is what Landlock plus seccomp on Linux and Seatbelt
on macOS both enforce: read, write, and exec under paths; network
none, loopback, or all; TCP connect and bind by port; new processes
allowed or denied; inherited by children and never liftable. on
Linux, Landlock carries the path and port rules and seccomp carries
the rest: `network none` denies `socket` for the internet families,
because Landlock cannot see UDP at all, and `no new processes`
denies `clone`, because denying `execve` would refuse the box its
own launch and a self-replacing exec is not a new process. every
denial returns one errno on both OSes, chosen once, whatever kernel
mechanism produced it.

per-host network rules are not in the core. Landlock's port rule has
no address, so "only the proxy's port" reaches any host on that
port, and no Landlock ABI or seccomp filter can close it. a caller
who needs per-host rules takes the Linux extension below or a
container.

Linux extensions (a loopback-only network namespace, seccomp
syscall lists, a private mount namespace, abstract socket scoping)
may only deny what the core allows, never allow what the core
denies; macOS reports them `skipped` by name. every section reports
`full`, `degraded`, or `skipped` from a conformance cell that ran,
never from an ABI number: a Landlock ABI below 3 cannot restrict
truncate, gVisor has no Landlock at all, and a healthy ABI 7 has been
seen to misenforce one right on one host. none of these is an error.

one conformance matrix (read inside and outside, create, unlink,
rename across the boundary, symlink escape before and after
restriction, truncate, UDP under `none`, allowed and denied ports,
bind, a new process) runs under the same declared policy on every CI
lane and fails on any cell that differs. equivalence is a test, not
a claim.

### the command line

verbs, with a bare path meaning run: `cosmic build`, `cosmic test`,
`cosmic check`, `cosmic fix`, `cosmic docs`; `cosmic file.tl` runs a
file; `-e` stays as Lua's one-liner idiom. `build` builds the tree and
writes an executable for each `cmd/<name>/` in it, so a library tree
builds too and a tree with binaries ships from the one verb. every verb
takes paths to narrow it, ends in a verdict line and an exit code,
and `cosmic help <verb>` is the whole discovery surface. no other
stock-interpreter flags, no argv[0] personality.

from a project, `docs` and `uses` answer for the project's own code
and for the public standard library, `cosmic.*` less `internal` and
tests: what a builder reads, never the build that made the binary.
inside cosmic's own tree they answer for everything.

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
build.zig           the C build; build.zig.zon names the package
vendor/<name>/      pristine upstream, never edited, with a PIN file
patch/<name>/       exact find/replace records, each with a note
core/               C: entry, locator, VFS, store, sqlite, surface, boot
core/syscalls.h     the annotated header the .d.tl and doc rows derive from
core/bridge.lua.h   the boot environment for tl.lua, Lua text in C
cosmic/             the standard library; entry files are public, siblings not
cmd/cosmic/         the binary's main
build/              the importer, checker driver, embed (Teal, private)
doc/                prose
o/                  output; o/cosmic.db, o/build.db; never committed
```

every directory name is singular: `doc`, not `docs`; `patch`, not
`patches`. the rule reaches module paths too, since a module that
grows past one file becomes a directory of the same name:
`cosmic.docs` is `cosmic.doc` for exactly this reason. the one
deliberate exception is a CLI verb, `cosmic docs`, since a verb
names an action and reads differently from a module naming a thing.

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
one lint follows: no two names in a directory may differ only in
case, because macOS's default filesystem cannot tell them apart, and
a case-only rename is a two-step commit there. entry-point
reachability is settled; whether an exported function's own name is
capitalized by convention, `fs.Read` rather than `fs.read`, is a
readability question and not yet decided, and the checker does not
enforce it either way. positional reachability is a compile-time
check over statically written imports; it says nothing about a value
already held by a script that walks a table's fields at runtime,
which is why `cosmic.sqlite` and `cosmic.store` keep their own
stronger mechanism, no requireable name at all, on top of this rule
rather than instead of it.

### the surface

the tier order is a reading order for what to write, not a size
target:

- **core**: `check`, `ast`, `fs`, `child`, `env`, `proc`, `hash`,
  `sqlite`, `json`, `time`, `rand`, `flags`, `string`, `posix.errno`,
  `errors`, `log`, `teal`, `format`, `test`, `coverage`, `doc`,
  `embed`, `shape`.
- **second**: `http`, `fetch`, `net`, `dns`, `re`, `zip`, `tar`,
  `compress`, `codec`, `url`, `ip`, `uuid`, `ksuid`, `sse`,
  `sandbox`, `posix.signal`, `poll`, `fd`, `tty`, `ansi`, `user`,
  `host`, `stream`, `deep`, `graph`, `fuzzy`, `literal`, `template`.
- **later, if pulled**: namespaces and egress proxying beyond what
  the sandbox core needs, `shm`, `instrument`, `html`, `css`, `js`.

what comes next, and the open questions that stand in the way, are
in [roadmap.md](roadmap.md).
