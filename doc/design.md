# cosmic, rewritten

a sketch. nothing here is settled until it is answered under
"open questions" at the end; everything above that line is the current
best guess, written to be argued with.

## thesis

keep the promises, drop the magic.

cosmic's promises stand: **no silent bugs**, **efficiency** (a builder
with only the binary does real work with less friction than Python,
Node, or Go), **self-sufficiency** (one file: runtime, compiler,
checker, formatter, test runner, docs, offline). the payoff is still
the best tool-building tool: `--embed`-built executables that are
correct, contained, fast.

what changes is the ground it stands on. Cosmopolitan delivered six
OSes and two architectures from one file, a filesystem inside the
executable, a portable `unix.*` layer, TLS, and OS sandboxes, all for
free. the bill came as accidental complexity that leaked into every
layer above it. the rewrite pays for portability and embedding
explicitly, in parts we can read, instead of inheriting them from a
runtime we cannot.

## what we learned

the first cosmic taught two kinds of lesson: things worth keeping
whatever the stack, and things that existed only because of the stack.

### keep

- **position is the manifest.** `*_test.tl` is a test, `cmd/<name>/`
  is a binary, a leading `_` is internal, the root is the module root.
  no list to maintain, none to go stale.
- **honest returns.** `T | nil, string` for a value, `boolean, string`
  for an effect, two slots and nothing in a third, a structured error
  record when the failure has shape. every throw or exit carries a
  trailing reason.
- **tests run because they are defined.** `local function test_*` is
  the enrolment.
- **gates end in a verdict line** and an exit code, never laundered
  through a pipe.
- **carried patches over forks.** a pinned upstream plus exact
  `find`/`replace` edits applied at fetch, each with a `note`, each
  failing loudly the day its anchor moves. 55 tl patch entries in 10
  files exist today; they are the type layer's real value and come
  along.
- **agents as the instrument.** a fresh agent with only the binary,
  journaling friction, is the cheapest honest measure of "good for
  the builder". the finding that held across rounds: an error-site
  hint beats a gotcha doc beats guide prose.
- **the surface gitboard actually leans on.** of roughly 500 call
  sites in the work board, `check` + `fs` + `child` are 367; `env`,
  `hash`, `sqlite`, `json` carry the rest. that is the core tier.

### drop, because Cosmopolitan made us

- **the APE trust root.** a POSIX sh script fetching one sha256-pinned
  fat binary, assimilation to a native ELF before a fenced child can
  exec it, a duplicate on-disk copy or a loader prefix. a static musl
  ELF needs none of it.
- **the two-generation convergence build.** a gate builds the tree,
  re-execs into what it built, caps at two generations, and fails
  `not a fixpoint` on a third. it exists because cosmic builds cosmic
  with cosmic through a pinned release; drop self-hosting through a
  pin and it goes.
- **the type bootstrap paradox.** `cosmo.*` declarations generated
  from the release binary that also builds the tree, so a C contract
  change could not cold-build until a release carried it. with one
  repo the C bindings and their declarations are siblings in the same
  commit.
- **zip as module root.** `/zip/cosmic/fs.lua`, dot-prefixed payload
  trees to stay out of the namespace, a bespoke searcher, `is_main`
  by zip-path comparison, and the "which compiler built the binary
  moves the coverage numbers" class of bug.
- **GNU make as the graph with cosmic as `SHELL`.** a forked
  landlock-make embedded forever (D14), a closed recipe-verb
  vocabulary, sandbox grants derived from recipe lines. essential
  once; accidental now.
- **cross-OS emulation leaking into the contract.** emulated fork and
  signals on Windows, termios over the console API, `rusage_children`
  as ENOSYS, syslog silently a no-op. D4 already conceded these were
  trusted, never verified.
- **pledge/unveil.** OpenBSD's model reached through cosmo. Landlock
  and seccomp are plain Linux syscalls and stay.

### carry forward, redesigned

- **sandboxing.** the one door stays (one call, fail-closed, reports
  full/degraded/skipped per section as D40 learned the hard way).
  Linux-only enforcement is honest about being Linux-only.
- **the `unix.*` layer.** the single largest thing Cosmopolitan gave
  us and the single largest thing to rebuild: a thin C binding over
  musl for the syscalls the stdlib actually uses, with the same
  fallible tuple discipline at the C boundary that the cosmopolitan
  fork settled (argument-shape errors raise, runtime failures return
  `nil, err, errno`).
- **TLS and HTTP.** `Fetch` rode mbedtls inside cosmo. an HTTP client
  and server need a TLS stack we vendor and a parser we own or vendor.
  open question below.

## the stack

```
kernel (Linux; macOS on libSystem)
  musl, static                         the C stdlib on Linux; libSystem on macOS
    lua 5.5 core                       vendored pristine
    sqlite3 amalgamation               vendored pristine
    small C libs                       argon2, a regex engine, zlib/miniz,
                                       a TLS stack (open), a JSON codec
    cosmic C bindings                  one tree of *.c: unix, sqlite,
                                       hash, re, zip, json, http
  cosmic binary
    modules in a sqlite database       the store IS the filesystem-that-was
    teal compiler + checker            pinned tl, carried patches
    cosmic.* stdlib in teal            typed wrappers, honest returns
    docs index, test records,          all rows in the same database
    coverage, code cache
```

one repo holds all of it: vendored sources under one tree, never
edited in place; a patch tree beside it, applied by the build; the C
binding layer; the Teal stdlib; the tooling. a `cosmo.*` contract
change and its type declaration land in one commit.

### the line between C and Teal

size yields to two things: **identical behavior on every target** and
**performance**. within that, the core is a syscall table plus a few
vendored libraries, and anything with a policy in it is Teal, stored
once in the database and shared by every target.

native, per target: the Lua VM; SQLite; one TLS library that also
serves hashing and HMAC; deflate; argon2; a vendored regex engine;
the syscall table; the database-at-offset VFS and the entry. the
syscall table is one C function per syscall with the same signature
on Linux and macOS, generated with its Teal declaration and its doc
row from one declaration file, so a binding cannot exist without its
type and the C surface cannot grow without a diff in that file.

never borrowed from the libc where semantics are observable: regex,
DNS resolution, anything locale-shaped. musl and libSystem agree on
`open`; they do not agree on `regcomp`'s corners or `getaddrinfo`'s
ordering, and a difference a test on one OS cannot see is the class
of bug the rewrite exists to remove.

Teal by default: filesystem policy (walk, find, atomic write), child
processes above spawn and wait, sandbox policy over raw enforcement
syscalls, URL, SSE, tar, the zip directory, the whole build including
the Mach-O section writer and ad-hoc signer. C when a benchmark on a
real scenario says the Teal is too slow and a fuzzed, vendorable C
implementation exists: JSON both directions and HTTP/1.1 framing
start in C on that rule. the benchmark harness, not taste, moves a
module across the line in either direction.

the compiled payload is shared: all four targets are little-endian
64-bit, so one bytecode column serves them all, verified by a test
that each image loads it. the core image column is the only
per-target data in the database.
### sqlite as the store

today derived state is file-per-record under `o/` and inside the zip:
`o/<path>.test.got` verdicts, a parallel `o/.coverage/` tree, a
Lua-literal doc index, a content-hashed compile cache, generated
`.d.tl` declarations, `o/project.mk` import closures. every one is
keyed data pretending to be a filesystem. in the rewrite one database
holds:

- **modules**: import path, source hash, Teal source, compiled Lua,
  declaration, kind (module, test, example, benchmark, binary entry).
  `require` is a searcher that runs one query.
- **docs**: extracted per symbol, queried by `--docs`.
- **records**: test verdicts and coverage keyed by source hash, so a
  change re-records and an unchanged file does not.
- **payload**: for an `--embed`-built executable, the user's files.

the binary carries its database the way it carried its zip: appended
to the executable, opened read-only through a VFS over the file at an
offset. the build database on disk (`o/cosmic.db`) and the shipped one
are the same schema; shipping is a `VACUUM INTO`.

what this buys: one open at startup instead of a zip directory walk,
a query instead of a searcher chain, records that are joins instead of
parallel trees, and a module namespace with no dot-prefix tricks.

what it costs: sqlite becomes load-bearing at boot, so its footguns
(silent NULL on a typo'd param, TEXT/BLOB indistinguishable at the
Lua boundary, throw-after-close) move from the stdlib's problem to
the runtime's, and get fixed first.

### teal for types

tl pinned, carried patches, the same upstream-first-fork-if-blocked
stance. the cast ledger and the thirty open `casts:` items say the
escape hatch is the multi-year cost of the first cosmic; the rewrite
decides up front whether `any` and `as` are structurally foreclosed or
merely policed (open question).

### the build

no make, no `SHELL := cosmic`, no convergence. the build is a cosmic
program reading the tree by position into the database: compile,
check, record, embed. it runs under the previous release binary or a
bootstrap C build of the core, and there is no fixpoint to prove
because the tool that runs the gate is not the artifact under gate.

### the surface, tiered

- **core** (what the work board needs today): `check`, `fs`, `child`,
  `env`, `proc`, `hash`, `sqlite`, `json`, `time`, `rand`, `flags`,
  `string`, `errno`, `errors`, `log`, `teal`, `format`, `test`,
  `coverage`, `doc`, `embed`.
- **second**: `http`, `fetch`, `net`, `re`, `zip`, `tar`, `compress`,
  `codec`, `url`, `ip`, `uuid`, `ksuid`, `sse`, `sandbox`, `signal`,
  `poll`, `fd`, `tty`, `ansi`, `user`, `sys`, `stream`, `shape`,
  `deep`, `graph`, `fuzzy`, `literal`, `ast`.
- **defer or drop**: `quicksand` (namespaces, egress proxy), `shm`,
  `template`, `instrument`, `html`/`css`/`js` escaping.

the first cosmic is ~124k lines of Teal across `cosmic/` (70k public),
`_cli/`, `_make/`, `_build/`, `_tool/`, `_types/`, with 293 test
files. the tier list is a reading order for what to port, not a size
target; G9 says the least tree that keeps its promises.

## open questions

answered one at a time; each answer becomes a line here and, when it
carries a tradeoff, a decision record later.

1. **platform scope: Linux and macOS, no Windows.** Linux is
   x86_64 and aarch64 on static musl. macOS is aarch64 and x86_64 on
   libSystem, which cannot be linked statically but is always present,
   so the one-file property holds. Windows is dropped, and with it
   every emulated fork, signal, and console quirk. two costs macOS
   carries regardless of toolchain: embedding is format-aware (an ELF
   takes appended bytes; a Mach-O needs a section added and an ad-hoc
   re-sign, or arm64 macOS kills it), and enforcement is honest, not
   equal (Landlock and seccomp are Linux; macOS reports `skipped` or
   uses sandbox_init). the C layer is written to POSIX plus a declared
   platform seam: no signalfd, inotify, epoll, or procfs outside
   modules guarded as Linux-only.
2. **host language C, zig as the toolchain only.** the binary is a C
   program; Lua, SQLite, and the small libraries are the C they ship
   as. one pinned zig replaces cc, make, and the macOS runner on the
   build path: `zig cc` cross-compiles all four targets from a Linux
   lane and `build.zig` compiles the vendored C. zig's churn touches
   build flags, not code, and the fallback is native toolchains on
   the same source (Linux clang against in-tree musl, Apple clang on a
   macOS runner) if its bundled musl or a release ever bites. Rust as
   the host was weighed and deferred: memory-safe glue and rustls
   against cargo, a crate tree in the hundreds, minute-long builds,
   unverified Lua 5.5 support in mlua, and no macOS cross-build
   without zig anyway. zig as the language was set aside for being
   pre-1.0 and the option agents know least. **revisit both after the
   first revision of this design.**
3. **the database is the only module source, always.** `require`
   reads the database and nothing else; a `.tl` on disk is input to
   the build, never to the runtime. the price is that every edit
   needs the build, so the build must be **fast, incremental, and
   fully reproducible**, all three at once:
   - *incremental*: a module row is keyed by the content hash of its
     source plus the hashes of its import closure; an unchanged key
     is a stat, a changed one recompiles and re-records only what
     depended on it. tests, coverage, and docs share the keys.
   - *fast*: the importer is one process, one transaction, no
     subprocess per file; the checker and compiler run in-process
     against declarations already in the database.
   - *reproducible*: the database bytes are a pure function of the
     tree. that is not automatic in SQLite: rows are written in a
     fixed order (path, then kind), no row carries a timestamp or an
     autoincrement counter, and the shipped file is produced by
     `VACUUM INTO` so freelist and page order never depend on the
     history of the build directory. a second build of the same tree
     is byte-identical, and CI's repro lane asserts it.
4. **every cosmic binary carries all four core images**, so any host
   builds any target offline with nothing fetched. the principle
   behind it, stated once and applied everywhere: **size yields to
   consistent behavior across targets and to performance.** a bigger
   binary is a cost paid once per download; a behavior that differs
   by OS, or a hot path left slow to save bytes, is paid on every
   run. the per-release size report still carries a per-component
   line for the core, so growth is named, never silent.
