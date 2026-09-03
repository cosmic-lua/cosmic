## Evidence

`hnlE_A39n` («casts: map view of a declared value, library half — 4 sites
close by declaring the type») built against `origin/main@96afd807`'s
Evidence, but the tree has since moved to `ffd41afb`, which includes
`a4ba83e3` ("casts: close incremental record construction sites in fetch,
format, signal, sqlite", landed 2026-09-03 same day). That commit already
rewrote `cosmic/fetch/init.tl:388`:

    -    return make_response(t as {string: any}) -- cast: from any
    +    return make_response(t as Response) -- cast: from any

`make_response` now takes `Response` directly, not `{string: any}}` — the
site no longer matches the "map view of a declared value" pattern at all.
`docs/design/cast-sites.tsv`'s row for this line is stale: it still
classifies the site "map view of a declared value" because
`_build/cast_sites.tl --reconcile` carries a class forward by line key and
never re-derives it from the current cast comment.

Separately, `cosmic/quicksand/box/merge.tl:135` was verified directly
against the pinned `tl` checker (`o/bin/cosmic --check types`) to be
un-closable by either method `hnlE_A39n`'s spec prescribes:

- `merge_section` taking the record (`types.BoxOptions`) directly and
  walking it via `pairs`: refused — `pairs` over `BoxOptions` errors
  "record is not a valid map; not all fields have the same type", with
  Teal's own hint recommending the `{string: any}` cast already in place.
- A declared `{string: T}` map naming the real value union: also refused
  to compile — `BoxOptions`'s fields span five distinct record types
  (`FsOpts`, `SysOpts`, `NetOptions`, `ProcOptions`, `EnvOptions`) plus
  scalars, and Teal refuses a union spanning more than one table type
  ("cannot discriminate a union between multiple table types").

This matches the module's own existing comment above the cast (Teal
refuses both halves of that bridge on its own) and mirrors `a4ba83e3`'s
own conclusion about this file's sibling cast at line 138, left as an
accepted floor case. It contradicts `docs/design/casts.md`'s claim for
the "map view of a declared value" class that "the type is knowable in
every case" — false for this specific site.

## The question

Two things need a decision before `hnlE_A39n` (or a successor) can
proceed:

1. `docs/design/cast-sites.tsv`'s `cosmic/fetch/init.tl:388` row is stale
   and needs reclassifying (or dropping, if `a4ba83e3`'s rewrite already
   closes whatever class it now belongs to — likely "incremental record
   construction", per that commit's own message) — a `bin/cosmic --make
   run _build/cast_sites.tl --reconcile` re-run plus a human/decision
   check of the new classification.
2. `cosmic/quicksand/box/merge.tl:135` cannot be closed by either method
   `docs/design/casts.md`'s "map view of a declared value" section
   prescribes. Either: (a) accept it as a floor case alongside its
   sibling at line 138, and correct `casts.md`'s "the type is knowable in
   every case" claim to name the exception; or (b) find a third closing
   method not yet documented. This is a decision about the class's own
   claim, not just this one site.

## Non-goals

Not re-litigating the class's existence or the other sites it still
correctly covers (13 sandbox/quicksand rows, `eDVe_UY1D`'s scope).
