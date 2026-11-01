# cosmic

this document specifies the intended design. parts may not be implemented yet.

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
   structured error record when the failure has shape. the one
   exception is the raw binding table [`cosmic.sys`], whose C calls
   add the errno in a third slot, and a stand-in a module stores
   into that table in a binding's place, which answers as the
   binding does; every other Teal function over it folds its answer
   back to two. a function a module exports answers one value, a
   failure pair, or a record: never a bare tuple, whose later slots a
   caller drops as quietly as a reason. a throw or exit carries a
   trailing reason and is exceptional by construction.
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
7. **pinned bootstrap seeds; offline builds once cached.** source
   inputs are in the repository. a fresh clone acquires the cosmic
   release and zig tarball their pins name, verifies their digests,
   and caches them. the build needs no network once both are present.
8. **docs are always right.** a disagreement between doc and code is
   fixed in the code, and every example runs or says why not. tests
   run because they are defined. a gate's verdict is its exit code. an
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

The x86_64 core is built for x86-64-v3, so the CPU needs AVX2, FMA, BMI1
and BMI2, F16C, LZCNT and MOVBE, and the kernel must enable AVX state.
That is Intel Haswell (2013) or AMD Excavator (2015) or newer mainstream
cores, but not Atom-class or AVX-less Pentium and Celeron parts, which
are still sold without AVX2. It buys wide vectors and fused multiply-add
in the numeric kernels (the vector search above all) with no runtime
dispatch, one core and one set of bytes to verify. The launcher reads
the CPU's flags before extracting anything and refuses a CPU without
them by naming what is missing, rather than letting the core die with
SIGILL.

The aarch64 Linux core is built for Armv8.2-A with the dot-product and
half-precision floating-point extensions (and what Armv8.1-A brought:
LSE atomics, rounding doubling multiply-add and CRC32), so the CPU needs
all of them. That is Arm Cortex-A55 and A75 (2017) or newer, Neoverse N1
and newer (AWS Graviton2 and later, Ampere Altra, the Arm runners GitHub
hosts) and the Raspberry Pi 5 (Cortex-A76). It is not Cortex-A53, A57,
A72 or A73, so not the Raspberry Pi 3 and 4, AWS Graviton1 or other
boards from before 2017. It buys `sdot` for the integer kernels, native
half-precision arithmetic and single-instruction atomics with no runtime
dispatch. The model is the generic Armv8 one with those features added,
so the code is not scheduled for one chip, and the optional cryptographic
extensions stay off. The launcher reads the `Features` line of
`/proc/cpuinfo` and refuses a CPU without them, as it does on x86_64. The
aarch64 macOS core stays at Apple M1, the oldest Apple silicon Mac.
The host tools the build runs stay at each architecture's baseline, since
their bytes key the build's caches across runners.

every cosmic binary carries the core for all three targets, so any
host builds any target offline with nothing fetched. each is stored as one zstd
frame beside a small decoder stub for its target, about 40% of the raw size. the
POSIX launcher selects one by `uname`, extracts and verifies it (decoding the
frame with the stub on a cold start), retains the artifact descriptor, and
executes a cached copy of the raw core. a program `cosmic build` writes has the
same portable prefix and its own database suffix. `cosmic build --host` writes
the running core itself with the program's database appended instead: it
starts with no launcher, and runs only where that core does.

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
    sqlite3, its ext/misc functions  vendored, patched (patch/)
    mbedtls, miniz, bzip2, xz,       vendored pristine
    zstd, c-ares, curl, yyjson
    argon2, a regex engine           planned
    syscall table                    C, one function per syscall
  cosmic binary
    modules in a sqlite database     the only module source
    teal compiler + checker          the tree's own source, seeded by the pinned release
    cosmic.* stdlib in teal          typed wrappers, honest returns
    docs                             rows in the same database
    Mozilla's CA roots               DER rows, once for every core
    three raw cores                  manifest ranges before the database
```

### toolchain

the host language is C: Lua, SQLite, and the small libraries are the
C they ship as. one pinned zig is the compiler and the build for the
C core: `zig cc` cross-compiles all three targets from a Linux lane,
and `build.zig` owns the C build graph: source lists and flags, release
and checked cores, the two links that embed the coverage map, static
analysis, fixture programs, installation and the boot bridge.

zig's bundled musl is the libc on Linux and its libSystem stubs are
the link target on macOS. the zig pin is therefore the libc pin. a
file names the zig version and the sha256 of each host's tarball;
[`bin/zig`] hands off to [`build/zig.tl`], which the pinned bootstrap
cosmic runs standalone to fetch into a cache, verify, and exec; the
fetch is [`build/zig_fetch.tl`]'s, run standalone in turn on a cache
miss, so what downloads and unpacks stays out of the import closure of
build/zig.tl, which the C checks require. it fetches from a few of
zig's community mirrors, as zig asks automated downloaders to, then
ziglang.org, retrying in rounds; the sha256 is what is trusted, so any
mirror will do.
`build.zig` compares `builtin.zig_version` against the pin at
comptime and refuses any other version by name; the `.zon` manifest's
minimum-version field is not enforced for a root package and is not
relied on. CI runs the same script, so the pinned bytes are the only
zig anything runs.

the three shipped images are built ReleaseFast with `.strip = true`,
which is what makes a build byte-identical across build paths on ELF
and Mach-O alike; debug info carries the absolute path and a
content-derived Mach-O UUID follows it. every lane builds a
fourth core for its own host in ReleaseSafe with `sanitize_c = .full`, which is
undefined-behavior checking with a message and a trace rather than a
bare trap. it is built for the host's shipped target, not the host's
own libc: static musl on Linux and libSystem on macOS, so the checks
run over the libc that ships, its floats are the release core's (a
glibc host's libm chose FMA variants by the processor and rounded a
last bit apart), and every runner of an architecture builds its
checked core for the same target, whichever libc the runner has (its
bytes still carry the path it was built at, below). glibc's headers
would have added null-argument and `_FORTIFY_SOURCE` checks, which
musl's lack; a `TODO:` above the checked core in `build.zig` for each
says how a header the checked build force-includes would recover them.
`bin/zig build sanitized` boots with that core and embeds it in
the build directory's `sanitized/bin/cosmic`; every full CI run (merge queue, main, or a
manual run) verifies the embedded core bytes and, on the Linux x86-64
leg, runs the test suite under a 320-second limit, with full
undefined-behavior checking and coverage collection enabled: every
test in main's scheduled run and a manual one, and in the merge
queue's and main's only the tests whose sandboxed verdict does not
stand from an earlier run ([`ci/cosmic_ci/orchestration.tl`]'s
`stands`). zig
ships no address sanitizer runtime for any target;
an address-sanitized job on a real clang, outside the pinned
toolchain and with that caveat stated, is a later addition. a
`cosmic-debug` asset, the sanitized build published beside the
release, waits for a way to distribute one fat, cross-platform debug
build; being unstripped, it is then built at one fixed path on every
runner, so no runner's path is in its bytes.

the C layer is POSIX plus a declared platform seam: no signalfd,
inotify, epoll, or procfs outside modules guarded as Linux-only.

### the line between C and Teal

the core is a syscall table plus a few vendored libraries; anything
with a policy in it is Teal, stored once in the database and shared
by every target.

native, per target: the Lua VM; SQLite; mbedtls, which also serves
hashing and HMAC; miniz for deflate; yyjson for JSON; expat for XML; argon2 and a
regex engine, both planned; the syscall table; the database VFS and the
entry. measured stripped on
x86_64 musl: Lua 360 KB, SQLite with the flags below 1.1 MB, FTS5
another 222 KB, miniz 98 KB; Lua and SQLite together in one static
binary 1.4 MB. three carried cores plus mbedtls is on the order of
6 MB per shipped binary before any Teal, and the size report carries
that per component.

the syscall table is one C function per syscall with the same
signature on Linux and macOS, written by hand in one strict shape in
an annotated header, each entry naming its arity: [`core/syscalls.h`]
for the public table, [`cosmic.sys`], and [`core/process.h`], in the same
grammar, for the raw process table, [`cosmic.internal.process`], the
calls that start, feed and reap a child, which only [`cosmic.child`]
and [`cosmic.proc`] are handed. the annotation grammar is LuaCATS, `---@param`, `---@return`,
`---@class`, `---@field`, the grammar the cosmopolitan fork's
`definitions.lua` proved on this exact job. the Teal declaration and
the doc row for each function are generated from its header when
the core first runs over the tree, and the generator refuses, by
name, any function whose annotation is incomplete, whose parameter
count disagrees with the arity, or whose returns are not one value
or the fallible three, so a binding cannot exist without its type
and the C surface cannot grow without a diff in one of those headers.
the tables the modules are opened with are filled from those same
entries, each an X-macro [`core/syscalls.c`] expands again, so there is
no second list to drift from them.
argument-shape errors raise; runtime failures return `nil, err,
errno` for a value and `false, err, errno` for an effect, plain
values, the convention the fork already uses at over a hundred sites.
that errno in a third slot belongs to these two tables alone, the
one exception to the two slots of honest returns: a Teal function over a
binding reads the errno where it needs one and answers in two slots
itself. in cosmic's own modules the build refuses a fallible Teal
function that declares a third, save a stand-in stored into the
table itself, which answers as the binding it replaces.

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
ordering. the planned regex engine is a standalone extraction of musl's
TRE-derived one, about 4,300 lines, compiled the same on both OSes.
DNS is c-ares, one resolver compiled the same on every target in place
of each libc's `getaddrinfo`, driven by the core's own poll loop
(core/ares_config.h). it reads `/etc/resolv.conf` and `/etc/hosts`,
and on macOS the system's DNS configuration too, through Apple's
dnsinfo, which reaches a Mach service a macOS sandbox profile will
have to allow.

Teal by default: filesystem policy (walk, find, atomic write), child
processes above spawn and wait, sandbox policy over raw enforcement
syscalls, URL, SSE, tar, the zip directory, and the whole artifact build.
C when a benchmark on
a real scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists. HTTP/1.1 framing and DNS started in C on the
second half of that rule: curl and c-ares are each fuzzed upstream
(OSS-Fuzz), and [`cosmic.http`] needed a TLS client, mbedtls under curl,
before a Teal one could be written and fuzzed. JSON starts in C
on the same half: every program that talks to a service parses it,
and yyjson is fuzzed upstream (OSS-Fuzz), keeps 64-bit integers
exact, and reads RFC 8259 unless a caller names JSON5 for the one
read. it reads; the core's own C walks the document into Lua values and
writes JSON back, with yyjson printing each float's shortest form.
XML starts in C on the same half: expat is fuzzed upstream (OSS-Fuzz),
bounds entity expansion, and reads no external entity unless a handler
asks, and the core sets none. it reads; the core's own C hands each
event to Lua, appending it under `lua_pcall` so no raise crosses expat.
the benchmark harness, not taste, moves a module across the line in
either direction.

### the lua surface

the global environment holds Lua's pure libraries and nothing that
reaches outside the process: `string`, `table`, `math`, `utf8`,
`coroutine`, and the base functions minus `dofile` and `loadfile`.
`package` keeps `loaded`, `preload`, and `searchers`, and the one
searcher reads the database; `path`, `cpath`, `loadlib`, and
`searchpath` do not exist: reading or writing one errors with what to write
instead, as the checker refuses it, and so does a `require` of `io`, `os`, or
`debug`. `io`, `os`, and `debug` are not globals.
files, standard streams, environment, time, and processes are
[`cosmic.fs`], [`cosmic.env`], [`cosmic.clock`], [`cosmic.time`], and [`cosmic.proc`], all
over the syscall table, so the same call behaves the same on both
OSes and the sandbox has one door. `print` writes through the
syscall table, and `fs` writes to a stream without a newline.
[`cosmic.errors`] exposes a traceback for error reporting; the coverage
collector is a C hook behind a private binding, and `debug` itself is
never opened. a name that is missing errors with the module
that replaces it. reading `io`, `os` or `debug` answers a stand-in
table, so `if os then` is true and the first field used raises, naming
the replacement for that very field, at the site that used it.
`cosmic docs <name>` (`cosmic docs os.exit`) answers the same text, and
[`cosmic.removed`] is the one place the map from a removed name to its
replacement lives.

the compiler -- the modules of `lang/` and the pipeline that drives them (below) --
reaches outside the pure libraries nowhere: it opens no file, reads no
variable and runs no code it compiles. the checker resolves the types of a
`require` through the declarations of the tree it is handed: the build
answers them from the staged tree, which is a build reading its inputs.
before the checker exists, at boot, a short Lua bridge, [`core/bridge.lua`],
which the boot reads from the tree as it reads the seed's compiler, answers
`require` from the tree's files.

Lua is built with `LUA_USE_POSIX` on both OSes and no compatibility
defines, so assigning an undeclared global is a compile error and
nothing can `dlopen`.

the raw C modules behind [`cosmic.internal.store`] and
[`cosmic.internal.sqlite`] have no requireable name for anything
outside them. the searcher hands each to its Teal wrapper,
[`cosmic.store`] and [`cosmic.sqlite`], as the loader's second argument,
and only when the wrapper is loaded, trusted, from the binary's own
database; nothing else ever calls `require` and gets an answer.
[`cosmic.internal.errors`] is the same shape behind [`cosmic.errors`],
unconditionally preloaded rather than argument-passed, since a
traceback carries less risk than a raw database handle. `internal`
is a reserved name: a path under `cosmic.internal.` never satisfies
an ordinary `require`, for any caller, which is stronger than
positional privacy and is where every raw C binding that is not
itself the public surface belongs, not only these three: the process
table behind [`cosmic.child`] and [`cosmic.proc`], and the hash table
behind [`cosmic.hash`], are the same shape. `internal` means not
declared or documented for a program to use, not unreachable. Teal
modules live there too, as `cosmic/internal/<name>.tl`, the machinery
cosmic's own modules share and a user should not see. They are ordinary
modules, with rows, closures and tests of their own, and
`cosmic.internal.<name>` reaches one at runtime by name like any module
of `cosmic.*`; but they are not documented, no part of the public API,
and each export is still held to be used. Only cosmic's own `cosmic/`,
`build/`, `cmd/`, `test/` and tests may require one, and a project
tree's module requiring a Teal one is refused
([`build.positions`]). A caller that asks `package.searchers` for a
raw wrapper by hand is handed its raw table too, which is no escalation, since that table reaches
nothing its wrapper does not. what keeps a raw call off the public
surface is that nothing names it -- no type, no doc row -- and nothing
the checker accepts reaches it by accident. [`cosmic.internal.testing`]
is the one exception: its five namespace calls (`mount`, `umount2`,
`unshare`, `setns`, `chroot`) are real in every core and have no
[`cosmic.sys`] wrapper, because the sandbox tests need them on every
core. They grant nothing a program could not do by starting `mount` or
`unshare`: the kernel, and the filter of any sandbox the caller is in,
are what refuse them.

### the database

`require` reads the database and nothing else; a `.tl` on disk is
input to the build, never to the runtime. one database holds:

- **modules**: import path, source hash, Teal source and bytecode,
  kind (module, test, example, main), and the test or example names
  the compile step found. the Lua tl generated on the way stays in
  the working database: nothing that reads a shipped file loads it.
  the source and the bytecode are stored raw-deflated, as a
  declaration's source is. the core inflates the bytecode when its
  searcher loads a module and in [`Store.bytecode`]; only an uncaught
  error's line and [`Store.source`] (a checker typing another tree, the
  self-rebuild reading the compiler) read the source, and each inflates
  it. `inflate(X)`, which every [`cosmic.sqlite`] handle knows, reads
  either back in a query.
- **stubs**: the tool's alone, one per standard-library module: its
  source with every function body left out and every other token it
  keeps where it was (build.stub), raw-deflated. a module that
  returns a record it declares keeps only the statements that record's
  type names, so code and requires only bodies read are left out too.
  a project's checker reads a module's stub in place of its source,
  which types it the same in a fraction of the time and loads fewer
  modules; cosmic's own build refuses a stub whose type differs from
  its source's.
- **places**: the tool's alone, where each standard-library module
  declares its types and their members, by dotted symbol, as lines and
  columns of the source `modules` holds (build/syntax_places.tl). `cosmic
  lsp` answers a go to definition of a `cosmic.*` symbol in a project from
  it, with the module's text written below the build directory.
- **members**: the tool's alone, what each standard-library module
  declares its types to have (build/syntax_members.tl), with the doc
  comment of each member. `cosmic lsp` completes the members of a
  `cosmic.*` type in a project from it.
- **docs**: one row per symbol a module declares at its top level --
  the module itself, each function, each record, enum or alias and
  every field and value under it, and each documented value -- with
  its kind, its declaration as the source wrote it, its doc comment
  (the run of comment lines directly above it, leaders stripped),
  and where it sits. every function is here, documented or not, so
  `cosmic docs` can always say where one lives. an FTS5 index,
  `docs_fts`, answers `cosmic docs` when the query is words rather
  than a name. It stems its words (`porter`), weighs a word in a
  symbol's name above one in its signature and that above one in its
  prose, and a query that no member answers whole falls back to the
  members that carry some of its words.
- **uses**: one row per place a module refers to another module's
  symbol through a top-level require alias (`Fs.read(...)` under
  `local Fs = require("cosmic.fs")`), resolved against the name the
  other module returns. `cosmic uses Fs.read` lists them.
- **links**: one row per link in a module's comments that resolves
  ([`build/link_index.tl`]), by what it names -- a symbol, a file, or a
  heading of one -- and where it is. A parse keeps each link as
  written; it is resolved as the database is written, when every
  module is known, and what the files it names said signs the
  database. `cosmic uses` lists them beside the uses, marked `link`,
  and answers a file's path too; `cosmic docs` counts them on a page.
- **examples**: one row per worked example, a `kind = "example"`
  module's own top-level `function Example.<name>()` -- found the same
  structural way `docs` finds `function Fs.read(...)`, shipped against
  only the module its file name pairs with ([`cosmic/fs_example.tl`]
  ships against [`cosmic.fs`]). A module's examples may be split by
  topic: `<module>_<topic>_example.tl` pairs with the longest module
  or declaration, not a test, its name less `_example` starts with
  followed by `_` (`cosmic/json_yaml_example.tl` ships against
  `cosmic.json`; `cosmic/jsonx_example.tl` against nothing). `<name>` is a free label, not a symbol:
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
- **payload**: for an embed-built executable, the files under the
  project's `static/` directory: `path` relative to it,
  `data`, the lowercase hex `sha256`, the Content-Type `type`, `gzip`,
  the gzip of `data` when that is worth sending, else NULL, and `zstd`,
  its zstd at level 19 under the same rule (a compressible type, over
  1 KiB, at least 10% smaller), else NULL. [`cosmic.web.static`] chooses
  among them by the request's Accept-Encoding. A program reads only its
  own build's payload, so no reader tolerates a table without `zstd`.
- **ca_roots**: Mozilla's CA bundle, one DER certificate a row,
  which [`core/http.c`] reads from the binary's own database alone.
- **ca_revoked**: the certificates Mozilla's OneCRL revokes
  (`vendor/onecrl`), by issuer and serial number or by subject and key,
  which [`core/http.c`] refuses anywhere in a chain.
- **zoneinfo**: the IANA time zone database (`vendor/tzdata`), one
  TZif file per zone name, the only zone rules [`cosmic.time`] reads:
  a host's own zone files are never read, so a zone name means the
  same rules everywhere. A boot reads it from the tree, a
  Teal-only rebuild carries the running binary's rows over, and
  `cosmic build` copies it into every executable it writes. It keeps
  a rowid, written in name order: a WITHOUT ROWID row lives in an
  index page, where a zone file past about a kilobyte spills into
  overflow pages, and the table would take two thirds more room.
- **web_assets**: the browser-side files [`cosmic.web`] serves under
  `/_web/` (`vendor/htmx`, `vendor/htmx-ext-sse`), one row each with its
  SHA-256 and its SHA-384 as base64 (the value of an `integrity`
  attribute), hashed at boot. A boot reads them from the tree, a
  Teal-only rebuild carries the running binary's rows over, and `cosmic
  build` copies them into every executable it writes;
  [`Store.web_asset`] reads one.
- **the compiler**: no row of its own. the modules of `lang/` are modules of the
  tree like the rest, and the `compiler` meta row is the identity of the checker
  that compiled the tool, which a tool older than its tree compares to rebuild.
- **decls**: every declaration the tree holds, generated or written,
  so a checker building another tree against this binary can type
  what it requires. Two rows are no module: `lang.prelude` and
  `lang.stdlib`, the text of [`lang/prelude.d.tl`] and of
  [`lang/stdlib.d.tl`], which are the globals the new checker types a
  project against (`COSMIC_GRAMMAR=new`, [`build/checker_declarations.tl`]).
- **catalog**: the errors a program can meet, one row per literal
  `return nil, ...` or `return false, ...` message under a top-level
  function, naming that function, plus hand-authored rows for the
  `strerror()` messages a syscall can raise. an FTS5 index over it,
  `catalog_fts`, is what an uncaught error's message is looked up
  in. a row's own text prints as guidance; a row with none prints
  one line naming the function the message came from and
  `cosmic docs <symbol>`, which shows its doc comment. the runtime
  also prints the Teal line the error was raised on: tl's generated
  Lua keeps the line numbers of the Teal it came from, so the line
  a Lua error names is a line of the module's own source, read
  straight out of `modules`.

A module has one type source. A `foo.d.tl` is the declaration of a
module whose code is C, says so with the line `--- @kind binding` in its leading comment, and has no `foo.tl`; a build
refuses a `.d.tl` that names no kind. ([`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`], the globals, say `--- @kind language`,
which no other file may.) A `foo.tl` is its own
declaration, its written record. A build refuses a `foo.d.tl` beside a
`foo.tl`, naming both files. The declaration remains in `decls`.

`ca_roots`, `ca_revoked` and `zoneinfo` go stale on upstream's schedule, not the
code's, so `cosmic refresh` ([`build/refresh.tl`]) writes a copy of a
binary -- the tool, or any executable `cosmic build` wrote -- with
any of them replaced from a newer release: fetched from NSS (Mozilla's root store), OneCRL or PyPI, or
read from a file. It splits the artifact at its database
([`artifact.split`]), replaces the rows with the same functions a boot
fills them with, records the release in `components`, and puts the
database back behind the same head, byte for byte. The binary it reads
is never written.

tables use natural keys. narrow rows use `WITHOUT ROWID`; `docs`,
`catalog` and `examples` have the rowids FTS5 joins against; `ca_roots`
and `zoneinfo` use rowid tables for their size. `modules` has a separate
path index, so a name lookup need not read unrelated bytecode and source
overflow pages. every producer inserts rows in a deterministic order;
a rowid is not an identity across builds. everything a build
does on one host lives in a second database beside it, `build.db`,
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

the binary is a versioned portable artifact (version 2): a POSIX shell launcher,
aligned stored ranges (each release core compressed, with the decoder stub of its
target), a fixed manifest, one SQLite database, and a fixed trailer.
[The portable runtime implementation guide](guides/portable-runtime.md) follows
those bytes through startup, project embedding, self-rebuild, and CI.
the manifest is the sole authority for target/configuration, byte range, and
sha256. each 104-byte entry has a kind (a core, or the decoder stub of a
core), a codec (raw or zstd), the stored range (offset, length, sha256) and
the core it decodes to (length, sha256). the core's length and digest are its
identity: the cache entry is named for them, and the stamp, the runtime
identity, a verdict's key and the launcher's environment hold them. a raw entry's
two are equal. a reader of version 2 refuses version 1 by name. the launcher
retains an open descriptor before executing the selected core; startup
validates the complete manifest and trailer against that same descriptor. the runtime's VFS reads only the validated database range from the
retained descriptor. it never reopens the logical pathname, so rename, unlink,
and atomic replacement after adoption cannot mix files. the last partial range
is hashed over its real length, never zero-padded.

a cold launch of a compressed core cuts the stub out of the descriptor first
(it is the only reader that relies on the descriptor's offset, which is 0 until
then), checks its length and digest, and runs it as `stub <descriptor> <offset>
<stored length> <length>`. the stub reads its range with `pread`, accepts
exactly one frame that names its content size and a checksum, with a window of
at most 8 MiB, and writes no more than the length it is given. the launcher
reads its exit status, removes it, and checks the output's length and digest as
it does a raw core's. the stub is private, mode 0500, in the validated leaf, and
a `noexec` cache fails there with a diagnostic that names it. a program
`cosmic build` writes shares the prefix and so the compressed cores. the
runtime's own readers never decode: `trusted_prefix` hashes each stored range
against its stored digest, and `trusted_core` (for `cosmic build --host`) reads
the running cached core and hashes it again.

the database is read-only, and the runtime never writes it. it is opened with `immutable=1`
so SQLite skips locks and staleness checks on a file no one else can
change. mutable state lives in an ordinary file. a program that
ships a dataset it updates copies it out once with `VACUUM INTO`, or
attaches the embedded database read-only beside a writable one and
queries across both.

the launcher's cache leaf is untrusted until its kind, owner, mode, and contents
meet the cache policy, and the core's length and digest match the manifest. its
parent directory is the user's trust boundary. a cold launch writes and
publishes a verified core atomically. a warm launch checks the entry's kind,
owner, mode, and length, and hashes it unless a verified stamp beside it still
holds: startup writes the stamp after hashing the entry, recording its size,
inode, and modification and change seconds once a second has passed since it
last changed, so any later write to the entry voids it. startup trusts the
same stamp and otherwise hashes the core it runs from. the stamp guards
against accidental damage, not against the entry's owner, who controls the
cache anyway. the launcher selects the platform forms of `stat`, `ln`, and
the SHA-256 utility; these are supported-system interfaces rather than a claim
that every invoked utility and flag is specified by POSIX. it reserves the
whole `COSMIC_PORTABLE_*` prefix for its descriptor handoff. startup requires
the complete handoff, validates it, adopts the descriptors, and clears every
name under the prefix except `COSMIC_PORTABLE_CACHE` before Teal runs, for both
portable and native startup. `COSMIC_PORTABLE_CACHE` alone is public
configuration.

ordinary artifacts have exactly three release cores (and their three stubs) and
select configuration 1. the checked artifact retains those required release
entries and adds one raw configuration-2 core for the real build host, 38 to 50
MB with its debug information, which compression would only slow; its private
launcher selects only that entry. a host-only boot stores the host's core and a
placeholder per other target raw. target/configuration/kind triples are unique
across the manifest and system identities are unique in the selected
configuration. the production
decoder's required-release mask is unchanged.

a project's projected module database, `cosmic.db` in its build
directory, is read ahead of the
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
tool is made of, `build/`, `core/`, `cosmic/`, `cmd/`, `patch/`, `lang/`, each
vendored tree's `PIN`, `build.zig` and the zig wrapper, but the Teal
tests among them, which no binary carries: an edit to a test rebuilds
no tool, and only a test may require one. a vendored
tree is a function of its pin and its patch records and is never
edited in place, so those are its inputs and the tree is not walked.
on a mismatch the tool rebuilds itself, as below, or refuses with exit 3
when it cannot. raw cores remain build outputs under the build directory's `core/`; the working
database carries the compiler source needed for a later database-only rebuild.

sqlite is load-bearing at boot, so its sharp edges are the runtime's
problem and are fixed first: a typo'd or overlong parameter table
never binds NULL silently, TEXT and BLOB are distinguishable at the
Lua boundary, and a closed handle fails the same way from every
method. the build is single-threaded, so SQLite compiles with
`SQLITE_THREADSAFE=0` and without extension loading, shared cache,
double-quoted strings, or deprecated interfaces, and with the
`dbstat` virtual table, so `cosmic db` can say what every table in
each database costs in rows, pages, and bytes.

### the build

the build is a cosmic program reading the tree by position into the
database: compile, check, record, embed. `build.zig` owns the C.
`bin/zig build` patches the vendored trees first, in Teal (below),
and `zig build` installs them under the build directory's `vendor/` and produces the core
for each target (`zig build boot` builds the host's alone unless given `-Dboot-cores=all`,
and puts a placeholder script where each other core goes). `zig build boot`
bridges: it runs the fresh host core over `build/` to compile the
importer with the compiler built from the checker, `lang/`, in two
stages (below), writes `cosmic.db`, and writes one
portable [`bin/cosmic`], each in the build directory. the tool carries `carried.db`, that projection
without the tree's own tests and examples, and with the docs, uses
and examples of the public standard library alone: `cosmic test` and a lookup
inside the tree read the rest from the projection, `cosmic.db`, and a release has no
use for them. a fresh clone and CI run `boot`; a
developer runs `bin/cosmic build` the other hundred times a day.

[`build.work`] stages inputs and manages the working database.
[`build.identity`] defines input policy, fingerprints and semantic identities.
[`build.derivation`] writes generated inputs and analysis rows;
[`build.pipeline`] defines compilation and acceptance. [`build.importer`]
coordinates parses, compiles and cache lookups. its `compile_tree` owns the
shared caches through derivation, identity selection and compilation; the caller
controls the transaction and publication. [`build.writer`] publishes deterministic
projections: it fills an attached in-memory schema, including its signature,
inside the transaction that staged and compiled the inputs. after committing,
it takes the publication lock and vacuums only those frozen rows into the file;
another build may commit while it waits without changing what it publishes.
reporting and cache placement stay outside the compiler's semantic
closure so changes to them do not invalidate every compile.

cosmic builds itself, so the tool is also an artifact of the tree,
and a stale tool is the bug to design against. `boot` stores two
fingerprints in the binary it produces: one over everything the tool
is made of, one over what the C core is built from. every run in
cosmic's own tree fingerprints the tree first. only the tree's own tool
in its build directory rebuilds itself ([`build.reboot.own_tool`]); a stale release or
an externally copied tool refuses with exit 3. when only Teal differs,
the tree's tool compiles the tree, projects the database and combines it
with the exact retained portable prefix before re-entering the command.
retained descriptors keep the running artifact available across rename
and unlink. when the C core's inputs differ, only zig can build it, so
the tree's tool runs `bin/zig build boot` and re-enters, or, under
`COSMIC_AUTO_BOOT=0`, refuses with exit 3.

semantic identities keep different kinds of reuse separate. the compiler
identity holds the modules that decide generated code, stored analysis and
acceptance, plus the checker's source and the Teal compiler's and Lua's
pins and Lua's patches ([`build.identity.compiler_identity`]). module keys carry it; importer
coordination, diagnostic presentation and general standard-library plumbing
stay outside it. the analyzer identity keys stored parses: the runtime basis,
the analyzer modules' sources and the code that reads
([`build.importer.analyzer_identity`]), not the whole compiler identity, so an
edit only a compile runs (build.plans) parses nothing again. the writer identity holds the code and
core image that determine a projection's bytes, including its standard-library
dependencies. the projection records which compiler and writer produced it so a
self-rebuild can settle on its own code. the runtime basis holds the same pins, patches
and checker source; startup combines it with the validated target, configuration
and exact core digest to identify the running runtime. every test verdict holds
that runtime identity. a row compiled by another compiler is never mistaken
for this one's. a sandboxed test's key holds what the
compiler made rather than its identity -- the bytecode and rows of
the store of the test's import closure, and the harness's epoch,
which a guard test holds to a digest per harness module of its source
and bytecode, so a compiler that compiles the harness otherwise asks for a
bump or an acknowledgment and runs every test in the merge queue --
so an edit to the importer that compiles every module as before runs
again only the tests whose closure holds or reads the compiler
([`build/declared_key.tl`]).

the C stage is hermetic and checked. `build.zig` runs with both of
zig's caches, keyed by content, in the user's cosmic cache directory
(`zig-project` and `zig-global` under `~/.cache/cosmic` by default) and
shared by every checkout (`COSMIC_ZIG_CACHE` and
`COSMIC_ZIG_GLOBAL_CACHE` move them, and with no cache directory at all
they fall back to the build directory); the build directory and those
caches are the only things to delete. the
applier's output replaces the vendor directory the core compiles
from, whole, never one file beside a pristine tree, because a quoted
`#include` finds the neighbor first and a half-applied patch builds
green. a provenance gate in CI asserts that no bytes from outside
the tree and the pinned zig reach any production output. four platform lanes
independently build the complete portable product, execute those exact bytes,
and attest its hash. the provenance join requires all four products and
attestations to agree; zig opens a few
host paths to probe the native target even for a cross build, so the
gate judges outputs, not opens. the trust chain has
exactly two seeds that the tree being built did not build, and they are
named here: the earlier cosmic release [`ci/cosmic-driver.pin`] names,
fetched and verified by the POSIX sh [`bin/cosmic-bootstrap`], and the
zig tarball [`bin/zig.pin`] verifies. everything else is vendored or
built from them.

[`build/zig.tl`] and [`build/rebuild_lock.tl`] serialize rebuilds on the
same lock file. they take flock first, then SQLite's transaction where
the two lock kinds are independent. the SQLite half excludes older tools
that take only that lock, including a checkout visited during a bisect.
a child boot proceeds under its parent's handed lock only when the handoff
names the same device and inode. a verb that only reads (`reads` in
[`build/verb_spec.tl`]) never waits on either lock: where another run
holds one, it rebuilds no tool and writes no projection, and reads what
is there.

[`build/patch.tl`] and [`build/zig_fetch.tl`] each use a persistent gate
while sweeping scratch directories and creating a new wrapper with its
owner file locked. the gate is released before patching or downloading;
the owner lock remains held through publication and cleanup. a sweep
removes a wrapper only after locking its existing owner file. wrappers
without one and legacy PID-only directories are left alone. publication
moves the payload alone, keeping ownership files out of the cached product.

the target build architecture is fast, incremental, and reproducible.
today a module whose key stands is read back from the working
database rather than compiled again, the shipped database is a
projection of that one, written only when what it is a function of
moved, and a test whose verdict stands is not run again. where the kernel can,
each worker runs sandboxed to its test's declared inputs, as it does by default
on Linux, and its verdict is keyed by those inputs -- the closure's sources, the
declared paths' contents, the declared variables' values, the declaration, the
core, the test harness's epoch and the worker's timeout, the host's kernel, processor and
user, and what it has installed only where the test declares the system's own
paths, which no worker is given otherwise -- digested
before the test runs, none of it naming where the tree is, and shared by that
key alone through a database under the cosmic cache directory, so a fresh
worktree runs only what no checkout has already run. a test reaches no network
but loopback addresses of 127/8, which it declares and its worker answers
offline, on a loopback of its own, keyed like any input: the build's analysis of
[`Test.policy`] refuses any other host, `::1` and `localhost` among them
(`policy` checks the declaration's shape; the build checks its
values). one that reads a link out of the tree, which no key holds, runs every time. an unsandboxed run (macOS,
`COSMIC_TEST_SANDBOX=0`) is keyed by declared inputs as a sandboxed run is, and
by where the tree is, which its workers see, trusting the declarations a
sandboxed run elsewhere enforces; it keeps its verdicts apart from sandboxed
ones, and shares them only through a file `COSMIC_VERDICT_CACHE` names, as
CI's macOS leg does. each test
that does run runs in a worker process of its own:

- *incremental*: a module row is keyed by the content hash of its
  source, the hashes of its import closure, and the compiler identity. a test
  verdict adds the runtime identity, a digest of the zones and CA roots the
  running binary carries (which `cosmic refresh` replaces without moving that
  identity), and the inputs the test declares ([`build/declared_key.tl`]).
  an unchanged key is a stat; a changed one recompiles and re-records only what
  depended on it. no path is in a module's key, so every checkout of a
  host shares its compiles through `$XDG_CACHE_HOME/cosmic/build/cache.db`
  (`~/.cache/cosmic/build/cache.db`)
  ([`build/shared_compiles.tl`]; `COSMIC_BUILD_CACHE` moves it, `0` turns
  it off), keyed beside the module's key by what else decides whether
  a compile is accepted -- cosmic's own tree or not, a doc's extracted
  test or not, the module's file, and the names the checker strips --
  and a fresh worktree compiles only what no sibling has. it parses
  only what no sibling has, too: a source's parse is shared under the
  analyzer that made it and the source's hash, and a boot, which names
  its analyzer by the very parse it has yet to make, takes an
  analyzer's parses only where the `requires` rows that analyzer found
  name it again over this tree ([`build/importer.tl`]'s
  `shared_analyzer`). the boot bridge's own compiles share the file too,
  in a table of their own ([`core/bridge.lua`]): the compiler's, and every
  module it loads up to [`build.boot`], keyed by the digest of every `.tl`
  and `.h` under the root and of the compiler and the bridge, since no
  import graph exists yet to key them by. a boot of a tree none of whose
  `.tl` or `.h` has changed, and each worker it starts, compile nothing
  in the bridge; an edit to any one of them compiles it all again.
- *parallel*: a build with much to parse or compile, a cold boot or an
  edit that reaches most of the tree, does it in worker processes: one
  fewer than the processors, `COSMIC_BUILD_JOBS` naming another count
  and `1` none (`build/workers.tl`). sources are dealt to them by
  size. modules are dealt by what they import (build/shards.tl),
  since the checker's types cannot leave a process and a worker checks
  every import of what it compiles. the build process alone writes the
  rows, in the order a build without workers writes them, and compiles
  itself what no worker did, a refusal included, so its error is the one
  a build alone gives and the database and the tool come out byte for
  byte the same (`build/worker.tl`). a boot loads the build's code from
  source in each worker, which takes seconds, so it starts them only for
  a few megabytes of new source.
- *fast*: compile and check run in one process, one transaction,
  against declarations already in the database. each test runs in a worker
  -- the same core relaunched directly, never through the launcher --
  one per processor at a time, with a fresh temporary directory, captured
  streams, and a deadline past which its whole process group is ended. the
  worker reads its import closure's store, never the working build database.
  it reports what it read, what it hit, and its verdict over a pipe; the
  build process alone records those results in the working database. a test
  that exits, crashes, or hangs fails by itself, and on Linux the runner, a
  child subreaper, also ends what a dead worker's descendants left behind.
- *reproducible*: the shipped database is a host-neutral projection of the
  working database into a fresh schema, filled in one transaction, with every
  table but those named above `WITHOUT ROWID` on a natural key and the file produced by `VACUUM
  INTO`. target identity comes from the selected, validated manifest entry;
  it is absent from database rows. `bin/zig build cores` cross-compiles every
  target from any host, so the complete artifact, its database and both test
  applications are byte-identical regardless of which host produced them.
  four CI platform lanes independently produce and execute the complete
  artifact. the provenance join proves their bytes agree.

four platform lanes cover Linux x86_64, Linux aarch64 on an arm runner, macOS
aarch64 on an arm Mac runner, and x86_64 Linux with additional offline Alpine
checks. each independently builds the complete product, runs it, and uploads the
executed bytes. the provenance join, in the job ci requires, compares the four
products and their attestations.

#### what a verdict's key leaves out

CI's Linux legs stand on shared verdicts: those of sandboxed runs, keyed by
each test's declared inputs ([`build/declared_key.tl`]), which the sandbox holds
the test to, and the host's identity: its kernel, processor, user and
capabilities; and what it has installed -- its package database, the system
it says it is and what its system paths hold -- only for a module that
declares `system`, whose worker alone
is given /usr, /bin, /lib and /etc, or that declares a host directory. what
that key still leaves out is in the `TODO:`s on `host_identity` and
`system_identity` there and in [`ci/cosmic_ci/orchestration.tl`]'s `stands`. the
macOS leg, which has no sandbox, stands on shared verdicts keyed the same way
(as every unsandboxed run is), which nothing holds its workers to: a Linux leg's
sandbox holds the same test, under the same declaration and closure, to them;
what reads something only on macOS is the gap. its image, beyond the sealed
system volume, is named by `COSMIC_SYSTEM_ID`. any other unsandboxed run is
keyed the same way, and shares nothing unless `COSMIC_VERDICT_CACHE` names a
file.

what the declared key leaves out, each with a `TODO:` where its fix goes:

- *the clock*: a test whose verdict turns on the date stands on one reached
  another day. CI's scheduled run, which stands on nothing, runs it daily.
- *what the host has installed*: what the system's own paths hold, for a test
  that declares `system`, is keyed by the package database, the image
  `COSMIC_SYSTEM_ID` names, and a walk of their files by mode, size and
  modification time, but /etc's, the host's configuration, which a run
  holding such a test makes once and remembers while no directory it
  walked moves (`system_identity`): a file written in place is not seen
  until a directory moves, one rewritten with its size and modification
  time put back is not told apart, and on macOS, which walks nothing, what a
  developer's Mac installs beyond the sealed system volume is keyed by
  nothing -- its runs keyed so are CI's, whose image the variable names.
- *the program's own modules*: a worker whose module does not declare
  `store` is given at its build directory's `cosmic.db` the store of its import closure alone
  ([`build/closure_store.tl`]'s `write`, kept under the build directory's `stores/` by the address its
  key holds), and `require` refuses it a module of the tree outside the
  closure ([`build/test_worker.tl`]'s `hold_requires`); nothing else in the
  worker holds a lookup in the store to the closure. A worker whose module
  declares neither `store` nor `tool`, a `nests` one among them, also runs on
  a sealed database of that closure ([`build/test_key.tl`]'s `sealed_for`) in the
  program's place, so what it and every process it starts read of the program
  is what its key holds. That leaves ways past it. Any other worker runs the
  program, whose own database holds every module of the tree, which
  [`Store.bytecode`], [`Store.source`], [`Store.requires`],
  [`Store.databases()`], [`Store.meta`] and a searcher called by hand read
  with no key to hold them ([`build/test_key.tl`], `seals`). A module the program carries that is no module
  of the tree -- in a project's tree, the standard library's -- is held by
  neither, and the runtime's identity names the core and the pins, not
  those modules ([`build/test_worker.tl`], the TODO on `refusal`). An
  unsandboxed run narrows none of it.

the processor is keyed, for good, by the features a core chooses code by
alone (`dispatched` in [`build/declared_key.tl`], which
[`ci/cosmic_ci/host_id.tl`] mirrors): mbedtls's AES and xz's CRC
instructions, and the VNNI instructions of the core's own int8 vector
search. no Linux core links a libm that dispatches: every one,
the checked core too, is static musl. the rest of
/proc/cpuinfo's flags, its model and its microcode choose no code a test runs,
and keying them split hosted runners of one leg for nothing.
[`build/dispatched_features_test.tl`] fails when the tree comes to ask the
processor anything else.

no run keys a verdict by what its test was seen to read: the observed key,
the log of a worker's reads it was made from, and `--audit`, which named what
a test read beyond its declaration, are gone, and with
them the syscall table's log and the SQLite VFS that recorded the files a
connection opened. a sandboxed
test that reads what it does not declare finds nothing there and fails with
its own error. what a declared key rests on beside the list above:

- *the tree's location*, by rule ([`build/key_parts.tl`], above
  `tree_name`): a test may not turn on where the tree is, nor where the
  program is. a worker no sandbox holds (the macOS leg, or
  `COSMIC_TEST_SANDBOX=0`) sees the tree where it is rather than at /tree, so
  its key holds the tree's path whole ([`build/declared_key.tl`]'s
  [`Spec.tree`]). CI moves its checkout, and the tool with it, to a path a hash
  of the commit and the leg chooses ([`ci/cosmic_ci/place_tree.tl`]), so a
  test that breaks the rule fails a run that meets a path it breaks on.
- *a stat's times and inode*, by rule ([`build/test_key.tl`], above `declared_of`):
  a key holds a file of the tree by its contents, so a test must not depend
  on the times, inode, device, link count or owner of a file it did not make;
  one that needs them makes its own files in its temporary directory and sets
  them. nothing enforces it yet: have a worker's hold answer fixed times and
  inode for a stat of the tree, which takes C and a boot.
- *the binary's data tables* ([`build/test_key.tl`], in its `runtime_of`): a refresh
  changes `zoneinfo` and `ca_roots` without the runtime identity. every verdict
  is keyed on a digest of them ([`schema.tables_digest`]), computed from the
  running binary's own rows as `cosmic test` starts.

`cosmic build` and `cosmic test` will fence themselves with the sandbox core, so
a build cannot read outside its tree and a test cannot reach the network by
accident. the sandbox module, its conformance matrix, and these tool fences are
planned. CI will require the fence; a laptop will report its enforcement level.

### vendored sources

`vendor/<name>/` holds the files the build reads from the upstream
archive its `PIN` names, never edited. `PIN` gives the version, the
url, the archive's sha256, and globs for which files are kept.
[`bin/vendor`] runs [`build/vendor.tl`] with `cosmic --standalone`, which
fetches the archive with [`cosmic.http`], verifies its sha256, unpacks
it with [`cosmic.archive`], and rewrites the tree to exactly the kept
files -- no `curl`, `tar` or `unzip`, and from any directory, since a
standalone run loads nothing of the tree but the one file.
`patch/<name>/` holds
records, each an exact `find`, a `replace`, and a `note` saying why
it exists. `bin/zig build` runs [`build/patch.tl`] standalone on the
bootstrap cosmic before zig, which writes each patched copy whole into
zig's project cache, in a directory named by a hash of the patched
tree as written -- the same path from every checkout, and across edits
to the applier or the records that write the same bytes, so zig, which
keys a C object by its source's path, compiles a vendored file once
for all of them -- and hands zig their manifest;
a record whose anchor no longer matches fails the build by name.

vendored: Lua 5.5, the SQLite amalgamation and twelve of its ext/misc
extensions, mbedtls, miniz, bzip2,
xz's liblzma (decoder and LZMA2 encoder), zstd, c-ares, curl, yyjson, expat, Mozilla's CA bundle, the
IANA time zone database's compiled `zoneinfo`, and tl;
argon2's reference implementation built without threads and the regex
engine are planned. a library that needs a configuration header gets a
hand-written one under `core/` (`curl_config.h`, `ares_config.h`,
`xz_config/config.h`, `mbedtls_cosmic_config.h`, `expat_config.h`), never one generated
by the library's own configure step.

zstd's decoder is also built apart from the core, as `cosmic-unzstd`, a
small static program ([`core/unzstd.c`]) for each target, installed in the
build directory beside that target's core (`core/<target>/cosmic-unzstd`).
It decodes one zstd frame read from a range of an inherited descriptor
and takes the frame's decoded length, so it can never write more than the
length it is told. It is built at the architecture's baseline CPU, and
the macOS one carries the ad-hoc signature zig's linker writes, which CI
verifies as it does the core's. Every release artifact carries it, stored raw,
beside the compressed core it restores.

each tree keeps its upstream license file (`vendor/<name>/COPYING`,
`LICENSE`, `LICENSE.md`). a few vendored files carry a license of their
own: c-ares' `src/lib/thirdparty/apple/dnsinfo.h`, Apple's declarations
for reading macOS's DNS configuration, is under the Apple Public Source
License 2.0 (APSL-2.0), not c-ares' MIT license, and only the macOS core
includes it; c-ares' `ares_sortaddrinfo.c` is BSD-3-Clause, and its
`inet_ntop.c` and `inet_net_pton.c`, like curl's `curlx/inet_ntop.c`
and `inet_pton.c`, carry ISC's text.

each PIN also names its component's SPDX license and the notices a copy
must travel with (`license`, `notice`); what the build links without
vendoring -- zig's runtime, musl, and the license the standard library's declarations inherit from
tl -- has a record of the same grammar under `build/bom/`. the tool's database carries them as a bill of
materials ([`build/bom.tl`]), every executable `cosmic build` writes
carries the same rows, and `cosmic bom` prints them, their notices, or
a CycloneDX document. a pin with no license fails the build.

### teal

the checker and compiler are the tree's own source, `lang/`, and the language is cosmic's own: it reads Teal's
syntax where that serves and breaks with it where Teal or a Lua idiom costs
soundness, simplicity or speed (`cosmic docs <code>` gives the rule behind any
error the checker reports). there is one checker. the fork of tl 0.24.8 that came before it is deleted, with its formatter, its comparison harness and its
patch records; a project written in the old grammar is rewritten to this one by hand
([`doc/guides/project.md`]), and `COSMIC_GRAMMAR=teal` is refused, pointing to that guide.

the pieces are small modules, each deciding one thing and asked by the rest:

- [`lang/lexer.tl`] and [`lang/parser.tl`] read a file into the syntax tree of [`lang/ast.tl`], recovering after
  an error so that one file reports many; [`lang/scopes.tl`] resolves each name to its binding.
- [`lang/declarations.tl`] lowers the types a file writes, and the declarations of other modules (their `.d.tl`
  or their own record, class, interface and enum declarations), to [`lang/types.tl`]; [`lang/relation.tl`] says
  when one type stands for another, and [`lang/generics.tl`] binds a generic's parameters.
- [`lang/check.tl`] types each expression and statement; [`lang/flow.tl`] decides reachability (which statements
  end their block, and so which narrowings survive an `if`); [`lang/check_codes.tl`] lists every code an error can
  carry. [`lang/truthy.tl`] and [`lang/warnings.tl`] are the rules for conditions and for the things worth a hint.
- [`lang/codegen.tl`] writes the Lua, one file at a time, from the tree and what the checker concluded;
  [`lang/fact_wraps.tl`] adds the checks of a checked run (below).
- [`build/pipeline.tl`] and [`build/driver.tl`] drive them over a tree: each module's declarations first, in the
  order its requires give, then its body, its errors judged against the ceilings (below), then its Lua and
  bytecode. [`build/compile_grammar.tl`] is the same for `cosmic compile` and a lone file.

the Lua standard library's declarations are not in the checker. they are [`lang/stdlib.d.tl`], the typing the checker
takes without proof, and [`lang/prelude.d.tl`], the names of the language itself (`any`, `thread`, `userdata`), written
in the new grammar from tl's declarations (the tl license travels in the bill of materials, as [`build/bom/tl.pin`]).
auditing or changing one is an edit of that file and touches no checker logic. the binary carries both as rows of
`decls` ([`build/checker_declarations.tl`]), so a project is typed against the declarations of the tool that builds
it. `cosmic docs` does not show them: it indexes the tree's modules, and these are neither.

the boot compiles the checker with the pinned release ([`ci/cosmic-driver.pin`]) once, as a seed: a `build.zig` step
runs `bin/cosmic-bootstrap compile` over the files [`build/seed.txt`] lists, and zig caches the Lua it writes. the bridge
([`core/bridge.lua`]) loads that Lua as stage one, which compiles the same files again from the tree to stage two. stage
two is the tree's own generator applied to the tree's own source, so the tool never depends on the pin's emitter, and it
is what builds the rest of the tree. the boot checks that the first stage equals the second wherever the generator
writes what the release's does, and fails naming the files unless `lang/SEED_DIFFERS` lists them (one path a line) as
declared to differ, a generator change ahead of the pin; a file listed that does not differ fails too, unless `COSMIC_BOOTSTRAP` names the seed instead of the pin. the sources are in
the compiler's identity, so in every compile's key, and in the tool's boot hash, so an edit to one boots the tool.

the grammar is Teal's, made smaller and explicit. a declaration is `local record R`, `local class C`, `local interface
I`, `local enum E` or `type X = require("m")`; a module returns one of them, or a local declared with its type. an
optional type is `T?` and an optional field `name?: T`; `T | nil` is refused. a field is fixed unless declared `mut`,
and a collection parameter is a view unless declared `mut {T}`. there are no casts (`as`), no `;`, no `goto` but a continue,
no `setmetatable` (a class's methods are written as methods and the compiler writes its metatable), no `global`, no `#!`
first line, no `a and b or c` for a choice (`if ... then ... else ... end` is an expression), and no call with a string
argument without parentheses. `pcall` and `coroutine.wrap` are typed, and the alternatives of a `pcall` are read with
`match`. a type changes only by a guard, `is` of a class or a tagged union, a narrowing declaration or a validator
([`cosmic.shape`]); `any` is legal only where untrusted data enters.

the rules the checker holds, each with its own codes, are these. nil is its own type, in no other: an index read of a
map or an array may be nil, and arrays are dense. a condition is a boolean or an optional. `or` and `and` return what
they say. a local is assigned before it is read, including by a function that names it and may run first. a place (a
local, or a path of fixed fields, `a.b.c`) is narrowed by a test and stays narrowed until an assignment, a write that may
reach it, or code that may run drops the fact; a function literal begins without the facts of the places that can change
before it runs, and a local that any function assigns is never narrowed. `never` is the
bottom type, the type of a call that does not return, and code after it is unreachable. a function type stands for another
when its parameters accept what the other's do and its returns are subtypes of the other's. a record is not a map; an
enum is a union of strings, and a union of enums is told apart by `is`. a record that is not a class is not tested by `is`:
a tagged union is told by its tag. there is no implicit conversion: `integer` is not concatenated without `tostring`, and
a number does not compare with a string. the error-slot discipline of the third principle ([`build/syntax_contracts.tl`])
holds the tree's functions that answer `T?, string` to the checks on their callers.

an error carries a `code` and the places and values it is about, and its message is written from them. each code has a
row in the catalog ([`build/error_catalog.tl`]) with the rule, why the language holds it and the fix, so `cosmic docs
<code>` answers it, and a refusal of a form the old grammar wrote carries the fix that says how to write it now
([`build/removed_fix.tl`]). a rule that refuses more lands with its code and its row together.

the tree is held to the rules by ceilings. build/ceilings.txt pins, per file and code, the violations a stage of the checker
finds there (`[declared]`, `[scoped]`, `[checked]`, and `[untyped]` for the calls whose callee the checker could not type),
and a module is refused above its pin and a tree check fails below it, so a count only falls and a new violation is refused.
a project outside the tree has no ceilings: every error refuses.

a build refuses a Teal `global` declaration in every source it holds: modules, tests, examples, guide examples and `.d.tl`
files; the forms are `global x`, `global function`, `global record`, `global interface`, `global enum`, `global type`, and a
`function f()` with no local `f` in scope, which writes a global. a module's compile key holds its kind, its source, the
keys of the modules it requires, and the compiler's identity; a global reaches other modules by none of those, so a cached
compile could stand after the module that declares it changed. everything a module sees comes through a `require`, which
the key covers. a Lua runtime trick the checker cannot see, `local _ENV = ...`, is refused, and a file run by `cosmic
--standalone` is checked and refused on a type error, cached by content hash like any compile.

the same holds for what a `require` names. the build reads a module's dependencies from the literal names handed to
`require("m")` and to `pcall(require, "m")` (the probe for a module that may be absent), anywhere in the file, and a
dependency is carried into a built program, held in a test's closure and covered by its key. a `require` whose name is
computed, `require(name)` or `pcall(require, name)`, names no module the build can see, so the parser refuses it
(`computed_require`); to choose between modules, require each by its literal name and pick from a table. this holds for
`cosmic.*` and C modules as for a project's: a literal name that no database holds is no edge, and a probe of it
answers false when it runs. a `.d.tl` file imports only with `local type T = require("m")`, whose name is a literal
`require` is a special form: the build reads only a direct call by its name, `require("m")` (a parenthesised literal counts as a literal), and `pcall(require, "m")` with `require` as pcall's first argument. Any other use of the name (kept in a variable, in parentheses, passed to another call) is refused (`require_value`), so a load of a module the build cannot see has no spelling in checked code. A chunk built by `load` gets, by default, an environment of its own, loaded as text: the base functions that share no state with the host (not `collectgarbage` or `warn`) and copies of the pure libraries (without `string.dump`, `math.random` and `math.randomseed`), so a chunk that writes into `string` changes its copy; it holds no `require`, `package`, `_G` or `_ENV`, and no metatable leads back to the globals. Method calls on strings go through the real metatable to the host's own `string`, which the chunk cannot change. A program that runs a chunk needing the globals passes them as its environment, through [`cosmic.internal.globals`], which only the tool and its tests may require (the tree check `requirers` lists who does). A module that is no test may read `package` only if the tree check `package_readers` names it, so the searchers and the table of loaded modules are no way around the build's edges. The type checker is a second barrier (`_G`, `_ENV` and `debug` have no declaration), and the one the build relies on is the first.
already.

`: never` is a flag on a function type, declared by a helper that only raises or exits (`error`, [`Proc.exit`], a module's
`spec_error`): a call of one ends its block, so code below an `if x == nil then fail() end` guard sees `x` narrowed. nothing
infers it from a body, and a declaration that returns anyway is a bug in the declaration.

a checked test run (`cosmic test --check-types`) finds where the checker's conclusions are false. it compiles the tree with
a call of a hook at each read of a place a test narrowed (`if x then`, `~= nil`, `is`, `type()`, `assert`), carrying the
place, the kinds the test took out and the classes and tags it told apart, and the hook raises "fact violated at file:y:x" for
a value the fact is false of, which fails the test and is kept as a row of `type_violations`. so what is checked is exactly
what a test concluded and nothing the declared type said; the programs the checker accepts that it fails are its holes, found
by real runs ([`doc/testing.md`] has the rest). the run changes the Lua, so its compiler has an identity of its own
([`build.importer`]'s `checked_tool`) in every compile key, and its projection is written aside (`cosmic.checked.db`): the
tree's projection, the tool and every executable `cosmic build` writes never carry a check.

the spirit is consistent, strong, explicit typing, the same shape the languages that hold it converged on: the top type
inert until narrowed, no casts, the escape hatch in one greppable region, boundaries decoded through declared shapes. a
runtime-checked cast is closed to Teal because Lua erases record types, so shapes construct their records rather than
asserting them. there is no planned `cosmic check` verb: compilation performs checking, while `cosmic fix` reads and checks
the files it is given and rewrites what the tree's structural rules (`build/fix/rule.tl`, still empty) ask for; it has no
layout for the new grammar yet.

### the runtime

one Lua state, one thread, coroutines over `poll`. every blocking
binding takes a timeout and can be driven from one event loop, which
is Teal over the `poll` binding; [`Server.serve`] and `fetch` are
coroutine-driven; CPU parallelism is by process through `child`.

the C layer is re-entrant, which costs discipline, not code: no
static buffers, no process-global state outside the entry, every
binding takes its context explicitly, SQLite opened per connection
and never shared across a boundary that could later be a thread. one
state per OS thread with message passing stays open as a later
addition that rewrites no bindings.

### tls

mbedtls 4.1, vendored as one tarball with its crypto subtree
included, whose support runs to 2029. the crypto subtree serves
digests and HMAC: MD5, SHA-1, the SHA-2 and SHA-3 sizes, through the
PSA API, with randomness from the OS rather than the library's own
entropy and DRBG modules. [`cosmic.hash`] is the Teal face of it, the
raw [`cosmic.internal.hash`] table's `digest`, `hmac` and streaming
hasher the bindings, and every SQLite
handle knows the same functions, so a query hashes in place. the TLS
1.2 and 1.3 client under [`cosmic.http`] (curl over c-ares and mbedtls)
comes from the same library and the same configuration: one header,
[`core/mbedtls_cosmic_config.h`], which every file that includes an
mbedtls header is compiled against, curl's included. it keeps
certificate expiry checks, extended master secret and TLS 1.3
middlebox compatibility on, and renegotiation and session tickets
off. Mozilla's root bundle ships in the binary's own database, one
row per certificate, identical on every machine, moved only by a
pinned bump; the core parses it once, and every TLS connection, a
proxy's too, verifies against that chain. `SSL_CERT_FILE` adds
certificates for the corporate-proxy case without making per-machine
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
the rest (today the core's `landlock_ruleset` holds paths alone, and
`spawn`'s `offline` namespace holds the network, the same on every
kernel): `network none` denies `socket` for the internet families,
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
`cosmic fix`, `cosmic docs`; `cosmic file.tl` runs a
file; `-e` is the one-liner: `cosmic -e '<chunk>'` runs a chunk of Teal
against the standard library, with no tree. The chunk is checked as a
file is, so a type error exits 1 with the checker's messages and
nothing runs; it takes the library by `require("cosmic.json")`, as a
file does (and the tool's own modules, which only the tool's one-liner
may require), with nothing pre-bound, and the words after it are its `...`. `build` builds the tree and
writes an executable for each `cmd/<name>/` in it, so a library tree
builds too and a tree with binaries ships from the one verb. every verb
takes paths to narrow it (`uses` after its symbol), except `docs`,
which takes words to search for; `sql`, which takes one statement
and names its database by option, since a statement already says
which rows it reads; `refresh`, which takes the datasets to fetch;
`bom`, which takes nothing; and `help`, which takes a verb. a verb's
exit code is its verdict and its stdout is its result alone; its stderr
says what went wrong, and a run that passed ends there in a summary of
how it went (`test`'s summary is its result, last on stdout). a file
run, `--standalone` and `-e` are programs, not verbs, and print only
what they print and exit with what they return. `cosmic help` prints an
index with a line per verb, `cosmic help <verb>` that verb's full text
and options, and `cosmic help exit` the exit codes and summaries. no
other stock-interpreter flags, no argv[0] personality.
[the command-line guide](guides/command-line.md) runs each of these.

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
bin/zig             POSIX sh: hand off to build/zig.tl, which fetches, verifies, execs the pinned zig
bin/zig.pin         version and per-host sha256; build.zig reads it
bin/vendor          POSIX sh: hand off to build/vendor.tl, which refetches vendor/<name>/
bin/cosmic-bootstrap POSIX sh: fetch, verify, cache the cosmic ci/cosmic-driver.pin names
build.zig           the C build; build.zig.zon names the package
vendor/<name>/      the upstream files the build reads, unedited, with a PIN
patch/<name>/       exact find/replace records, each with a note
core/               C: entry, locator, VFS, store, sqlite, surface, boot
core/syscalls.h     the annotated header cosmic.sys's .d.tl and doc rows derive from
core/process.h      the same for the raw cosmic.internal.process table
core/bridge.lua     the boot bridge: its compile of the seed's files and of the build, by hand
lang/               the Teal checker and compiler: lexer, parser, scopes, types, flow, code generator
cosmic/             the standard library; entry files are public, siblings not
cmd/cosmic/         the binary's main
build/              the importer, checker driver, embed (Teal; private to build/, mains, tests, test/)
doc/                prose
bin/cosmic          the stable way to run the tree's tool, wherever the build directory is
```

the build directory, which build/paths.tl names, is outside the tree:
`$XDG_CACHE_HOME/cosmic/trees/<sha256 of the canonical root>`, or under the
absolute base `COSMIC_BUILD_HOME` names. it holds cosmic.db, carried.db,
build.db, stores/, bin/, core/ and the rebuild lock; nothing falls back to a
checkout's `o/`, which an older tool wrote and the build now ignores.

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
within that directory. [`cosmic/fs.tl`] is `require("cosmic.fs")`,
public. a module too large for one file becomes a directory of the
same name with an `init.tl` as its entry, the ordinary way Lua
already resolves `require("cosmic.fs")` to `cosmic/fs/init.tl`; a
sibling beside it, `cosmic/fs/walk.tl`, compiles as [`cosmic.fs.walk`]
and the checker refuses an import of it from any file outside
`cosmic/fs/`. the same rule applies everywhere in the tree, not only
under `cosmic/`: a nested directory with no `init.tl` has no entry,
so nothing in it is reachable from outside it, while a top-level
directory with none, as `cosmic/` and `build/` are, is a namespace
whose every file is a flat module of its own. `build/` is private
besides: in cosmic's own tree only `build/` itself, the binary under
`cmd/`, a test, and test support under `test/` may import `build.*`,
so the standard library never depends on the tool that builds it.
two more rules hold in every project. a module whose path has an
`internal` directory, `app/internal/store.tl`, may be required only
by modules under `app/`, as in Go (a top-level `internal/` is the
project's own); that rule stands in the closed-directory rule's
place for the module. a module of a closed directory that holds the
line `--- @public` in the doc block that opens it is open to every importer, which
is how [`cosmic.http.server`] and five others are. in cosmic's own
tree a test, and test support (a file of the top-level `test/`
directory), may be required only by a test or test support, since
the tool carries neither, and two places do not fit the directory
rule and are stated exceptions with a `TODO:` each in
[`build/positions.tl`]:
`cosmic/internal/` is internal to the tree root, since the tool and
its tests are the library's implementation too, and `build/` is
private to the tool.
that is the position rule again rather than a list to maintain: it
names places, the binary the tool is and the tests that check it,
never modules, so a new file under `build/` or a new test needs no
entry anywhere. a project tree may hold no `cosmic`-prefixed path at
all unless it is cosmic's own tree, so a project can never place
itself as a false sibling to claim another module's private surface.
entry-point reachability is settled; whether an exported function's own name is
capitalized by convention, `fs.Read` rather than `fs.read`, is a
readability question and not yet decided, and the checker does not
enforce it either way. positional reachability is a compile-time
check over statically written imports; it says nothing about a value
already held by a script that walks a table's fields at runtime,
which is why [`cosmic.sqlite`] and [`cosmic.store`] keep their own
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

[`artifact.split`]: ../build/artifact.tl
[`bin/cosmic-bootstrap`]: ../bin/cosmic-bootstrap
[`bin/cosmic`]: ../bin/cosmic
[`bin/vendor`]: ../bin/vendor
[`bin/zig.pin`]: ../bin/zig.pin
[`bin/zig`]: ../bin/zig
[`build.boot`]: ../build/boot.tl
[`build.derivation`]: ../build/derivation.tl
[`build.identity.compiler_identity`]: ../build/identity.tl
[`build.identity`]: ../build/identity.tl
[`build.importer.analyzer_identity`]: ../build/importer.tl
[`build.importer`]: ../build/importer.tl
[`build.positions`]: ../build/positions.tl
[`build.reboot.own_tool`]: ../build/reboot.tl
[`build.test_worker`]: ../build/test_worker.tl
[`build.work`]: ../build/work.tl
[`build.writer`]: ../build/writer.tl
[`build/bom.tl`]: ../build/bom.tl
[`build/bom/tl.pin`]: ../build/bom/tl.pin
[`build/checker_declarations.tl`]: ../build/checker_declarations.tl
[`build/closure_store.tl`]: ../build/closure_store.tl
[`build/compile_grammar.tl`]: ../build/compile_grammar.tl
[`build/declared_key.tl`]: ../build/declared_key.tl
[`build/dispatched_features_test.tl`]: ../build/dispatched_features_test.tl
[`build/driver.tl`]: ../build/driver.tl
[`build/error_catalog.tl`]: ../build/error_catalog.tl
[`build/identity.tl`]: ../build/identity.tl
[`build/importer.tl`]: ../build/importer.tl
[`build/key_parts.tl`]: ../build/key_parts.tl
[`build/link_index.tl`]: ../build/link_index.tl
[`build/patch.tl`]: ../build/patch.tl
[`build/pipeline.tl`]: ../build/pipeline.tl
[`build/rebuild_lock.tl`]: ../build/rebuild_lock.tl
[`build/refresh.tl`]: ../build/refresh.tl
[`build/removed_fix.tl`]: ../build/removed_fix.tl
[`build/seed.txt`]: ../build/seed.txt
[`build/shared_compiles.tl`]: ../build/shared_compiles.tl
[`build/syntax_contracts.tl`]: ../build/syntax_contracts.tl
[`build/test.tl`]: ../build/test.tl
[`build/test_key.tl`]: ../build/test_key.tl
[`build/test_worker.tl`]: ../build/test_worker.tl
[`build/vendor.tl`]: ../build/vendor.tl
[`build/verb_spec.tl`]: ../build/verb_spec.tl
[`build/zig.tl`]: ../build/zig.tl
[`build/zig_fetch.tl`]: ../build/zig_fetch.tl
[`ci/cosmic-driver.pin`]: ../ci/cosmic-driver.pin
[`ci/cosmic_ci/host_id.tl`]: ../ci/cosmic_ci/host_id.tl
[`ci/cosmic_ci/orchestration.tl`]: ../ci/cosmic_ci/orchestration.tl
[`ci/cosmic_ci/place_tree.tl`]: ../ci/cosmic_ci/place_tree.tl
[`core/bridge.lua`]: ../core/bridge.lua
[`core/http.c`]: ../core/http.c
[`core/unzstd.c`]: ../core/unzstd.c
[`core/mbedtls_cosmic_config.h`]: ../core/mbedtls_cosmic_config.h
[`core/process.h`]: ../core/process.h
[`core/syscalls.c`]: ../core/syscalls.c
[`core/syscalls.h`]: ../core/syscalls.h
[`cosmic.archive`]: ../cosmic/archive.tl
[`cosmic.child`]: ../cosmic/child.tl
[`cosmic.clock`]: ../cosmic/clock.tl
[`cosmic.env`]: ../cosmic/env.tl
[`cosmic.errors`]: ../cosmic/errors.tl
[`cosmic.fs.walk`]: ../cosmic/fs.tl
[`cosmic.fs`]: ../cosmic/fs.tl
[`cosmic.hash`]: ../cosmic/hash.tl
[`cosmic.http`]: ../cosmic/http/init.tl
[`cosmic.internal.errors`]: ../cosmic/internal/errors.d.tl
[`cosmic.internal.hash`]: ../cosmic/internal/hash.d.tl
[`cosmic.internal.process`]: ../core/process.h
[`cosmic.internal.sqlite`]: ../cosmic/internal/sqlite.d.tl
[`cosmic.internal.store`]: ../cosmic/internal/store.d.tl
[`cosmic.internal.testing`]: ../cosmic/internal/testing.d.tl
[`cosmic.proc`]: ../cosmic/proc.tl
[`cosmic.removed`]: ../cosmic/removed.tl
[`cosmic.sqlite`]: ../cosmic/sqlite.tl
[`cosmic.store`]: ../cosmic/store.tl
[`cosmic.sys`]: ../core/syscalls.h
[`cosmic.time`]: ../cosmic/time.tl
[`cosmic.web`]: ../cosmic/web/init.tl
[`cosmic/fs.tl`]: ../cosmic/fs.tl
[`cosmic/fs_example.tl`]: ../cosmic/fs_example.tl
[`doc/testing.md`]: testing.md
[`lang/ast.tl`]: ../lang/ast.tl
[`lang/check.tl`]: ../lang/check.tl
[`lang/check_codes.tl`]: ../lang/check_codes.tl
[`lang/codegen.tl`]: ../lang/codegen.tl
[`lang/declarations.tl`]: ../lang/declarations.tl
[`lang/fact_wraps.tl`]: ../lang/fact_wraps.tl
[`lang/flow.tl`]: ../lang/flow.tl
[`lang/generics.tl`]: ../lang/generics.tl
[`lang/lexer.tl`]: ../lang/lexer.tl
[`lang/parser.tl`]: ../lang/parser.tl
[`lang/relation.tl`]: ../lang/relation.tl
[`lang/scopes.tl`]: ../lang/scopes.tl
[`lang/truthy.tl`]: ../lang/truthy.tl
[`lang/types.tl`]: ../lang/types.tl
[`lang/warnings.tl`]: ../lang/warnings.tl
[`lang/prelude.d.tl`]: ../lang/prelude.d.tl
[`lang/stdlib.d.tl`]: ../lang/stdlib.d.tl
[`Proc.exit`]: ../cosmic/proc.tl
[`schema.tables_digest`]: ../build/schema.tl
[`Server.serve`]: ../cosmic/http/server.tl
[`Spec.tree`]: ../build/declared_key.tl
[`Store.bytecode`]: ../cosmic/store.tl
[`Store.databases()`]: ../cosmic/store.tl
[`Store.meta`]: ../cosmic/store.tl
[`Store.requires`]: ../cosmic/store.tl
[`Store.source`]: ../cosmic/store.tl
[`Store.web_asset`]: ../cosmic/store.tl
[`Test.policy`]: ../cosmic/test.tl

[`build.pipeline`]: ../build/pipeline.tl
[`build/positions.tl`]: ../build/positions.tl
[`cosmic.http.server`]: ../cosmic/http/server.tl
[`cosmic.internal.globals`]: ../cosmic/internal/globals.d.tl
[`cosmic.shape`]: ../cosmic/shape.tl
[`cosmic.web.static`]: ../cosmic/web/static.tl
[`doc/guides/project.md`]: guides/project.md
