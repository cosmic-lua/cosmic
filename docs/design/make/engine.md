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
  It shipped **opt-in** for a while, which was the wrong shape: a fence
  nobody turns on is a fence, and off-by-default cannot be tested
  honestly, because the only runs that exercise it are the ones that
  ask for it. It is **ON**, and `COSMIC_FENCE=0` opts out.

  Costless where it cannot work — `unveil()` no-ops without Landlock,
  so a host that cannot enforce is unaffected. The loud case is a host
  that CAN enforce and fails to apply the policy: that is a fence that
  silently is not there.

  **A build step and a test are fenced differently, and the difference
  is not a compromise.** A build step's inputs are its argv -- that is
  the whole design, and its grants are exactly that. A TEST is
  arbitrary code whose argv says only *run this compiled file*: this
  repo's own tests allocate ptys, count their file descriptors through
  `/proc/self/fd`, resolve names, and exec helpers. No derivation sees
  any of it.

  So a test is fenced from WRITING: its `.got` base and TMPDIR, which
  the shape names, and nothing else. It may read the project it belongs
  to, and read and exec the operating system, from an enumerated list
  rather than `/`.

  Two failures made the read half explicit before the runtime half did:
  `_types/gentl_test.tl` reads the pinned `tl.tl`, which no `require`
  names, and `_build/workflows_test.tl` reads `.github/workflows`,
  which the model prunes as a dotfile and which is the entire subject
  of that ratchet. A fence that stops a ratchet test reading the thing
  it ratchets protects nothing; a fence that fails honest tests is one
  that gets turned off.

  Narrowing the read half again wants a channel for "I read this file"
  that is not `require`. That channel now exists -- `-- @reads <glob>`,
  scanned by `_make/reads.tl` -- and it is deliberately NOT wired to
  the fence. It was added for **staleness**: a ratchet's subject is not
  an import, so nothing scheduled on it, and an incremental `--make
  test` reported the previous run's pass while `.github/workflows/*.yml`
  or a decision record changed underneath it. Only a fresh tree caught
  the drift, which is the shape of a gate that has stopped being one.

  Scheduling can take an incomplete declaration; a grant cannot. A
  forgotten `@reads` costs one stale target today and would cost a
  denied read if the fence narrowed onto it -- and nothing can check
  that the declarations are complete, because the reads happen at
  runtime through any API a test likes. So the fence keeps its floor
  ("a test may read the project it belongs to") until something can,
  and the declarations stay what they claim to be: prerequisites.
  What the validator CAN check, it does -- a declaration matching no
  file is refused, since it schedules nothing while reading as though
  the hole were closed.

  Also open: the portable in-process gate producing the same denial on
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

**What a target depends on is what it imports, plus what it says it
reads.** The import closure is computed from `require` edges and covers
every module a step loads. It does not cover a file read as bytes,
which is what a ratchet does to its subject — and the failure was
quiet in the worst way: the target stayed up to date, the stage
reported the previous run's pass, and only a fresh tree ran the check
against the tree it was about. A source closes that with `-- @reads
<glob>`, scanned by `_make/reads.tl`, expanded against the tree
(matches **and** their directories, since a deletion moves no surviving
file's mtime) and emitted as `datadeps_<stem>` beside the closure. A
declaration that matches nothing is a validation error: it would
schedule nothing while reading as though it had. Recorded as D17.

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
