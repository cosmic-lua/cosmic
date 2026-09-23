# roadmap

what comes after the current state in [design.md](design.md): what
is decided but not yet built, and the questions still open.
design.md says what cosmic is today; this says what is next, and
anything here moves to design.md when it lands.

## self-check

`cosmic check` and `cosmic test` gate cosmic's own tree,
incrementally, under the foreclosed-cast checker, with records in a
database of their own. tests, the in-process runner, doctests,
coverage, and a real Teal AST (`build.ast`: parse, walk, structural
match, rewrite) have landed; what follows leans on `build.ast`,
still build-internal today, and on `o/records.db`.

- **`cosmic check`**: the foreclosed-cast checker gate over a
  project, which needs the binary's own declarations reachable on
  disk or in a form the checker can read. today even `cosmic
  file.tl` outside cosmic's own tree cannot `require("cosmic.fs")`:
  the checker looks for `cosmic.*` declarations under that tree's
  own `o/types/`, and only cosmic's own build writes them there.
- **the rewrite rules `cosmic fix` applies.** the verb has landed, and
  with it the renderer that writes a parsed tree back out as source; its
  rule list is empty, because the rules worth writing are lint fixes and
  the lint waits on the narrowing patches below. adding one is the whole
  cost of a new fix: no part of the pipeline moves around it.
- **the case lint**, the rest of what "checking" means beside the
  sibling-privacy rule that has landed: no two names in a directory
  may differ only in case, because macOS's default filesystem cannot
  tell them apart, and a case-only rename is a two-step commit there.
- **the remaining tl narrowing patches**, record-field narrowing and
  container covariance, so cast-foreclosure holds against real code,
  not only a trivial one-file script.

**C testing and coverage.** no C-level unit test framework exists
yet, and C coverage is researched but not built: source-based LLVM
instrumentation on `core/*.c` only (`-fprofile-instr-generate
-fcoverage-mapping`), a vendored `compiler-rt` profile runtime per
target since zig ships the instrumentation but no runtime to act on
it, `llvm-profdata` and `llvm-cov` pinned to zig's bundled LLVM
version and re-verified on every bump, `llvm-cov export` as one
JSON. the requirement: the same facilities and the same ergonomics
as Lua and Teal testing, not a separate system beside it, one
discovery convention, one verb that runs both, coverage reported the
same way for either.

**alongside, not gating the above:**

- **child-process spawning**, `cosmic.child` over `posix_spawn`.
  serves two things at once once it lands: the isolation layer the
  test runner still lacks, and the re-exec the stale-tool refusal
  needs.
- **the provenance gate**: no bytes from outside the tree and the
  pinned zig reach an output, checked by building on two hosts and
  comparing hashes.
- **`O_CLOEXEC` on the remaining `fopen` paths** in boot and the
  patch applier; the syscall table's own `open` already sets it.
- **a fuzzer over the executable locator**, now that it parses
  untrusted bytes at every startup.

## decided, not built

### the build

- **`cosmic build`**, the verb a developer runs the hundred times a
  day between boots. on a stale tool it runs `boot` and re-execs
  into the result, once, and refuses a second round by name, rather
  than only refusing as every run does today.
- **tests in a child process each**, for a fresh temp directory, a
  deadline, and captured streams; a child never opens a database, it
  reports its result over a pipe and the one build process writes
  it. a hang or a crash in one test no longer takes down the run.
- **observed reads in the record key**: a test's row is also keyed
  by the set of files it was observed to read, which the runner
  already records, so a changed input re-runs exactly the tests that
  read it.
- **declarations in the database**: compile and check run in one
  process, one transaction, against declarations already in the
  database.
- **a second repro lane** that builds from a second transaction
  layout and on a second host, not only at a second path.
- **the fence**: `cosmic build` and `cosmic test` confine themselves
  with the sandbox core, so a build cannot read outside its tree and
  a test cannot reach the network by accident. CI's profile requires
  the fence; a laptop reports it.

### the toolchain

- **the sanitized core runs the suite and the fuzzers**, not only
  the boot, on every push.
- **an address-sanitized lane.** zig ships no address sanitizer
  runtime for any target; a job on a real clang, outside the pinned
  toolchain and with that caveat stated, is a later addition.
- **a `cosmic-debug` asset**, the sanitized build published beside
  the release, once the fuzzers exist; being unstripped, it takes
  prefix-map flags to keep the build path out of its bytes.

### the C core

- **mbedtls**, which also serves hashing and HMAC; **argon2's
  reference implementation**, built without threads; and **a regex
  engine**, all vendored. three carried cores plus mbedtls is on the
  order of 6 MB per shipped binary before any Teal, and the size
  report carries that per component.
- **one trace point at the syscall table's dispatch**, giving a
  syscall log for every call uniformly when asked.
- **a doc row per syscall**, generated from `core/syscalls.h` beside
  the Teal declaration.
- **`posix` modules.** `posix` is a reserved name of a different kind
  than `internal`: not privacy, but scope. a module lives under
  `cosmic.posix.` when its whole job is exposing a POSIX standard's
  own vocabulary directly, names and numeric codes, rather than
  presenting cosmic's own abstraction over it. `posix.errno` and
  `posix.signal` are the first two; a module that instead builds an
  abstraction on top of a standard call, `fs` over `open`, `poll`
  over `poll(2)`, stays where it is.
- **never borrowed from the libc where semantics are observable**:
  regex, DNS resolution, anything locale-shaped. musl and libSystem
  agree on `open`; they do not agree on `regcomp`'s corners or
  `getaddrinfo`'s ordering. the regex engine is a standalone
  extraction of musl's TRE-derived one, about 4,300 lines, compiled
  the same on both OSes. DNS is a resolver in Teal over UDP and TCP,
  reading `/etc/resolv.conf` and `/etc/hosts`, which both OSes have;
  this also keeps Mach services out of the macOS sandbox profile.
- **Teal for the rest of the policy**: child processes above spawn
  and wait, sandbox policy over raw enforcement syscalls, URL, SSE,
  tar, the zip directory, JSON. HTTP/1.1 framing starts in C, since
  a fuzzed implementation exists; JSON starts in Teal and is measured
  against a C implementation on the harness when its tier lands, and
  the numbers pick.

### the database

- **docs**: extracted per symbol, queried by `cosmic docs`, from a
  module named `cosmic.doc`.
- **payload**: for an embed-built executable, the user's files.
- **roots**: Mozilla's CA bundle.

### teal

casts are foreclosed: `x as T` type-checks only from `any`, from a
userdata record declared in a `.d.tl`, or from the enclosing
generic's type variable. `any` is legal only where untrusted data
enters and a shape validator turns it into a record by construction.
no justification comments, no ledger. the rule is switched on from
the first line it can be, which is only once the narrowing gaps that
force casts, record-field narrowing and container covariance chiefly,
land as carried patches; `cosmic check` and the lint rules `cosmic
fix` applies both gate on them.

the spirit is consistent, strong, explicit typing, the same shape the
languages that hold it converged on: the top type inert until
narrowed, casts confined to subtype moves or runtime-checked, the
escape hatch in one greppable region, boundaries decoded through
declared shapes. a runtime-checked cast is closed to Teal because
Lua erases record types, so shapes construct their records rather
than asserting them.

three rules follow. `any` never assigns into a typed slot; tl
already refuses that on assignment, argument, return, index, and
call. an unannotated parameter is an error, never an implicit `any`,
which tl does not enforce and a lint does. `v is R` for a record `R`
is refused on an `any` or a union of records by lint, because it
compiles to a table check that cannot tell two records apart; the
shape module is the way in. the checker's own hint on an `any`
index points at a shape, not at a cast. the per-release report
names the modules that cast from `any`; the expected list is the
shape module, the codec decoders, the C declaration layer, and the
build step that loads the compiler chunk.

### the runtime

coroutines over `poll`. every blocking binding takes a timeout and
can be driven from one event loop, which is Teal over the `poll`
binding; `http.serve` and `fetch` are coroutine-driven; CPU
parallelism is by process through `child`. one state per OS thread
with message passing stays open as a later addition that rewrites no
bindings.

### tls

mbedtls: TLS 1.2 and 1.3, one configuration, hashes and HMAC from
the same library. the branch is chosen when the `fetch` module is
pulled; 4.x is the expectation, since 3.6's support ends in March
2027 and 4.1's runs to 2029 as one tarball with its crypto subtree
included. Mozilla's root bundle is stored in the database, identical
on every machine, moved only by a pinned bump; an environment
variable adds a certificate for the corporate-proxy case without
making per-machine trust the default.

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
a claim. once it exists, a target also needs the matrix to run on it.

### the command line

`cosmic build`, `cosmic check`, `cosmic docs`, and `cosmic embed`
join the verbs; `-e` stays as Lua's one-liner idiom. every verb takes
paths to narrow it, and `cosmic help <verb>` is the discovery surface
for one verb. `cosmic docs` is the one deliberate exception to
singular names: a verb names an action and reads differently from a
module naming a thing, so the module behind it is `cosmic.doc`.

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

## the release bar

the core tier, then the second, each module earning its place. a
release ships when three things hold: cosmic builds and tests the
work board, gitboard, from its own tree; the agent evaluation suite
scores at or above its recorded baseline; the release job produces
all three targets and the repro lane proves them byte-identical.

## open questions

- **host language and toolchain.** Rust as the host was weighed and
  deferred early on; zig as the language was set aside. revisit now
  that a real C core and build.zig exist to compare against, not a
  sketch.
- **FTS5.** measured at 222 KB per core image, three images per
  binary, from the current size report. the decision itself is
  still open, and belongs to whoever needs full-text search first.
- **capitalized exports.** whether an exported function's own name
  is capitalized by convention, `fs.Read` rather than `fs.read`, is a
  readability question and not yet decided, and the checker does not
  enforce it either way.
