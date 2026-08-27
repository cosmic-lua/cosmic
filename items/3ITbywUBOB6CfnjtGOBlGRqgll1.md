## Capture — a human decision, not code

The codec_base64_roundtrip_64k regression (+21% on the release host,
cosmos 354c17e08, bisect 3ITOUv0w) has a diagnosed layout mechanism
but no locally validatable fix: 3ITVR6Ku restored the hot entries'
64-byte alignment (whilp/cosmopolitan PR #280, draft) and the
rel-vs-rel interleave shows it recovers nothing on the measuring
host, whose own expression of the effect is ~+3.6% steady-state
(+25.7% only while boosted) — inside pairwise spreads. With internal
layout equality restored and no recovery, the remaining mechanism is
relative-position (BTB/frontend aliasing against the Lua VM loop)
and/or frequency-dependent — not addressable by pinning symbols, and
only measurable on the release CI host class.

The release lane stays red until one of two calls, both outward-facing
and therefore a human's:

1. **Merge PR #280 and let release.yml measure it** — the compare
   step (new release vs previous) is the only instrument on the
   affected host class; the change is three alignment attributes, no
   behavior or contract move, upstream tests green. If the gate stays
   red, the PR cost nothing and option 2 remains.
2. **Re-baseline**: dispatch release.yml with `perf_gate: false`
   once, accepting +21% on this scenario as the new floor — the
   workflow's own documented path for a deliberate accept. The
   regression stays real for base64-heavy users on that host class.

Blocked work behind this decision: 3ISVlHT6 (pin bump to a
narrow-pack-n release) → 3ISPGV8z (pack-n cast retire).
