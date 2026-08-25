## Goal
G3 — an honest type layer. Parent: "casts: the 16 any-map residue".
This is its binding-boundary group: the 3 sites in `cosmic/fetch/init.tl`
where the census counted `from any`, but the value comes off a
dual-shape `cosmo.*` return rather than out of an untyped table walk.

## Evidence

Measured 2026-08-25 against `1f9279ab` with
`grep -n -- "-- cast: .*from any" cosmic/fetch/init.tl` — 3 sites, in a
427-line file (73 lines of headroom under the 500-line cap):

```
238:  -- cast: from any
366:  -- cast: from any
384:    return make_response(t as {string: any}) -- cast: from any
```

`:238` and `:366` are the same line in the two transports:

```teal
  -- cast: from any
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
```

**These are not the shape the parent census describes.** `headers_or_err`
is the second return of `cosmo.Fetch` / `cosmo.FetchStream` — a
dual-shape binding return that is the header table on success and an
error string on failure — and both sites sit within a few lines of a
cast already reasoned `-- cast: dual-shape binding return`
(`:241` and `:363`). The value is not being walked field by field; it
is being handed across the C boundary once, after a `if not status`
guard has already established which of the two shapes it is.

`:384` is a third thing again: the callback `fetch_extras.make`
receives is declared `function(t: any): any` by its own contract, and
the cast is the callback naming the shape its caller promised.

## Direction, not a decision

The question is whether the honest closure here is a TYPE or a truer
REASON. Both are legitimate outcomes and refinement picks one:

- **A truer reason.** If `headers_or_err`'s two shapes are already
  discriminated by the `if not status` guard above each site, the cast
  is a dual-shape binding return like its neighbours, and the fix is to
  say so — three reason strings, no code change, and the census's
  "any-map field walk" class loses three sites it never really had.
  This is the same judgment board item `3IPqVcwW` puts to the json and
  literal test sites.
- **A typed boundary.** If `cosmo.Fetch`'s declared return tuple can
  carry the discrimination — a narrower `.d.tl` shape, or a small
  typed unwrapper in `cosmic/fetch/` that takes the raw tuple and
  returns either headers or an error — the casts close for real. Cost:
  `_types/gentype.tl` generates `cosmo.*` from
  whilp/cosmopolitan's `tool/net/definitions.lua`, so a narrower
  declared return is a change in the OTHER repo, landed as its own
  change and its own pin bump.

Whichever is chosen, `:384` is judged separately: it belongs to
`fetch_extras.make`'s callback contract, not to the transports, and may
close by typing that contract instead.

Refinement must state, with the command that measured it, whether the
`if not status` guard above `:238` and `:366` genuinely discriminates
the two shapes, because that single fact decides between the two
directions.

## What this must not do

`cosmic.fetch`'s public contract is frozen: `fetch.fetch` returns
`Response | nil, fetch.Error`, `Error` carries its typed `kind` field,
and callers classify by `err.kind` — that is D24 and is not reopened
here. The `Response` record's fields, `headers` vs `raw_headers`
semantics, and the retry/redirect behaviour do not move.

**The C boundary is frozen from this side.** Binding contracts —
return shapes, error values, constants — are fixed at the
`cosmo.*` boundary and a deliberate change needs a matching
`definitions.lua` update in whilp/cosmopolitan, landed as its own
change with its own pin bump, never inside this slice. If refinement
picks the typed-boundary direction, the cosmopolitan half is a separate
item this one is `blocked_by`.

No behaviour change in either transport. If the answer is "a truer
reason", the diff is comment text and a baseline row and nothing else —
which is a legitimate and complete outcome, not a cop-out.

The closure diff lowers the affected row in `_build/casts_baseline.tl`
only if the cast COUNT moves; a reason-only change leaves it untouched
because the counter counts `as` tokens, not reasons. Either way, run
exactly the regen command the gate's failure message prints and commit
the result; no gate is weakened any other way. Leave
`docs/design/casts.md` alone — it is a stale snapshot, tracked as
`3IQC4GeO`.
