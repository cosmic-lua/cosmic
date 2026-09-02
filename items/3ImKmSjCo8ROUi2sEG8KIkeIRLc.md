## Evidence

Found by the builder of item `3IlXxCIJoy2zMVGDDgaxkE6w2QQ` («xkE6_w2QQ»,
cosmic-lua/cosmopolitan#363) while fixing the identical bug in
`tool/lua/test_slurp_ranges.lua:20`. `tool/lua/test_unix_misc.lua:20` has
the same pattern:

```lua
tmpdir = "%s/o/tmp/lunix_test.%d" % {os.getenv('TMPDIR'), unix.getpid()}
```

`os.getenv('TMPDIR')` is `nil` when `TMPDIR` is unset, so this errors the
same way `test_slurp_ranges.lua` did before its fix: `bad argument #2 to
'string.format'`. It only passes under `make` because the Makefile
exports `TMPDIR = o/tmp`; run by hand from a bare shell (`env -u TMPDIR
o//tool/lua/lua tool/lua/test_unix_misc.lua`) it should reproduce the
same failure.

## Change

`tool/lua/test_unix_misc.lua`: fall back to `os.tmpname()`'s directory
(or `/tmp`) when `TMPDIR` is unset, the same one-line fix #363 applied
to `test_slurp_ranges.lua`. Test assertions unchanged.

## Non-goals

- No Makefile change.
- No change to `test_slurp_ranges.lua` (already fixed, #363).
