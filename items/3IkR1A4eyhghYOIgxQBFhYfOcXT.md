## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#338, which makes
`unix.sigaction` return one `unix.SignalAction` table (`handler`,
`flags`, `mask`) as its sole success value. Two ungated demos save the
old positional first value and later pass it back as the handler:

- `tool/net/demo/unix-subprocess.lua:13-14`, `:24-25`, `:50-51`
- (`tool/net/demo/unix-unix.lua:12-13` only saves the value and never restores it, so it is not broken — the round-2 review of #338 checked.)

each of the shape `oldint = assert(unix.sigaction(SIGINT, SIG_IGN))`
followed by `unix.sigaction(SIGINT, oldint)`. Once #338 lands `oldint`
is a table, and the restore raises
`bad argument #2 to 'sigaction' (sigaction handler not integer or function)`
— the same failure #338 had to fix in the gated
`tool/lua/test_unix_misc.lua:101,110`. Demos run under no test target,
so nothing red points at them. Re-locate at pull time:
`grep -n 'sigaction' tool/net/demo/*.lua`.

## Change

`tool/net/demo/unix-subprocess.lua`:
read the saved value's `.handler` field where the old handler is passed
back (`unix.sigaction(SIGINT, oldint.handler)`), one line per site,
nothing else. Run each demo once by hand against
`make -j$(nproc) o//tool/lua/lua` to confirm it no longer raises;
`make -j$(nproc) o//tool/lua/test` stays green.

## Non-goals

- No change to `unix.sigaction` or its annotation.
- No new test target for the demos.

The demo is embedded into `o//tool/net/redbean-demo` (`tool/net/BUILD.mk`,
`TOOL_NET_COMS`), so the tree ships a binary whose demo raises on its
restore path; no gate executes it, hence green CI (confirmed by #338's
review on the merged binary:
`pcall(u.sigaction, u.SIGINT, old)` → `false, bad argument #2 ...`).
