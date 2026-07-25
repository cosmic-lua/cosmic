# Design — `cosmic --make`: delivery plan

the design is in [make.md](make.md); this is how it lands.

## Provisioning and the trust root

**This repo:** `bin/cosmic` — POSIX sh, one job: fetch the pinned cosmic
(pin in `bootstrap/cosmic.pin.tl`) and exec it. `bin/cosmic --make ci`.
Since make is embedded, the chain is **kernel → committed fetcher → one
pin → everything**, down from two pins.

**Downstream projects: commit the binary.** A fat APE in the repo means
`./cosmic --make ci` works from a fresh clone with **zero network and no
shell at all** — the strongest possible version of the bare-sandbox
story, and the right default for a repo pinning a stable toolchain.
Cosmic itself keeps a fetcher because it bumps its own toolchain
constantly and would bloat fastest.

**D13** is amended twice: make ships inside the release (its rejection
reasoned from this repo, where both pins are already in hand — it does
not survive the user case), and vendoring is *recommended downstream*
while rejected here, which is a sharper rule than the blanket one.

**D14** is completed, not contradicted: it rejects a cosmic-native
*graph executor* and says the endgame shrinks make to "a job execution
system and dependency graph, nothing else." Exactly this. Its rejection
of "driving the build from a cosmic script that shells out to make"
needs revisiting — make remains the engine, not a subroutine.

## Worked examples

**This repo, after migration**

```
bin/cosmic                  fetch pinned cosmic, exec it
cosmic/                     PUBLIC API — this directory is the interface
  fs/init.tl  fs/path.tl  fs/fs_test.tl
  json.tl  json_test.tl  json_example.tl
  net/  sqlite/  fetch/  …
_cli/  main.tl  help.tl  searcher.tl  version.tl
_build/  _make/  _perf/
_types/cosmo/cosmo.gen.tl   → o/_types/cosmo/*.d.tl
_types/tl/tl.gen.tl         → o/_types/tl/tl.d.tl
_docs/index/index.lua.gen.tl → o/_docs/index/index.lua
cmd/cosmic/main.tl          the binary → o/bin/cosmic
3p/tl/tl.pin.tl  3p/cosmos/cosmos.pin.tl
bootstrap/cosmic.pin.tl
sys/  skills/  docs/  .github/
o/                          everything generated
```

**A single-binary user project**

```
myapp/
  main.tl                   → o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl          reads staged db/**, writes TEST_TMPDIR
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  schema.sql                asset
  3p/lpeg/lpeg.pin.tl       cosmic --make fetch
```

```
o/bin/myapp  →  /zip/main.lua          generated wrapper
                /zip/main.user.lua     compiled main.tl
                /zip/config.lua
                /zip/db/init.lua  /zip/db/query.lua
                /zip/_internal/util.lua
                /zip/schema.sql
                /zip/cosmic/**         the floor
                /zip/usr/share/ssl/**  the floor
```

**Multi-binary**

```
tools/
  cmd/fetchit/main.tl
  cmd/servit/main.tl  cmd/servit/routes.tl
  shared/http.tl            require("shared.http")
  _internal/log.tl
```

`o/bin/fetchit` embeds `shared/**`, `_internal/**`, `cmd/fetchit/**`;
`o/bin/servit` the same roots plus `cmd/servit/**`. Neither can import
the other's `cmd` directory.

## What this repo looks like afterward

| today | becomes |
|---|---|
| `cook.mk`, `mk/*.mk` | conventions |
| `lib/cosmic/`, `lib/build/`, … | `cosmic/`, `_build/`, … (root = module root) |
| `public.tl` | the `_` prefix; the tree is the manifest |
| `pack_copies` enumeration | the artifact layout rule |
| `3p/*/version.lua` | `*.pin.tl`, statically extracted |
| `gentype`/`gentl` rules | generation units, one directory each |
| doc index, version stamp | a generation unit; committed data + env |
| `.PLEDGE`/`.UNVEIL`/`.ENV` | derived grants, enforced by cosmic-as-`SHELL` |
| `.SANDBOXED`, hostx, recipe-scan ratchets | mostly unnecessary; the vocabulary is closed |
| ratchet tests reading the tree | moved to the root, where their inputs are |
| coverage/enforce/reproducible/offline | policy verbs |
| `bin/make ci` | `bin/cosmic --make ci` |

`-include cosmic.mk` is the migration bridge only. What stays bespoke:
the first-fetch shell in `bin/cosmic`.

## Gates for the change itself

- fixture projects — single-binary, `cmd/` multi-binary, `.lua`-only,
  mixed, assets, `testdata/`, `.cosmicignore` — each built and *run*
- reproducibility: double-build into different paths, compare sha256
- stripped-artifact lane: the stdlib's own tests inside a stripped
  artifact (what makes the floor safe to shrink)
- sandbox canary under cosmic-as-`SHELL`, on Landlock **and** via the
  in-process gate, proving both produce the same denial
- fence tests: a generator reading outside its subtree; a test writing
  outside `TEST_TMPDIR`; a test's *spawned child* attempting the same
- stage immutability: read-only modes survive a run; optional CI-only
  before/after hash to name a culprit
- `exec` refuses an unpinned binary; `fetch` is the only verb that can
  open a socket (asserted, not assumed)
- pin extraction: a `*.pin.tl` that is not a literal is rejected, and a
  pin is never executed
- `testdata/` never appears in an artifact
- `_` enforcement: importing `_x` from outside its container fails
- `o/`-only check: no generated file lands in the tree
- the `lint` verb sees **tracked plus untracked-not-ignored** files
  (#799) and applies the 500-line cap to every file, not only `.tl` —
  which is why this design is two documents
- validator messages asserted: reserved import path,
  `cmd/foo`→`cmd/bar`, `foo.tl`+`foo.lua`, missing entry, space in
  filename, ambiguous root, internal import
- spawn-cost budget: `cosmic -c` under `-j`, reported in phase 1

## Phasing

1. **`-c` shell mode — landed, except the fence default.** the closed
   verb vocabulary, the trailing-`;` sentinel that makes `SHELL`
   interception real at all, `exec`'s pinned-only resolution, grants
   derived per verb, and `SHELL := $(bootstrap_cosmic)`. recipe output
   streams via `child.spawn`'s `"inherit"` mode (#798), so no new stdio
   machinery. spawn cost measured at 6.4 ms per line (assimilated ELF),
   the same one spawn the recipes already paid.

   Two things this phase learned the hard way, both recorded above: a
   derived fence still needs a runtime floor, and **a pin bump ships
   every change in that release into this repo's own build** — pinning
   a release for `-c` also pinned an unproven always-on fence, which
   turned three lanes red until the pin was rolled back. The fence is
   therefore opt-in (`COSMIC_FENCE=1`) with a canary asserting it
   denies; making it the default is its own change, gated on that
   canary passing on a Landlock host.

   Still open here: the portable in-process gate, which only matters
   once generator and test units exist (phase 2).
2. **User-facing `--make`.** the phase that **answers the original
   ask**, and the one that is almost entirely user-facing: `--make`
   does not run in this repo's own recipes, so unlike phase 1 a bug
   here cannot take the build down with it, and nothing needs a release
   until phase 3. Code lives in `lib/cosmic/make/` (a directory module
   replacing today's `make.tl`), moving to `_make/` when the tree
   flattens — no reason to hold the split hostage to the rename.

   - **2a — project model and `check`. Landed.** the walk and the
     classification (package, `_test`, `_example`, `.d.tl`, `*.pin.tl`,
     `*.gen.tl`, `testdata/`, asset, ignore), the validator (reserved
     import paths, `foo.tl`+`foo.lua`, `cmd/foo`→`cmd/bar`, internal
     imports, missing `cmd/` entry, spaces and metacharacters), root
     discovery with the ancestor guard and the `make: root=` banner,
     and `--make check` running in-process. The old `--make [dir]
     [target]` Makefile generator is **dropped**, not carried: two
     grammars for one flag is worse than one rewrite of the guides.
     Gates: fixture trees, and every validator message asserted — those
     are what a fresh agent hits first.

     Six things it settled, each because the design left room for two
     readings:

     - **`[paths…]` is selection, never the root.** the design says
       "root discovery: cwd, an explicit path overrides", which read
       two ways once paths also select files. The root override is
       `COSMIC_MAKE_ROOT`, and it **suppresses the ancestor guard** —
       the guard exists to catch a root nobody thought about, and
       naming one is thinking about it. Without that, the refusal
       would have no escape hatch at all.
     - **planned verbs are named, not hidden.** an unimplemented verb
       answers "planned but not implemented yet" and an unknown one
       lists the vocabulary. A typo and a schedule question fail
       differently, which is the whole value.
     - **`guide.makefile` is retired, not rewritten.** every section of
       it described the generator. One flag, one guide; the test now
       asserts the topic *misses* and that the miss lists what exists.
     - **`.d.tl` beside `.lua` is not a duplicate.** declaring types for
       a Lua implementation is what `.d.tl` is for. Only files carrying
       an import path's *code* collide.
     - **the reserved names are namespaces**, so `cosmic/fs.tl` is
       refused, not just `cosmic.tl` — shadowing `cosmic.fs` inside an
       artifact is the hazard the rule exists for. Consequence for
       phase 3, recorded now: this repo's own `cosmic/` tree needs an
       exemption, since it *provides* those modules rather than
       shadowing them.
     - **dot-prefixed entries and non-regular files are invisible.**
       otherwise `.github/workflows/*.yml` is an asset embedded at its
       relative path, which is nobody's intent.
   - **2b — the graph. Landed.** constant `o/cosmic.mk` plus the
     `o/project.mk` facts generator, driving make with the sentinel;
     `build`/`test`/`fmt`/`clean` lowered onto it; parallelism.

     What it settled:

     - **the `test` verb never propagates its child's code.** It writes
       the `.got`/`.out`/`.err` contract and returns 0; the report
       grades. That is the deliberate answer phase 1 asked for: `--test`
       propagates exit 2, so a rule shaped that way reads a skip as a
       broken rule *and* stops every other test at the first failure.
       Recording and grading are different jobs, and only the second
       one is make's business.
     - **selection travels as a make variable override**, which beats
       `o/project.mk`'s assignment. No rule knows selection exists,
       which is exactly what keeps the rules file constant.
     - **per-test dependency closures — added after 2e, fixing a flaw
       2b shipped.** The rule was `$(test_got): $(compiled)`: every test
       depended on every compiled file, so changing any module re-ran
       the whole suite. Write-if-changed absorbed a bare `touch`, which
       hid it — it only bit on real content changes, which is exactly
       when you are iterating.

       The facts generator now follows `require()` edges (the same
       literal scan the validator uses) and emits one `deps_<stem>` per
       test: its transitive closure, as built paths. The rule takes them
       as prerequisites through `.SECONDEXPANSION`, which is what lets a
       CONSTANT rule name a per-target variable.

       The same list goes into the recipe line, so the **fence** grants
       a test read access to what it imports and nothing else — where
       an earlier draft granted the whole build root, i.e. every other
       module's output. One answer, two consumers, and the design's own
       rule for how it travels: *the argument positions are the
       declaration*. Measured on a fixture: editing a module no test
       imports re-runs nothing; editing one that a single test imports
       re-runs that test alone.

       Known limit, inherited deliberately: a computed `require` is
       invisible, exactly as it is to the validator. The consequence is
       now a denied read as well as a missing edge, which is a sharper
       failure than a stale result.
     - **`check` and `clean` stay out of the graph.** `check` in
       process means the one verb that says whether a project is
       coherent needs no engine at all — which matters most right now,
       because there is no engine to find. `clean` through a graph
       whose rules live in the directory being deleted is a knot with
       no payoff.
     - **the engine is named or pinned, never guessed.** `COSMIC_MAKE`
       names it; PATH is not searched. Until 2e embeds one, a graph
       verb refuses with the command to run. That is the honest interim
       — a build whose engine came from whatever the host installed is
       a build nobody can reproduce.
     - **the design doc has one internal tension, resolved.** It says
       both "discovery uses `$(wildcard)` and rwildcard" and "discovery
       and validation stay in Teal, where errors can be good". The
       second wins: the walk, the classification, and the validator are
       Teal, and `o/project.mk` is the list of variables they produce.
       A makefile cannot say "`my notes.tl` cannot be a filename here".
     - **make's recipe echo stays on.** For a build system whose whole
       capability surface is a closed verb list, watching that list
       scroll past is the feature, not noise.
   - **2c — the artifact. Landed.** compile → stage → embed →
     `o/bin/<name>`, stripping to the floor, reproducibility (the
     `AddOptions.mtime` plumbing), `cmd/` multi-binary. This is the
     slice where a tree of `.tl`/`.lua` plus tests becomes an
     executable.

     What it settled, and one thing it did not:

     - **a `cmd/<name>/` directory is a generator**, which is the
       observation that produced the *Units* section in
       [make.md](make.md). Every output under `o/` comes from a unit:
       a directory that declares it, a scope of inputs that is also its
       grant set, and an output path derived from its position. The
       artifact's `scope_of` is written in that shape; 2d's pin makes
       the third instance, which is when the abstraction earns itself.
     - **the stripped-floor risk did not materialize.** The design
       flagged `.lua/cosmo/**` as possibly backing a lazily-required
       binding. This base carries no such directory at all, so there is
       nothing to strip and nothing to break. The lane that would have
       caught it is now the stripped-artifact test, which boots a
       stripped binary and asserts the stdlib loads while `tl` does not.
     - **stripping is semantic, not yet a size win — recorded, not
       papered over.** `Appender:remove` unlinks an entry from the
       central directory and leaves its bytes as dead space, so a
       stripped artifact is ~14 KB smaller than its base rather than
       the ~1.2 MB the design's table projects. Everything the strip
       *promises* holds: the toolchain is unloadable and unextractable,
       and the floor is a positive list so a future base cannot
       silently start shipping a new directory. What is missing is
       compaction, which needs a zip rewrite the binding does not
       expose — an upstream whilp/cosmopolitan change, and exactly the
       kind of thing the fork exists for. Until then the size table in
       make.md is a projection, not a measurement.
     - **removing a directory marker removes its subtree.**
       `Appender:remove` treats a trailing `/` as a prefix, so stripping
       the bare `.lua/` marker takes `.lua/cosmic/**` — the floor —
       with it. Markers are zero bytes and are never removed now. This
       cost one debugging cycle and is the kind of thing that reads as
       "the stdlib vanished" rather than "the strip was too wide".
   - **2d — pins and `fetch`. Landed.** `*.pin.tl` static extraction and
     the network-only-under-`fetch` posture.

     **The Units investigation ran here, and falsified one of its three
     predictions.** The pin's scope was written without consulting the
     artifact's, which was the whole method:

     - **P1 (every scope is `filter(files, predicate)`) — holds, but
       vacuously.** A pin's scope is the pin file itself. Expressed as
       a filter it is a filter returning one element, which is not an
       instance of a shared computation, it is the shape being satisfied
       by having nothing to say.
     - **P2 (the fence wants a directory, the stage wants a file list)
       — holds, and sharpens.** The pin needs one thing no path
       abstraction can express: a socket. So the fence's question is
       (directory, capability set), not a directory.
     - **P3 (an output path is derivable from position) — FALSE.** A
       pin's output is named by the URL *inside* it: `3p/lpeg/lpeg.pin.tl`
       with a url ending `lpeg-1.0.tar.gz` produces
       `3p/lpeg/lpeg-1.0.tar.gz`, because the extension matters to
       whatever reads it next. The Units table asserted this of all five
       rows; it is true of four. The table now carries the correction.

     **Verdict: the `Unit` record is not earned, and now there is a
     reason rather than a hunch.** What the evidence supports is
     smaller — `unit_dir(path)`, which is what `exec`'s fence actually
     wants — while "scope as a file list" is a question only the
     artifact and the test stage ask. Two of five rows is not an
     abstraction. This is what a third instance was supposed to settle,
     and it settled it the other way.

     Also settled here:

     - **a pin is data, and the grammar enforces it.** `return { … }` of
       literals, lexed and matched, never loaded and never called. A
       call, a concatenation, a variable, a statement before the return,
       anything after the table — each refused by name. "This file
       cannot do anything" is the property; the tests are adversarial
       for that reason.
     - **a pin without a digest is a download.** `url` and `sha256` are
       both required, and mismatched bytes are never written — not
       written-then-checked. A build runs on the bytes you named or does
       not run.
     - **`fetch` opts out of the SSRF guard, deliberately.** That guard
       exists because an attacker-controlled url can aim a fetch at an
       internal service. A pin's url is a literal in a committed file
       the extractor has already refused to let compute itself, and the
       bytes are digest-verified before they land — so the threat is
       absent by construction, while the case the guard breaks (an
       internal artifact mirror) is exactly what pinning is for.
     - **the posture is structural, not aspirational.** `fetch.tl` is
       the only module under `cosmic.make` that requires
       `cosmic.fetch`, so "can a build phone home" is answered by
       grepping seven files. The test asserts it from outside too: a
       project whose pin points at a dead port still builds.
   - **2e — embedded make. Landed.** packing it into the release, which
     user projects need and this repo does not (it has
     `bin/cosmo-make`). Carries the D13 amendment, so it is the one
     slice with release mechanics — deliberately last.

     The pinned make from `cosmos.zip` ships at `/zip/make` and
     `find_make` extracts it to `o/make` on first use, through a temp
     file and a rename so a concurrent build cannot exec a half-written
     engine. Gate: a fixture project builds and runs with `COSMIC_MAKE`
     unset — nothing installed, nothing fetched.

     **The cost, stated rather than justified away.** +765 KB on the
     release (7.89 MB → 8.66 MB), which is almost exactly the ~760 KB
     the design projected. What the design also projected is that
     stripping would pay for it, and 2c found it does not: the strip
     leaves dead space, so it recovers ~14 KB, not ~1.2 MB. So this is
     an uncompensated 10% and was accepted as one — deliberately, on
     the grounds that a build system which cannot build without a host
     toolchain is not a build system. The size table in make.md is a
     projection; the compaction that would make it true is filed
     upstream and is not a blocker.

     One thing worth knowing about the extracted engine: it is a fat
     APE, so its shell stub needs a POSIX environment to reach its
     loader. A build with `PATH` emptied entirely fails inside the
     stub, not inside cosmic. Found by writing that test too
     aggressively.

   Also closed here: **`exec` is fenced to its units**, not to `.`.
   Phase 1 stood the grant in as the whole working tree for want of any
   notion of a unit; 2d's investigation supplied one, and `unit_dir` is
   the single abstraction that investigation earned — a fence wants a
   directory where a stage wants a file list. `exec` now reads the
   units its argv touches (the program's own always included, so a step
   with no path arguments is not fenced to nothing), and a generation
   unit resolves to the directory holding its `*.gen.tl` rather than to
   the leaf.

   Three things phase 1 paid for, carried forward rather than
   relearned:

   - **fenced tests land opt-in. Landed after 2e**, having been missed
     in 2b/2c — the plan assigned it there and the slices shipped
     without it, which is recorded here rather than quietly closed.
     Two halves, and the split is the useful part:

     - **portable and unconditional:** the `test` verb points `TMP` at
       a scratch directory beside the step's own output, so a test's
       `TEST_TMPDIR` lands in `o/<test>.test.tmp.d`. Tests stop being
       able to collide through the temp directory on *every* platform,
       Landlock or not, and it needs no flag because it takes nothing
       away.
     - **kernel-enforced and opt-in:** the derived write grant is that
       same directory and nothing else, and reads are the compiled tree
       plus the test's own source directory (where `testdata/` lives,
       so fixtures need no special grant — the design's rule, stated as
       two paths). Behind `COSMIC_FENCE=1`, with an A/B canary in the
       enforce lane asserting the denial. Both canaries skip on a host
       without Landlock, which is precisely what that lane is for.
   - **skip semantics are not inherited.** `--test` propagates exit 2
     to make, so a test file that means to skip fails its rule instead
     of being graded. The `test` verb has to define this deliberately.
   - **doc churn is work, not a footnote.** retiring the Makefile
     generator meant rewriting `skills/cosmic/make.md`, deleting
     `makefile.md`, and rewriting the `--make` lines in `checking.md`,
     `formatting.md`, `testing.md`, `sys/help.md` and `AGENTS.md` — plus
     `doc/guide_test.tl`, which asserted `guide.makefile` resolves. All
     of it landed in 2a with the drop, as predicted.
3. **Dogfood.** flatten to root = module root, introduce `_` internals,
   migrate families behind `-include cosmic.mk`: packages,
   tests/examples, pins, generators, the pack. `bin/make` → `bin/cosmic`.
4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; port isolation; `--make
   explain`; single-arch artifacts.

## Open items

1. **`--make` as a name** survives though nothing makes a Makefile.
   `--build` frees up after phase 1 — worth deciding then whether to
   take it.
2. **stripped-floor risk**: `.lua/cosmo/**` may back a lazily-required
   binding. the stripped-artifact lane is the gate; anything that comes
   back comes back with a test naming it.
3. **ports** remain unfenced; `TEST_PORT_BASE` or a `net` helper later.
4. **an upstream fork knob** — a special target forcing make's slow path
   would let generated recipes drop the trailing `;` sentinel. Pure
   ergonomics now that the sentinel works, and the D14 mechanism if it
   is ever worth a release cycle.

Spawn cost is no longer open: measured at 6.4 ms per recipe line for the
assimilated ELF, the same one spawn per line this repo's recipes already
pay. See [make.md](make.md).
