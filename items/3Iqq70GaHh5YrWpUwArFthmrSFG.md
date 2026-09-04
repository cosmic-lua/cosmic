## Evidence

Found while proving the trust-root pin bump «Xvox_XNCM» (its spec
names the fixpoint test as the two-build proof). The test fails
identically on `origin/main` at `f9f31a26` with the OLD pin
(`2026-08-31-a5b36f4`), so it is a standing break, not the bump's:

```
$ COSMIC_FIXPOINT=1 bin/cosmic --make test _make/fixpoint_test.tl
o/_make/fixpoint_test.lua:193: gen2: --make build should succeed:
make: root=…/fixpoint-gen2
generate _types/tlast_gen.tl
generate _types/types_gen.tl
build: FAIL (make)
make: _build/coldbuild_test.tl declares `reads: o/bootstrap/cosmic`, which does not exist
```

Mechanism: `generation()` (`_make/fixpoint_test.tl:182-196`) copies
the working tree minus everything generated (`copy_tree`, `:71-101`)
and seeds only the five pinned inputs under `o/3p` (`seed_pins`,
`:106-131`: `tl.lua`, `tl.tl`, `make`, `lua`, `lua-debug`). The copy
therefore has no `o/bootstrap/cosmic`, while
`_build/coldbuild_test.tl:1` declares
`--- reads: … o/bootstrap/cosmic o/_types/types_gen`, and the build
refuses a declared read that does not exist before the graph runs.
Nothing ran this test after that declaration landed: it is opt-in
(`COSMIC_FIXPOINT=1`), and pr.yml's `build` lane asserts convergence
on the real artifact by other means, so the break was invisible.

`git log -1 --format='%h %ad' --date=short -S'o/bootstrap/cosmic' -- _build/coldbuild_test.tl`
at pickup names the commit that added the declaration; re-run the
test to confirm the message before changing anything.

## Change

One edit to `_make/fixpoint_test.tl`: `seed_pins` also seeds the
trust root — copy `o/bootstrap/cosmic` (and `o/bootstrap/cosmic.pin`
beside it, which `bin/cosmic` reads to decide whether the cached
bootstrap matches the pin) into the copied tree, with a comment
saying why: a declared read must exist for the build to start, and
`_build/coldbuild_test.tl` declares the bootstrap. Add both to the
`want` table (`:107-118`) as `{"bootstrap", "cosmic",
"o/bootstrap/cosmic"}` / `{"bootstrap", "cosmic.pin",
"o/bootstrap/cosmic.pin"}`, or a sibling list if the tuple's first
two fields are used to name the pin in a message (read `:119-129`).
The two generations then run to `test_the_fixpoint_converges`.

Proof: `COSMIC_FIXPOINT=1 bin/cosmic --make test _make/fixpoint_test.tl`
ends `test: PASS`, and `bin/cosmic --make ci` ends `ci: PASS`.

Wall: no change to `_build/coldbuild_test.tl`'s declaration; a
declared read that does not exist staying a refusal is the point.

## Non-goals

Not un-gating the test (it stays behind `COSMIC_FIXPOINT=1`); not
adding it to CI.
