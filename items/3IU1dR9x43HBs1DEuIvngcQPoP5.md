## Evidence

Observed 2026-08-27 implementing 3ISSGDIN (tl-patch edits on branch
3ISSGDIN-closure-carry). Sequence:

1. A patch-set edit (8 entries, one later shown buggy) was fetched
   into o/3p/tl/tl.lua; `o/bin/cosmic --make test` gen-1 compiled the
   tree with the OLD embedded checker, PARALLEL make staged the new
   embed payload (o/stage/cosmic/tl.lua, bytecode, mtime 04:06) and
   linked o/bin/cosmic before a failing compile-batch group stopped
   the build (the buggy checker refused _tool/coverage/report.tl).
2. Every later run — including `bin/cosmic --make ci` from the trust
   root, which prefers o/bin/cosmic — re-entered that HALF-BUILT
   binary: its embedded checker was the buggy 8-entry one, so gen-1
   itself now failed on report.tl, the build never reached the embed
   stage, and the corrected patch (9 entries, fetched 04:09/04:15,
   sitting in o/3p/tl/tl.lua the whole time) never made it into any
   binary. The loop is wedged: red gen-2 poisons every later gen-1.
3. Escape needed a human's `rm o/bin/cosmic` (cold start from the
   pin). Nothing diagnosed the state; the failure read as a source
   error in report.tl, which was green under both the pinned and the
   corrected checker.

Two things worth weighing at refinement: (a) a failing converging
build should not leave its half-product as o/bin/cosmic (link last,
or unlink on failure), and (b) the `not a fixpoint` machinery could
name the wedge: when gen-1 fails under a binary newer than the last
green stamp, say "remove o/bin/cosmic to rebuild from the pin"
instead of printing the compile error alone. Related: 3IIm7ZyN (the
convergence hiding cold-build failures), 3ISnyPb7 (the cold-build
rule's enforcement).

## Second face, same session (2026-08-27, ~05:1x)

The wedge is not only red-gen-2: SWITCHING BRANCHES reproduces it in
mirror. o/bin/cosmic built on branch A (carrying a checker patch and
A's tree fixes for it) stays the toolchain after `git checkout B`;
gen-1 on B then compiles B's tree under A's embedded checker and
fails on exactly the files A's diff had to fix (cosmic/json.tl's
metatable `==` under the closure-carry checker). Same escape, by
hand: `rm o/bin/cosmic o/3p/tl` and cold-start from the pin. Whatever
countermeasure the refinement picks should treat "the toolchain
binary does not match the tree that would rebuild it" as the general
condition, with red-gen-2 and branch-switch as its two observed
faces.
