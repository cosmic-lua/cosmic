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
