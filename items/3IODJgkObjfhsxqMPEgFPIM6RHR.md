The checker admits an unnarrowed `T | nil` everywhere except an
index: it passes into a non-nil parameter, a declared non-nil local,
arithmetic and concatenation, so an unguarded union becomes a
runtime nil downstream. The gap is pinned as fact by
cosmic/teal_narrowing_test.tl (test_nil_union_is_admitted_outside_an_index,
line 222) and stated as doctrine in AGENTS.md's narrowing section
(92 lines today: `awk '/^### Error Handling Patterns/,/^## Build
System/' AGENTS.md | wc -l`, measured 2026-08-25). This is the
deepest "types never lie" gap: closing it makes the checker DEMAND
narrowing at every non-nil sink, which is what lets the doctrine
shrink toward a footnote (G3's win condition). Upstream-first: a
strict nil-flow mode in tl, carried-patch if blocked; expect this to
decompose (measure the tree's violation count first — every site the
strict mode flags is a latent unguarded union) rather than land as
one slice.
