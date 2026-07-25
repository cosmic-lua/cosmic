# Design — `cosmic --make`: delivery plan

the design is in [make.md](make.md); this is how it lands. what each
landed slice *settled* is in [make-log.md](make-log.md) (phases 1–2)
and [make-log-dogfood.md](make-log-dogfood.md) (phase 3) — one file per
phase, since the 500-line cap applies to every tracked file and a
record only grows.

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
  which is why this design is four documents and counting
- validator messages asserted: reserved import path,
  `cmd/foo`→`cmd/bar`, `foo.tl`+`foo.lua`, missing entry, space in
  filename, ambiguous root, internal import
- spawn-cost budget: `cosmic -c` under `-j`, reported in phase 1

## Phasing

1. **`-c` shell mode — landed, except the fence default.** the closed
   verb vocabulary, the trailing-`;` sentinel, `exec`'s pinned-only
   resolution, grants derived per verb, `SHELL := $(bootstrap_cosmic)`.
   The fence is opt-in (`COSMIC_FENCE=1`) behind a canary; making it the
   default is its own change. Still open here: the portable in-process
   gate, which only matters once generator and test units exist.
2. **User-facing `--make` — landed, 2a through 2e.** the phase that
   answers the original ask. 2a project model and `check` (the old
   Makefile generator dropped whole); 2b the graph — constant
   `o/cosmic.mk` plus generated `o/project.mk` facts, with per-target
   dependency closures; 2c the artifact — compile → stage → embed →
   `o/bin/<name>`, stripped and reproducible; 2d pins and `fetch`, the
   only networked verb; 2e the embedded engine. Fenced tests and
   `exec`'s unit fence closed after 2e.
3. **Dogfood — build this repo with `--make`.** the phase where the
   design meets the tree it was written for. It inverts phase 2's risk
   profile: nothing here is user-facing and every slice can take the
   build down, so each lands *behind* the existing build rather than
   replacing it — `-include cosmic.mk` is the bridge, and `bin/make ci`
   stays green through every step. The last slice is the one that
   removes the bridge.

   - **3a — the provider exemption. Landed.** `--make check` refused
     this repo's own stdlib 290 times over one rule, exactly as 2a
     predicted. `cosmo` and `main.user` are native and generated, so
     nothing can provide them and they stay unconditionally reserved;
     `cosmic` and `tl` are Lua trees a project may claim by defining the
     namespace's root module, which the design already requires of both.
     Partial provision stays refused — that is the shadow the rule was
     written for. The artifact half (a claimed namespace drops the
     base's floor copy) is what keeps the validator half honest.
   - **3b — the flatten. Landed.** `lib/cosmic/` → `cosmic/`,
     `lib/build/` → `_build/`, `lib/types/` → `_types/`, `lib/perf/` →
     `_perf/`, `lib/docs/` → `_docs/`, `lib/cook.mk` → `mk/modules.mk`.
     `_` arrives *with* the move rather than after it, because
     `lib/docs/` cannot pass through `docs/` — the markdown tree is
     already there. **`cosmic/_cli/` → `_cli/` and `cosmic/_make/` →
     `_make/` are deliberately not here**, and move to 3c: those two are
     not position changes but *surface* changes — they are how the `_`
     prefix replaces `public.tl`'s internal list — so they belong with
     the slice that deletes it. Gates: `bin/make ci` green, and `cosmic
     --make check` at the root **PASS (349 files)** — the phase's
     milestone, and the first time the model has described the repo it
     was written for.
   - **3c — `_` replaces `public.tl`. Landed.** position becomes the
     manifest: the public surface and what the docs generator documents
     both derive from "public is `cosmic.<name>` with no `_`".
     `cosmic/cli/` → `cosmic/_cli/`, `cosmic/make/` → `cosmic/_make/`,
     `cosmic/build/` → `cosmic/_build/`, `require.tl` → `_require.tl`,
     and the generated version stamp to `cosmic/_version.lua`.
     `public.tl` is deleted; its lint becomes `surface_test.tl`, which
     asks what the manifest was a *means to* rather than whether the
     manifest is current. Marked **in place, not hoisted to the root** —
     the hoist is 3d's, since the embed wrapper in every artifact
     requires the searcher and the floor is `cosmic/**`.
   - **3d — the pack. Landed.** `/zip/.lua/cosmic/*` → `/zip/cosmic/*`
     and `/zip/.lua/tl.lua` → `/zip/tl.lua`, so the zip root is the
     module root inside the artifact too. Touches the searcher's
     include dirs, the floor's prefixes, the pack's three zip groups,
     and `package.path` itself — cosmopolitan's default is
     `/zip/.lua/`-rooted, so the entry has to insert the zip root ahead
     of it. That is what makes 3a's provider rule load-bearing rather
     than theoretical: before the move a project's `cosmic/` and the
     base's `.lua/cosmic/` did not collide at all. **The entry and the
     hoist moved out**, to 3h.
   - **3e — compiles behind `-include cosmic.mk`.** the first family to
     move: `$(o)/%.lua: %.tl` becomes cosmic.mk's rule driven by
     `o/project.mk`'s facts. The bridge direction is the point — the
     Makefile includes the generated rules, so a family that has not
     moved still builds the old way.
   - **3f — tests and examples.** the `test` verb against the staged
     tree, with the fence. This repo's ratchet tests read the live tree,
     so they move to the root — the consequence make.md already records.
   - **3g — pins and generators.** `3p/*/version.lua` → `*.pin.tl`;
     `gentype`, `gentl`, the doc index and the version stamp become
     `*.gen.tl` units. This is where "nothing generated is committed"
     bites: `_types/*.d.tl` stop being committed files, which the
     design names as its own sharpest edge.
   - **3h — the entry and the hoist.** `cmd/cosmic/main.tl` becomes the
     binary's entry, and `cosmic/_cli/` and `cosmic/_make/` hoist to
     root `_cli/` and `_make/`. The two are one change: root-level is
     what an entry *outside* `cosmic/` needs, and both are what
     `--make build` needs before it can build this repo. It is also the
     change that decides where the searcher lives — the embed wrapper
     requires it in every artifact and the strip floor is `cosmic/**`,
     so hoisting `_cli/` out of `cosmic/` makes `cosmic/searcher.tl`
     public, the same way 3c made `cosmic/style.tl` public.
   - **3i — `bin/make` becomes `bin/cosmic`.** `mk/`, `cook.mk` and the
     ratchets the closed vocabulary makes moot go with it. Last by
     construction: it removes the bridge.
4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; port isolation; `--make
   explain`; single-arch artifacts.

## Open items

1. **`--make` as a name** survives though nothing makes a Makefile.
   `--build` frees up after phase 1 — worth deciding then whether to
   take it.
2. ~~stripped-floor risk~~ — **closed in 2c.** this base carries no
   `.lua/cosmo/**` at all, so there is nothing to strip; the
   stripped-artifact lane is in place regardless, and anything that
   comes back comes back with a test naming it.
3. **ports** remain unfenced; `TEST_PORT_BASE` or a `net` helper later.
4. **an upstream fork knob** — a special target forcing make's slow path
   would let generated recipes drop the trailing `;` sentinel. Pure
   ergonomics now that the sentinel works, and the D14 mechanism if it
   is ever worth a release cycle.

Spawn cost is no longer open: measured at 6.4 ms per recipe line for the
assimilated ELF, the same one spawn per line this repo's recipes already
pay. See [make.md](make.md).
