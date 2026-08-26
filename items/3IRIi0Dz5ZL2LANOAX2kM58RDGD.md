## Goal

G3, via the cosmo-contracts container: make the contract doctrine
durable. The rule the container works by — which failures raise and
which return the fallible tuple — currently lives only in the
container's own spec, which leaves the board when the container ends.
A binding author reading whilp/cosmopolitan today finds no statement
of it, so the census's classifications decay as new bindings arrive.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815`:

- `AGENTS.md`'s Conventions section states that binding contracts are
  frozen at the C boundary and that `definitions.lua` updates ride the
  same commit — nothing about what shape a NEW or deliberately changed
  contract must take: `grep -c "raise" AGENTS.md` reports 0.
- The doctrine's precedents are all already in-tree: issue #151
  converted data-dependent throwers TO `nil, err`
  (`tool/lua/test_lfuncs_errors.lua` pins DecodeHex, Inflate,
  GetCryptoHash); PR #276 (`path.join`) and PR #277 (`clock_gettime`)
  converted degenerate-input nils TO raises.
- `tool/net/definitions.lua` (8276 lines) opens with annotation
  mechanics only; an annotator deciding a return shape has no rule to
  consult.
- The backlog item 3IHCM4K2 (an introduction bar for new C binding
  code) lists EINTR, malloc-across-raise, bounds, error-path tests —
  the QUALITY bar; this slice writes the CONTRACT-SHAPE rule, which
  that bar can later reference rather than restate.

## Change

1. **`AGENTS.md`** (whilp/cosmopolitan), in the Conventions section,
   one new bullet stating the rule, in three sentences:

   - An argument-shape error — a degenerate input no correct program
     passes (zero or all-nil components, an invalid clock or fd
     constant, a malformed flags value) — raises through
     `luaL_argerror`/`luaL_error`.
   - A failure a correct caller can meet at runtime — bad input DATA
     or a changed ENVIRONMENT (ENOENT, EINTR, a truncated buffer) —
     returns the fallible tuple: `value|nil, err:string, errno?`, the
     error always in slot 2, nothing else sharing a slot.
   - When slot 1 of a declared return admits nil, slot 2 is the error
     — an annotation that deviates is a bug, and a contract change to
     conform is made deliberately (definitions.lua same commit,
     conformance probe same PR), never inside another change.

   Cite the three in-tree precedents by number in the bullet so the
   rule reads as recorded practice, not aspiration.

2. **`tool/net/definitions.lua`** header comment: two lines pointing
   at the AGENTS.md bullet, so an annotator deciding a return shape
   finds the rule from the file they are editing.

## Non-goals

- No C changes and no reclassification of any existing binding — the
  census children own reachability judgments, one namespace at a time.
- No edits to `tool/lua/test_definitions_conformance.lua` — probes
  ride the contract slices that change behavior, and this one doesn't.
- No restating of the quality bar 3IHCM4K2 will define (EINTR,
  malloc-across-raise, bounds); shape only.
- No cosmic-side docs — cosmic's own doctrine (AGENTS.md, D20 rule
  11, D23) already says its half.

## Acceptance

Run from the cosmopolitan repo root:

- `grep -c "argument-shape" AGENTS.md` reports 1 or more (today 0).
- `grep -c "AGENTS" tool/net/definitions.lua` reports 1 or more
  (today 0).
- `make -j$(nproc) o//tool/lua/test` exits 0 (docs-only diff; the
  gate still binds every PR).

## Enablement

none needed. Docs-only; parallel-safe with every sibling.
