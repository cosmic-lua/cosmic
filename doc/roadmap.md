# roadmap

what comes after the current state in [design.md](design.md), and
the questions still open. this doc is read alongside design.md, not
instead of it: design.md says what cosmic is, this says what is
next and what is undecided.

most of what follows has been built once already, on `main`: the
existing, much more complete cosmic, built on a different toolchain
(Cosmopolitan Libc, not a from-scratch C core over zig) and a
different process model (a test runner that forks a process per
test, not the in-process one here). main is not a template -- its
toolchain, its enforcement points, and some of its tradeoffs are
ones this tree deliberately did not repeat -- but it is a working
answer to nearly everything below, sometimes a good one, sometimes
one worth reading only to see what this tree is avoiding. each
section below names the paths on main worth reading before building
the item fresh; a few things on main have no counterpart here at
all yet and are called out as their own entries.

## self-check

`cosmic test` compiles what changed in the tree with the patched Teal
checker, reads the rest back from the working database, and runs, in
process, every discovered test whose stored verdict does not stand,
with records in that same database. the planned restriction on casts
is not yet implemented.
tests, the in-process runner, and a real Teal AST (`build.ast`:
parse, walk, structural match, rewrite) have already landed; what
follows leans on `build.ast`, still build-internal today, and on
`o/build.db`, which already holds test verdicts.

there is no separate `cosmic check` verb, and none is planned:
type and visibility checking run on every `cosmic test` and plain
`cosmic file.tl` invocation. `cosmic fix` parses, rewrites, renders,
and checks the rendered AST and comments against the rewritten input;
it does not run type or visibility checking. `build/
importer.tl`'s `complain()` folds syntax errors, type errors, and
warnings into one list, and any of them refuses the whole compile --
remaining compiler warnings are errors on these compile paths
(the importer filters unused discovered test functions and generated
doctest `print` shadowing warnings). `build/positions.tl`'s
sibling-privacy check runs the same way, on every compile -- see the
visibility lint entry below, which this same mechanism already closes.

- **the doctest extractor has landed** (`build/doctest/`: `markdown.tl`
  parses fenced blocks, `generate.tl` turns them into one compiled Teal
  file per doc, one function per example), and is wired straight into
  `build/importer.tl`'s ordinary collection: `doc/guides/*.md` is
  discovered and run through it exactly like a hand-written `_test.tl`,
  needing no runner of its own, per meta.md. Live today, not
  hypothetical -- `doc/guides/quickstart.md` compiles and runs as
  `doc.guides.quickstart`, and CI's own step name already says "run
  every test the tree defines, including doctests".
- **Lua and Teal coverage has landed** (`cosmic/coverage.tl`), and so
  has the collector cheap enough to leave on by default: a line hook
  that keeps its own hit accounting in C (`core/coverage.c`), one
  `lua_getinfo` call filling `currentline`/`short_src` straight into a
  C struct and a table write, no Lua closure and no `debug.getinfo`
  call from Lua on the hot path -- the earlier Lua-side hook this
  replaced cost exactly that call per line the whole suite executed,
  which was minutes on this tree; `build.test` now runs it on every
  `cosmic test` and reports a real percentage. `debug` itself stays
  out of reach the same way it always has, for reasons that are not
  this module's; nothing fetches it back out any more.
- **main's coverage module is the same idea, one level ahead on a
  problem this tree hasn't hit yet.** `cosmic/coverage/init.tl` uses
  the same line-hook-in-C shape; what's worth taking is
  `cosmic/coverage/SENSITIVITY.md`, a maintained table of every test
  whose coverage depends on the environment it runs in (root vs not,
  Landlock availability, a tty, a free port, fork availability, even
  which compiler built the artifact), with a rule that a floor only
  ever moves from what CI measures, never from a laptop. this tree's
  coverage floors will hit the same problem the moment they start
  gating anything, and there is no reason to rediscover it by hand.

**deferred, not dropped: C testing and coverage.** no C-level unit
test framework exists yet, and C coverage is researched but not
built: source-based LLVM instrumentation on `core/*.c` only
(`-fprofile-instr-generate -fcoverage-mapping`), a vendored
`compiler-rt` profile runtime per target since zig ships the
instrumentation but no runtime to act on it, `llvm-profdata` and
`llvm-cov` pinned to zig's bundled LLVM version and re-verified on
every bump, `llvm-cov export` as one JSON. both wait until Lua and
Teal testing exists first, deliberately: `core/*.c` is a handful of
files today, and the cost of waiting is small next to the cost of
building two systems that diverge. the requirement once they land:
the same facilities and the same ergonomics as Lua and Teal testing,
not a separate system beside it, one discovery convention, one verb
that runs both, coverage reported the same way for either.

- **cosmic's own stdlib resolves from outside its tree** -- landed:
  the binary ships every `cosmic.*` source and declaration as rows
  (`decls` beside `modules`), and the checker's module search falls
  through to them for a name the project's own stage does not hold,
  so `require("cosmic.fs")` in a project that is not cosmic's own
  checkout compiles, is typed, and runs, with nothing of this repo on
  disk. This, not a missing verb, is what "a real project imports
  more than a trivial one-file script" was actually pointing at.
- **the rewrite rules `cosmic fix` applies.** the verb has landed, and
  with it the renderer that writes a parsed tree back out as source; its
  rule list is empty, because the rules worth writing are lint fixes and
  the lint rules have not yet been implemented. adding one is the whole
  cost of a new fix: no part of the pipeline moves around it.
- **the visibility lint has landed**, and turned out to already be
  built: `build/positions.tl`'s sibling-privacy check -- a directory
  with its own `init.tl` is private, only a file inside it may
  require a sibling beside that entry, generalized to every directory
  in the tree, not only `cosmic`'s own reserved namespaces -- already
  runs on every compile, and `test/visibility_test.tl` already proves
  it. The case-collision half (no two names in a directory differing
  only in case) is dropped, not merely deferred -- nothing about it
  is currently planned. main enforces the same rule a different way,
  worth comparing: `_cli/visibility.tl` runs it as a lint
  (`--check lint`), not a compile-time refusal (decision D19) -- a
  looser enforcement point this tree deliberately did not take,
  since a lint can be silenced and a compile error cannot.
- **record-field narrowing has landed** (`patch/tl/08` through `14`,
  plus the bare-variable statement-form `assert` narrow it builds on,
  `07-assert-narrows.txt`): a guard on `x.field` -- truthy read,
  `assert`, `== nil` / `~= nil`, the early-return shape -- narrows the
  field the same way a bare variable already narrows, on a
  bare-variable base only (`a.b.field` does not chain). container
  covariance, once considered the other remaining narrowing patch, is
  dropped, not deferred: no v1 precedent ever needed it, against a far
  larger codebase, and no evidence of a live blocker has ever turned up
  in this tree either -- a hypothetical with nothing behind it, not a
  known gap. main carries its own version of this same patch
  (`3p/tl/tl_patch/narrow_record_field.tl`, `narrow.tl`) -- a second
  implementation worth diffing against this tree's `patch/tl/08`-`14`
  before either is called finished.
- **the cast restriction design.md describes is not just a plan
  somewhere else: main built it and measured it.**
  `3p/tl/tl_patch/cast.tl`, gated behind `COSMIC_CAST_LEGALITY=1` so
  the unpatched tree is byte-for-byte the same without it, implements
  close to the exact rule design.md's teal section specifies -- `x as
  T` legal only from `any`, from a `.d.tl` userdata record, or from
  the enclosing generic's type variable. `docs/design/cast-
  legality.md` carries a census run against main's own tree with the
  flag on: 135 refusals across 133 of its 198 cast sites. that is the
  closest thing either tree has to real evidence for what turning
  this rule on actually costs, and it is worth reading before this
  tree's own version is written, not after.

**alongside, not gating the above:**

- **child-process spawning**, `cosmic.child` over `posix_spawn`.
  serves two things at once once it lands: the isolation layer the
  test runner still lacks (a hang or a crash in one test currently
  takes down the whole run), and a real default time limit on
  `cosmic test` (something like 30 seconds) that can actually kill a
  hung test rather than just watch it: a cooperative, checked-between-
  tests budget was considered and set aside deliberately, since it
  cannot preempt one single test stuck in a genuine infinite loop
  mid-execution -- exactly the failure a timeout exists to catch --
  it can only notice aggregate slowdown after the fact, which
  `cosmic test`'s own verdict line (pass/fail plus wall-clock-visible
  slowness) already surfaces well enough. Worth a CLI flag
  (`--timeout SECONDS`) and an env var default, once there is a
  process to actually kill. main already built this and has run it
  for a while: `cosmic/child/{init,fast,io,types}.tl` is a
  `posix_spawn`-backed fast path with `__gc`/`__close` finalizers
  that SIGKILL-and-reap an abandoned child, and main's own test
  runner already isolates every `*_test.tl` in its own process this
  way (`_tool/testrun.tl` and the `_cli/build/*` graph that drives
  it). worth reading closely for the shape -- the finalizer-based
  reap-on-drop especially -- though it sits on Cosmopolitan's
  `cosmo.unix` binding, which this tree's syscall table replaces
  outright, so the design carries over and the implementation does
  not.
- **`O_CLOEXEC` on the remaining `fopen` paths** in boot and the
  patch applier; the syscall table's own `open` already sets it.
- **a fuzzer over the executable locator**, now that it parses
  untrusted bytes at every startup. main's `_fuzz/**` is a working
  fuzzing framework worth building this on rather than one-off: a
  seeded property loop (`FUZZ_SEED`/`FUZZ_ITERS`), each iteration
  re-exec'd into an isolated child for crash containment, an
  instruction-count budget as a hang backstop independent of
  wall-clock, and shrinking on a failure. the locator is one target
  for that shape, not a reason to build a narrower one.
- **out-of-process containment, for the gap the sandbox module admits
  it does not close.** design.md's sandbox section says plainly that
  per-host network rules are not in its core -- Landlock's port rule
  has no address, so "only the proxy's port" reaches any host on
  that port -- and that a caller who needs that "takes the Linux
  extension below or a container." main already built that
  extension: `cosmic/quicksand/` is a separate, Linux-only,
  out-of-process system -- a network namespace per child (`netns.tl`),
  an allowlist HTTP/CONNECT egress proxy that dials upstream from a
  different namespace with SSRF protection (post-DNS-resolution
  checks against public IPs) and per-host auth injection
  (`proxy/{dial,http,rules,serve}.tl`), and a declarative `Box`
  builder (`box/{init,env,merge,run}.tl`) composing netns, proxy,
  process primitives, and `cosmic.sandbox` itself into one call.
  main's own `cosmic/sandbox/` -- Landlock plus seccomp, per-section
  `full`/`degraded`/`skipped` reporting -- is close enough to
  design.md's sandbox section already that it reads as a second
  implementation of the same design, not merely related work;
  `cosmic/quicksand/` is the part with no counterpart here at all,
  worth its own line once the sandbox module's tier is reached.

## documentation

`cosmic docs` and `cosmic uses` (#1885) read the `docs` and `uses`
tables every build derives, and the stdlib is already documented at
the doc-comment level: every public function in `cosmic.fs`,
`cosmic.hash`, `cosmic.env`, `cosmic.proc`, `cosmic.errors`,
`cosmic.sqlite`, `cosmic.store`, `cosmic.time`, `cosmic.compress`, and
`cosmic.coverage` carries one. A narrative gap belongs in the doc
comment itself, not in a new `doc/guides/*.md` file: the doc comment
is already in the index, already what an uncaught error surfaces as
guidance, and already what `cosmic fix` keeps honest against the
source beside it.

main already ships a full `cosmic --docs`: `cosmic/doc/{init,query,
show,lookup,types,visibility}.tl` serves an embedded index with
`go doc`-style lookup, fuzzy search, and guide rendering, and
`_tool/doc/{init,scan,dtl,exports,signature,comments,index}.tl` is
the extraction half that builds it. the split -- extraction at build
time, query at runtime, from the same doc-record shape -- is close
to what `docs`/`uses` already plans here; worth reading before
#1885 lands, as a second implementation of the same idea rather than
a different one.

**worked examples have landed.** `build/work.tl`'s `inputs` view
already reserved the shape (`*_example.tl` GLOBs to `kind = 'example'`
next to `*_test.tl`'s `kind = 'test'`); `build/positions.tl` now reads
a top-level `function Example.<name>()` the same structural way
`docs_of` reads `function Fs.read(...)`, no tag naming the association;
`build/writer.tl` resolves it against the paired module's own entry
record (`cosmic/fs_example.tl`'s `Example.read` against `cosmic/fs.tl`'s
`Fs`) and ships it in a new `examples` table, kept only where the
resolved symbol is one `docs` actually declares; `build/test.tl` runs
it exactly like a `test_*` function, one assertion mechanism for code,
not a second, output-diffing one; `cosmic docs Fs.read` prints it,
source and all, beneath the doc comment. `cosmic/hash_example.tl`
is the first one, proving the whole path end to end. the convention
is not speculative -- main's own `cosmic/` layout already carries
`*_example.tl` files beside their modules the same way.

**what is actually left is writing more of them**, one `_example.tl`
per stdlib module that does not have one yet: `fs`, `sqlite`, `env`,
`proc`, `time`, `errors`, `store`. Each is small (one file, one or a
few `Example.<name>` functions, verified by `assert` like any test) and
adds exactly one thing: a runnable example under a real symbol, not a
guide restating what the doc comment already says. `compress` and
`coverage` can wait, same as before -- each has exactly one internal
caller today, so an example would demonstrate a library nobody outside
this repo can use yet.

a related gap neither tree currently closes for code, only for
guides: `cosmic uses` will say where a symbol is called, but nothing
says where it is *mentioned* -- a guide's prose about `Fs.read`
drifting out of sync with `Fs.read`'s own doc comment, with no gate
catching it. main has exactly this: `cosmic/doc/mentions.tl`, an
FTS5 query over guide and doc text, separate from its own code-
reference index. worth a line of its own once `docs`/`uses` lands,
not folded into it -- it answers a different question.

smaller things on main worth a passing look, not yet substantial
enough for their own line here: `env.d/`, an embedded-dotenv
convention for shipped credentials; `_docs/derive.tl`, which
rewrites derived regions of committed markdown so a summary can't
drift from the record it summarizes.

separately, README.md's own `sh`/`output` example is not swept by the
doctest extractor, which discovers exactly `doc/guides/*.md` (see
`build/work.tl`'s `is_doc_guide`) -- it is checked by hand only. Worth
either moving it under `doc/guides/` or accepting, explicitly, that
the front door is the one doc this build does not enforce.

## the release bar

the core tier, then the second, each module earning its place. a
release ships when three things hold: cosmic builds and tests the
work board, gitboard, from its own tree; the agent evaluation suite,
`eval/`, passes its task's grader (`eval/check/<task>`); the release
job produces all three targets and the provenance job proves them
byte-identical.

main's `_eval/**` is a working second implementation of the same
idea, worth reading closely before `eval/check/<task>` grows past
what it holds today: `_eval/suite.tl` pins a fixed set of tasks as
data, never executed code; each task pairs a brief
(`_eval/tasks/<id>.md`) with a grader (`_eval/checks/<id>.tl`) wired
through a shared `_eval/checks/registry.tl` so the grader and its own
tests can't drift apart; and each task ships golden run-directories
for a pass, a partial, and a fail outcome
(`_eval/testdata/run_{pass,partial,fail}/<task>/`) so a grader change
can be checked against known verdicts instead of only against live
runs.

"cosmic builds and tests the work board, gitboard, from its own
tree" wants a decision before it is taken literally: main's own
gitboard is not built from its tree at all. `bin/gitboard` and
`bin/gitboard.pin` are a separately pinned external binary, the same
shape as `bin/zig`'s trust root, with only
`_build/gitboard_pin_test.tl` and `_cli/gitboard_root_test.tl` on the
tree side. main never attempted a self-built board; whether this
line means something more self-hosted, or the same pinned-artifact
relationship worded differently, is worth settling before it becomes
a release-bar item that can't be checked.

**not yet on this list at all: a perf gate.** `_perf/**` on main is a
mature scenario-benchmark harness with no counterpart here --
`_perf/bench/*.tl` covers roughly eighteen scenarios (child,
download, embed, fs, http, json, sqlite, startup, tar, teal, and
more), and `_perf/gate.tl`/`compare.tl`/`reproduce.tl`/`tiebreak.tl`
gate a release on the result without flaking: a flagged regression is
re-measured and only fails if it reproduces against a common
baseline, an A/A self-check reclassifies same-binary noise, and a
third reading breaks ties by median. design.md's efficiency promise
("a fresh agent... journaling what slowed it down") is a one-off
measurement today; this is what turns it into something a release can
actually be gated on, and it belongs on this list once there is more
than one target worth comparing against.

## open questions

- **host language and toolchain.** Rust as the host was weighed and
  deferred early on; zig as the language was set aside. revisit now
  that a real C core and build.zig exist to compare against, not a
  sketch. there is a third answer neither of those is: main wrote no
  C of its own at all and vendored Cosmopolitan Libc wholesale
  (`3p/cosmos/`), trading a hand-built core for one binary that is
  already portable across six OSes. this tree's C core is
  deliberately not that, for the size and behavior-consistency
  reasons principle 1 states -- but the decision trail behind main's
  choice (`docs/decisions/d04-portability-via-cosmopolitan.md`,
  `d13-trust-root.md`) is worth reading before this question is
  answered again, and `d14-no-self-hosting.md` is a real
  counter-example to this tree's own self-hosting boot design: main
  considered and explicitly rejected a cosmic-native build executor
  in favor of a permanently pinned external one. worth reading before
  assuming self-hosting the build was obviously right.
- **an address-sanitized lane** on a clang outside the pinned
  toolchain. deferred until the C core is large enough to want it;
  today's core is a few files and hasn't earned the second toolchain
  yet. no comparison to draw from main here -- it has no C core to
  sanitize.
- **how a settled question here gets recorded.** this file has no
  mechanism for closing a question, only for holding it open; once
  one of the above is actually decided, it either gets deleted from
  this list with nothing to show for the decision, or the list grows
  forever. main's `skills/decide/SKILL.md` is a lightweight ADR
  process governing exactly this -- one file per decision under
  `docs/decisions/`, a fixed four-section form (context, decision,
  rejected alternatives, consequences), amended rather than deleted
  when a decision changes. worth adopting something like it before
  this section has enough resolved entries to need one.
