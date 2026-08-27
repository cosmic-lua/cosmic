`3ITbccMu` reproduced `354c17e08`'s `codec_base64_roundtrip_64k`
regression on LOCAL builds for the first time, and its control arm ruled
out the one cheap fix. Three single-arch x86_64 `m=rel` builds of
whilp/cosmopolitan, measured through cosmic tree `5ef13f40` with nine
isolated round-robin readings each: arm A (`8dd093cea`, the parent) min
138.67 / lo 138.78 / **med 143.88** / hi 147.23 µs; arm B
(`354c17e08`) min 161.50 / lo 162.42 / **med 164.37** / hi 172.33 µs;
arm C (`354c17e08` with `llua.o` moved to the end of
`TOOL_LUA_LUA_MODULES`) min 160.81 / lo 161.85 / **med 166.91** / hi
168.47 µs. The noise floor from six `gate.tl selfcheck` passes was
**3.7%**. B is +14.24% over A and C is +16.00%, both with trimmed
ranges disjoint from A's (hi A 147.23 < lo B 162.42 and < lo C 161.85)
and both far past the floor; the raw ranges are disjoint too (A max
153.31 < B min 161.50, < C min 160.81). That is `3ITbccMu`'s (7) row
`not-link-position`, which prescribes this item.

Arm C turned out to be a NULL control, which is what makes this item
necessary rather than optional. `nm` on the two `lua.dbg` files gives
arms B and C byte-identical addresses for every base64 symbol —
`DecodeBase64` `0x43a7ca0`, `EncodeBase64` `0x43a7fa0`, `IsBase64`
`0x43a9d40`, `kBase64` `0x4450040`, `kBase64Alpha` `0x44510c0` — the
same `.text` size (2790188) and the same APE size (3000420), so
reordering that make variable does not move compiled code at all. What
IS settled is that the one-line `tool/lua/BUILD.mk` reorder is not a
fix. What is NOT settled is whether layout is the mechanism: against
arm A the addresses did move (`DecodeBase64` `0x43a49c0` →
`0x43a7ca0`, `+0x32E0`; `.text` 2777412 → 2790188, +12776 bytes) and
nothing here says whether that shift, the image growth, or something
else is what costs the 20 µs.

The next question is WHERE the 20 µs went, and the instrument does not
need a profiler: `perf` is absent on the host `3ITbccMu` ran on
(`which perf` → nothing, `/proc/sys/kernel/perf_event_paranoid` → `2`),
so a spec that requires `perf record -g` on `o/rel/tool/lua/lua.dbg` is
not runnable there and its enablement check would fail. The cheaper
split is to time the three C calls separately on the two arms that
matter — `cosmo.EncodeBase64` on the 64 KB blob, `cosmo.IsBase64` on
the 87 KB encoded string, `cosmo.DecodeBase64` on that string — since
`cosmic/codec.tl:37,82,83` is a thin wrapper over exactly those three
and the scenario is their sum. Whichever call carries the delta is then
read in both arms' disassembly (`objdump -d` from the `.cosmocc`
toolchain, which is present) for loop alignment and instruction
selection. Refinement owns the choice between doing that as a new
`_perf` scenario, a standalone script run under both arms' `lua`
directly, or an added `*_bench.tl` module, and owns whether the split
belongs in the tree at all or only in the result.

The arms are cheap to rebuild: one whilp/cosmopolitan checkout,
`make -j$(nproc) m=rel o/rel/tool/lua/lua` at `8dd093cea` then at
`354c17e08` (~10 minutes cold including the cosmocc download, ~90
seconds for the second), the APEs copied out between builds, then
`cp` into `o/3p/cosmos/lua` of a cosmic worktree at `5ef13f40` and
`bin/cosmic --make build`. Their sha256 digests, for anyone re-running:
arm A runtime `a108f199fc2e37f315e988776c948ffd4e597a689075786abc8ed4a9b6e01296`,
arm B runtime `44fd5c18efbf8e9d4eac5ea9fa23b88cea196ef64995317dc87cfeb62e9115bf`.
