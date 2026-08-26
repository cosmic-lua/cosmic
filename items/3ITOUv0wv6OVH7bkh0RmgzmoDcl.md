## Evidence

`3ITHROpY` narrowed the `codec_base64_roundtrip_64k` regression from
five cosmos commits to three, but could not name one, because the host
it ran on was too noisy for the disjoint-ranges condition its verdict
rule requires. Two of the five are eliminated with certainty and need
never be measured again: the `lua` runtime inside the published
`cosmos.zip` is BYTE-IDENTICAL across `2026.08.21-07fc94a1c`,
`2026.08.23-bf92718a1` and `2026.08.23-8e071ec98`
(sha256 `b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b`
for all three, from `sha256sum o/3p/cosmos/lua` after `--make fetch` on
each pin), so `bf92718a1` (AGENTS.md only) and `8e071ec98` (sqlite3
header stubs behind untaken guards) changed no compiled byte. The
surviving candidates are `5bfcf79d0` (zipos stored-member handle
recycling), `8dd093cea` (EncodeJson float formatting) and `354c17e08`
(the 650-line `tool/net/llua.c` DecodeLua parser) — git range
`8e071ec98..354c17e08`.

What `3ITHROpY` measured, on cosmic tree `5ef13f40` with only the two
pin lines varied, four isolated round-robin readings per arm: medians
`07fc94a1c` **143.43 µs** [139.06, 174.27], `5bfcf79d0` **145.93 µs**
[137.29, 151.11], `8dd093cea` **158.75 µs** [141.29, 179.72],
`354c17e08` **180.28 µs** [167.03, 189.64]. The same-binary noise
floor from eight `gate.tl selfcheck` passes was **6.5%**. The medians
rise monotonically and `354c17e08` is **+25.70%** over the base — far
past the floor — but the base arm's own four readings spanned 139.06
to 174.27 µs, a 25% internal swing that overlaps every other arm's
range, so all three pairs read NOT REPRODUCED under the rule's second
condition. The direction and magnitude agree with `3ISlWFiS`'s
confirmed +8.35%; only the separation is missing.

**What this item is.** Re-measure the three surviving candidates plus
the `07fc94a1c` base with an instrument that survives host noise: more
isolated readings per arm than four, and/or a verdict rule stated in
terms robust to a single outlier reading rather than a raw min/max
range. Deciding that rule is refinement's job, not the measuring
session's — `3ITHROpY` correctly refused to change its own rule
mid-slice, which is why this item exists. The arms are cheap and
already characterised: each is a two-line edit to
`3p/cosmos/cosmos_pin.tl` in a worktree at `5ef13f40` plus
`--make fetch && --make build`, the shas are recorded on `3ITHROpY`'s
`## Result`, and the built `o/bin/cosmic` digests are reproducible
across sessions (`3ITHROpY` rebuilt two of `3ISlWFiS`'s arms
byte-for-byte).

Any fix that follows lands in whilp/cosmopolitan and must not move a
binding contract: return shapes, error values and constants at the C
boundary are frozen for cosmic's generated types.
