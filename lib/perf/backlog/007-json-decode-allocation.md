# 7. json decode allocation pressure

- status: rejected (2026-07) — at the cosmic layer; see entry 21 for
  the cosmopolitan-side follow-up
- layer: cosmic
- scenario: json_decode_large

- evidence: ~1.3ms/op, ~375KB allocated per op.
- finding: the wrapper (lib/cosmic/json.tl) is a two-line delegation
  to `cosmo.DecodeJson`; the allocation is the decoded table graph
  itself (1000 records × maps/arrays), which is the workload's
  output, not overhead. no cosmic-layer fix exists; a
  cosmopolitan-side arena would change object lifetimes. revisit only
  if a scenario shows GC pauses dominating a real workload.
- the C-side implementation (`ljson.c` in whilp/cosmopolitan) is fair
  game, though — see entry 21.
