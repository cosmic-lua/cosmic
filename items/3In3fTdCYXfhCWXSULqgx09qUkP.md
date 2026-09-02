## Question

`bnpp_lZOK`'s `cosmic.sqlite.open` `extensions` option consumes a C-side
`db:register_extension(name)` entry point and an `lsqlite3.Extension`
Teal-enum alias in `definitions.lua` that this repo's currently pinned
cosmos release does not carry. Does `3p/cosmos/cosmos_pin.tl` need
bumping past what `utpf_HTkH` (already in flight, bumping for FTS5) is
targeting, or does that bump already land past the commit this item
needs?

## Evidence

Found by the builder of `bnpp_lZOK` while attempting to build it, against
the pin at the time (`3p/cosmos/cosmos_pin.tl` → `2026.08.31-6dfa6728a`,
same one `utpf_HTkH`'s Evidence section also found lacking FTS5):

```
$ grep -n "register_extension\|lsqlite3.Extension\|lsqlite3.extensions\b" definitions.lua   # unzipped from the pinned cosmos lua binary
(no output)
```

`o/_types/types_gen/cosmo/lsqlite3.d.tl` (generated from that pin) has
no `register_extension`, no `extensions()`, no `Extension` alias.

The registration mechanism `bnpp_lZOK` needs was added to
`cosmic-lua/cosmopolitan` by commit `405d8840` ("lsqlite3: register a
sqlite extension by name, per connection", PR #364) — confirmed on
`cosmic-lua/cosmopolitan` `origin/master`, `definitions.lua` at HEAD
there has the exact shape `bnpp_lZOK` expects.

`405d8840` lands strictly AFTER `d88e994f` (the commit `utpf_HTkH`
targets for FTS5): `git merge-base --is-ancestor d88e994f 405d8840`
confirms the ancestry, and `git log --oneline d88e994f..405d8840` shows
5 intervening commits. So the specific release `utpf_HTkH`'s Evidence
names as the earliest FTS5 carrier (`2026.09.02-d88e994fc`, published
2026-09-02T10:29Z) predates `405d8840` and does NOT carry
`register_extension` — but `utpf_HTkH`'s `## Change` only says "a
cosmos release at or after 2026.09.02-d88e994fc," not that specific one,
so its builder may or may not land on one that also carries `405d8840`.

As of this writing, `cosmic-lua/cosmopolitan`'s latest published release
is `2026.09.02-7b5a1f609` (2026-09-02T19:45Z), built from current
`master`, which DOES carry `405d8840` (and everything `utpf_HTkH`
needs). A release satisfying both items already exists.

## Change

Whichever lands second between `utpf_HTkH` and this question: confirm
the pin `utpf_HTkH` bumped to also carries `405d8840` (check
`register_extension`/`lsqlite3.Extension` are present in the built
`definitions.lua`/generated types). If it does, this question closes as
"already satisfied by utpf_HTkH's bump, no further pin bump needed" and
`bnpp_lZOK` unblocks. If `utpf_HTkH` landed on an earlier release than
`405d8840`'s, file (or this question becomes) a further pin bump to a
release at or after `2026.09.02-405d8840d` (or whatever tag the actual
release carrying it turns out to be).

## Non-goals

- Not building `bnpp_lZOK` itself — that resumes once this question
  closes.
- Not re-litigating `utpf_HTkH`'s own scope or FTS5 target.
