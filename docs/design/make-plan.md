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
   - **2c — the artifact.** compile → stage → embed → `o/bin/<name>`,
     stripping to the floor, reproducibility (the `AddOptions.mtime`
     plumbing), `cmd/` multi-binary. This is the slice where a tree of
     `.tl`/`.lua` plus tests becomes an executable.
   - **2d — pins and `fetch`.** `*.pin.tl` static extraction and the
     network-only-under-`fetch` posture.
   - **2e — embedded make.** packing it into the release, which user
     projects need and this repo does not (it has `bin/cosmo-make`).
     Carries the D13 amendment, so it is the one slice with release
     mechanics — deliberately last.

   Three things phase 1 paid for, carried forward rather than
   relearned:

   - **fenced tests land opt-in.** 2b/2c introduce the test fence
     (writes to `TEST_TMPDIR`, reads to the staged subtree). Nothing
     available here can enforce Landlock, so it ships behind the flag
     with a canary in the enforce lane, and the default flips only
     after that canary asserts.
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
