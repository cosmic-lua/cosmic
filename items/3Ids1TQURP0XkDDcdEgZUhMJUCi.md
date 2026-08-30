## Goal

`plaA_uCdm` (3Ib3FO7T, "deflate the embedded .lua payload") proposed
deflating every embedded `.lua` entry unconditionally, on the premise
that the per-launch inflate cost of the boot-path modules is
immaterial against startup. That premise was measured false and the
item was dropped 2026-08-30 (see its own item history): plain-Lua bare
boot (`startup_run_lua`) measures ~2.4ms on this tree, not the ~13ms
the spec assumed, and deflating unconditionally adds a reproducible
+20-30% (~0.7-1ms) regression to it — about a third of measured
startup, confirmed by 3 independent interleaved baseline/current
rounds, a raw shell-loop timing check, and the optimize skill's compare
gate (`perf-compare: FAIL`). The size win is real and large (zip
payload −2.0MB / −19%) and comes from exactly two dominant entries
(`.docs/index.lua`, `tl.lua`) plus the rest of the non-boot `.lua` set
— none of which loads at bare boot.

This item is the follow-up `plaA_uCdm`'s own Non-goals section named:
keep the size win by deflating what boot never reads, keep startup by
leaving the boot-path set stored (zero-copy), instead of picking one
of the two.

## Evidence (from `plaA_uCdm`'s own measurement, 2026-08-29/30)

- Boot read set is small and enumerable: `./cosmic-lua -e 'for k in
  pairs(package.loaded) do print(k) end'` prints 35 modules, of which
  16 resolve from `/zip` (`main`, `_cli.args`, `_cli.main_handlers`,
  `_cli.require_hints`, `_cli.run`, `cosmic._fields`, `cosmic.env`,
  `cosmic.errno`, `cosmic.flags` ×5, `cosmic.instrument`,
  `cosmic.searcher`, `cosmic.tty`), summing 54,816 bytes.
- The two entries that dominate the deflate win are `.docs/index.lua`
  (1,858,377 → 460,149 bytes) and `tl.lua` (340,255 → 137,134 bytes) —
  neither is in the boot read set above; both load only on `--docs`
  and type-check paths.
- `embed_run_startup` (the scenario meant to isolate store-vs-deflate
  cost for an embedded app) showed no consistent effect from
  unconditional deflate — the regression is specific to plain-Lua bare
  boot, consistent with the boot set being tiny and dominated by fixed
  per-entry inflate overhead rather than payload size.
- Re-run these numbers at pull — `plaA_uCdm`'s own numbers are two days
  old by the time this is picked up; a moved number is fine to refresh
  in place, a number that overturns the boot-set shape is a real
  bounce.

## Change

In `cosmic/embed/init.tl`, replace the current all-or-nothing embed
policy (currently: every `.lua` entry stored, everything else
deflated, per `plaA_uCdm`'s dropped attempt to flip it to all-deflate)
with a policy that stores exactly the measured boot-path set and
deflates everything else:

1. Enumerate the boot read set the same way `plaA_uCdm`'s evidence did
   (`./cosmic-lua -e 'for k in pairs(package.loaded) do print(k) end'`
   against a built `cosmic-lua`, filtered to the modules that resolve
   from `/zip`) and re-measure it against the current tree — the set
   may have moved since 2026-08-29.
2. In the embed policy (the `AddOptions` loop around
   `cosmic/embed/init.tl:380-397`), replace the current `is_lua`
   store-everything-`.lua` branch with a check against that boot-path
   set: an embedded entry gets `method = "store"` only when its module
   path is in the boot set (plus whatever non-`.lua` entries the
   existing policy already stores, if any — check the current code
   rather than assuming), and `method = "deflate"` otherwise. Update
   the policy comment above the loop to state the new policy and the
   measured boot set it is keyed to.
3. Update `cosmic/embed_test.tl` (the test currently pinning embedded
   `.lua` at method 0/stored, per `plaA_uCdm`'s notes at lines 336-357)
   to assert the new per-entry split: boot-set entries stored, the rest
   (including `.docs/index.lua` and `tl.lua`) deflated.
4. Performance is the one thing `--make ci` cannot judge: run the loop
   in `skills/optimize/SKILL.md` — baseline `origin/main`, change, A/A
   selfcheck, compare gate — on both `startup_run_lua` (must NOT
   regress, since the whole point is to avoid `plaA_uCdm`'s regression)
   and the size scenario/measurement (must show most of the ~2.0MB win,
   since `.docs/index.lua` and `tl.lua` — the two dominant entries — are
   outside the boot set and stay deflated). Keep only on a pass on both
   axes; never weaken either scenario or its check to pass.

## Non-goals

- No zstd, no change to the zip method vocabulary — `"store"` and
  `"deflate"` remain the only methods, `cosmo.*` C boundary frozen
  (same wall `plaA_uCdm` stated).
- No change to `cosmic.zip`'s public `AddOptions` or explicit per-add
  `method` behavior.
- Not a redo of `plaA_uCdm` as filed — that item is dropped on its own
  premise; this is the narrower mechanism its own Non-goals pointed to,
  not a re-litigation of whether to deflate at all.
