The checker itself still accepts `return nil` from a bare non-nil declared
return. `_build/nil_returns.tl` counts the class and holds it against a
committed floor, which stops it growing — but a ratchet is a measurement, not a
guarantee: nothing prevents the next site, it only reports it after the fact,
and only for the trees the count walks.

Making the checker refuse it is the honest end state. The route is the carried
tl patch (`3p/tl/tl_patch/`, mechanism in `_make/patch.tl`): each entry is an
exact `find` string replaced in the unpacked `tl.lua`, and an anchor that no
longer matches fails the fetch loudly, so a pin bump re-audits it. The existing
groups are `narrow.tl` (393 lines), `closure.tl` (207) and `ast_cache.tl` (168);
a fourth would sit beside them. What it has to change is where tl checks a
`return` statement's expressions against the enclosing function's declared
return type — the same place that already reports an arity mismatch, which is
evidence the comparison exists and admits nil rather than not running at all.

**This is gated behind the sweep by arithmetic, not by preference.** A checker
that refuses the class fails 136 sites the day it lands, so the floor has to
reach zero first. Land it as: sweep to zero, then the patch, then delete the
ratchet — the count's own retirement is the signal that the guarantee became
real.

Worth measuring before committing to the patch: whether upstream
teal-language/tl considers this a bug or a deliberate accommodation. If
upstream fixes it, the carried patch is a bridge rather than a fork, and the pin
bump that lands it is the cheapest possible version of this work.
