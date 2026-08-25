## Goal

G3 — an honest type layer. `docs/design/nil-flow.md` names a second
missing narrowing rule but deliberately does not size it: `if not x
then break end` does not narrow, though `if not x then return end`
does. Every directory walk in the tree is written the first way. This
slice measures the rule's yield and, if it is worth it, lands it — the
same shape as the `or` rule, which closed 69 of 358 sites.

## Evidence

The census reports the SINK, not the guard the author wrote, so it
cannot separate "no guard" from "a guard the checker does not credit".
What it does show is the cluster:

```text
-- cosmic/fs/tree.tl:28
      local s = cosmo_path.join(src, entry)
```

`entry` comes from `h:read()` two lines up and is guarded by `if not
entry then break end`. The same shape produces all three `index-key`
sites — `cosmic/fs/dir_test.tl:218`, `cosmic/fs/init_test.tl:246`,
`cosmic/fs/traps_test.tl:192`, each `entries[entry] = true` inside a
`while true do … if not entry then break end` loop.

`3p/tl/tl_patch.tl` carries `narrow-truthiness` today, which credits
`if not r then return end`. `goto`, `error()` and `os.exit()` are the
same family as `break`: control leaves the branch, so the union is
narrowed after it.

## Change

1. Measure first, the way the `or` rule was measured: rebuild the
   throwaway strict checker from `docs/design/nil-flow.md`'s
   `## Method`, add one further edit that treats `break`, `goto`,
   `error()` and `os.exit()` as narrowing exits, re-run the same scan,
   and report the delta and that the new site set is a strict subset.
2. If the yield justifies it, add the edit to `3p/tl/tl_patch.tl` as a
   seventh narrowing key with a pinning test in
   `cosmic/teal_narrowing_test.tl`, and take the same measurement
   upstream to teal-language/tl.
3. If it does not, say so with the number and close the item — a
   measured no is the deliverable.

## Non-goals

- Do not fix sites by hand while measuring.
- Do not land the edit without the pinning test.
- Do not bump the `tl` pin.

## Acceptance

- The delta is reported with both `comm` directions, as the `or` rule
  was: sites closed, and zero sites created.
- If the edit lands: `bin/cosmic --make ci` ends `ci: PASS`, the new
  test fails with the edit key removed, and the census is re-derived
  rather than hand-edited.
