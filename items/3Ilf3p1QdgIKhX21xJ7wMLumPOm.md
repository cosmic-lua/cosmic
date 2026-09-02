## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#359.
`tool/lua/test_zip.lua:512`, `test_zip_append.lua:496` and
`test_zip_security.lua:322` clean up with `os.execute("rm -rf " ..
tmpdir)`; under `o//tool/lua/lua.dbg` the call prints `rm: illegal
option -- r` in default mode and the temp directory is never
removed. cosmo's `system()` appears to dispatch `rm` to a builtin
that lacks `-r`. Re-measure at pull time: `o//tool/lua/lua.dbg
tool/lua/test_zip.lua 2>&1 | grep 'illegal option'` and `ls
$TMPDIR` afterwards.

## Change

Decide whether the builtin `rm` in cosmo's `system()`/`_cocmd`
should honour `-r`/`-f` (upstream jart/cosmopolitan behaviour is the
reference; check `tool/build/cocmd.c` or wherever the builtin
lives) or whether the three tests should use `unix.rmrf`-style Lua
cleanup instead; do the smaller one that stops the leak, and add a
test that asserts the temp directory is gone after the suite's
cleanup.

## Non-goals

- No change to what the zip tests assert about zips.
