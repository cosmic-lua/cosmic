The compact literal encode pays more for its guard than for its
encoding. Measured 2026-08-25 at main a0c4ebd, 221KB config-shaped
payload (10k string-keyed entries, mixed scalars, 30 iterations, two
consistent runs): raw `cosmo.EncodeLua(t, {sorted=true})` is 3.65
ms/op, `literal.format(t, {layout="compact"})` is 7.93 ms/op — the
Teal `is_compact_writable` domain walk
(cosmic/_literal_format.tl:395-407) more than doubles the encode.
For scale, `cosmo.EncodeJson` on the same value is 2.83 ms/op. The
hypothesis: fold the domain check into the encode pass — either
teach the C encoder to refuse the literal domain's exclusions (a
definitions.lua contract change in whilp/cosmopolitan, landed as its
own change per that repo's conventions) or restructure the walk to
short-circuit per table instead of pre-walking the whole value. The
optimize skill's compare gate is the acceptance; parse(format(v))
fidelity and the refusal set must not move (the strict walk exists
because the C encoder spells some values the reader refuses — byte
27, reserved keys, math.mininteger — so any fold must keep those
handed off to the pin layout).
