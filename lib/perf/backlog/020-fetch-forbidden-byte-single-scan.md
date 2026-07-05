# 20. fetch.has_forbidden_byte runs three scans where one would do

- status: done (2026-07-04) — modest win
- layer: cosmic
- scenario: http_fetch_get_with_headers

- result: `http_fetch_get_with_headers` (new — the existing
  `http_fetch_get` never passes headers, so `validate_headers`
  short-circuits on `if not headers then return nil end` and never
  calls `has_forbidden_byte` at all): 70.56µs baseline; three
  re-measures came back -2.1%, -1.6%, -3.0% — small but consistently
  faster, never a regression. `http_fetch_get` itself (no headers)
  is unaffected, as expected, since it never touches this function.
- evidence: `has_forbidden_byte` (lib/cosmic/fetch.tl, called once
  per header name and once per header value in `validate_headers`,
  security-critical CRLF-injection guard, audit §2.3) ran three
  separate `s:find(byte, 1, true)` calls — one each for CR, LF, NUL —
  each a full scan of the string on the common (no-early-exit)
  clean-header path.
- fix: replaced the three plain-text `find` calls with one
  character-class pattern scan, `s:find("[\r\n\0]")` — still exactly
  one `string.find` C call, just checking all three bytes per
  position instead of one call per byte. Verified in a standalone
  Lua 5.4 script that embedded NUL bytes inside a Lua pattern
  character class match correctly (Lua 5.4 removed the old `%z`
  class; a literal `\0` inside `[...]` works directly since Lua
  strings carry an explicit length, not a NUL terminator).
- why this one worked where entry 19 (`url.decode`) didn't: this
  fix reduces the call *count* on the happy path (3 C calls -> 1),
  not just bytes touched by more calls — the exact distinction
  entry 19's "lesson for future rounds" called out.
- correctness: ran the full `fetch_headers_test.tl` suite (CRLF in
  value, LF-only, CR-only, CRLF in name, NUL in value, empty name,
  clean headers, plus the `stream()` variants) and `fetch_test.tl` —
  all pass unchanged, confirming identical accept/reject behavior
  for every existing case.
- risk: low — same three forbidden bytes, same short-circuit
  semantics (`find` still returns at the first match), only the
  call shape changed.
