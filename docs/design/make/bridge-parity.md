# Phase 3i: parity, gap by gap

What each Makefile lane did that a verb did not, and what closing it
took. The Makefile is gone, so what follows is the record plus the rows
still open; what the removal TAUGHT is 3i in [phasing.md](phasing.md).

## Verb parity — closed

`--make ci` runs six stages in a fixed order — fmt, check, test,
example, lint, coverage — ending in the `ci: PASS/FAIL (stages)` verdict
line CI parses. The old `model` stage dissolved, as predicted: running
`--make check` from `--make ci` is just a stage. `coverage --baseline`
is where the rewrite flow landed.

The reproducibility step built twice with an **alternate output
directory** (`o=o2`), which `--make` has no spelling for. It did not need
one: building the same tree at two different PATHS is a stronger check,
because an absolute path leaking into the artifact only shows up when the
root moves — and switching to it immediately caught one that `o=o2` could
not have (see 3i in [phasing.md](phasing.md)).

`test only=<substring>` became path selection, which is strictly finer.

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
     — it is why `o/bin/cosmic-check` exists and why the trust
     root assimilates the pinned binary — but the canary passed the APE, because
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

`regen-types` / `regen-tl-types` rewrote the committed `_types/*.d.tl`
from the pinned cosmos/tl, with drift tests failing on divergence. This
is the **pin-bump workflow**, and it outlived the Makefile as scripts
rather than being orphaned: `cosmic _types/gentype.tl` and `cosmic
_types/gentl.tl o/3p/tl/tl.tl`. `regen` is still the destination —
`_types/` becomes generation units run by it.

**The `.d.tl` decision has to be recorded, not defaulted.** The design
says generated outputs are never committed, which means un-committing
`_types/*.d.tl` and accepting the cost (a fresh clone cannot read
`cosmo.*` types without building; editors need `o/` on the include
path). The alternative — keep them committed with the byte-drift test,
regenerated by `regen` — preserves today's ergonomics at the cost of one
documented exception. Either is coherent; pick one in [choices.md](choices.md).

`docs` / `doc-publish` generated into `o/docs` and pushed to the `docs`
branch. **Done, as the split predicted**: `--make docs` produces
`o/docs/**` from the model's own file set, and the **push stays a
workflow step**, because it needs credentials and a network. Nobody
should try to give the build a git verb.

`facts` dissolved — the graph is the facts.

A `regen`-run unit is also the first real consumer of the portable
in-process gate on non-Landlock hosts, so this shares a milestone with
the fence work above.

**Exit:** a cosmos pin bump lands using only `bin/cosmic` + `--make`
verbs (fetch → regen → test), and docs.yml publishes from a
`--make`-produced `o/docs`.

## Release parity

release.yml shipped **two**
binaries — `cosmic-lua` and `cosmic-lua-debug`, the same payload on a
different base — plus SHA256SUMS.

1. ~~No debug-variant concept.~~ **Done**, as the variant: a unit's
   output directory holds `base-<variant>` beside `base`, and the same
   staged payload is embedded onto each as `o/bin/<name>-<variant>`.
   Staging happens once, so the two cannot drift, and a project that
   writes no variant is unaffected. The rejected option was a second
   `cmd/cosmic-debug/` unit, whose generator would have had to be kept
   in step with the first.
2. ~~Artifact weight.~~ **Resolved structurally** by D15: shipping is
   opt-in, so the `--make` artifact no longer carries `docs/`, `mk/`,
   `_perf/` and the Makefile as implicit assets. Re-measure against the
   Makefile's output before switching builders.
3. **No parity gate.** release.yml has switched builders without one.
   The check that was wanted — build both and compare: the same zip entry set (minus decided
   deltas), both passing the smoke assertions, sizes within an explained
   budget. Entry-set comparison is specifically the test that catches
   the class that bit twice — 3d lost `tl.lua` and the type tree, 3h
   lost every compiled `_cli/**` and `_make/**` module, and both shipped
   a binary that booted.

**Exit:** release.yml produces both artifacts via `cosmic --make`, and
the parity lane has compared them against the Makefile's output for at
least one release cycle.

## The trust-root swap

**Done.** `bin/cosmic` is committed POSIX sh whose one job is to fetch
the pinned cosmic and exec it: kernel → fetcher → **one** pin →
everything. The engine half of the old root was already obsolete —
cosmic extracts its embedded make to `o/make` itself — so the swap
removed a pin, a fetch and a bootstrap step at once. D13 is amended.

The pin is **`bin/cosmic.pin`, two plain lines, not a `*_pin.tl`**: a
`*_pin.tl` is resolved by `--make fetch`, which needs the cosmic this pin
provides. The sh script reads it with `sed`.

Small features died with the Makefile, each chosen: `help` (→ `--make
help` plus the skill docs), `only=` (→ path selection), the `bootstrap`
target, `TMP=` and `INCLUDE_DIRS` (→ env the verbs already read), and
`o=` (→ building the tree at two paths, which is the better check).

**Exit, met:** a fresh clone with a network runs `bin/cosmic --make
fetch && bin/cosmic --make build && o/bin/cosmic --make ci` to green
with nothing else on the host.

## The pin grammar's two frays

Both are scheduled here rather than settled in the model, because neither
can move while two pipelines read the same committed files — and after
this phase only one does.

- **The landing name comes from the url's tail** (the ⚠ in [model.md](model.md)'s
  units table), which is why url-name validation has to exist at all and
  why an on-disk name is coupled to a remote server's path layout.
  Retire it positionally: `3p/tl/tl_pin.tl` + `tar.gz` →
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

