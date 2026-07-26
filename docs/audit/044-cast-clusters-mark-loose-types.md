# 044 — cast clusters mark types looser than the code they describe

severity: low
type: design / types
area: `cosmic/literal.tl`, `_make/types.tl` + `_make/init.tl`

## issue

the repo's own lint philosophy says it: "a cast you cannot justify is
one to remove, via `is`, `check.must`, or a precise type." two places in
the new code have *justified* casts that cluster — the tell that the
type, not the call site, is what wants fixing:

1. **`literal.parse_table` returns `{string:any}|nil, integer|string`**
   — the second value is an index on success and an error message on
   failure. every caller (including the recursive call) must therefore
   cast twice, with paired justification comments:
   `nexti as string -- cast: the failure branch returns a message` and
   `nexti as integer -- cast: the success branch returns an index`.
   three call sites, six casts, all annotating the same union. a
   three-value return (`table|nil, integer, string`) — index always
   meaningful on success, message on failure — matches the codebase's
   `value, err` convention and deletes every cast.

2. **`types.fmt_kinds` is `{string: boolean}`** — its keys are kinds,
   and `_make/init.tl`'s `fmt_kinds()` casts each back
   (`k as Kind -- cast: the table is keyed by Kind`). declaring it
   `{Kind: boolean}` states the invariant where it lives and deletes
   the cast; the 003 fix introduced the single-definition table
   precisely so the two consumers could not drift, and the type is part
   of that definition.

neither is a defect; both are the small kind of looseness that
compounds — the next reader copies the cast pattern rather than
tightening the type, because the cast is what the existing code
demonstrates.

## suggested fix

as written above: three-value return for `parse_table` (private to the
module, so no API change), and `{Kind: boolean}` for `fmt_kinds`. both
are mechanical; the casts and their justification comments delete with
them.
