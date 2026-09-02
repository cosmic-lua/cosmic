# Why the build works this way

the reasons behind `cosmic --make`'s shape, for a reader who has built a
project and wants to know why the tool refuses what it refuses.

`cosmic --docs howto.build` has the steps. `cosmic --docs
reference.make` has the tables.

## There is no build spec

a project is its directory tree. a file's position and name declare
what it is: `*_test.tl` is a test, `cmd/<name>/main.tl` is a binary,
`embed/**` ships, a leading `_` is internal. nothing lists these, so a
directory added to the tree is built, checked, tested and documented
without anyone registering it.

a spec file is a second copy of the tree, and a second copy drifts. the
tree cannot disagree with itself.

the name says nothing about a Makefile. nothing scans a directory to
emit one for a host `make` to run. the verbs are the interface.

the same rule names the artifact. a binary is named by its
`cmd/<name>/` directory, never by the checkout directory, so a root
`main.tl` is refused. two clones of one project in two directories
build the same `o/bin/<name>`.

## Why a gate verb converges

a gate verb's result is a statement about a toolchain. a project that
defines the `cosmic` namespace builds its own toolchain. run `fmt` under
the pinned release and it formats with the release's formatter, so a
formatter fix passes its own gate while shipping broken.

so a gate verb builds first. when the built binary is not the one
running, the verb re-execs into it with the original argv. the build
scrolls past before the stage does:

```text
$ cosmic --make ci
make: root=/home/you/cosmic
build: PASS (377 files, 1 binary)
make: root=/home/you/cosmic
fmt: PASS (377 files)
...
ci: PASS (5 stages)
```

the second `make: root=` line is the re-exec under the new binary.

this terminates because the build is content-addressed. `o/bin/<name>`
is replaced only when its bytes change, so "did that change anything"
is a question the filesystem answers. two generations is the cap. a
third would mean the build is not a fixpoint, and that is a loud
`not a fixpoint` failure rather than a spin.

an ordinary project never sees this. its artifact is not the tool that
gates it, so there is nothing to converge to, and the machinery does
nothing.

## Why the gate is also the inner loop

`ci` is the gate, and warm it is the fastest loop too. every stage
skips what its stamps already proved, so a rerun after a one-file edit
redoes only that file's work: about a second in a small project.
rerunning the whole gate is cheaper than remembering which verb checks
what.

the stamp is a hash of the embedded bytes that run when a rule's verb
runs, not of the binary. the binary embeds every module, so a stamp on
the binary would invalidate the whole graph on any edit.

compiles recompile importers, too. a strict compile type-checks against
the modules it imports, so a changed contract recompiles everything
that depends on it. an incremental build catches a broken contract
exactly as a clean one does.

## Why shipping is opt-in

an artifact carries its modules and `embed/**`, and nothing else. a
file that is merely in the repo is not in the binary. `docs/`, a
`Makefile`, a `notes.md` and `testdata/` stay behind without anyone
excluding them. a `schema.sql` the program needs becomes
`embed/schema.sql`: the move is the declaration.

there is no un-ship knob because there is nothing to un-ship. what an
artifact contains is greppable from the tree: `ls embed/` plus the
module set, the same way its network and exec surfaces are.

the same rule holds between binaries. each `cmd/<name>` artifact
carries the root packages plus its own subtree, and nothing from a
sibling `cmd/`. the validator refuses an import across that boundary
for the same reason.

## Why the base is stripped to a positive floor

an artifact is a program, not a copy of the thing that built it. so the
base keeps a positive floor: cosmic's compiled standard library, the TLS
roots, zoneinfo and `.args`. it drops the toolchain: the Teal compiler,
the type declarations, cosmic's own `.tl` sources, the doc index, the
docs, the build rules. `require("cosmic.json")` works in an artifact and
`require("tl")` does not.

a keep-list is chosen over a strip-list because a base that grows a
directory must not start shipping it silently. there is no opt-out. a
project that wants Teal at runtime vendors it, and it ships because the
project's own tree provides it.

## Why grants come from the recipe line

make runs `cosmic -c '<line>'` for every recipe line. a line is argv,
not shell: whitespace-split, the first word a verb from a closed
vocabulary, shell metacharacters refused rather than interpreted. no
quoting, no expansion, no pipes, no redirects. the build's whole
capability surface is that vocabulary.

cosmic derives its sandbox grants from the line's own shape. `copy
<src> <dst>` reads the first and writes the second, and the process
restricts itself before doing the work. a rule cannot over-declare its
way out of the fence, because a rule declares nothing.

this is why a space in a filename is refused. recipe lines have no
quoting anywhere, so `my notes.tl` cannot be expressed, and the
validator says so by name instead of letting make read it as two words.

a test's grants come from the same place. the recipe names the test's
import closure after `--deps`; that closure is what the fence grants,
and it is never handed to the child. on a Landlock host the kernel
enforces it. a test writes only its own step's directory. it reads the
compiled tree plus its own source directory, which is where `testdata/`
lives, so fixtures need no special grant. on a host without Landlock the
grants are computed and cannot be enforced, so the step runs unfenced.
that is why CI asserts a real denial rather than trusting that the
mechanism ran.

## Why the rules are constant and the facts are generated

`o/cosmic.mk` is the rules. it is committed, shipped inside the binary,
and byte-identical for every project. no rule is ever generated.
`o/project.mk` is the facts: variable assignments only, the file lists
the walk produced and each source's import closure.

a constant rules file is one that can be read once and trusted. it also
lets a path selection travel as a make variable override, so no rule
knows about selection at all.

the trailing `;` in a rule is load-bearing. make execs a line it judges
shell-free itself, without consulting `SHELL`, so without it cosmic
would never see the line.

## Why builds are reproducible

zip entries carry a fixed mtime, `SOURCE_DATE_EPOCH` when set and else
the 1980 DOS floor, rather than the staging file's. two builds of one
tree in two different directories are byte-identical.

compiles are always strict: type check, then generate from that same
checked AST. there is no flag to select it. that is what makes output
independent of parallel build order.

a selected `build` names binaries, not sources, and still compiles the
whole tree. a selected build must stage exactly what a full one would.
half a tree cannot make a whole artifact.

## Why `fetch` is the only networked verb

`fetch` is the only part of `--make` that can open a socket at all.
building is not fetching, so a project whose pin points at an
unreachable host still builds.

a pin is data, not code. the file is lexed and matched against a
literal grammar, never loaded, compiled or called, so a pin cannot run
anything. `url` and `sha256` are both required: a pin without a digest
is a download. bytes that do not hash to the pin are never written, so
a build either runs on the bytes you named or does not run. `fetch`
verifies before unpacking, because an archive is a program for a
decompressor, and running one on unverified bytes is what pinning
exists to prevent.

`{version}` substitution is the one templating the grammar allows, so
a bump is a one-line diff. the fetched file lands under `o/`, beside
the pin's position, because nothing generated belongs in the tree.

## Why the engine is embedded

the graph verbs need a make binary, and cosmic carries one. it extracts
itself to `o/make` the first time it is needed, so a fresh clone on a
machine with no toolchain builds.

`PATH` is never searched. a build whose engine came from whatever the
host had installed is a build nobody can reproduce. the engine is pinned
inside the binary, or named with `COSMIC_MAKE`, never guessed.

## Why tests are isolated per step

each test gets its own scratch directory inside its own build step.
`TEST_TMPDIR` points at a fresh directory under `o/<test>.test.tmp.d`,
not at a shared `/tmp`, so tests cannot collide through the temp
directory on any platform.

a test re-runs only when something it imports changes. cosmic follows
`require()` edges to compute each closure, so editing a module no test
imports re-runs nothing. make runs with `-s`, so the only output of such
a run is one line per step, the verb plus the path it writes.

tests see the root `embed/**` at its `/zip` path because `--make test`
runs them under a runner that carries it. a binary's private
`cmd/<name>/embed/**` is one artifact's cargo, so a test covers it by
spawning the built `o/bin/<name>`.

## Why `clean` spares `o/bootstrap`

`o/bootstrap` is the verified copy `bin/cosmic` fetched from the pin.
removing it makes the next command reach for the network. cleaning a
build must not have network consequences.

## Why the root is never searched for

the root is the current directory. a build that guesses which project
it is in is a build that writes into the wrong tree. so `--make` never
searches upward, and every run prints the root it used.

the upward search exists only to refuse. a run from inside a project
names the likely root and the command to run. a run from a directory
that declares nothing is refused too. otherwise every directory is a
project, and a typo in an empty directory reports a green build over
nothing. `COSMIC_MAKE_ROOT` is the escape hatch: naming a root is
how you say you meant it.

## Why the output has a grammar

four things leave a run for something other than a person: a row, a
summary, a verdict and an exit code. they are one grammar so a printer
and a parser cannot disagree.

a row names the source path, not a basename. eleven files in cosmic's
own tree are called `init_test.tl`, and a failing row that cannot be
resolved to a file costs a grep with eleven hits.

a summary survives a failing stage. its recipe exits nonzero because
the stage failed, so a rule that deletes targets on error would delete
the one file a consumer opens next. the summary target is phony instead:
never deleted, and rewritten every run.

the verdict is the last line, and the one that survives truncation. it
says how much failed, not how much there was, because that is the
number worth keeping.

a skip is not a pass. exit code `2` exists so that a stage that stopped
checking and said nothing is visible.

## Why the coverage floor has that shape

the floor is `.cosmic-coverage`, namespaced because a bare `.coverage`
is coverage.py's binary data file and cosmic targets polyglot repos.

it is one row per file and no shared total line. `--baseline` writes
this run's exact measurement into every row, raises and drops alike.
so a row a change did not touch reappears with the same numbers, and
two changes touching different files have nothing to conflict on. the
guard that remains is on breadth, not direction. a rewrite that lowers
more than half the rows is refused, because that shape is what a
partial or stale run produces, not a real project-wide decline.

`merge=union` resolves the conflict that remains: both sides' rows
land, and the ratchet reads a repeated path as its lower percentage.
that is the safe direction, since a merge that raised a floor would
fail a build for a decline neither side introduced.

## The `COSMIC_COVERAGE` wart

`COSMIC_COVERAGE` carries two protocols under one name. `1` or `true`
means collection is armed, which is what the coverage rules export. any
other value is the directory to dump into, which is what `--test` sets
per test. `cosmic.coverage.dir_from_env` is the one reader that knows
the difference. anything that treats the variable as a path must go
through it; reading it directly is how a build once created a directory
named `1`. this is a wart, not a design.
