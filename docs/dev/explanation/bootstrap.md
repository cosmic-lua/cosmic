# Why building cosmic needs a cosmic

the trust root, why a gate converges, why the cold-build rule exists,
and why a release is built twice. for a contributor who wants to know
which binary is running their gate, and why that is the right one.

## the trust root

compiling a `.tl` file needs a Teal compiler, and cosmic's compiler is
inside cosmic. so the build starts from a cosmic that already exists.
`bin/cosmic` is a POSIX shell script with one job: read the url and
sha256 in `bin/cosmic.pin`, download that one release, verify the
digest, and exec it with the arguments it was given. before the exec it
assimilates the download to a native ELF, because a sandboxed build
rule cannot grant the APE loader its extraction step, and stamps the
binary with the sha so a pin bump re-downloads instead of leaving a
tree on the previous release.

everything after that runs under the pin. cosmic extracts its own
build engine (`make`) and its own rules (`cosmic.mk`) from its own zip,
and resolves the tree's other pins itself. the chain is short enough
to state:

```text
kernel -> bin/cosmic -> one pin -> everything else
```

the host surface is POSIX sh, `curl`, `sha256sum` and `od`. no host
make, no host compiler, no host Lua. supply-chain review reduces to
reading `bin/cosmic`, auditing one sha, and trusting the kernel. the
pins are the trust root and TLS is only transport, which is what lets
CI run the whole gate with the network removed and treat any download
as a failure. the decision that shrank the chain to one pin, and the
one that keeps make as the graph executor instead of re-implementing
it, are [D13](../../decisions/d13-trust-root.md) and
[D14](../../decisions/d14-no-self-hosting.md).

## why a gate converges

a gate's result is a statement about a toolchain, and this project
builds the toolchain. run `fmt` under the pinned release and it formats
with the release's formatter, so a formatter fix passes its own gate
whether or not it works. run `check` under it and a new narrowing rule
is judged by a checker that has never heard of it.

so a gate verb in a project that defines the `cosmic` namespace builds
first. when the artifact it produced is not the binary running, it
re-execs into `o/bin/cosmic` with the original argv. the loop ends
because the build is content-addressed: `--make build` replaces
`o/bin/cosmic` only when the bytes change, so "did this change
anything" is a question the filesystem answers. two generations is the
cap. generation 1 is the pin building the tree; generation 2 is the
tree's own binary building the tree again and finding nothing to
change. a third generation means the tree does not build a fixpoint,
and the verb fails with `make: build is not a fixpoint` instead of
spinning. in an ordinary project the artifact is not the tool that
gates it, so there is nothing to converge to and the step does
nothing.

`bin/cosmic` prefers `o/bin/cosmic` when one exists and reaches for
the pin only on a cold start. for a gate that is the point. for a
script there is no convergence: `bin/cosmic _perf/run.tl` runs under
whatever `o/` holds, which may be several commits old. name the binary
when its identity is the experiment.

## the cold-build rule

convergence has a flip side. generation 1 compiles the whole tree, not
only `cosmic/**`, with the pinned release's checker and its patch set.
a source that only the tree's own checker accepts (a new narrowing
rule, a new entry in `3p/tl/tl_patch/`) passes the converged `--make
ci` on a warm tree, because generation 2 re-judges everything with the
new checker. it fails on a cold tree, where generation 1 has to get
through first: CI's `build` and `repro` lanes, and every fresh clone.

that failure would land far from its cause, so `_build/coldbuild_test.tl`
runs generation 1's exact type check on every change: the pinned
bootstrap's checker, resolving modules from the tree. a source that
needs the new checker fails there, on the pull request that introduces
it. the fix is staging: land the checker first, wait for a release that
carries it, bump `bin/cosmic.pin`, then land the code
([howto/bump-pin.md](../howto/bump-pin.md)). the rule is the price of
building the toolchain with itself, and the test makes the price
visible where it is paid.

## why `bin/cosmic --make ci` is right on a cold tree

on a cold tree `bin/cosmic` runs the pinned release, and the pinned
release runs generation 1 with its own checker. that generation judges
the whole tree once with the pin's rules before the tree's own binary
judges it again. so the one command does two things in order: it
proves the tree builds under the release the world has, then it gates
the tree under the release the tree is. a change that passes both is
a change anyone can build from a clone.

## why a release is built twice

`release.yml` runs `bin/cosmic --make build`, then `o/bin/cosmic --make
build`, and ships the second. the first binary is the pin's product:
the pinned compiler and the pinned patch set compiled the tree. the
second is the tree's product: the tree's own compiler compiled the
tree. a release is produced by the code it contains, not by whatever
the pin happened to be that day. the gate then runs under the binary
being released, and the release measures itself before it publishes.
CI's `build` lane asserts the same two generations are byte-identical
on every push, so a release never discovers the fixpoint is broken.

## what this costs

a fresh clone needs a network once, for the pin and the `3p/` fetch;
after that a build is hermetic. a checker change waits for a release
before the code that needs it can land. a warm `o/` is a toolchain
generation, and a pin bump starts cold. a contributor has to know
which binary is running, and the answer is: for a gate, the tree's;
for a script, whatever `o/` holds. the pages that say what to do about
each are [howto/bump-pin.md](../howto/bump-pin.md) and
[reference/ci.md](../reference/ci.md).
