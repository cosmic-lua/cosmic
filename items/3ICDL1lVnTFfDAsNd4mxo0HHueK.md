## Evidence

2026-08-20 audit at main 0b2907b9, by reading. #1266 fixed the /zip
chunk normalization in `_tool/coverage/report.tl` (the /zip branch
returns `(source, source)`, :108) but the `o/` branch still returns
`(source, p)` (:129) — display `x.tl`, parse `o/x.lua`. One display
path can therefore still arrive via two spellings in one run
(`@o/cosmic/url.lua` and `@/zip/cosmic/url.lua`), and `merge_hits`
(:215) keeps whichever parse created the entry first over
nondeterministic `pairs` iteration (:385) — so if the compiled .lua
and the .tl have different executable-line sets, the reported total
still depends on merge order, contra the commit's "independent of
which .cov file wins the merge race". Pre-existing in the same
function: the o/ branch lacks the init.tl fallback the /zip branch
has, so a directory module reached via an `o/…/fs.lua` chunk is
dropped entirely. Not confirmed at runtime whether both spellings
coexist for one module in a CI run — measuring that is part of this
item.

## Confirmed at runtime, 2026-08-21

The evidence above closed with "not confirmed at runtime whether both
spellings coexist for one module in a CI run". They do, and the effect
is a moving denominator.

Measured while implementing 3I7Otbvg at main `aaf4af95`. That change
makes `cosmic/instrument.tl` require `cosmic.string`, which puts
`cosmic.string` on the boot surface — every spawned child now loads it
from `/zip` as well as from `o/`. `bin/cosmic --make coverage` then
reports:

```
coverage ratchet: cosmic/string.tl: coverage declined 98.4% -> 96.9% (158/163, baseline 180/183)
```

The TOTAL moved 183 -> 163 while the source file GREW by 25 lines, so
the denominator is not a property of the file. The two lines newly
reported as missing are `local M: StringModule = {` (:433) and `return
M` (:456) — module-level statements that run on every require and
cannot be unhit. Reverting only the `instrument.tl` require (leaving
`cosmic/string.tl`'s new function and tests in place) removes the
ratchet complaint entirely, which isolates the cause to the module
becoming boot-loaded rather than to anything about its own coverage.

The consequence for other work: a slice that makes any module
boot-loaded appears to lower that module's coverage and is pushed
toward a `--make coverage --baseline` that would freeze an artifact as
a floor. 3I7Otbvg is blocked on this item for exactly that reason.
