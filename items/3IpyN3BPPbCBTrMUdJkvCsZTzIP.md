## Evidence

`FePr_L4FB` ("casts: record-field narrowing — the tl patch closing 5
record-union-after-guard sites") is engineering-complete and gate-green
but cannot land as specified. Its `## Change` step 4 requires opening
an issue against `teal-language/tl` and recording its number in the
new patch entry's `note` field (D21's maturity clause: "each carried
patch is debt with a written-down maturity date: it must be submitted
upstream").

This session's (and this board's orchestrator's) GitHub access is
scoped to `cosmic-lua/cosmic` and `cosmic-lua/cosmopolitan` only —
confirmed via `mcp__github__list_issues` against `teal-language/tl`
("Access denied: repository ... is not configured for this session")
and a direct API call (403). Landing the patch with a fabricated or
placeholder issue number (`teal-language/tl#PENDING`) would violate
D21 outright, so the builder correctly stopped short of push/PR rather
than fake it.

The finished work is preserved: branch `3IpBKCCg`, commit `f0234765`,
pushed to `origin/3IpBKCCg` on `cosmic-lua/cosmic` (not a PR — no
`Board:` line, not ready for review). It implements
`3p/tl/tl_patch/narrow_record_field.tl` (record-field narrowing: a
guard on `x.field` narrows the field itself, keyed
`"varname.fieldname"` in the same fact table a bare variable's narrow
already uses), flips `cosmic/teal_test.tl`'s
`test_hint_index_through_nil_union` canary, adds
`test_narrowing_field_canary` in `cosmic/teal_nilflow_test.tl`, and
`bin/cosmic --make ci` passes (5 stages, 3273/3273 tests). A real bug
was found and fixed along the way: a naive first version narrowed a
nil-compared field to bare `nil` even when the field's own declared
type didn't admit nil, exposed by `cosmic/re.tl`'s `CacheEntry.iter_err`
— fixed by excluding non-nil-admitting fields from the eq-nil shape.

## The question

File the upstream issue against `teal-language/tl` (a session/user
with broader GitHub access is needed) titled along the lines of "Guard
on a record field does not narrow the field", referencing
`docs/design/casts.md`'s "record union after guard" section and the 5
motivating sites this item names. Once filed, substitute its number
for every `teal-language/tl#PENDING` occurrence (16 in
`3p/tl/tl_patch/narrow_record_field.tl`) on branch `3IpBKCCg`, push,
open the PR (`Board: 3IpBKCCgrFFSMZampIPFePrL4FB` as the body's first
line), and hand it to `take FePr_L4FB --pr N` as normal.
