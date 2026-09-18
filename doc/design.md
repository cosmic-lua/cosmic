# cosmic, rewritten

revision 1. the sketch and the first thirteen questions, folded into
one document. everything here is settled unless the last section
lists it for revisiting; changing a settled point is an amendment to
this document, not a remark in passing.

## thesis

keep the promises, drop the magic.

cosmic's promises stand: **no silent bugs**, **efficiency** (a builder
with only the binary does real work with less friction than Python,
Node, or Go), **self-sufficiency** (one file: runtime, compiler,
checker, formatter, test runner, docs, offline). the payoff is still
the best tool-building tool: `cosmic embed`-built executables that
are correct, contained, fast.

what changes is the ground it stands on. Cosmopolitan delivered six
OSes and two architectures from one file, a filesystem inside the
executable, a portable `unix.*` layer, TLS, and OS sandboxes, all for
free. the bill came as accidental complexity that leaked into every
layer above it. the rewrite pays for portability and embedding
explicitly, in parts we can read, instead of inheriting them from a
runtime we cannot.

## principles

stated once, applied everywhere. a proposal that violates one of
these argues with the principle, not with the reviewer.

1. **size yields to consistent behavior across targets and to
   performance.** a bigger binary is paid once per download; a
   behavior that differs by OS, or a hot path left slow to save
   bytes, is paid on every run. growth is still named in the size
   report, never silent.
2. **position is the manifest.** `*_test.tl` is a test, `cmd/<name>/`
   is a binary, a leading `_` is internal, the root is the module
   root. no list to maintain, none to go stale.
3. **honest returns.** `T | nil, string` for a value, `boolean,
   string` for an effect, two slots and nothing in a third, a
   structured error record when the failure has shape. a throw or
   exit carries a trailing reason and is exceptional by construction.
4. **no escape hatch in the type layer.** the checker forecloses
   casts from the first line; `any` lives only where untrusted data
   enters and a shape validator turns it into a record.
5. **the least tree that keeps its promises.** a module exists when
   the tier order pulls it and it earns its place. surface parity
   with the first cosmic is not a goal.
6. **`skipped` is reported, never silent.** enforcement is a property
   of the host, even on Linux. anything that can be half-enforced
   reports per section.
7. **no network in a build; one external tool.** every input is in
   the repository. the one thing a fresh clone needs is the pinned
   zig.
8. **docs are always right**: a disagreement between doc and code is
   fixed in the code, and every snippet runs or says why not.
   **tests run because they are defined, gates end in a verdict line,**
   and an error-site hint beats a gotcha doc beats guide prose.

## what we learned

### keep

- the conventions above: position as manifest, honest returns,
  tests by definition, verdict lines.
- **carried patches over forks.** a pinned upstream plus exact
  `find`/`replace` edits, each with a `note`, each failing loudly the
  day its anchor moves. the 55 tl patch entries are the type layer's
  real value and their rules come along.
- **agents as the instrument.** a fresh agent with only the binary,
  journaling friction, is the cheapest honest measure of "good for
  the builder".
- **the surface the work board actually leans on.** of roughly 500
  stdlib call sites in gitboard, `check` + `fs` + `child` are 367;
  `env`, `hash`, `sqlite`, `json` carry the rest. that is the core
  tier.
- **the sandbox's per-section report.** full, degraded, skipped, per
  section, refusing when nothing enforced. learned from a Landlock
  ABI that silently stripped rights.

### drop, because Cosmopolitan made us

- **the APE trust root**: a shell script fetching one sha256-pinned
  fat binary, assimilation before a fenced child can exec it, a
  duplicate on-disk copy or a loader prefix.
- **the two-generation convergence build**: cosmic building cosmic
  with cosmic through a pinned release, capped at two generations,
  `not a fixpoint` on a third.
- **the type bootstrap paradox**: `cosmo.*` declarations generated
  from the release binary that also built the tree.
- **zip as module root**: `/zip/cosmic/fs.lua`, dot-prefixed payload
  trees, a bespoke searcher chain, `is_main` by zip-path comparison,
  coverage numbers that moved with the compiler that built the zip.
- **GNU make as the graph with cosmic as `SHELL`**, a forked
  landlock-make embedded forever.
- **Windows, and every emulated fork, signal, and console quirk.**
- **pledge and unveil**, OpenBSD's model reached through cosmo.

### redesign

- **the `unix.*` layer**: the largest thing Cosmopolitan gave and the
  largest thing to rebuild, now a generated syscall table.
- **sandboxing**: one door, an equivalent core on both OSes.
- **TLS and HTTP**: a vendored library and a Teal client and server.

## the stack

```
kernel                               Linux; macOS
  libc                               musl, static, vendored (Linux)
                                     libSystem (macOS)
    lua 5.5                          vendored pristine
    sqlite3                          vendored pristine
    mbedtls 3, deflate, argon2,      vendored pristine
    a regex engine
    syscall table                    generated C, one per syscall
  cosmic binary
    modules in a sqlite database     the only module source
    teal compiler + checker          vendored tl, carried patches
    cosmic.* stdlib in teal          typed wrappers, honest returns
    docs, records, coverage,         rows in the same database
    the other targets' core images
```

### targets and toolchain

Linux on x86_64 and aarch64, static musl. macOS on aarch64 and
x86_64, libSystem, which cannot be linked statically but is always
present, so the one-file property holds. no Windows; a static musl
binary under WSL2 is the Windows story.

the host language is C: Lua, SQLite, and the small libraries are the
C they ship as. one pinned zig replaces cc, make, and the macOS
runner on the build path: `zig cc` cross-compiles all four targets
from a Linux lane and `build.zig` compiles the vendored C. zig's
churn touches build flags, not code. the fallback is native
toolchains on the same source, Linux clang against in-tree musl and
Apple clang on a macOS runner.

the C layer is POSIX plus a declared platform seam: no signalfd,
inotify, epoll, or procfs outside modules guarded as Linux-only.

### the line between C and Teal

the core is a syscall table plus a few vendored libraries; anything
with a policy in it is Teal, stored once in the database and shared
by every target.

native, per target: the Lua VM; SQLite; mbedtls, which also serves
hashing and HMAC; deflate; argon2; a regex engine; the syscall table;
the database-at-offset VFS and the entry. the syscall table is one C
function per syscall with the same signature on Linux and macOS,
generated with its Teal declaration and its doc row from one
declaration file, so a binding cannot exist without its type and the
C surface cannot grow without a diff in that file. argument-shape
errors raise; runtime failures return `nil, err, errno`.

never borrowed from the libc where semantics are observable: regex,
DNS resolution, anything locale-shaped. musl and libSystem agree on
`open`; they do not agree on `regcomp`'s corners or `getaddrinfo`'s
ordering. the regex candidate is musl's own TRE-derived engine,
compiled as a library on both OSes, since it is already in the
vendored tree. DNS is a resolver in Teal over UDP and TCP, reading
`/etc/resolv.conf` and `/etc/hosts`, which both OSes have; this also
keeps Mach services out of the macOS sandbox profile.

Teal by default: filesystem policy (walk, find, atomic write), child
processes above spawn and wait, sandbox policy over raw enforcement
syscalls, URL, SSE, tar, the zip directory, the whole build including
the Mach-O section writer and ad-hoc signer. C when a benchmark on a
real scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists: JSON both directions and HTTP/1.1 framing
start in C on that rule. the benchmark harness, not taste, moves a
module across the line in either direction.

### sqlite as the store

`require` reads the database and nothing else; a `.tl` on disk is
input to the build, never to the runtime. one database holds:

- **modules**: import path, source hash, Teal source, compiled Lua
  and bytecode, declaration, kind (module, test, example, benchmark,
  binary entry).
- **docs**: extracted per symbol, queried by `cosmic docs`.
- **records**: test verdicts and coverage keyed by source hash.
- **payload**: for an embed-built executable, the user's files.
- **images**: the core executable for every target, so any host
  builds any target offline with nothing fetched.
- **roots**: Mozilla's CA bundle.

all four targets are little-endian 64-bit, so one bytecode column
serves them all, verified by a test that each image loads it. the
core image column is the only per-target data.

the binary carries its database the way it carried its zip: on ELF,
appended and opened read-only through a VFS over the file at an
offset; on Mach-O, added as a section and ad-hoc re-signed, because
arm64 macOS kills a binary with trailing data. the build database on
disk, `o/cosmic.db`, and the shipped one share a schema; shipping is
a `VACUUM INTO`.

sqlite is load-bearing at boot, so its footguns are the runtime's
problem and get fixed first: a typo'd or overlong parameter table
never binds NULL silently, TEXT and BLOB are distinguishable at the
Lua boundary, and a closed handle fails the same way from every
method.

### the build

no make, no `SHELL := cosmic`, no convergence. the build is a cosmic
program reading the tree by position into the database: compile,
check, record, embed. the tool that runs the gate is not the artifact
under gate, so there is no fixpoint to prove.

the bootstrap chain, from a fresh clone with zig on the path: zig
builds the patch applier; the applier writes patched copies of the
vendored sources to `o/vendor/`; zig builds the core for the host;
the core runs the vendored `tl.lua` to compile the importer; the
importer compiles the tree into `o/cosmic.db`; the build attaches the
database to each target's image.

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
  or an autoincrement counter, and the shipped file is produced by
  `VACUUM INTO` so freelist and page order never depend on the build
  directory's history. a second build of the same tree is
  byte-identical, and CI's repro lane asserts it.

`cosmic build` and `cosmic test` fence themselves with the sandbox
core, so a build cannot read outside its tree and a test cannot reach
the network by accident. CI's profile requires the fence; a laptop
reports it.

### teal for types

tl vendored, carried patches, upstream-first and fork-if-blocked.
casts are foreclosed from the first line: `x as T` type-checks only
from `any`, from a userdata record declared in a `.d.tl`, or from the
enclosing generic's type variable. `any` is legal only where
untrusted data enters and a shape validator turns it into a record by
construction. no justification comments, no ledger.

the spirit is consistent, strong, explicit typing, checked against
the languages that hold it: the top type inert until narrowed (Go,
Luau's `unknown`, TypeScript's late `unknown`), casts confined to
subtype moves or runtime-checked (Luau, Kotlin), the escape hatch in
one greppable region (Rust's and Go's `unsafe`), boundaries decoded
through declared shapes (serde, `json.Unmarshal`, Elm's decoders).
Kotlin's runtime-checked cast is closed to Teal because Lua erases
record types, so shapes construct their records rather than asserting
them.

two tightenings follow, each to verify against tl's semantics and to
carry as a patch if needed: `any` narrows only through `is`, a shape,
or an explicit `as`, never by assignment into a typed slot; and an
unannotated parameter or return is an error, never an implicit `any`.
the per-release report names the modules that cast from `any`; the
expected list is the shape module, the codec decoders, and the C
declaration layer.

### the runtime

one Lua state, one thread, coroutines over `poll`. every blocking
binding takes a timeout and can be driven from one event loop, which
is Teal over the `poll` binding; `http.serve` and `fetch` are
coroutine-driven; CPU parallelism is by process through `child`.

the C layer is re-entrant from day one, which costs discipline, not
code: no static buffers, no process-global state outside the entry,
every binding takes its context explicitly, SQLite opened per
connection and never shared across a boundary that could later be a
thread. one state per OS thread with message passing stays open as a
later addition that rewrites no bindings.

### tls

mbedtls 3.x: TLS 1.2 and 1.3, one configuration, hashes and HMAC
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

one repository, this branch, becoming `main` at the cutover below.

```
vendor/<name>/      pristine upstream, never edited, with a PIN file
patches/<name>/     exact find/replace records, each with a note
core/               C: entry, VFS, the generated syscall table, build.zig
core/syscalls.decl  the one declaration file: C stub, .d.tl, doc row
cosmic/             the public API: cosmic.<name>, no leading _
cmd/cosmic/         the binary's entry
_build/             the importer, checker driver, embed (Teal, internal)
doc/                prose
o/                  output; o/cosmic.db; never committed
```

a ~200-line C applier that zig builds first applies the patch records
into `o/vendor/<name>`; a record whose anchor no longer matches fails
the build by name. repo size is a one-time clone cost, the cheap
kind under principle 1.

### the surface

the Teal layer is rewritten from scratch. the first cosmic's docs,
tests, and examples are read for the behavior they verified and the
traps they caught, and nothing is copied. the internal trees have no
successor by port.

the tier order is a reading order for what to write, not a size
target:

- **core** (what the work board needs today): `check`, `fs`,
  `child`, `env`, `proc`, `hash`, `sqlite`, `json`, `time`, `rand`,
  `flags`, `string`, `errno`, `errors`, `log`, `teal`, `format`,
  `test`, `coverage`, `doc`, `embed`, `shape`.
- **second**: `http`, `fetch`, `net`, `dns`, `re`, `zip`, `tar`,
  `compress`, `codec`, `url`, `ip`, `uuid`, `ksuid`, `sse`,
  `sandbox`, `signal`, `poll`, `fd`, `tty`, `ansi`, `user`, `sys`,
  `stream`, `deep`, `graph`, `fuzzy`, `literal`, `ast`.
- **defer or drop**: namespaces and egress proxying beyond what the
  sandbox core needs, `shm`, `template`, `instrument`, `html`, `css`,
  `js`.

## sequencing

1. **hello from the database.** zig builds the applier, patches,
   builds the core; the core runs `tl.lua` to compile the importer;
   the importer writes `o/cosmic.db` with one module; the build
   attaches it; `cosmic hello.tl` runs on all four targets from
   byte-identical databases. proves boot, store, `require`, embed on
   ELF and Mach-O, cross-build, reproducibility. review.
2. **self-check.** `cosmic check` and `cosmic test` gate the
   rewrite's own tree, incrementally, under the foreclosed-cast
   checker, with records in the database. proves the type layer, the
   build's incrementality, and that the tree can gate itself. review.
3. **the core tier**, then the second, each module earning its place.
4. **cutover**, when three things hold: the new binary builds and
   tests gitboard from its own tree; the agent-eval suite scores at
   or above the last recorded round on the old binary; the release
   job produces all four targets and the repro lane proves them
   byte-identical. then old `main` is renamed `v1` and this branch is
   renamed `main`. issues, the board, org access, and history stay in
   one place throughout.

## to revisit

- **host language and toolchain**, after this revision: Rust as the
  host was weighed and deferred (memory-safe glue and rustls against
  cargo, a crate tree in the hundreds, minute-long builds, unverified
  Lua 5.5 support in mlua, and no macOS cross-build without zig
  anyway); zig as the language was set aside for being pre-1.0 and
  the option agents know least.
- **tl's `any` semantics** and implicit `any`: verify before
  milestone 2, patch if needed.
- **the core budget**: measure the per-target image after milestone
  1 and set the per-component line the size report carries; decide
  FTS5 on that number.
- **the regex engine**: confirm musl's TRE builds standalone on
  macOS, else pick one vendored engine for both.

## decisions, in the order they were made

1. Linux and macOS, no Windows.
2. C as host language; zig as toolchain only.
3. the database is the only module source; the build is fast,
   incremental, reproducible.
4. every binary carries all four core images; size yields to
   consistency and performance.
5. casts foreclosed from the first line; `any` only at shape
   boundaries.
6. one state, coroutines over `poll`, re-entrant C.
7. pristine sources committed; patches as exact records applied at
   build time.
8. the Teal layer rewritten from scratch; the old tree is reference.
9. mbedtls 3.x with a bundled root store.
10. this branch becomes `main` at a named cutover.
11. a verb CLI.
12. an equivalent sandbox core on both OSes with a conformance suite;
    no default-deny for scripts.
13. milestones: hello from the database, then self-check.
