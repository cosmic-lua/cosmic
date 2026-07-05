# 18. codec.decode_base64 scans the input twice on the happy path

- status: done (2026-07-04)
- layer: cosmic
- scenario: codec_base64_roundtrip_64k

- result: 1.88ms baseline; two re-measures came back -71.8% and
  -70.8% — large and consistent.
- evidence: `decode_base64` ran a negated-character-class scan
  (`str:match("[^A-Za-z0-9+/=]")`, to give a specific "invalid
  character" error) unconditionally, THEN an anchored
  content/padding-capturing scan (`^([A-Za-z0-9+/]*)(%=*)$"`) to
  validate structure — two full passes over the input on every
  call, valid or not, even though the anchored pattern alone already
  proves the input is well-formed when it matches.
- fix: run the anchored content/padding match first. On the happy
  path (matches — i.e. every valid base64 string) that's the only
  scan; the character-class scan now only runs to disambiguate the
  error message in the failure branch (invalid character vs. padding
  before the end), which is the rare path. Same two error messages,
  same conditions, just reordered so the common case pays for one
  scan instead of two.
- why the win is bigger than "cut one of two equal-cost scans in
  half": the removed scan was the *negated* character class
  (`[^A-Za-z0-9+/=]`, 4 ranges + a literal, excluded), which Lua's
  pattern matcher evidently checks per byte less efficiently than
  the anchored match's two positive classes — so removing it from
  the happy path saved more than 50% of the matching-related work.
- correctness: verified against all existing `decode_base64` tests
  (`test_decode_base64_basic`, `_no_padding`, `_empty`,
  `_invalid_char`, `_invalid_padding`, `_padding_in_middle`) by hand
  — traced each through both branches to confirm identical error
  messages and identical accept/reject decisions, then ran
  `bin/make test only=codec_test`, which passed.
- risk: low — same two validation conditions and error messages,
  only their evaluation order changed; no change to what
  cosmo.DecodeBase64 is ultimately called with.
