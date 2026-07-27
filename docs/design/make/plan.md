# Delivery plan

How the design lands: what provisions a build, what gates the change
itself, and what is still open. The phase-by-phase sequence is
[phasing.md](phasing.md); what each landed slice *taught* is in
[log/](log/).

## Provisioning and the trust root

**This repo, target state:** `bin/cosmic` — POSIX sh, one job: fetch the
pinned cosmic (pin in `bootstrap/cosmic_pin.tl`) and exec it.
`bin/cosmic --make ci`. Since make is embedded, the chain would be
**kernel → committed fetcher → one pin → everything**, down from two.

**It was two pins.** The trust root was `bin/make`, with the
bootstrap url and sha in `cook.mk` and the cosmos pin beside it; there
is no `bin/cosmic` and no `bootstrap/cosmic_pin.tl`. The one-pin chain
arrives with the Makefile's retirement (3i), not before it.

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
- pin extraction: a `*_pin.tl` that is not a literal is rejected, and a
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
pay. See [engine.md](engine.md).
