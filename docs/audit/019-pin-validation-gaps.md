# 019 — pin digest length and url-derived output name unvalidated

severity: low
type: bug (diagnostics + robustness)
area: `_make/pin.tl`

## issue

two validation gaps in the pin reader:

1. **digest length.** the sha pattern `^%x%x%x%x%x%x%x%x+$` accepts any
   string of eight or more hex characters. a truncated sha256 (a common
   copy-paste slip) is accepted at read time, and every fetch then fails
   with `sha256 mismatch` — a correct refusal (fails closed, not a security
   hole) with a wrong diagnosis that sends the user chasing the url instead
   of the digest.
2. **output name.** the archive name derived from the url is used unchecked
   in `fs.join`: query strings, a literal `..`, or backslashes survive into
   the landing path. the older fetcher has `validate_archive_name` for the
   same derivation (`_build/build-fetch.tl:68-79`); the new reader dropped
   it.

## where

- `_make/pin.tl:139` — the digest pattern.
- `_make/pin.tl:166-169` — the url-derived output name into `fs.join`.
- `_build/build-fetch.tl:68-79` — the validation the older pipeline has.

## failure scenarios

1. a pin with a 40-char (truncated) digest reads fine; `--make fetch`
   reports mismatch with a full-length "got" hash against a short "want" —
   the message never says the pin's digest is malformed.
2. a pin url ending `?token=x` or containing `..` produces a landing path
   with those characters; on the `..` case the archive can land outside the
   pin's directory under `o/` (still inside the tree in practice, but
   outside the "mirrors the pin's position" contract).

## suggested fix

require exactly 64 hex characters for `sha256` at read time with a message
naming the field, and port `validate_archive_name` (or share it — see 030)
before joining the landing path.

## test to add

pin tests: a 40-hex digest refused with a length message; urls with `..`,
`\`, and `?` in the tail refused (or sanitized, matching whichever contract
`_build`'s validator enforces).
