_build/coldbuild_test.tl (#1433) replicates generation-1's TYPE CHECK
but not generation-1's RUNTIME, so a cosmos-pin-shaped cold-build
failure passes it. Gen 1 also RUNS the tree's generators (*_gen.tl,
embed_gen.tl) under the pinned binary's C runtime: a generator calling
a cosmo.* binding added by a cosmos pin bump type-checks clean under
the pinned checker (the declaration comes from o/_types/types_gen,
generated from the FETCHED cosmos) yet is nil at gen-1 runtime — cold
build fails in generate, coldbuild_test green, converged --make ci
green, and the failure lands in CI's build lane, exactly what #1433
exists to prevent. The checker half is faithful (verified:
--include-dir resolution order matches embed/cosmic.mk's compile
rule). No instance in the current window, but the staging rule the
test enforces for checker features has no guard for cosmos-runtime
features. Adjacent to 3IIm7ZyN (boot-surface calls into non-boot
modules fail cold in generate, hidden by convergence) — refine
together: the missing instrument is "generators run under the pinned
runtime", not another type check.
