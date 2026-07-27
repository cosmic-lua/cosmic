# Phasing

The five phases, with what each one landed. Phases 1–3 are the record of
work done; 4 and 5 are the plan. A phase's *reasoning* — what it
predicted and what actually happened — is in [log/](log/).

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
     → `3p/cosmos/cosmos_pin.tl` and `3p/tl/tl_pin.tl`, read by the same
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
     position, so `cosmic.instrument` is
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
   - **3i — the verbs took over, and the bridge went. Landed.** The
     Makefile, `cook.mk`, `mk/**`, the seven module `cook.mk`s,
     `bin/make`, the Makefile's fetch/stage/pack pipeline and its
     reporter, the tests that tested the Makefile, and the `--build`
     flag are all deleted. A cold checkout runs `bin/cosmic --make
     fetch`, `--make build`, then gates with the binary it just built.
     `bin/cosmic` is the trust root and carries the one pin.

     What it taught, beyond the sequence in [bridge.md](bridge.md):

     - **The gate has to run under the binary the tree BUILDS.** Modules
       resolve from the artifact before the tree, so a gate run under
       the pinned cosmic measures the PIN — it ran the released
       formatter over a formatter fix and passed. Six checks reporting
       on code that was not under test.
     - **The Makefile had been covering real defects**, all in coverage.
       It measured almost nothing under `--make` (chunks arrived as
       `/zip/...` and were dropped as absolute paths, so the ratchet
       held a floor over data it never collected); the coverage lane
       never put binaries on PATH, so every test that spawns the binary
       under test failed there and only there; `.tl` under `o/` are
       staged COPIES and were counted as sources; and a `./` prefix made
       every file read as new.
     - **Varying the tree PATH in the reproducibility check** — not just
       the output directory, as `o=o2` did — immediately caught a real
       one: `o/embed/` is both the root unit's generated-payload
       directory and where the build writes its bookkeeping about
       `embed/**`, so a lint run before a build shipped
       `cosmic.mk.lint.got` inside the binary.
     - **A pin older than a build-system change cannot build the tree.**
       The pin predated the `*_pin.tl`/`*_gen.tl` rename, so it read the
       tree as having no pins and no generator and produced a bare Lua
       interpreter. The deletion had to wait for one release in between,
       and a release is built in two generations for the same reason.

4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; port isolation; `--make
   explain`; single-arch artifacts.
