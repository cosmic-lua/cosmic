# 22. codec.decode_hex scans the whole input for validity on every call

- status: open
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
