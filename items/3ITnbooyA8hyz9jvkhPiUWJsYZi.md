## Capture

Cosmopolitan master now carries the base64 durability pins — #281
(IsBase64's alphabet scan) and #282 (DecodeBase64's quantum loop),
both `.balign 64` ahead of the hot loop, both measured no-ops on the
current roll and both removing a demonstrated placement lottery
(±93% on IsBase64 across otherwise identical builds). The #282 merge
(3977e62f) triggers the cosmos release workflow; the release tags
`YYYY.MM.DD-<short-sha>`.

Work, once that release publishes: bump `3p/cosmos/cosmos_pin.tl`
(version + sha256 from the release's own SHA256SUMS), then
`bin/cosmic --make fetch && bin/cosmic --make ci` (types regenerate in
the build; no separate step), plus the compare gate against a baseline
taken on the OLD pin — quote the codec_base64_roundtrip_64k line in
the bump commit, since this pin is the one that carries its fix class.
Verify eligibility with `git merge-base --is-ancestor 3977e62f
<release sha>` in a cosmopolitan checkout.
