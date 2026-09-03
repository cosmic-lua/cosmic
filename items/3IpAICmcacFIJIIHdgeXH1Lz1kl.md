## Evidence

The cold-build rule as CLAUDE.md states it today (`grep -n "cold-build rule" -A9 /home/user/cosmic/CLAUDE.md`):

```text
**The cold-build rule** is convergence's flip side: build generation 1
compiles the WHOLE tree — not just `cosmic/**` — with the pinned
release's checker and patch set, so a source that needs the tree's own
checker (a new narrowing rule, a new patch entry) passes the converged
`--make ci` and fails only a cold build.
```

What it leaves unsaid is where generation 1's `cosmo.*` DECLARATIONS
come from. Today: the running binary's bundled `/zip/.types`
(`_make/generate.tl:133-139`, the documented fallback), i.e.
`bin/cosmic.pin`'s release — so a cosmos contract change cannot
cold-build under any pin whose bundled types predate it, and no pin
can carry it until the adapted tree builds. Board item
`3IoULYAu` (handle «1FGT_ZOR3») holds the measured deadlock (both
generators' closures reach changed bindings) and the adopted
resolution: a seed pass that generates the declarations from the
FETCHED `3p/cosmos` pin before any closure compiles, filed as
«pawY_zI7x». The losing options are recorded there too: dual-shape
wrappers (casts, permanent), generator reordering (does not help), an
intermediate release (cannot be built).

Latest record: `ls /home/user/cosmic/docs/decisions | grep -oE '^d[0-9]+' | sort -t d -k2 -n | tail -1` → `d42`; this one is `d43`.

## Change

`docs/decisions/d43-<slug>.md`: a new record in the four-section
form the `decide` skill prescribes (`skills/decide/SKILL.md`; the H1
grammar the index derives from). The tradeoff: generation 1 takes its
CHECKER from `bin/cosmic.pin` but its `cosmo.*` declarations from the
tree's own `3p/cosmos` pin, via a seed pass, so a cosmos contract
change stages behind a cosmos pin bump alone and never behind a cosmic
release. What was given up: the trust root's bundled types are no
longer what a cold build checks against, and a change to the upstream
annotation FORMAT now stages like a checker change (land it in
`_types/gentype.tl`, ship a release, bump `bin/cosmic.pin`, then bump
the cosmos pin). Name the two pins and the two staging rules
explicitly; cite no board ids, PR numbers or sessions in the record
(docs-style: no history references).

`docs/decisions/README.md`: regenerate the derived index the way the
`decide` skill says the index is produced; never hand-edit a row.

`CLAUDE.md`, the "cold-build rule" paragraph: add one sentence after
"with the pinned release's checker and patch set": the cosmo
declarations it checks against are seeded from the tree's `3p/cosmos`
pin, not the pinned binary, and link the new record. Keep the
paragraph's existing staging example intact.

`_build/coldbuild_test.tl`: read its header comment; if it states that
generation 1 resolves `cosmo.*` from the pinned binary, correct the
sentence — behaviour is «pawY_zI7x»'s change, this item touches prose
and the record only.

## Non-goals

No engine change (that is «pawY_zI7x»); no amendment to D26 or the
decide skill; no change to which files the strip floor or the
generators own.
