# Design — `cosmic --make`: what the landed slices settled

the design is in [../README.md](../README.md); the plan is in
[../plan.md](../plan.md) and [../phasing.md](../phasing.md). this is the record of what *landing* each
slice taught — kept out of the plan so the plan stays about what is
next, and out of the design so the design stays about what is true.

phases 1 and 2 are here; **phase 3 is in
[phase3-dogfood.md](phase3-dogfood.md)**. one file per phase,
because the 500-line cap applies to every tracked file and a record
only grows.

Read it when a decision looks arbitrary. Most of them were arbitrary
once and stopped being so because something failed.

## What `--make` replaced, and why conventions

`--make [dir] [target]` scanned for `*.tl`, classified by suffix, emitted
a Makefile and ran make on it. It **needed a host make** (the generated
file is useless without one, contradicting promise 3 for exactly the user
cosmic is for); it **produced build files, not builds** (no rule made an
executable); and its **project model was a flat scan** — no packages, no
entry point, no artifact, no notion of what ships. Dropped whole in 2a.

Three fixes that landed the week the design was written are the evidence
for its central bet, that a hand-maintained description of a project
drifts from the project:

- **#800** — `_build`, `_docs`, and `_types` were not
  type-checked or format-checked at all, because no `cook.mk` declared
  their sources. Three directories, silently outside the gates.
- **#802** — the teal and format gates "never ran the check they
  report": an argv-ambiguity bug meant they passed everything.
- **#799** — lint only saw *tracked* files, so a new file got no lint
  locally and first failed in CI.

Under conventions the first cannot happen (a package is a directory with
sources in it, discovered, never declared), and the closed recipe
vocabulary removes the argv ambiguity behind the second. The third is a
policy the `lint` verb inherits: **tracked plus untracked-not-ignored**.

Two primitives the design needed already existed: `child.spawn`'s
`"inherit"` stdio mode (#798), which is how a recipe step streams while
it runs, and `--test`'s argv slicing (#804), which the `test` verb keeps.

## Phase 1 — `-c` shell mode

Landed, except the fence default: the closed verb vocabulary, the
trailing-`;` sentinel that makes `SHELL` interception real at all,
`exec`'s pinned-only resolution, grants derived per verb, and
`SHELL := $(bootstrap_cosmic)`. recipe output streams via
`child.spawn`'s `"inherit"` mode (#798), so no new stdio machinery.
spawn cost measured at 6.4 ms per line (assimilated ELF), the same one
spawn the recipes already paid.

Two things this phase learned the hard way: a derived fence still needs
a runtime floor, and **a pin bump ships every change in that release
into this repo's own build** — pinning a release for `-c` also pinned an
unproven always-on fence, which turned three lanes red until the pin was
rolled back. The fence is therefore opt-in (`COSMIC_FENCE=1`) with a
canary asserting it denies; making it the default is its own change,
gated on that canary passing on a Landlock host.

Left open here: the portable in-process gate, which only matters once
generator and test units exist.

## Phase 2 — user-facing `--make`

The phase that **answers the original ask**, and the one that was almost
entirely user-facing: `--make` does not run in this repo's own recipes,
so unlike phase 1 a bug here could not take the build down with it, and
nothing needed a release until phase 3. Code lives in
`lib/cosmic/_make/` (a directory module replacing the old `make.tl`),
moving to `_make/` when the tree flattens — no reason to hold the split
hostage to the rename.

### 2a — project model and `check`

The walk and the classification (package, `_test`, `_example`, `.d.tl`,
`*.pin.tl`, `*.gen.tl`, `testdata/`, asset, ignore), the validator
(reserved import paths, `foo.tl`+`foo.lua`, `cmd/foo`→`cmd/bar`,
internal imports, missing `cmd/` entry, spaces and metacharacters), root
discovery with the ancestor guard and the `make: root=` banner, and
`--make check` running in-process. The old `--make [dir] [target]`
Makefile generator is **dropped**, not carried: two grammars for one
flag is worse than one rewrite of the guides. Gates: fixture trees, and
every validator message asserted — those are what a fresh agent hits
first.

Six things it settled, each because the design left room for two
readings:

- **`[paths…]` is selection, never the root.** the design says "root
  discovery: cwd, an explicit path overrides", which read two ways once
  paths also select files. The root override is `COSMIC_MAKE_ROOT`, and
  it **suppresses the ancestor guard** — the guard exists to catch a
  root nobody thought about, and naming one is thinking about it.
  Without that, the refusal would have no escape hatch at all.
- **planned verbs are named, not hidden.** an unimplemented verb answers
  "planned but not implemented yet" and an unknown one lists the
  vocabulary. A typo and a schedule question fail differently, which is
  the whole value.
- **`guide.makefile` is retired, not rewritten.** every section of it
  described the generator. One flag, one guide; the test now asserts the
  topic *misses* and that the miss lists what exists.
- **`.d.tl` beside `.lua` is not a duplicate.** declaring types for a
  Lua implementation is what `.d.tl` is for. Only files carrying an
  import path's *code* collide.
- **the reserved names are namespaces**, so `cosmic/fs.tl` is refused,
  not just `cosmic.tl` — shadowing `cosmic.fs` inside an artifact is the
  hazard the rule exists for. Consequence for phase 3, recorded at the
  time and paid in 3a: this repo's own `cosmic/` tree needs an
  exemption, since it *provides* those modules rather than shadowing
  them.
- **dot-prefixed entries and non-regular files are invisible.**
  otherwise `.github/workflows/*.yml` is an asset embedded at its
  relative path, which is nobody's intent.

### 2b — the graph

Constant `o/cosmic.mk` plus the `o/project.mk` facts generator, driving
make with the sentinel; `build`/`test`/`fmt`/`clean` lowered onto it;
parallelism.

What it settled:

- **the `test` verb never propagates its child's code.** It writes the
  `.got`/`.out`/`.err` contract and returns 0; the report grades. That
  is the deliberate answer phase 1 asked for: `--test` propagates exit
  2, so a rule shaped that way reads a skip as a broken rule *and* stops
  every other test at the first failure. Recording and grading are
  different jobs, and only the second one is make's business.
- **selection travels as a make variable override**, which beats
  `o/project.mk`'s assignment. No rule knows selection exists, which is
  exactly what keeps the rules file constant.
- **per-test dependency closures — added after 2e, fixing a flaw 2b
  shipped.** The rule was `$(test_got): $(compiled)`: every test
  depended on every compiled file, so changing any module re-ran the
  whole suite. Write-if-changed absorbed a bare `touch`, which hid it —
  it only bit on real content changes, which is exactly when you are
  iterating.

  The facts generator now follows `require()` edges (the same literal
  scan the validator uses) and emits one `deps_<stem>` per test: its
  transitive closure, as built paths. The rule takes them as
  prerequisites through `.SECONDEXPANSION`, which is what lets a
  CONSTANT rule name a per-target variable.

  The same list goes into the recipe line, so the **fence** grants a
  test read access to what it imports and nothing else — where an
  earlier draft granted the whole build root, i.e. every other module's
  output. One answer, two consumers, and the design's own rule for how
  it travels: *the argument positions are the declaration*. Measured on
  a fixture: editing a module no test imports re-runs nothing; editing
  one that a single test imports re-runs that test alone.

  Known limit, inherited deliberately: a computed `require` is
  invisible, exactly as it is to the validator. The consequence is now a
  denied read as well as a missing edge, which is a sharper failure than
  a stale result.
- **the same closure for compiles, which turned out to be a correctness
  bug rather than a tidiness one.** The compile rule was `$(O)/%.lua:
  %.tl` — a module's output depended only on its own source. But a
  *strict* compile type-checks against the modules it imports, so
  changing a module's contract left its importers un-recompiled and the
  incremental build kept output a clean build rejects. Reproduced
  exactly: `util.n()` changed from `integer` to `string` while `main.tl`
  assigns it to an `integer` — clean build FAILS, incremental build
  PASSED.

  Compiles take the **source** closure, tests the **built** one, and the
  distinction is load-bearing: the type checker resolves
  `require("util")` to `util.tl` through the include path, while a test
  runs against compiled Lua. Getting them backwards is the difference
  between catching a broken contract and shipping past it.
- **the fence's variadic tail grants files, not directories.** A tail is
  a list of inputs; a directory in one is a search path the verb hands
  its child — `compile`'s `--include-dir .` — and granting it read would
  hand over the whole tree and undo the closure entirely. Named
  positions may still be directories the verb genuinely walks (`verdict
  <o_dir>`), which is why the two are now separated rather than filtered
  together.
- **`--deps` is a separator the verb strips and never forwards,** and
  the reason is a bug caught in the act. Passing the closure as plain
  trailing arguments meant `do_compile` forwarded them to the child as
  *compiler flags*: `cosmic --include-dir . util.tl --compile-strict
  main.tl`. getopt stops at the first positional, so the child RAN
  `util.tl` as a script and wrote its empty stdout as `o/main.lua` — a
  compile reporting a pass for a check it never performed. That is the
  #801/#802 shape exactly, and it was found only because the fixture
  asserted the type error still fires.
- **`check` and `clean` stay out of the graph.** `check` in process
  means the one verb that says whether a project is coherent needs no
  engine at all — which mattered most at the time, because there was no
  engine to find. `clean` through a graph whose rules live in the
  directory being deleted is a knot with no payoff.
- **the engine is named or pinned, never guessed.** `COSMIC_MAKE` names
  it; PATH is not searched. Until 2e embedded one, a graph verb refused
  with the command to run. That is the honest interim — a build whose
  engine came from whatever the host installed is a build nobody can
  reproduce.
- **the design doc had one internal tension, resolved.** It said both
  "discovery uses `$(wildcard)` and rwildcard" and "discovery and
  validation stay in Teal, where errors can be good". The second wins:
  the walk, the classification, and the validator are Teal, and
  `o/project.mk` is the list of variables they produce. A makefile
  cannot say "`my notes.tl` cannot be a filename here".
- **make's recipe echo stays on.** For a build system whose whole
  capability surface is a closed verb list, watching that list scroll
  past is the feature, not noise.

### 2c — the artifact

compile → stage → embed → `o/bin/<name>`, stripping to the floor,
reproducibility (the `AddOptions.mtime` plumbing), `cmd/` multi-binary.
This is the slice where a tree of `.tl`/`.lua` plus tests becomes an
executable.

What it settled, and one thing it did not:

- **a `cmd/<name>/` directory is a generator**, which is the observation
  that produced the *Units* section in [../model.md](../model.md). Every output
  under `o/` comes from a unit: a directory that declares it, a scope of
  inputs that is also its grant set, and an output path derived from its
  position. The artifact's `scope_of` is written in that shape; 2d's pin
  made the third instance, which is when the abstraction was to earn
  itself.
- **the stripped-floor risk did not materialize.** The design flagged
  `.lua/cosmo/**` as possibly backing a lazily-required binding. This
  base carries no such directory at all, so there is nothing to strip
  and nothing to break. The lane that would have caught it is now the
  stripped-artifact test, which boots a stripped binary and asserts the
  stdlib loads while `tl` does not.
- **stripping is semantic, not yet a size win — recorded, not papered
  over.** `Appender:remove` unlinks an entry from the central directory
  and leaves its bytes as dead space, so a stripped artifact is ~14 KB
  smaller than its base rather than the ~1.2 MB the design's table
  projects. Everything the strip *promises* holds: the toolchain is
  unloadable and unextractable, and the floor is a positive list so a
  future base cannot silently start shipping a new directory. What is
  missing is compaction, which needs a zip rewrite the binding does not
  expose — an upstream whilp/cosmopolitan change, and exactly the kind
  of thing the fork exists for. Until then the size table in ../remaining.md is
  a projection, not a measurement.
- **removing a directory marker removes its subtree.**
  `Appender:remove` treats a trailing `/` as a prefix, so stripping the
  bare `.lua/` marker takes `.lua/cosmic/**` — the floor — with it.
  Markers are zero bytes and are never removed now. This cost one
  debugging cycle and is the kind of thing that reads as "the stdlib
  vanished" rather than "the strip was too wide".

### 2d — pins and `fetch`

`*.pin.tl` static extraction and the network-only-under-`fetch`
posture.

**The Units investigation ran here, and falsified one of its three
predictions.** The pin's scope was written without consulting the
artifact's, which was the whole method:

- **P1 (every scope is `filter(files, predicate)`) — holds, but
  vacuously.** A pin's scope is the pin file itself. Expressed as a
  filter it is a filter returning one element, which is not an instance
  of a shared computation, it is the shape being satisfied by having
  nothing to say.
- **P2 (the fence wants a directory, the stage wants a file list) —
  holds, and sharpens.** The pin needs one thing no path abstraction can
  express: a socket. So the fence's question is (directory, capability
  set), not a directory.
- **P3 (an output path is derivable from position) — FALSE.** A pin's
  output is named by the URL *inside* it: `3p/lpeg/lpeg.pin.tl` with a
  url ending `lpeg-1.0.tar.gz` produces `3p/lpeg/lpeg-1.0.tar.gz`,
  because the extension matters to whatever reads it next. The Units
  table asserted this of all five rows; it is true of four. The table
  now carries the correction.

**Verdict: the `Unit` record is not earned, and now there is a reason
rather than a hunch.** What the evidence supports is smaller —
`unit_dir(path)`, which is what `exec`'s fence actually wants — while
"scope as a file list" is a question only the artifact and the test
stage ask. Two of five rows is not an abstraction. This is what a third
instance was supposed to settle, and it settled it the other way.

Also settled here:

- **a pin is data, and the grammar enforces it.** `return { … }` of
  literals, lexed and matched, never loaded and never called. A call, a
  concatenation, a variable, a statement before the return, anything
  after the table — each refused by name. "This file cannot do anything"
  is the property; the tests are adversarial for that reason.
- **a pin without a digest is a download.** `url` and `sha256` are both
  required, and mismatched bytes are never written — not
  written-then-checked. A build runs on the bytes you named or does not
  run.
- **`fetch` opts out of the SSRF guard, deliberately.** That guard
  exists because an attacker-controlled url can aim a fetch at an
  internal service. A pin's url is a literal in a committed file the
  extractor has already refused to let compute itself, and the bytes are
  digest-verified before they land — so the threat is absent by
  construction, while the case the guard breaks (an internal artifact
  mirror) is exactly what pinning is for.
- **the posture is structural, not aspirational.** `fetch.tl` is the
  only module under `cosmic._make` that requires `cosmic.fetch`, so "can
  a build phone home" is answered by grepping seven files. The test
  asserts it from outside too: a project whose pin points at a dead port
  still builds.

### 2e — embedded make

Packing it into the release, which user projects need and this repo does
not (it has `bin/cosmo-make`). Carries the D13 amendment, so it is the
one slice with release mechanics — deliberately last.

The pinned make from `cosmos.zip` ships at `/zip/make` and `find_make`
extracts it to `o/make` on first use, through a temp file and a rename
so a concurrent build cannot exec a half-written engine. Gate: a fixture
project builds and runs with `COSMIC_MAKE` unset — nothing installed,
nothing fetched.

**The cost, stated rather than justified away.** +765 KB on the release
(7.89 MB → 8.66 MB), which is almost exactly the ~760 KB the design
projected. What the design also projected is that stripping would pay
for it, and 2c found it does not: the strip leaves dead space, so it
recovers ~14 KB, not ~1.2 MB. So this is an uncompensated 10% and was
accepted as one — deliberately, on the grounds that a build system which
cannot build without a host toolchain is not a build system. The size
table in ../remaining.md is a projection; the compaction that would make it true
is filed upstream and is not a blocker.

One thing worth knowing about the extracted engine: it is a fat APE, so
its shell stub needs a POSIX environment to reach its loader. A build
with `PATH` emptied entirely fails inside the stub, not inside cosmic.
Found by writing that test too aggressively.

### Closed across phase 2

**`exec` is fenced to its units**, not to `.`. Phase 1 stood the grant
in as the whole working tree for want of any notion of a unit; 2d's
investigation supplied one, and `unit_dir` is the single abstraction
that investigation earned — a fence wants a directory where a stage
wants a file list. `exec` now reads the units its argv touches (the
program's own always included, so a step with no path arguments is not
fenced to nothing), and a generation unit resolves to the directory
holding its `*.gen.tl` rather than to the leaf.

Three things phase 1 paid for, carried forward rather than relearned:

- **fenced tests land opt-in. Landed after 2e**, having been missed in
  2b/2c — the plan assigned it there and the slices shipped without it,
  which is recorded here rather than quietly closed. Two halves, and the
  split is the useful part:

  - **portable and unconditional:** the `test` verb points `TMP` at a
    scratch directory beside the step's own output, so a test's
    `TEST_TMPDIR` lands in `o/<test>.test.tmp.d`. Tests stop being able
    to collide through the temp directory on *every* platform, Landlock
    or not, and it needs no flag because it takes nothing away.
  - **kernel-enforced and opt-in:** the derived write grant is that same
    directory and nothing else, and reads are the compiled tree plus the
    test's own source directory (where `testdata/` lives, so fixtures
    need no special grant — the design's rule, stated as two paths).
    Behind `COSMIC_FENCE=1`, with an A/B canary in the enforce lane
    asserting the denial. Both canaries skip on a host without Landlock,
    which is precisely what that lane is for.
- **skip semantics are not inherited.** `--test` propagates exit 2 to
  make, so a test file that means to skip fails its rule instead of
  being graded. The `test` verb has to define this deliberately.
- **doc churn is work, not a footnote.** retiring the Makefile generator
  meant rewriting `skills/cosmic/make.md`, deleting `makefile.md`, and
  rewriting the `--make` lines in `checking.md`, `formatting.md`,
  `testing.md`, `sys/help.md` and `AGENTS.md` — plus
  `doc/guide_test.tl`, which asserted `guide.makefile` resolves. All of
  it landed in 2a with the drop, as predicted.
