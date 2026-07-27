# `cosmic --make`: the engine

The execution half of the [`--make` design](README.md): how a project
model becomes make input, how cosmic runs the recipes, and what a
recipe is allowed to do. The model half — units, kinds, artifacts,
verbs — stays in README.md.

## Constant rules, generated facts

`o/cosmic.mk` ships in the binary, byte-identical everywhere; discovery
uses `$(wildcard)` and `rwildcard` foreach-recursion — builtins only, no
`$(shell)`. `o/project.mk` is generated and contains only variable
assignments, so codegen shrinks to "emit a list of variables" while
discovery and validation stay in Teal where errors can be good. This
repo's makefile ratchets collapse from "scan generated recipe text" to
"one file that does not change."

## Cosmic as `SHELL`

`SHELL := cosmic`; cosmic grows `-c '<line>'`, so make's default
`.SHELLFLAGS` works unchanged. A line is whitespace-split argv — no
quoting, no expansion, no pipes, no redirects — whose `argv[0]` is a
cosmic verb or `exec`.

- **the capability surface is enumerable**; the metacharacter-scanning
  ratchet becomes unnecessary.
- **sandboxing stops depending on fork-specific syntax, and on any
  declaration at all.** grants are *derived from the verb's signature*:
  `copy <src> <dst>` reads src and writes dst, `compile <bootstrap>
  <src> <out>` execs the first, reads the second, writes the third.
  cosmic self-restricts from that before dispatching, so
  `.PLEDGE`/`.UNVEIL` attributes become optional rather than
  load-bearing — and a rule cannot over-declare its way out of the
  fence, because a rule declares nothing.

  An earlier version of this design carried grants in target-specific
  make variables (`COSMIC_UNVEIL = $^`). Closing the vocabulary made
  that channel redundant: the argument positions *are* the declaration.
  Two mechanical details the kernel forces, recorded because getting
  them wrong disables the fence rather than tightening it — a write
  grants the parent **directory** (creating and unlinking are rights on
  the directory, and the output does not exist yet), and a read naming
  a path that does not exist is **dropped**, since landlock opens every
  rule and one missing input would fail the whole restrict.

  `exec` is the one verb whose reads are not derivable — a pinned
  compiler reads headers nobody listed — so it is fenced to the unit's
  subtree instead of its argv, per the same rule generators and tests
  use. Landed after 2d, which is what supplied `unit_dir`: until there
  were units this was a promise with nothing behind it.

  **A derived fence still needs a floor.** Shipping the derivation with
  nothing else turned three CI lanes red at once: argv says nothing
  about the APE loader beside a binary (a fat APE that cannot reach it
  fails `ENOEXEC`, which reads like a corrupt file rather than a denied
  path), nor about `/dev/urandom`, nor about the paths a *child's* own
  argv names — `tee <out> cosmic --report <got…>` hands those to a
  process that inherits the fence. The make rules already spell this
  floor as `unveil_base`/`unveil_dev`; the derived fence needs its own.
  It is therefore **opt-in (`COSMIC_FENCE=1`) until the canary proves
  it on a Landlock host** — no machine available while writing it could
  enforce anything, so every local run was a silent no-op.

  **Making it the default is its own change**, and it is the last step
  of the enforcement swap rather than the first. The order matters
  because the Makefile's per-rule `.PLEDGE`/`.UNVEIL` are already gone:
  the project sits between "an undeclared read fails CI on a Landlock
  host" and "nothing is enforced anywhere", and only a defaulted fence
  closes that. What is left: the fence becomes the default for `-c`,
  with the same denial produced by the portable in-process gate on
  non-Landlock hosts.

  Two things a CI lane that requires a fenced child to **succeed**
  found, and they are the argument for testing enforcement in both
  directions — a mechanism exercised only in its failing direction is
  one nobody has checked:

  - The floor handed Landlock `/zip/.types`, a path *inside the
    executable*, where `fs.isdir` says yes and the kernel knows
    nothing — so the whole policy failed to construct with `EBADFD`. A
    fence that cannot be built is worse than one that is too wide: it
    fails on correct input.
  - A fenced child today must be an **assimilated ELF**, not a fat APE:
    exec'ing an APE needs a loader, and the search falls back to
    `~/.ape-*`, which no grant covers.

  **The better answer to the second is the loader, and it is already in
  `o/`.** `o/bin/ape` is a plain ELF the build stages, and `o/bin/ape
  <fat APE> …` runs — so a fenced recipe could exec any pinned APE with
  two grants and no duplicate binary. What blocks it is the recipe
  vocabulary, not the fence: a verb line names one program, and there is
  no way to say "run THIS through THAT loader". Putting the loader on
  `PATH` is not a substitute — it was tried, and the fenced exec still
  failed, because the stub's search is not what a direct shell-free exec
  goes through. So the choice is between assimilating a duplicate (what
  happens now, at the cost of a second copy on disk) and teaching
  `exec`/`compile` to prefix the staged loader when the program is an
  APE. The second is the one that scales to a project pinning its own
  tools, and it wants doing before the fence becomes the default.

**The trailing `;` is load-bearing.** Setting `SHELL` is not enough:
make does not use `SHELL` for a line it judges shell-free — job.c
builds argv and execs directly whenever the line contains none of
`` #;"*?[]&|<>(){}$`^ `` and does not start with a shell builtin. Lines
in this vocabulary are shell-free *by construction*, so the naive
`SHELL := cosmic` intercepts nothing at all: measured on the fork, a
recipe of `rm -rf a.txt` under `SHELL := cosmic` deleted the file, and
`copy a.txt out.txt` failed with `copy: No such file or directory`
because make tried to exec `copy` as a program. `.ONESHELL` does not
change it.

So generated recipe lines end in `;`, which forces the `SHELL` path,
and `-c` strips exactly one trailing sentinel before dispatch. A `;`
anywhere else is still refused, so `copy a b ; touch evil` does not
become two commands. `;` is the cheapest sentinel that behaves
identically under a real shell — a leading `:` also forces the path,
but `sh` would discard the line's arguments entirely.

The alternative is a fork change (a special target that forces the slow
path), which is the D14 mechanism and remains open — but the sentinel
needs no release, so the upstream knob is an ergonomic cleanup rather
than a dependency.

**`exec` opens onto pinned bytes only.** It resolves against the build
root (`$COSMIC_EXEC_ROOT`, else `o/`) and refuses anything outside it,
so a bare `exec cc` resolves to `<cwd>/cc`, is not under the root, and
is refused rather than silently picking up the host's compiler. Pins
declare bytes, `fetch` obtains them, `exec` runs them; nothing else
runs at all.

Known limitation, recorded rather than papered over: a program's
*arguments* travel through the same whitespace split, so they cannot
carry shell characters either. A pinned compiler invoked with
`-DFOO(x)=y` is refused. Nothing in this repo's rules needs it, and the
out-of-band channel that would fix it (paths and args in target-specific
variables rather than in the line) was considered and rejected for
costing the legibility of `o/cosmic.mk`. If a real project hits it, that
tradeoff is the thing to revisit.

`--build` and `-c` are the same dispatcher; `-c` wins. Ordering was a
constraint, not a preference — `-c` had to ship in a release before
this repo could set `SHELL := cosmic`, since recipes run the pinned
older bootstrap. Done; `--build` retires a release later.

## Staleness and parallelism

Mtime schedules; content decides. Every verb writes its output only when
the bytes change — the existing `run_into` contract, generalized by
cosmic owning the shell. A no-op step doesn't touch its output, so
non-changes stop propagating.

**Everything is parallel** (`-j$(nproc)`, honoring an inherited
jobserver and an explicit `--jobs`). Parallel-by-default is defensible
only because isolation is structural.

Spawn cost, measured (200 runs of a no-op verb): **10.4 ms** per line
for the fat APE, **6.4 ms** for the assimilated ELF, against **1.5 ms**
for `/bin/sh -c true`. The comparison that matters is not against a
shell: this repo's recipes *already* spawn cosmic per line, so routing
through `SHELL` costs the same one spawn. At 6 ms a 1000-node graph
carries ~6 s of startup serially, under a second at `-j8` — a budget
that argues for chunky verbs and, eventually, an action cache keyed on
`(argv + input hashes)`, deferred until profiling justifies it.
