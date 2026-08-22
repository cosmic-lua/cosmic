## Evidence

Measured 2026-08-22 at main `3d73d670` while refining 3ICDL1lV, with
`bin/cosmic --make coverage` followed by `o/bin/cosmic
--coverage-report o/.coverage cosmic`.

A module's own top-level statements are reported as MISSING when the
module is on the boot surface. `cosmic/fs/types.tl` reads:

```
cosmic/fs/types.tl                   64.2%     34/53  missing: 3,5,180,184-187,197,200,212,249 +8 more
```

Line 3 is that module's own `local unix = require("cosmo.unix")` and
line 5 its `local record fs_types` (a plain assignment in the compiled
file). Both execute on every require and cannot be unhit, so their
absence from the hit set means the statements ran before the coverage
collector installed its hook — the module was already loaded, from the
binary's boot path, by the time instrumentation started.

The consequence is a gate that punishes a change for making a module
boot-loaded. Recorded on 3ICDL1lV, 2026-08-21, at main `aaf4af95`:
putting `require("cosmic.string")` into `cosmic/instrument.tl` moved
`cosmic/string.tl` from 180/183 to 158/163 — `covered` fell by 22 while
the file GREW by 25 lines. Reverting only that require removed the
ratchet complaint. `covered` counts hit lines, so no choice of the
report's `parse` target can explain a fall in it; the merge-order race
3ICDL1lV fixes is a different defect, and closing it will not close
this one.

What a slice here would have to settle: whether the collector can be
installed before the boot modules load (or their module-level lines
attributed some other way), and what the ratchet should do meanwhile
for a module that moves onto the boot surface. 3I7Otbvg is the open
work this blocks in practice.
