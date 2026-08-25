## Goal

G3 — an honest type layer. One declaration produces **26 of the 358**
unguarded-nil sites `docs/design/nil-flow.md` measured, and its nil is
unreachable from every call in this tree. It is the single largest
mechanical win in the census and the only one that lives in
whilp/cosmopolitan.

## Evidence

`o/_types/types_gen/cosmo/path.d.tl:40` declares:

```text
  join: function(str?: string, ...: string): string | nil
```

Its own generated doc comment, from `tool/net/definitions.lua` in
whilp/cosmopolitan, says: "If exclusively `nil` arguments are passed,
then `nil` is returned." No call site in this tree passes exclusively
nil arguments — every one passes at least one non-nil path — so the nil
member is unreachable and the union is a declaration Teal cannot make
precise.

The cost is a cascade, not 26 independent sites.
`cosmic/fs/tree.tl:28-29` reads

```text
      local s = cosmo_path.join(src, entry)
      local d = cosmo_path.join(dst, entry)
```

and the file's remaining eight flagged sites are `s` and `d` being
spent as arguments and concatenation operands.

Per-class and per-file figures: `grep -c` over
`docs/design/nil-flow-sites.tsv`.

## Change

In whilp/cosmopolitan, decide and record the honest contract for
`path.join` at the C boundary. Two shapes are available and the slice
must pick one with reasoning, not taste:

1. Declare the first parameter required (`str: string`) so the return
   is `string`, and let the all-nil case keep whatever runtime
   behaviour it has today.
2. Keep the signature and accept the union, closing the 26 sites on the
   cosmic side with guards.

If (1): update `tool/net/definitions.lua` in the same commit as any C
change, per that repo's AGENTS.md contract-freeze rule; then on the
cosmic side bump the cosmos pin, `--make fetch && --make build` to
regenerate the types, and fix whatever the narrower type breaks.

Prefer routing callers through `cosmic.fs.join` where the wrapper can
state the contract Teal can express, rather than widening call sites.

## Non-goals

- Do not add a cast at any of the 26 sites.
- Do not change any other `cosmo.path` binding's contract in passing.
- Do not fix sites belonging to other producers; this slice owns one
  declaration.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes in whilp/cosmopolitan if
  that repo is touched, and `definitions.lua` moves in the same commit.
- On the cosmic side `bin/cosmic --make ci` ends `ci: PASS`.
- Re-deriving the census (the command in `docs/design/nil-flow.md`'s
  `## Method`) shows zero sites attributed to `path.d.tl`'s `join`.
