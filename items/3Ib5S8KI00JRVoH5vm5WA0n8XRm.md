## Change

Bump the board branch's `bin/cosmic.pin` to the release main already
pins, so the board's toolchain carries `cosmic.shape` (and the rest of
the late-August stdlib).

Measured 2026-08-29: the board's pin is
`2026-08-17-f421fa1` / sha256 d00aef83ff714163da06e1457c3274008832a9d8956e015e8c4ee69664cca46f;
main's is `2026-08-27-555873e` / sha256
145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900 —
a proven combination, since main's whole gate runs under it.
`require("cosmic.shape")` under the board's current pin fails
`module not found: 'cosmic.shape'` (reproduced by a builder bounce on
3Ib4KH0q).

The change: in `bin/cosmic.pin`, set the url line to
`url = https://github.com/whilp/cosmic/releases/download/2026-08-27-555873e/cosmic-lua`
and the sha256 line to
`sha256 = 145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`
— both fields together, nothing else in the file. Then prove the
toolchain: from a cold checkout of this branch, delete `o/`, run
`bin/cosmic --make fetch` and `bin/cosmic --make ci` and read
`ci: PASS`; the pin decides which fence and checker the gates run
under, so the whole gate under the new pin IS the acceptance.

## Non-goals

No machinery changes ride along — if the new toolchain's gate refuses
existing `_work/**` code, that is a bounce naming what broke, not a
fix-up in this diff.
