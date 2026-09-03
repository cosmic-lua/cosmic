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

**Update 2026-09-03, research pass.** Re-checked all of the above
against the current tree; the facts above still hold (pin still at
`2026.08.31-6dfa6728a`, `405d8840`'s ancestry unchanged, latest
published release still carries it). But the premise the `## Change`
below was written against no longer holds:

- `utpf_HTkH` (board item `3ImjB20Oly8ZWwt0lMAutpfHTkH`) has **not**
  landed a pin bump. Its builder pass hit a systemic blocker and the
  item was dropped: `blocked_by = "3IkSSqvH4BLD8YdvdYwohk2Pemz"` (board
  commits `f5695cce block 3ImjB20O on 3IkSSqvH`, `e4e2c823 drop
  3ImjB20O`). `3p/cosmos/cosmos_pin.tl` on `main` is unchanged since
  utpf_HTkH's own Evidence was written.
- The blocker, item `3IkSSqvH4BLD8YdvdYwohk2Pemz` ("a binding-contract
  pin bump cannot fix any wrapper reachable during the build's own
  generation phase"), establishes that **any** pin bump crossing a
  release where 8 specific files (`cosmic/fd.tl`, `cosmic/fs/ops.tl`,
  `cosmic/fs/file.tl`, `cosmic/embed/init.tl`, `cosmic/child/init.tl`,
  `cosmic/proc/rusage.tl`, `cosmic/time.tl`, `_cli/main_handlers.tl`)
  change a destructured `cosmo.*` binding's shape breaks `--make ci` no
  matter which destructuring style (old or new) those files carry —
  proven against the `d88e994fc` target with a fresh clean-tree build.
  Its `## The decision needed` is unresolved as of this writing (no
  `builders`/`claim` on that item).
- **This item's own target inherits that blocker in full, not just by
  extension**: `d88e994f` (FTS5) and `b2a49c60` (the mkstemp shape
  change `3IkSSqvH` already reproduced the failure against) are both
  confirmed ancestors of `405d8840`
  (`git merge-base --is-ancestor b2a49c60 405d8840`,
  `git merge-base --is-ancestor d88e994f 405d8840`). Any pin bump
  reaching `405d8840` necessarily also crosses every commit `3IkSSqvH`
  already found breaking, so this item's target is not independently
  bumpable while `3IkSSqvH` is open — it was never just "further along
  the same road," it is blocked by the identical deadlock.
- **New evidence beyond what `3IkSSqvH` currently documents**: one more
  binding-shape change lands strictly inside the range this item's
  target has to cross. `46ae1472` ("unix.wait: return one WaitResult
  table instead of sharing slots with errors", #340,
  2026-09-02T15:26:37Z, published as release `2026.09.02-46ae1472b`)
  rewrites `unix.wait`'s success shape from three positional values
  into one `unix.WaitResult` table, and is a confirmed ancestor of
  `405d8840` (`git log --oneline d88e994f..405d8840` lists it,
  between `d88e994f` and `405d8840`). `3IkSSqvH`'s own list of at-risk
  wrappers already includes `cosmic/proc/rusage.tl`, the file most
  likely to destructure `unix.wait`'s old shape — but `3IkSSqvH`'s
  probe was run only against `d88e994fc`, not this far downstream, so
  it has not yet reproduced or measured this specific break.
- The exact release tag carrying `405d8840` is confirmed via GitHub:
  `2026.09.02-405d8840d`, published 2026-09-02T18:53:51Z (between
  `2026.09.02-46ae1472b` at 15:44:26Z and the next commits). `git show
  405d8840:tool/net/definitions.lua | grep -n
  "register_extension\|Extension"` confirms the exact shape
  `bnpp_lZOK` needs: `---@alias lsqlite3.Extension
  "regexp"|"series"|"zipfile"` and
  `function lsqlite3.Database:register_extension(name) end` (parameter
  typed `lsqlite3.Extension`).

## Change

**Superseded by the 2026-09-03 update above.** The original either/or
below cannot be evaluated as written, because `utpf_HTkH` has not
landed any bump — it hit the same systemic blocker this item's own
target inherits.

~~Whichever lands second between `utpf_HTkH` and this question: confirm
the pin `utpf_HTkH` bumped to also carries `405d8840` (check
`register_extension`/`lsqlite3.Extension` are present in the built
`definitions.lua`/generated types). If it does, this question closes as
"already satisfied by utpf_HTkH's bump, no further pin bump needed" and
`bnpp_lZOK` unblocks. If `utpf_HTkH` landed on an earlier release than
`405d8840`'s, file (or this question becomes) a further pin bump to a
release at or after `2026.09.02-405d8840d` (or whatever tag the actual
release carrying it turns out to be).~~

**Current Change**: block this item directly on
`3IkSSqvH4BLD8YdvdYwohk2Pemz` — the true, shared root blocker — rather
than on `utpf_HTkH`/`3ImjB20O`, mirroring `3ImjB20O`'s own block-first
move onto the same item (blocking on the intermediate item would just
relay the same wait one hop later once it is re-pulled). Once
`3IkSSqvH` resolves its decision (a) [stage behind a `cosmic-lua`
release + `bin/cosmic.pin` bump carrying the new shapes first] or (b)
[decouple the generators' subprocess spawn from the affected bindings],
re-open this item's original either/or against whatever pin bump
actually lands:

- if that bump already targets a release at or after
  `2026.09.02-405d8840d`, this question closes as satisfied and
  `bnpp_lZOK` unblocks on this leg with no further pin bump;
- otherwise this item still needs a further bump — but its target is
  already fully identified and needs no more discovery:
  `2026.09.02-405d8840d` (confirmed above), or any release built from a
  commit at or after `405d8840`.

Noted for whoever resolves `3IkSSqvH` (not a scope change to either
item): since both `d88e994fc` (utpf_HTkH's FTS5 target) and
`405d8840d` (this item's register_extension target) are blocked by the
identical root cause, and `405d8840d` is strictly downstream of and a
superset of `d88e994fc`, one pin bump straight to `2026.09.02-405d8840d`
or later would satisfy both items' needs in a single pass.

Gate: unchanged from `utpf_HTkH`'s own gate once a bump lands —
`bin/cosmic --make ci` ends `ci: PASS` against the bumped pin, plus (for
this item specifically) `register_extension`/`lsqlite3.Extension`
present in the generated `cosmo/lsqlite3.d.tl`.

## Non-goals

- Not building `bnpp_lZOK` itself — that resumes once this question
  closes.
- Not re-litigating `utpf_HTkH`'s own scope or FTS5 target.
- Not resolving `3IkSSqvH4BLD8YdvdYwohk2Pemz`'s own decision (a) vs
  (b) — that is a separate item, out of scope here exactly as it was
  for `3ImjB20O`.
