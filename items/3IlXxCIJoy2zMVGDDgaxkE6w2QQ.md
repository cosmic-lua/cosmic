## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#354.
`tool/lua/test_slurp_ranges.lua:20` formats `os.getenv('TMPDIR')`
into a path; with `TMPDIR` unset it errors with `bad argument #2 to
'string.format'`. It passes under make only because the Makefile
exports `TMPDIR = o/tmp`; run by hand from a bare shell it fails.
Re-measure at pull time: `env -u TMPDIR o//tool/lua/lua
tool/lua/test_slurp_ranges.lua`.

## Change

`tool/lua/test_slurp_ranges.lua`: fall back to `os.tmpname()`'s
directory or `/tmp` when `TMPDIR` is unset, one line; the test's
assertions are unchanged.

## Non-goals

- No Makefile change.
