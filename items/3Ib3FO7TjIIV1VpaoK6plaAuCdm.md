## Change

In `cosmic/embed/init.tl`, retire the store-`.lua` branch of the embed
policy: every embedded entry is added with `method = "deflate"`.

1. `cosmic/embed/init.tl:394-397` — delete the `is_lua` local and set
   `method = "deflate"` unconditionally in the AddOptions; rewrite the
   policy comment above the loop (lines 380-383) to state the new
   policy and its measured reason (boot read set ≈ 55 KB, so the
   per-launch inflate is immaterial against a ~13 ms startup; numbers
   below).
2. `cosmic/embed_test.tl:336-357` — the test pinning embedded `.lua`
   at method 0 (stored) flips to assert method 8 (deflate); the
   non-`.lua` deflate test at lines 311-329 stands. (`cosmic/
   zip_test.tl:272-283` exercises explicit per-add `method` options on
   `cosmic.zip` and is untouched — that contract does not change.)
3. Performance is the one thing `--make ci` cannot judge here: run the
   loop in `skills/optimize/SKILL.md` — baseline `origin/main`, change,
   A/A selfcheck, compare gate — and keep only on a pass. The
   binary-startup scenario is the one this change can move. Never
   weaken a scenario or its check to pass.

Why, measured against the pinned release binary
(https://github.com/whilp/cosmic/releases/download/2026-08-27-555873e/cosmic-lua,
10,525,673 bytes; the same artifact `bin/cosmic` fetches):

- The zip payload is 7,551,523 → 4,846,861 bytes
  (`zipinfo -l cosmic-lua | tail -1` →
  `665 files, 7551523 bytes uncompressed, 4846861 bytes compressed`).
  By method (`zipinfo -l cosmic-lua | awk` summing per-entry
  size/compressed-size by the `defN`/`stor` column):
  `defN n=391 uncompressed=4416323 compressed=1711661` and
  `stor n=274 uncompressed=3135200` — the stored set is exactly the
  `.lua` this policy stores.
- Per-entry deflate at level 9 over the extracted stored set
  (`unzip` the binary, then `python3 -c 'zlib.compress(data, 9)'` per
  file) takes the `.lua`/`.luac` set 3,282,220 → 1,138,412 bytes:
  about −2.0 MB on the shipped binary (−19%), 10.5 MB → ≈8.5 MB. The
  two entries that dominate: `.docs/index.lua` 1,858,377 → 460,149 and
  `tl.lua` 340,255 → 137,134.
- The boot read set is small:
  `./cosmic-lua -e 'for k in pairs(package.loaded) do print(k) end'`
  prints 35 modules of which 16 resolve from `/zip`
  (`main`, `_cli.args`, `_cli.main_handlers`, `_cli.require_hints`,
  `_cli.run`, `cosmic._fields`, `cosmic.env`, `cosmic.errno`,
  `cosmic.flags` ×5, `cosmic.instrument`, `cosmic.searcher`,
  `cosmic.tty`), summing 54,816 bytes (`stat -c%s` over the extracted
  files); `time ./cosmic-lua -e 'print(1)'` → `real 0m0.013s`.
  The heavyweight stored entries (`.docs/index.lua`, `tl.lua`) load
  only on `--docs` and type-check paths, never at bare boot.
- Decode is already paid for: zipos inflates method 8 via `__inflate`
  (zlib when linked, and the lua base links zlib), and the writer
  behind `cosmic.zip` already emits deflate for the other 391 entries.
  No cosmopolitan change, no pin bump, and external `unzip`/`zipinfo`
  keep reading the artifact.

The cost this trades away, stated: stored entries are zero-copy
(`__zipos_load` points the handle into the mapped binary); a deflated
entry costs an alloc plus inflate on each open. The policy applies to
every artifact `--make build` produces, user projects included — their
boot sets are the same stdlib modules plus their own entry.

## Non-goals

- No zstd, and no change to the zip method vocabulary — `"store"` and
  `"deflate"` remain the only methods, and the `cosmo.*` C boundary is
  frozen. (Measured separately: zstd-19 over deflate-9 on this payload
  is worth ~320 KB but needs a ~60-150 KB decoder in every base; not
  this item.)
- No stored-subset mechanism (a list of boot-path files kept at
  `"store"`). If the compare gate shows a real startup regression,
  do not tune this diff: release the claim with the numbers on the
  item, and the follow-up — store exactly the measured boot set,
  deflate the rest — is its own item.
- `cosmic.zip`'s public AddOptions and explicit per-add `method`
  behavior untouched.
