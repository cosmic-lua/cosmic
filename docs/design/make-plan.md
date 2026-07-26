# Design — `cosmic --make`: delivery plan

the design is in [make.md](make.md); this is how it lands. what each
landed slice *settled* is in [make-log.md](make-log.md) (phases 1–2),
[make-log-dogfood.md](make-log-dogfood.md) (3a–3g) and
[make-log-selfbuild.md](make-log-selfbuild.md) (3h onward) — a new file
whenever one fills, since the 500-line cap applies to every tracked
file and a record only grows.

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
_cli/  args.tl  help.tl  run.tl  build/   the dispatcher, internal
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
| `3p/*/version.lua` | `*.pin.tl`, statically extracted (done, 3g) |
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

## What remains before `--make` builds cosmic

The phase's endpoint is one command producing this repo's binary, with
the checks along the way. **The command produces a binary now** (3h):

```
$ cosmic --make build
make: o/bin/cosmic
build: PASS (359 files, 1 binary)
$ o/bin/cosmic --help | head -1
cosmic-lua: cosmopolitan lua with bundled libraries
```

What remains is not the building but the *payload* — what a cosmic
carries beyond its own modules, and where each piece comes from.
Measured against the binary above rather than guessed:

| # | gap | why it blocks | evidence |
|---|---|---|---|
| ~~1~~ | ~~no entry~~ | **closed in 3h** — `cmd/cosmic/main.tl` | `build: PASS (359 files, 1 binary)` |
| ~~2~~ | ~~`_cli`/`_make` inside `cosmic/`~~ | **closed in 3h** — both at the root | `check: PASS (359 files)` |
| 3 | `tl.lua` is not in the tree | the artifact ships what the tree provides; tl arrives as a *tarball* beside its pin | no `tl.lua` in the built artifact; `fetch` downloads, it does not extract |
| 4 | the type tree's location | assets ship at their relative path (`/zip/_types/**`), but 3d put the payload at `/zip/.types/` to keep it out of the module root | no `.types/` in the built artifact |
| 5 | the docs index | a generation unit, and `regen` is not implemented | no `.docs/index.lua` in the built artifact |
| 6 | `cosmic.mk` and `make` | the code reads them at `/zip/cosmic.mk` and `/zip/make`; as assets they would land at `/zip/_make/cosmic.mk` | `RULES_ZIP`/`MAKE_ZIP` in graph.tl; neither path exists in the built artifact |
| 7 | the version stamp | still minted by a shell recipe reading `git describe` | the built artifact's `--version` prints `Lua 5.4` |
| 8 | the base is not selectable | `artifact.build` always passes the running cosmic | `embed.run(dir, out, cosmic, …)` |
| 9 | **the artifact ships the repo** | every non-source file is an asset at its relative path, so the repo's own build files ride along. The big one is closed: the make engine moved from `bin/cosmo-make` into `o/`, where nothing generated is ever an input (−751 KB) | remaining asset weight: `docs` 169 KB, `_perf` 91 KB, `_build` 60 KB, `mk` 23 KB |

Items 3–7 and 9 are what 3i means by "the verbs take over": each is a
capability `--make` has to *have*, not a migration. Item 8 is the one
genuinely open design question — cosmic building cosmic bases on a
cosmic, strips to the floor, and re-adds its own `cosmic/**` (which 3a
makes legal); whether that is right, or whether a project should be able
to name its base, is undecided. Item 9 carries a second one: a
`.cosmicignore` entry removes a path from the **model**, not only from
the artifact, so ignoring `bin/` also hides it from `check`, `lint` and
the coverage scan — whether "not shipped" and "not seen" should be one
knob is undecided too.

Testing along the way is in better shape than building: `--make test`
runs today, and the repo's own tests already take their closures from
the same model (3f). What `bin/make ci` still owns beyond it are the
policy lanes — coverage, enforce, reproducible, offline — which the
design puts in phase 4 as verbs.

## Fixtures

`_make/testdata/**` holds hello-world-sized projects, one per
behaviour, each checked, built and *run* by `fixtures_test.tl`:

| fixture | what it pins down |
|---|---|
| `hello/` | the smallest project that is one: entry → `o/bin/hello` |
| `pkg/` | import path is position (`greet/init.tl` is `greet`) |
| `multi/` | two `cmd/` binaries, shared root packages, no cross-imports |
| `luaonly/` | `.lua` sources are first-class |
| `assets/` | an asset ships at its relative path; `testdata/` never ships |

They are committed rather than written inline by the test because they
double as the examples a person reads, and they are built with the same
two commands a user would type. Being real projects under `testdata/`,
they are invisible to this repo's own model — which is what `testdata/`
is for, and is now also why the source-reachability ratchet and the
coverage scan skip it.

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
     already there. **Hoisting `cosmic/cli/` and `cosmic/make/` to root `_cli/`
     and `_make/` is deliberately not here.** Those two are not position
     changes but *surface* changes, so 3c marked them internal in place;
     the hoist itself needs an entry outside `cosmic/` to justify it and
     lands in 3h. Gates: `bin/make ci` green, and `cosmic
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
     the hoist waits for an entry outside `cosmic/` to need it (3h), and
     for the searcher question the embed wrapper forces (settled in 3g).
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
   - **3e — the compiles take the generated closures. Landed.** the
     bridge turns out to have two halves, and only the first can land
     now: the Makefile `-include`s the generated **facts**
     (`o/project.mk`) and keeps its own rules. The **rules** half
     (`-include o/cosmic.mk`) waits for 3i, because that file's
     `build`/`test`/`fmt` targets collide with the ones the Makefile
     still defines — including it would silently redefine `test`.
     Adopting the facts is not a consolation prize: `$$(srcdeps_$$*)`
     fixes in this repo the exact correctness bug 2b found for `--make`,
     reproduced here first (delete an exported function and
     `make o/_build/lint.lua` says "up to date" and exits 0, while the
     same target from scratch fails the type check).
   - **3f — tests and examples take their closures. Landed.** the same
     shape as 3e, one lane over: the test and example rules take
     `$$(deps_$$*)` — the *built* closure — and the per-module test
     dependencies each `cook.mk` declared by hand retire. It closes a
     gate that was open: a test resolves an unlisted import through the
     runtime `.tl` searcher, which compiles **lax**, so a module failing
     its **strict** compile could still have a passing test. The `test`
     verb itself, the fence, and moving the ratchet tests to the root
     wait for the rules half of the bridge (3i) — same blocker as 3e.
   - **3g — the searcher is public, and the pins are data. Landed.**
     Two things. **The searcher** (`cosmic/_cli/searcher.tl` →
     `cosmic/searcher.tl`): the generated embed wrapper requires it in
     every artifact ever built, so the module with the widest caller set
     in the tree was the one marked internal. Third instance of one rule
     (`cosmic.style` in 3c, the searcher noted in 3a) — who requires a
     module decides whether it is internal — and the precondition for
     the hoist, since at root it would sit outside the `cosmic/**` strip
     floor and every stripped artifact would fail to boot.

     **The pins**, which an earlier pass of this plan had moved to 3i as
     "blocked on the fetch verb" and which were not: `3p/*/version.lua`
     → `3p/cosmos/cosmos.pin.tl` and `3p/tl/tl.pin.tl`, read by the same
     grammar `--make fetch` uses. What the repo needed was not the verb
     but a *reader* both sides can call — the fourth instance of the
     rule above, so `cosmic.literal` is public and `cosmic._make.pin`
     keeps only what is specific to a pin.

     Closed out by a **bootstrap bump to a release cut from this
     branch** (`2026-07-26-5de5474`), which put that reader in the
     stdlib the trust root runs against. `_build/make-boot.tl` — the
     last place that executed a pin, and unconvertible until then
     because it runs with `LUA_PATH=";;"` before the tree exists — reads
     one now. **Nothing in the build executes a pin:** not the trust
     root, not fetch, not stage, not the version stamp. The bump was
     verified the way phase 1's lesson says to, from nothing:
     `rm -rf o bin/cosmo-make && bin/make build && bin/make ci`.
   - **3h — the entry and the hoist. Landed.** `cmd/cosmic/main.tl` is
     the binary's entry and `cosmic/_cli/`, `cosmic/_make/` are root
     `_cli/`, `_make/` — gaps 1 and 2, and with them `cosmic --make
     build` produces a running `o/bin/cosmic`. The two were one change:
     root-level is what an entry *outside* `cosmic/` needs.

     What the hoist cost, and it is the substance of the slice: with
     two trees out of `cosmic/`, the validator refused **seven imports
     across four modules**, each a module marked internal to `cosmic/`
     with a caller outside it. Two left (`cosmic._build` →
     `_cli/build/`, `cosmic._require` → `_cli/require_hints.tl`; no
     in-`cosmic/` caller, and both leave the strip floor, so no user
     artifact carries the `--build` vocabulary any more). Two could
     not, because `cosmic.testrun` and `cosmic.searcher` are public and
     require them — inside `cosmic/` and not internal to it leaves one
     position, so `cosmic.instrument` and `cosmic.script_cache` are
     **public**, each with the example the closed coverage ratchet
     demands. Fifth application of "who requires a module decides
     whether it is internal", and the first where a position change
     asked the question instead of a person noticing.

     Also here because the hoist broke it: the pack **derives** its zip
     groups from the staging tree now. It enumerated top-level names,
     its own comment named the hazard, and this was the second time
     that silently dropped files — 3d lost `tl.lua` and the type tree,
     3h lost every compiled `_cli/**` and `_make/**` module and still
     produced a binary that booted.
   - **3i — the verbs take over, and the bridge goes.** `-include
     o/cosmic.mk` once the Makefile's own `build`/`test`/`fmt` targets
     retire; `--make fetch` replaces `_build/build-fetch.tl` (the
     pins themselves are already `*.pin.tl`, done in 3g); `regen` runs the
     generation units, which is what lets `_types/*.d.tl` stop being
     committed. Then `bin/make` → `bin/cosmic`, and `mk/`, `cook.mk`
     and the ratchets the closed vocabulary makes moot go with it.

     **Generators moved here from 3g; the pins did not.** The pins
     looked blocked for the same reason: converting them means
     something must read them, and the only reader was
     `cosmic._make.pin`, which `_build/build-fetch.tl` cannot import
     from outside `cosmic/`. That reasoning was one step short — what
     the repo needed was not the *verb* but the *reader*, and promoting
     it (`cosmic.literal`) unblocked the conversion in 3g without
     waiting for anything. The generators are genuinely blocked, and on
     something more specific than "a verb": `regen` does not exist yet,
     and un-committing `_types/*.d.tl` needs it to.
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
