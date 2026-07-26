# Phase 3i: parity, gap by gap

What each Makefile lane does that a verb does not do yet, and the exit
criterion for closing it. The sequence these plug into is
[bridge.md](bridge.md).

## Verb parity

`bin/make ci` is the repo's only gate: format + teal + model + test +
example + lint + coverage, parallel, ending in a `ci: PASS/FAIL` verdict
line that CI parses. pr.yml runs nothing else. `--make` has three of
those stages.

Missing: **`ci`** itself (the fixed order with per-stage material
gating, and the verdict-line contract); **`example`** and **`lint`**,
both now named in the planned verb set; **`coverage`** plus the
`coverage-baseline` rewrite flow, which needs a home (a verb option or a
documented flag). The **`model`** stage dissolves — running `--make
check` from `--make ci` is just a stage.

Also in the gate's orbit: the enforce and reproducibility steps of
pr.yml's `build` lane. The reproducibility one builds twice with an
**alternate output directory** (`o=o2`) — a Makefile feature `--make`
has no spelling for.
The `reproducible` verb needs either an out-dir override or a different
mechanism for building one tree twice into comparable paths. And
`bin/make test only=<substring>`: path selection is the designed
replacement and is strictly finer, so there is no gap — but the habit
and the skill docs need the translation.

**Exit:** `cosmic --make ci` runs all seven stages' worth of checking on
this repo, gated by material, ending in the same machine-readable
verdict, and a pr.yml lane runs it.

## Enforcement parity

The repo's *enforced* sandboxing lives in the Makefile world: per-rule
`.PLEDGE`/`.UNVEIL`/`.ENV`, exercised under `.SANDBOXED := 1`, plus the
hostx ratchet and the sandbox-canary that proves the mechanism is live.
The `--make` replacement — grants derived per verb, applied by `cosmic
-c` — is opt-in (`COSMIC_FENCE=1`).

Delete the `.mk` files before the derived fence is the default and the
project goes from "an undeclared read fails CI on a Landlock host" to
"nothing is enforced anywhere". The design promises the derived fence
*replaces* the annotations; the order of operations is what keeps that
promise true at every commit.

What has to land first:

1. ~~The fence floor covers the compile verbs' real reads.~~ **Done**
   (audit 014): `tlconfig.lua` and the include directories are granted,
   derived from `cosmic.teal` rather than listed.
2. ~~A Landlock-host CI lane runs a real compile under
   `COSMIC_FENCE=1`.~~ **Done**: the enforce lane asserts both
   directions — a denial, and that a real compile still succeeds. A
   fence that denies everything is not enforcement, and a denial test
   alone cannot tell the two apart.

   Adding the second direction found two real things, which is the
   argument for it:

   - The floor handed Landlock `/zip/.types` — a path *inside the
     executable*, where `fs.isdir` says yes and the kernel knows
     nothing — so the whole policy failed to construct with `EBADFD`.
     A fence that cannot be built is worse than one that is too wide:
     it fails on correct input.
   - A fenced child today must be an **assimilated ELF**, not a fat
     APE: exec'ing an APE needs a loader, and the search falls back to
     `~/.ape-*`, which no grant covers. The repo already relies on this
     — it is why `o/bin/cosmic-check` exists and why `bin/make`
     assimilates the bootstrap — but the canary passed the APE, because
     nothing had ever forced the question.

   Both were invisible until a test required a fenced child to
   **succeed**: the two pre-existing fence tests pass whether or not
   their child runs at all (one expects a denial, the other's verb
   records rather than grades). A mechanism exercised only in its
   failing direction is one nobody has checked.

   **The better answer is the loader, and it is already in `o/`.**
   `o/bin/ape` is a plain ELF the build stages, and
   `o/bin/ape <fat APE> …` runs — so a fenced recipe could exec any
   pinned APE with two grants and no duplicate binary. What blocks it is
   the recipe vocabulary, not the fence: a verb line names one program,
   and there is no way to say "run THIS through THAT loader". Putting
   the loader on `PATH` is not a substitute — it was tried, and the
   fenced exec still failed, because the stub's search is not what a
   direct shell-free exec goes through. So the choice is between
   assimilating a duplicate (what happens now, at the cost of a second
   copy of the binary on disk) and teaching `exec`/`compile` to prefix
   the staged loader when the program is an APE. The second is the one
   that scales to a project pinning its own tools, and it wants doing
   before the fence becomes the default.
3. The fence becomes the default for `-c`, as its own change, with the
   same denial produced by the portable in-process gate on
   non-Landlock hosts.
4. Only then do `.PLEDGE`/`.UNVEIL`/`.ENV`, `.SANDBOXED`, the hostx
   ratchet and the canary retire, with the `.mk` files.

**Exit:** a CI lane demonstrates a denied undeclared read under the
derived fence, on a real recipe, before the first `cook.mk` annotation
is deleted. The enforcement gap between the two systems is never open
at HEAD.

## Generation workflows

`bin/make regen-types` / `regen-tl-types` rewrite the committed
`_types/*.d.tl` from the pinned cosmos/tl, with drift tests failing on
divergence. This is the **pin-bump workflow**: without it a cosmos bump
cannot be landed, so retiring the Makefile before `regen` exists orphans
it entirely. `_types/` becomes generation units run by `regen`.

**The `.d.tl` decision has to be recorded, not defaulted.** The design
says generated outputs are never committed, which means un-committing
`_types/*.d.tl` and accepting the cost (a fresh clone cannot read
`cosmo.*` types without building; editors need `o/` on the include
path). The alternative — keep them committed with the byte-drift test,
regenerated by `regen` — preserves today's ergonomics at the cost of one
documented exception. Either is coherent; pick one in [choices.md](choices.md).

`bin/make docs` / `doc-publish` generate into `o/docs` and push to the
`docs` branch. The coherent split: `--make` produces `o/docs/**`, and
the **push stays a workflow step**, because it needs credentials and a
network. Say so, so nobody tries to give the build a git verb.

`bin/make facts` dissolves — the graph is the facts.

A `regen`-run unit is also the first real consumer of the portable
in-process gate on non-Landlock hosts, so this shares a milestone with
the fence work above.

**Exit:** a cosmos pin bump lands using only `bin/cosmic` + `--make`
verbs (fetch → regen → test), and docs.yml publishes from a
`--make`-produced `o/docs`.

## Release parity

release.yml runs `bin/make -j teal test build` and ships **two**
binaries — `cosmic-lua` and `cosmic-lua-debug`, the same payload on a
different base — plus SHA256SUMS.

1. **No debug-variant concept.** A `--make` binary unit has one output
   and one `base`; nothing in the model expresses "this unit, twice, on
   two runtimes". Options: a second entry (`cmd/cosmic-debug/` with a
   two-line `embed.gen.tl` reusing cosmic's payload — works today,
   duplicates the unit), or a variant concept (an output directory
   holding `base` and `base-debug`, producing `o/bin/<name>` and
   `o/bin/<name>-debug`). Decide deliberately: the release shape is a
   public contract.
2. ~~Artifact weight.~~ **Resolved structurally** by D15: shipping is
   opt-in, so the `--make` artifact no longer carries `docs/`, `mk/`,
   `_perf/` and the Makefile as implicit assets. Re-measure against the
   Makefile's output before switching builders.
3. **No parity gate.** Before release.yml switches builders, a lane
   should build both and compare: the same zip entry set (minus decided
   deltas), both passing the smoke assertions, sizes within an explained
   budget. Entry-set comparison is specifically the test that catches
   the class that bit twice — 3d lost `tl.lua` and the type tree, 3h
   lost every compiled `_cli/**` and `_make/**` module, and both shipped
   a binary that booted.

**Exit:** release.yml produces both artifacts via `cosmic --make`, and
the parity lane has compared them against the Makefile's output for at
least one release cycle.

## The trust-root swap

The end state is a committed POSIX-sh `bin/cosmic` whose one job is to
fetch the pinned cosmic and exec it: kernel → fetcher → **one** pin →
everything. Today the trust root is `bin/make`, its url and sha live in
`cook.mk` (a file scheduled for deletion), and it provisions *two*
artifacts — the bootstrap cosmic and the make engine from cosmos.zip.
The engine half is already obsolete: cosmic extracts its embedded make
to `o/make` itself.

The work: `bootstrap/cosmic.pin.tl` in the same grammar as every pin;
`bin/cosmic` to fetch, verify, cache and exec with argv passed through;
and the cold-start gate moves to `rm -rf o && bin/cosmic --make ci` —
verify the swap from a clean tree, not an incremental one, which is 3g's
lesson.

Small features die with `bin/make`, and each loss should be **chosen**:
`help` (the `##`-comment catalog → `--make` usage + the skill docs),
`only=` (→ path selection), the `bootstrap` target, `TMP=` and
`INCLUDE_DIRS` (→ env the verbs already read, documented), and `o=`
(→ the reproducible verb's out-dir question above).

Workflow rewiring is incremental: pr.yml, docs.yml and release.yml each
switch to `bin/cosmic --make <verb>` as their lane's verbs land, not in
one big-bang commit.

**Exit:** a fresh clone with a network runs `bin/cosmic --make ci` to
green with nothing else on the host; `bin/make`, `cook.mk`'s bootstrap
block, and the second pin are deleted in the change that flips the last
workflow.

## The pin grammar's two frays

Both are scheduled here rather than settled in the model, because neither
can move while two pipelines read the same committed files — and after
this phase only one does.

- **The landing name comes from the url's tail** (the ⚠ in [model.md](model.md)'s
  units table), which is why url-name validation has to exist at all and
  why an on-disk name is coupled to a remote server's path layout.
  Retire it positionally: `3p/tl/tl.pin.tl` + `tar.gz` →
  `o/3p/tl/tl.tar.gz`, with an optional `output` field for archives
  whose inner layout makes the name matter. The url becomes purely
  *where the bytes come from*, and the guard's reason to exist
  disappears rather than being hardened. Close the ⚠ in the same change
  — the table row becomes true again, which is worth a line in the log.
- **Integrity has two spellings**, flat `sha` and the `platforms` table,
  so one committed file can satisfy both readers. A pin that must be
  written twice can disagree with itself. Keep `platforms` (with `*` as
  the single-platform case), refuse the other with a pointer.

The reader is already shared (`_make.pin`, called by both pipelines), so
what is left is a grammar change with one implementation to change.

