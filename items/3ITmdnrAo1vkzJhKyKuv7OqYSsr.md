`3ISVlHT6`'s narrow-pack-n probe does not discriminate the two pins the
way its spec says, and the wrong version travelled: the item's
`## Evidence` states it, its `## Enablement` calls it "the one fact a
puller must not invert", PR #1421's body repeats it, and the review
comment on that PR repeats it again. The claim is that under the
pre-patch checker `table.pack(1, "a").n` is `any`, so
`local s: string = t.n` PASSES, and that the new pin is therefore
"proven by the REFUSAL".

Measured 2026-08-27 against both release assets, each verified by
sha256 against the pin lines PR #1421 changes — old
`5161fd8c7b6de8c3f2c49a8b5a02d87e2356955d154f81fca253ec2182165e9d`
(`2026-08-15-c497c04`), new
`9f81e916ed78afacbc04a8cd901b8dc77b15638785f9ecc2c944b215b55799dd`
(`2026-08-27-afad5b5`) — on a two-line probe file
(`local t = table.pack(1, "a")` then `local s: string = t.n`):

```
old: packn-probe.tl:2:20: error: in local declaration: s: got <any type>, expected string   (exit 1)
new: packn-probe.tl:2:20: error: in local declaration: s: got integer, expected string      (exit 1)
```

Both REFUSE, and both exit 1. A declared `local s: string = <any>` is a
type error under either checker — an `any` does not assign anywhere in
a declared local, whatever it does elsewhere — so pass-versus-refusal
carries no signal at all here. What discriminates is the MESSAGE:
`got <any type>` before the patch, `got integer` after. The
2026-08-23 release behaves like the old pin, as expected, since
`1ca3f7ff` merged 2026-08-26.

Nothing landed wrong: PR #1421's quoted transcript happens to show
`got integer`, so the evidence it presents is real proof and the pin
bump is correct and independently verified. The risk is forward. A
literal-minded session following the stated discriminator would accept
"the probe refused, therefore the new checker is in" — which is true of
the OLD binary too, so the check passes vacuously and a pin bump that
silently failed to move would read as proven.

The fix is the probe, not prose about it: a discriminating probe must
have opposite EXIT STATUS on the two sides. `local n: integer =
table.pack(1, "a").n` is one candidate — under the patch `.n` is
`integer` and it compiles, under the old checker it is `any` and it
does not — which is the direction the current spec claims but inverted,
and it should be verified against both assets before it is written into
any item rather than reasoned out. Whatever probe is chosen, the two
places to correct are `3ISVlHT6`'s `## Evidence` and `## Enablement`
(now landed history, so a correction note rather than an edit) and
whatever `3ISPGV8z` and the next pin-bump item inherit from them.
