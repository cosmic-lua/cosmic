`3ITdLKeR` localized `354c17e08`'s `codec_base64_roundtrip_64k`
regression to a single function and to a single cause, and the cause is
not the one whilp/cosmopolitan PR #280 is built on. Splitting the
scenario into its three C calls and timing each on the two local
`m=rel` arms, nine isolated round-robin readings apiece against a 3.7%
floor: `IsBase64` **med 27.137 → 52.445 µs, +93.26%**, trimmed ranges
disjoint (hi A 27.251 < lo B 52.238); `EncodeBase64` +0.57% and
`DecodeBase64` -0.44%, both with overlapping ranges and both NOT MOVED;
the whole roundtrip +16.13% (med 136.680 → 158.725 µs, hi A 140.644 <
lo B 157.246). The 25.3 µs `IsBase64` gains is the entire 22.0 µs the
roundtrip loses, and `IsBase64` allocates nothing
(`grep -c 'malloc\|realloc\|calloc' net/http/isbase64.c` → `0`), so the
allocator and the heap are excluded.

`objdump -d` on the two `lua.dbg` files gives `IsBase64` **identical
instruction bytes** in both arms — same 167-byte body, same
instructions in the same order, differing only in the two absolute
operands (the `kBase64Alpha` displacement and the `strlen` call target)
and in where the function sits. So this is placement, not codegen, and
the placement that matters is the scan loop's, not the entry's:

- arm A: entry `0x43a6a60`, `& 0x3F` = **32**; the scan loop
  (`add $1,%rbx` at `+0x30` through the `jne` back to it at `+0x46`,
  24 bytes) runs `0x43a6a90`–`0x43a6aa7`, `& 0x3F` = **16**, entirely
  inside the 64-byte fetch block `0x43a6a80`–`0x43a6abf`.
- arm B: entry `0x43a9d40`, `& 0x3F` = **0** — already 64-byte
  aligned; the same loop runs `0x43a9d70`–`0x43a9d87`, `& 0x3F` =
  **48**, **straddling** the block boundary at `0x43a9d80`.

The slow arm is the one whose function entry is already 64-byte
aligned, because a 64-aligned entry puts this loop head at `+0x30` = 48
and a 24-byte loop from offset 48 cannot fit in one block. That is the
direct refutation of PR #280's premise: `forcealign(64)` on the three
entries makes arm A's `IsBase64` look like arm B's, so the draft cannot
recover the timing on any host, which is exactly what the interleave
recorded on `3ITbywUB` found. `skills/optimize/measurement.md` already
carries the same class measured on `codec_hex` (`local rel (straddled)`
versus `local rel (padded)`).

What this item is: test the intervention that follows from the
mechanism — pin the LOOP to a fetch block rather than the entry
(`-falign-loops=64` scoped to these files, or whatever cosmopolitan's
own idiom is), A/B two local `m=rel` builds differing only by that
change per `skills/optimize/cosmopolitan.md`, confirm from `objdump`
that the loop no longer straddles, and re-run `3ITdLKeR`'s
`/tmp/b64split.lua` for the `is` column before and after. Refinement
owns the choice of lever and owns what to do about PR #280, which
should not merge on its current premise. The correctness gate is
`make -j$(nproc) o//tool/lua/test`, and no binding contract moves —
`IsBase64`'s signature, return value and `definitions.lua` entry are
untouched by an alignment attribute. Arm digests to rebuild against:
arm A `a108f199fc2e37f315e988776c948ffd4e597a689075786abc8ed4a9b6e01296`,
arm B `44fd5c18efbf8e9d4eac5ea9fa23b88cea196ef64995317dc87cfeb62e9115bf`.
