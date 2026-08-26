`3p/tl/tl_patch.tl` is at the 500-line cap with ONE line to spare, and
the mechanism resolves exactly one patch file per pin, so no further
carried patch entry can land at all.

Measured 2026-08-26 at main `ec794d44`, from the repo root:

- `wc -l 3p/tl/tl_patch.tl` -> **499**. `o/bin/cosmic --check lint
  3p/tl/tl_patch.tl` passes today; one more line does not. The cap is
  `file-length` in `_tool/lint.tl`, exempting `.d.tl` only.
- `_make/patch.tl:56-61` derives the patch path from the pin's by
  string surgery -- `<stem>_pin.tl` -> `<stem>_patch.tl` -- so there
  is one file per pin and no second place to put an entry.
- The landed `3ISKgfS6` already spent the available slack: it
  compressed the 28-line header to 22 to free the 6 lines its
  single-anchor entry needed, landing the file back at 499. There is
  no comparable slack left.
- Entry sizes in the file today, by the offsets of consecutive keys:
  `narrow-or-fallback` 13 lines, `narrow-or-guard` 19,
  `narrow-exit-break` 25, `narrow-truthiness` 30. An anchored entry
  is 13-30 lines; a two-anchor gap needs a PAIR.

Four open items each need to add entries and are therefore all stuck
behind this: `3ISSFrCO` (is-dispatch over `metatable<T>`, whose two
anchors are `o/3p/tl/tl.lua:11510` and `:11607`), `3ISSGDIN` (is-fact
narrowing into closures), `3ISSGm9B` (the closure carry-through
acceptance), and `3IPXRRd2` (strict nil-flow as a sixth patch group).

Whichever way this is resolved -- the mechanism scanning a
`<stem>_patch/` directory of files, a per-group split the resolver
concatenates, or an argued exemption for carried-patch DATA the way
`.d.tl` is exempt -- it is a decision this item should settle before
any of the four is refined further, because each one's `Change`
section names the file it writes into.
