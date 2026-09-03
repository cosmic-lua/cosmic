# D43 — generation 1 seeds `cosmo.*` declarations from the tree's own cosmos pin, not the pinned binary

- **date:** 2026-09
- **status:** active
- **context:** build generation 1 compiles the whole tree under
  `bin/cosmic.pin`'s pinned release — its checker and its patch set —
  before `--make ci` converges and re-judges everything with the
  checker the tree just built. Before this record, generation 1 also
  resolved its `cosmo.*` and `tl` type declarations from that same
  pinned release: a generator's import closure compiles ahead of the
  generator running it, and on a cold tree `o/_types/types_gen` does
  not exist yet, so that compile fell through to the documented
  fallback — the running binary's bundled `/zip/.types`, whatever
  release built it. Those declarations are themselves generated from
  `tool/net/definitions.lua` in whatever cosmos release
  `3p/cosmos/cosmos_pin.tl` names, a pin bumped independently of, and
  typically far more often than, `bin/cosmic.pin`. A `cosmo.*` contract
  change lands in `definitions.lua`, and a tree adapted to it needs its
  own freshly generated declarations to type-check against — but
  generation 1 was checking against the OLD release's bundled types
  instead, so a tree carrying an adapted `cosmo.*` shape failed cold,
  on a fresh clone, with no `--make ci` cache to hide the gap. No
  cosmic release could close it either: a release is cut from a tree
  that has already adapted to the new shape, and that same tree is
  what needed the fresh declarations to cold-build in the first place.
- **decision:** generation 1 seeds `o/_types/types_gen` — the directory
  every project's compile include path hardcodes first — by running
  `_types/types_gen.tl` itself, unclosed, straight against the running
  binary's own helpers, before any generator's import closure compiles.
  That seed pass reads `3p/cosmos/cosmos_pin.tl` — the FETCHED pin, the
  one this checkout just resolved — never `bin/cosmic.pin`'s bundled
  `/zip/.types`. Generation 1 therefore draws on two different pins for
  two different things: `bin/cosmic.pin` supplies the CHECKER — the
  Teal compiler and its carried patch set — and `3p/cosmos/cosmos_pin.tl`
  supplies the `cosmo.*` DECLARATIONS that checker checks the tree
  against. A `cosmo.*` contract change now stages behind a cosmos pin
  bump alone: bump `3p/cosmos/cosmos_pin.tl`, fetch, and the adapted
  tree cold-builds under the new shape without waiting on a cosmic
  release. A change to the upstream annotation FORMAT itself — what
  `_types/gentype.tl` parses `definitions.lua` into — still stages the
  old way, like any other checker change: land it in
  `_types/gentype.tl`, ship a release, bump `bin/cosmic.pin` to carry
  it, then bump the cosmos pin.
- **rejected:**
  - dual-shape wrappers: give every changed binding two type shapes and
    cast between them at each call site, so a wrapper compiles under
    both the old and the new declarations. Rejected because the casts
    do not expire once the seed pass makes them unnecessary — a wrapper
    adapted this way carries a permanent, unsound cast that outlives
    the contract change it was written for, trading one PR's build for
    every later reader's ability to trust the declared type.
  - reordering the generators so the types generator runs before the
    closure compile that needs it. Rejected because the closure that
    fails is `_types/types_gen.tl`'s OWN closure: the generator that
    produces `cosmo.*` declarations needs those same declarations to
    type-check the helpers it imports before it can run at all. No
    ordering of two generators resolves a generator that depends on
    its own output.
  - an intermediate cosmic release cut between the `cosmo.*` change
    landing and the tree adapting to it, to give generation 1 something
    fresher than the current pin to fall back on. Rejected because it
    cannot be built: the release is itself produced by a cold build of
    the adapted tree, which is exactly the build this record exists to
    unblock.
- **consequences:** a cold build — a fresh clone, CI's `build` and
  `repro` lanes — now checks `cosmo.*` shapes against the pin this
  checkout actually fetched, rather than against whatever shape
  happened to ship in the trust root's release. The trust root's
  bundled types stop being what a cold build checks a `cosmo.*` call
  against; they remain the checker's compiler and patch set, and the
  bundled-types fallback still exists for every downstream project with
  no `_types/types_gen.tl` of its own. `3p/cosmos/cosmos_pin.tl` and
  `bin/cosmic.pin` now carry two independent staging rules instead of
  one, and the next reader has to know which applies before reaching
  for either: a checker or annotation-format change waits on a release,
  a `cosmo.*` contract change does not. Revisit if the seed pass and the
  generator it seeds ever need to check against a third source — a
  cosmos release the tree has fetched but not yet adapted to, say —
  since the seed pass assumes the fetched pin and the closure it seeds
  always target the same contract.
