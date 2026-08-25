`cosmic.json` round-trips silently mutate any string that is not
valid UTF-8, including ordinary binary bytes. Measured 2026-08-25 at
main a0c4ebd with the built binary: `json.encode({s = string.char(0,
1, 27, 127, 128, 255)})` writes each byte as a JSON unicode escape
of its raw value (backslash-u 0000, 0001, 001b, 007f, 0080, 00ff) —
`cosmo.EncodeJson` reads raw bytes >= 0x80 as Latin-1 code points —
and `json.decode` then emits those code points as UTF-8, so 6 bytes
in become 8 bytes out (byte 128 comes back as the pair 194,128;
byte 255 as 195,191). No error is returned at either end: the value
changes silently, which is exactly the shape the no-silent-bugs
promise forbids. cosmic.literal preserves the same bytes exactly in
both layouts (same audit). The decision to make: refuse non-UTF-8
strings at encode (honest nil), or document and CI-verify the
Latin-1 reinterpretation as the contract; today cosmic/json.tl's
docs say neither. The C binding's behavior is a frozen contract at
the boundary, so a refusal likely lands as a cosmic-side pre-check,
not a binding change.
