# Phase 3i: removing the Makefile bridge

Phase 3 landed every slice **behind** the existing build: `-include
cosmic.mk` is the bridge, and `bin/make ci` stayed green through all of
it. 3i is the slice that removes the bridge — and it is the one phase
where "land it behind the existing build" stops being available, because
the existing build is what goes.

So it is sequenced rather than attempted. This file is the sequence: the
mechanism it runs inside, the gaps each step has to close first, and the
exit criterion for each. The design itself is [make.md](make.md); the
phase list is [make-plan.md](make-plan.md).

## The mechanism

**A dual gate.** Add a pr.yml lane running `cosmic --make ci` **beside**
`bin/make ci`, both required. Every bridge-removal slice lands behind
both gates green — the same discipline phase 3 used, now with the
replacement also gating. The lane starts as `check` + `test` + `build`
and grows a stage per delivered verb. The Makefile's gate is deleted
only when the two have been redundant for a full cycle.

**Why a dual gate and not a cutover:** a gate that cannot report its own
absence goes quietly decorative. That is not hypothetical here — audit
029 hardened graph tests to hard-fail in CI instead of skipping, and its
very first CI run caught the 027 payload gate silently skipping in every
prior run. Two gates that must agree is the shape that survives one of
them being wrong.

### Measured: what `--make test` does to this repo today

The plan used to say `--make test` "runs today" with nothing recording
a full run. It has now been run over the whole tree, from a clean
`git archive` copy seeded by `--make fetch` alone:

```
bin/make test        173 checks: 173 passed
cosmic --make test   173 checks: 121 passed, 46 failed, 6 skipped
```

**Discovery parity is exact** — the same 173 targets, `.lua` tests
included. That is the half worth checking first, because a test set that
silently shrinks is the failure mode nobody notices.

The 46 failures are **not 46 defects**. They reduce to a handful of
causes, and every one of them is the harness the Makefile provides and
`--make test` does not:

| n | cause | what it means |
|---|---|---|
| 25 | `command not found: cosmic` (incl. `cosmic-debug`) | a test spawns the binary under test. `bin/make` puts it on the lane's `TEST_BIN`/`PATH`; `--make test` passes no such thing. **This is the single change that moves the number most** — the test verb needs a defined answer for "which binary is under test". |
| 4 | staged 3p trees (`TEST_DIR`, `o/tl/.staged`) | fixtures the Makefile's stage rules produce, not `fetch`'s landing layout |
| 3 | Makefile-only fixtures (`database.out`, `dry-run.out`, reporter PASS) | these tests test the MAKEFILE; they retire with it |
| 2 | `exec failed: EACCES` | the exec fence's resolution differs from the Makefile lane's |
| ~12 | assorted: `o/make` extraction, facts write paths, orphan-root discovery, symlink stat | individually small, each needing its own look |

So the honest status is: the graph and the discovery are right, and the
**test-execution environment is the gap**. That is a much smaller thing
than "the suite does not pass", and it is a prerequisite for the dual
gate rather than a blocker for the phase — the lane can start at
`check` + `build` and add `test` when the environment is defined.

**A disposition table.** Every `##`-documented target gets a recorded
fate *before* deletion — the inventory is the Makefile, `mk/*.mk`,
`cook.mk`, and the module `cook.mk`s:

| fate | targets |
|---|---|
| verb, exists | build, test, clean, fetch/staged, format→fmt, teal→check |
| verb, needed | ci, example, lint, coverage, coverage-baseline, regen-types→regen, docs/doc-publish, benchmark/perf* |
| dissolves | model (is `check`), facts (the graph is the facts), bootstrap (the trust-root swap), help (usage + skills) |
| stays outside the build | doc-publish's git push (a workflow step); the perf harness's orchestration if it does not become a verb — **decide, do not drop** |

`_perf`'s targets are the easiest to lose by accident: no CI lane runs
them, so nothing fails when they break. Their home is part of the table,
not an afterthought.

## Deletion order

Dependencies, not preference. Each arrow is "cannot start until":

```
029 hard-fail (done)
  → dual-gate lane
  → verb parity          (ci, example, lint, coverage)
  → generation workflows (regen, docs)
  → fence default        (enforcement parity)
  → release parity
  → trust-root swap
  → delete the Makefile, mk/, cook.mk, the -include bridge,
    _build/build-fetch.tl, the --build flag, and
    makefile_ratchet_test.tl — the ratchet retires WITH the file it
    guards, last.
```

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

Also in the gate's orbit: pr.yml's `enforce` lane, and its
`reproducible` lane, which builds twice with an **alternate output
directory** (`o=o2`) — a Makefile feature `--make` has no spelling for.
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
documented exception. Either is coherent; pick one in make.md's table.

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

Both are scheduled here rather than settled in make.md, because neither
can move while two pipelines read the same committed files — and after
this phase only one does.

- **The landing name comes from the url's tail** (the ⚠ in make.md's
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

## The lanes themselves

Each pr.yml lane carries real logic as YAML-embedded bash — which is
exactly the orchestration the design assigns to policy verbs. Logic in
YAML is unrunnable locally, unversioned by the verbs' tests, and
per-forge. The convergence target is that every job is checkout + setup
+ **one verb**, with the YAML as transport:

| YAML today | destination |
|---|---|
| offline: `bin/make staged` online, then `unshare --net` + `bring_up("lo")` + the gate | the `offline` verb — the netns bring-up is already cosmic code, so the verb owns it |
| reproducible: build, `cp`, `o=o2` build, `cmp`, echo a verdict | the `reproducible` verb (double-build + compare is also what `_make/fixpoint_test.tl` does for the `--make` artifact — two mechanisms today, one verb at the end) |
| enforce: `make enforce` + `make sandbox-canary` + always-dump | the `enforce` verb, canary included, printing its own evidence |
| build: "dump failing test output" (find + cat over `.got`/`.out`/`.err`) | **the reporter.** A failing `--make test`/`ci` should print the failing tests' captured output itself; the dump step exists because the summary does not, and every other consumer of the gate — a laptop, a downstream repo — lacks it too |
| smoke matrix assertions | mostly fine as YAML (real cross-OS runners are the point), but the assertion list duplicates what `_make/fixpoint_test.tl` smokes — worth one committed portable smoke script both invoke |

Do the reporter piece **first**: it is verb-independent, it shrinks
every lane, and it improves the local experience today. As each policy
verb lands, delete the corresponding YAML in the same change — the
verb's exit criterion includes "the lane is one line".

## Two properties worth asserting rather than hoping

**The gate needs no git.** CI carries git plumbing because two recipes
shell out to git from inside the sandboxed build: `git ls-files` (lint's
file discovery, hence `safe.directory` in every lane) and `git describe`
(the Makefile-path version stamp, hence `fetch-depth: 0` in docs.yml).
Both are already scheduled to dissolve — the `--make` stamp reads a
committed `.version` (D16), and a `lint` verb discovers files from the
**model**, which computes exactly the tracked-shaped set minus `o/`.
What must *not* dissolve is docs.yml's push, which is a real git
operation and stays a workflow step.

This is a meaningful property, not tidiness: each git exec is host
surface inside a sandboxed recipe and a hostx grant the ratchets must
enumerate, and a git-free gate runs in a barer container, on a tarball
checkout, and under the derived fence without a git-shaped hole in its
floor. It is also easy to lose by accident — one new recipe that shells
to git re-acquires the whole apparatus. **Exit criterion for the gate:**
`bin/cosmic --make ci` passes in a container with no git installed, and
the fence refuses `git` as a recipe child.

**Coverage's environment-sensitivity is the root of the pinning.** Two
of CI's heaviest complications exist to hold the coverage ratchet's
inputs still: the digest-pinned container (an OS image roll moved the
floor) and the non-root builder in every lane (tests skip differently as
root). Both treatments are correct given the ratchet's design. The shape
to notice is that an environment-sensitive metric forced CI to pin the
environment *twice*, and each newly discovered sensitivity adds another
pin.

Options, none free:

1. **Skip-aware coverage** — exclude lines inside a test that reported
   skip (status 2) from the denominator, so a skipped path moves no
   floor. Requires the collector to know test boundaries; it may
   already, via the per-test `.got` contract. This is the structural
   fix if the data supports it.
2. **Floor on the intersection** — ratchet against lines covered in
   *every* lane, so environment-variable lines fall out by
   construction. Costs cross-lane aggregation.
3. **Accept and document** — keep the pins and add the missing half: a
   recorded inventory of known environment-sensitive tests, so the next
   floor churn is diagnosable in minutes instead of rediscovered. Cheap,
   and worth doing regardless of 1 and 2. The inventory lives in
   [`cosmic/coverage/SENSITIVITY.md`](../../cosmic/coverage/SENSITIVITY.md).
