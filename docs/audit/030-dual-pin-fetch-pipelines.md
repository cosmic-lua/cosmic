# 030 — two live pin-fetch pipelines over the same committed files

severity: medium (drift generator)
type: refactor
area: `_make/pin.tl` + `_make/fetch.tl` vs `_build/build-fetch.tl`

## issue

the same committed `*.pin.tl` files are read by two independent pipelines:
the new `--make fetch` (`_make/pin.tl` + `_make/fetch.tl`) and the old
Makefile path (`_build/build-fetch.tl`, wired via `mk/deps.mk:34-35`).
commit 180b0d3 says outright they "read the SAME committed files" — which
is why pins grew dual `sha`/`platforms` spellings, so one file can satisfy
both readers.

4a15b92 narrowed the observable drift by *copying* behaviors across
rather than sharing code: `_make` now checks http status, caps responses,
retries, and validates the url-derived name — each a second
implementation beside `_build`'s. what remains different:

| behavior | `_make` | `_build` |
|---|---|---|
| interpolation | `{version}`, `{platform}` only | any scalar field `{key}` |
| name validation | `^[%w._%-]+$` in `pin.read` | `validate_archive_name` |
| unpack manifest / repair | `.unpacked` manifest, re-unpack | none |

the interpolation drift is the sharp one: a pin using any other placeholder
works on one side and produces a garbage url on the other. today's two
committed pins use only `{version}`, so it is latent. and the copied
behaviors re-diverge the moment either side changes — duplication is now
larger than before the fix pass, which strengthens rather than weakens
the case below.

## plan context

make-plan.md 3i schedules "`--make fetch` replaces `_build/build-fetch.tl`"
— the full retirement waits on the bridge. but every week both live, a pin
edit can pass one reader and break the other.

## suggested fix

short of the full 3i retirement, unify the *reader* now: extract one shared
pin-resolution module (parse, field validation, interpolation, landing-path
derivation — the pure parts, no io) that both pipelines call, keeping only
the transport differences local. this is the same move that already worked
once on this branch (`cosmic.literal` extracted as the shared literal
reader in 3g). fold 006 and 019's fixes into the shared half so they land
once.

## verification

after unification: both pipelines resolve both committed pins to identical
urls, digests, and landing paths (a table-driven test over the shared
module), and a pin exercising `{platform}` behaves identically through
each.
