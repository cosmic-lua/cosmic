# 22. codec.decode_hex scans the whole input for validity on every call

- status: done (2026-07-05)
- layer: cosmic
- scenario: codec_hex_roundtrip_64k

- evidence: `codec_hex_roundtrip_64k` runs 2.09ms/op with 188KB/op
  alloc, vs `codec_base64_roundtrip_64k` at 558µs/op on the same 64KB
  input. Part of the gap is inherent (hex text is 128KB vs ~87KB for
  base64), but `decode_hex` (lib/cosmic/codec.tl:18-29) still runs
  `hex:match("[^0-9a-fA-F]")` — a full negated-character-class scan of
  the 128KB string — on every call before delegating to
  `cosmo.DecodeHex`. That is exactly the scan shape entry 18 removed
  from the base64 happy path, and Lua's pattern matcher handles
  negated classes per byte relatively slowly (entry 18's "why the win
  is bigger" note).
- hypothesis: keep the O(1) even-length check, wrap the delegation in
  `pcall(cosmo.DecodeHex, hex)` — on the happy path that is still
  exactly one C call (entry 19's lesson: don't add per-occurrence Lua
  calls, and this doesn't) — and only run the character-class scan in
  the failure branch to pick between the two documented error
  messages. Expected: the decode half stops paying a full extra scan;
  scenario delta likely 10-30% given encode+decode split.
- correctness constraints: the documented `value, string` returns and
  the exact messages "hex string must have even length" / "invalid
  hex character" must be preserved; `codec_test.tl` pins them.
  Verify `cosmo.DecodeHex`'s raise conditions cover every input the
  scan currently rejects (it raises on non-hex and odd length per
  entry 1), so no invalid input can slip through the pcall path.
- risk: low — same accept/reject set, same messages, evaluation order
  changes only on the failure path.
- result: done. `decode_hex` now keeps the O(1) even-length check and
  wraps `cosmo.DecodeHex` in `pcall` on the happy path, dropping the
  128KB negated-character-class `hex:match` scan entirely; the failure
  branch returns the documented "invalid hex character" message
  (even length is already guaranteed, so a raise can only mean a
  non-hex byte). Verified against `tool/net/lfuncs.c:718` `LuaDecodeHex`,
  which raises via `luaL_argerror` on non-hex/odd input and never
  returns nil — so the pcall path cannot leak a bad decode.
  `perf-compare`: `codec_hex_roundtrip_64k` 2.14 ms/op -> 137.38 µs/op
  (-93.6%), no regressions in the other 31 scenarios. The win landed
  far above the predicted 10-30% because the full-string scan, not the
  decode, dominated the workload. `bin/make ci` green (codec_test pins
  the messages and roundtrip).
