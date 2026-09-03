## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`), the LIBRARY half
of the class — the outcome's sibling child (`eDVe_UY1D`, "check: one
member-swap helper for the 13 test doubles that map-view landlock and
quicksand") already covers the other 13 rows (the sandbox/quicksand
test-double sites); this change is only the 4 library rows:

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="map view of a declared value"{print $1":"$2}'
    cosmic/coverage/init.tl:92
    cosmic/coverage/init.tl:93
    cosmic/fetch/init.tl:388
    cosmic/quicksand/box/init_test.tl:143
    cosmic/quicksand/box/init_test.tl:145
    cosmic/quicksand/box/init_test.tl:146
    cosmic/quicksand/box/init_test.tl:148
    cosmic/quicksand/box/merge.tl:135
    cosmic/sandbox/init_test.tl:192
    cosmic/sandbox/init_test.tl:193
    cosmic/sandbox/init_test.tl:197
    cosmic/sandbox/landlock_net_test.tl:127
    cosmic/sandbox/landlock_net_test.tl:128
    cosmic/sandbox/landlock_net_test.tl:132
    cosmic/sandbox/landlock_scope_test.tl:87
    cosmic/sandbox/landlock_scope_test.tl:88
    cosmic/sandbox/landlock_scope_test.tl:92

The 4 in scope here (`coverage/init.tl:92,93`, `fetch/init.tl:388`,
`quicksand/box/merge.tl:135`):

    cosmic/coverage/init.tl:92
      local co = coroutine as {string: any} -- cast: patch stdlib table
    cosmic/coverage/init.tl:93
      local os_mod = os as {string: any} -- cast: patch stdlib table
    cosmic/fetch/init.tl:388
        return make_response(t as {string: any}) -- cast: from any
    cosmic/quicksand/box/merge.tl:135
          acc = merge_section("", acc, t as {string: any}) -- cast: record inspected as map

`cosmic/quicksand/box/init_test.tl` and `cosmic/sandbox/*_test.tl`
(13 rows) are OUT of scope — the `eDVe_UY1D` sibling.

`_build/casts_baseline.tl` rows this lowers:

    grep -F -e '"cosmic/coverage/init.tl"' -e '"cosmic/fetch/init.tl"' \
      -e '"cosmic/quicksand/box/merge.tl"' _build/casts_baseline.tl
    ["cosmic/coverage/init.tl"] = 5,
    ["cosmic/fetch/init.tl"] = 7,
    ["cosmic/quicksand/box/merge.tl"] = 2,

`coverage/init.tl` carries both of its class-2 sites here (92 and 93,
its only two `map view` rows) but also 3 other-class casts, so it goes
5→3, not to 0. `fetch/init.tl:388` is one of that file's 7 casts (the
other 6, including `incremental record construction`'s line 220, are
this outcome's other children or the pre-existing binding-boundary
work at `3IQCrJpB`), so it goes 7→6. `merge.tl:135` is one of that
file's 2 casts (the other, line 138, is the sibling
`incremental record construction` child in this same outcome — do not
touch it here), so `merge.tl` goes 2→1 from this change alone, 2→0
only once both children land.

## Change

Each site re-types a value this tree ALREADY declared — a stdlib
module table Teal knows the shape of, or a record this tree owns — to
`{string: any}` so it can be walked or passed by computed key.
**What closes it here** (`docs/design/casts.md`, "map view of a
declared value"): declare the narrower type the call site actually
needs, instead of widening to `{string: any}`.

- **`cosmic/coverage/init.tl:92,93`** — `coroutine` and `os` are
  patched (specific functions swapped) by the coverage hook. Declare a
  local record naming only the fields this file swaps (e.g.
  `record CoroutinePatch resume: function ... end`, one per stdlib
  table, matching whichever functions `init.tl` actually reassigns —
  read the surrounding code to enumerate them) instead of widening the
  whole stdlib table to `{string: any}`.
- **`cosmic/fetch/init.tl:388`** — `t` reaches `make_response` already
  typed by its caller; find where `t` is bound above this line and
  either change `make_response`'s parameter type to match `t`'s real
  type directly (removing the cast at the call site entirely) or, if
  `make_response` genuinely needs a map view for a good reason,
  declare that need as a narrow record/map type in its own signature
  rather than accepting `{string: any}`.
- **`cosmic/quicksand/box/merge.tl:135`** — `t` is a record ("record
  inspected as map") walked into `merge_section`. If `merge_section`'s
  own signature can take the record type directly and walk it through
  `pairs` (Teal allows iterating a record with `pairs` returning
  `any` values already, so a record-typed parameter may not need
  widening at all — check `merge_section`'s declared parameter type
  first), narrow the parameter instead of widening the argument; only
  fall back to a declared `{string: T}` map type (naming the value
  type `T`, not `any`) if the fields' value types genuinely differ in
  a way `pairs` over the record can't express.

Regenerate and reconcile:

    bin/cosmic --make run _build/casts.tl --baseline
    bin/cosmic --make run _build/cast_sites.tl --reconcile

Confirm the class's remaining rows (the class does not empty here —
`eDVe_UY1D`'s 13 sandbox/quicksand rows persist until that sibling
lands):

    git show HEAD:docs/design/cast-sites.tsv | awk -F'\t' '$3=="map view of a declared value"'

Do not delete the `### map view of a declared value` heading from
`docs/design/casts.md` in this change — the class is not empty until
`eDVe_UY1D` also lands; update the heading's prose only if the "What
closes it here" text no longer matches (it should still hold, since
that prose already describes the fix this change makes).

Gate with `bin/cosmic --make ci`.

## Non-goals

The 13 sandbox/quicksand test-double rows (`box/init_test.tl`,
`sandbox/init_test.tl`, `landlock_net_test.tl`,
`landlock_scope_test.tl`) are `eDVe_UY1D`'s scope, not this change's.
`cosmic/quicksand/box/merge.tl:138` is the sibling
`incremental record construction` child's site, not this one's.
