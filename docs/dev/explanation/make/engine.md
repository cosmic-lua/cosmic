# The engine

how a project model becomes make input, how cosmic runs each recipe
line and what a line may do, for a contributor who changes
`_make/graph.tl`, `embed/cosmic.mk` or `_cli/build/`.

## constant rules, generated facts

two files land in `o/` and make reads both. `o/cosmic.mk` is constant:
it is the committed `embed/cosmic.mk`, shipped at `/zip/cosmic.mk`,
and `_make/graph.tl` copies it out rather than composing it. it is
byte-identical for every project. `o/project.mk` is generated and
holds only variable assignments: `COSMIC` and `O`, the file lists
(`tl_sources`, `lua_sources`, `tests`, `examples`, `benchmarks`,
`fmt_sources`, `lint_sources`), one `srcdeps_<stem>` per source with
its transitive import closure, one `deps_<stem>` per test with its
built closure, the compile groups (`groupsrcs_<dir>`,
`groupdeps_<dir>`, `groupof_<stem>`), and `testrun` with
`testrun_dep`. discovery and validation stay in Teal, where an error
can name a path. codegen is "emit a list of variables". no rule is
ever generated.

both files are written only when their bytes change, so re-running a
verb does not invalidate the graph it just built. a selection travels
as command-line variable assignments, which beat the ones in
`o/project.mk`, so narrowing a run needs no rules of its own.

the invocation is `o/make --no-builtin-rules --no-builtin-variables -s
-f o/cosmic.mk -j<n> <target>`, with `MAKEFLAGS` and `MAKELEVEL`
cleared from the environment. no builtin rules, because a builtin
pattern firing on a `.lua` would run a step nobody wrote. `-s`,
because the driver owns the progress voice: it prints `<verb> <what it
writes>` instead of a 400-character line. `<n>` is the processor
count, or `COSMIC_JOBS` when set.

the make binary is `/zip/make`, extracted to `o/make` on first use.
`COSMIC_MAKE` names another. `PATH` is never searched: a build that
picks up the host's make is a build whose engine is not pinned.

the trust root is one level up. `bin/cosmic` is POSIX sh with one job:
read `bin/cosmic.pin` (a url and a sha256, two plain lines), fetch that
cosmic into `o/bootstrap/cosmic`, verify the digest, assimilate it to
a native ELF and exec it. `clean` keeps `o/bootstrap/`, because
re-obtaining it costs a network and cleaning a build must never make a
project unbuildable offline. the chain is kernel, committed script,
one pin, everything else. `bin/cosmic.pin` is not a `*_pin.tl`,
because `--make fetch` resolves those and needs the cosmic this pin
provides. a downstream project commits its cosmic instead: a fat APE
in the repo means `./cosmic --make ci` works from a fresh clone with
no network and no shell. cosmic itself keeps a fetcher because it
bumps its own toolchain constantly.

## cosmic as `SHELL`

`SHELL := $(COSMIC)`, and cosmic answers `-c '<line>'`, so make's
default `.SHELLFLAGS` works unchanged. a line is whitespace-split
argv: no quoting, no expansion, no pipes, no redirects. its `argv[0]`
is one of thirteen verbs: `compile`, `compile-batch`, `capture`,
`record`, `copy`, `tee`, `link`, `remove`, `verdict`, `write-list`,
`assert-elf`, `assert-marker` and `exec`. the build's whole capability
surface is that vocabulary.

**grants are derived from the verb's signature.** `copy <src> <dst>`
reads src and writes dst; `compile <bootstrap> <src> <out>` execs the
first, reads the second, writes the third. cosmic restricts itself
from that before dispatching. a rule cannot over-declare its way out
of the fence, because a rule declares nothing. two mechanical details
the kernel forces: a write grants the parent directory, because
creating and unlinking are rights on the directory and the output does
not exist yet; and a read naming a path that does not exist is
dropped, because Landlock opens every rule and one missing input fails
the whole policy. `exec` is the one verb whose reads are not
derivable, since a pinned compiler reads headers nobody listed, so it
is fenced to the unit's subtree instead of its argv.

**a derived fence needs a floor.** argv says nothing about the APE
loader, `/dev/urandom` or the paths a child's own argv names. the
driver adds them: exec on every loader file it finds (`/usr/bin/ape`
and `.ape-*` under `TMPDIR`, `HOME` and the current directory), read
on `/dev/random` and `/dev/urandom`, `/dev/null`, and the running
binary itself. with `TMPDIR` unset it points `TMPDIR` at a scratch
directory under `o/` before fencing and copies `HOME`'s loaders into
it, so a nested driver that cannot read `HOME` still finds a loader
inside a directory the fence grants. never hand Landlock a path inside
the executable: `fs.is_dir("/zip/.types")` says yes and the kernel
knows nothing, so the policy fails to construct with `EBADFD`. a fence
that cannot be built fails on correct input, which is worse than one
that is too wide.

**the fence is on.** `COSMIC_FENCE=0` opts out. an opt-in fence is a
fence nobody turns on, and off-by-default cannot be tested honestly,
because only the runs that ask for it exercise it. it is costless
where it cannot work: `unveil()` is a no-op without Landlock. the loud
case is a host that can enforce and fails to apply the policy; that
step fails. `_cli/fence_test.tl` asserts a real denial, and CI's
`build` lane asserts the host can enforce before trusting its own
fenced builds. a portable in-process gate for hosts without Landlock
is planned and not built.

**a build step and a test are fenced differently.** a build step's
inputs are its argv, and its grants are exactly that. a test is
arbitrary code whose argv says only "run this compiled file": this
repo's tests allocate ptys, count file descriptors through
`/proc/self/fd`, resolve names and exec helpers. so a test is fenced
from writing, to its `.got` base and `TMPDIR`, and may read the
project it belongs to plus an enumerated runtime list.
[testing.md](testing.md) has the list. two tests are why the read half
is the whole project: `_types/gentl_test.tl` reads the pinned `tl.tl`,
which no `require` names, and `_build/workflows_test.tl` reads
`.github/workflows`, which the model prunes as a dotfile and which is
the subject of that ratchet. narrowing the read half again needs a
grant channel that is not `require`, which the design does not have.
the `--- reads:` declaration feeds scheduling and the content key,
not the fence.

**the trailing `;` is load-bearing.** make does not use `SHELL` for a
line it judges shell-free: it builds argv and execs directly whenever
the line contains none of `` #;"*?[]&|<>(){}$`^ `` and does not start
with a shell builtin. lines in this vocabulary are shell-free by
construction, so a bare `SHELL := cosmic` intercepts nothing, and
`.ONESHELL` does not change that. so every generated recipe line ends
in `;`, which forces the `SHELL` path, and `-c` strips exactly one
trailing sentinel before dispatch. a `;` anywhere else is refused, so
`copy a b ; touch evil` does not become two commands. a special make
target that forces the slow path is an open ergonomic cleanup, not a
dependency.

**`exec` opens onto pinned bytes only.** it resolves against
`$COSMIC_EXEC_ROOT`, else `o/`, with realpath on both sides so a
symlink like `o/tool -> /bin/sh` cannot pass, and a prefix match on a
separator boundary so `o-other/` cannot pass for `o/`. a bare `exec
cc` resolves to `<cwd>/cc`, is not under the root, and is refused
rather than picking up the host's compiler. a known limitation: a
program's arguments travel through the same whitespace split, so
`-DFOO(x)=y` is refused too. nothing in this repo's rules needs it;
carrying paths and args in target-specific variables instead costs
the legibility of `o/cosmic.mk`, and that is the tradeoff to revisit
if a real project hits it.

## staleness and parallelism

mtime schedules; content decides. `write-list`, the two makefiles and
the artifact itself are written only when their bytes change, so an
unchanged binary never invalidates the tree that depends on it. most
steps (`compile`, `capture`) restamp the target's mtime even when the
bytes are unchanged, deliberately, so a target make judged out of date
does not stay out of date forever. convergence rests on the artifact.

every graph rule names a tool stamp, `o/.stamp/<tool>`, written before
make runs. a result is only as fresh as the tool that produced it: a
formatter fix must invalidate every `.fmt.got`. the stamp is a hash of
the embedded bytes that run when the rule's verb runs, not of the
binary, because the binary embeds every module and naming it makes
any edit anywhere recompile the world. `o/_types/types_gen.stamp` is
the same idea one layer down: every compile resolves `cosmo.*` through
a generated directory, so the stamp is content-addressed and a cosmos
pin bump moves it.

mtimes lie in exactly the situations that hurt: a branch switch, a CI
cache restore under a fresh checkout, a `touch` storm. so an expensive
step first asks whether the bytes of its inputs are the ones that
produced the recorded result. `<out>.in` records a hash over the
step's stable argv, five environment switches (`CI`, `COSMIC_COVERAGE`,
`COSMIC_FENCE`, `COSMIC_FIXPOINT`, `COSMIC_BENCHMARK_MIN_MS`) and the
bytes of every input file. a hit restamps the output and does
nothing. only a line that declares its inputs gets the skip.

compiles are batched per directory. `compile-batch` compiles a
directory's members in one process, so the boot, the compiler and
every checked import are paid once per group. each member keeps its
own `.in` record, byte-compatible with the per-file `compile` step's,
so the per-file rule stays the correctness safety net rather than the
hot path.

summaries are `.PHONY` where everything else is `.DELETE_ON_ERROR`. a
summary's recipe exits nonzero because its stage failed, and deleting
it removes exactly the file a consumer opens next; `.PRECIOUS` keeps
it with a newer mtime than the `.got` files it reports on, so the
failure is never re-reported.

everything is parallel: `-j<nproc>`, honoring `COSMIC_JOBS`.
parallel-by-default is defensible because isolation is structural.
spawn cost, measured over 200 runs of a no-op verb, is 10.4 ms per
line for the fat APE and 6.4 ms for the assimilated ELF, against 1.5
ms for `/bin/sh -c true`. this repo's recipes spawn cosmic per line
anyway, so routing through `SHELL` costs the same one spawn. at 6 ms a
1000-node graph carries about 6 s of startup serially and under a
second at `-j8`. that budget argues for chunky verbs, and an action
cache keyed on argv plus input hashes stays deferred until profiling
justifies it.
