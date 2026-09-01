## Evidence

Found by the fresh-context review of cosmic-lua/cosmopolitan#337: a new
test rule inserted into `tool/lua/BUILD.mk` between an existing
`test_sqlite_prepare_error.ok` recipe line and its `@touch $@` left that
target without its touch. Measured at #337's first head `2e73500b`:

```
$ grep -c '\.ok:' tool/lua/BUILD.mk ; grep -c '@touch' tool/lua/BUILD.mk
65
64          # base: 65 / 65
```

The consequence is silent: after a green `make -j$(nproc) o//tool/lua/test`
the file `o//tool/lua/test_sqlite_prepare_error.ok` does not exist, so
every subsequent `make o//tool/lua/test` re-runs that test — the target
never converges — and CI stays green because the test itself passes.
Nothing in the tree checks that every `.ok` rule ends in a touch.

## Change

One PR on cosmic-lua/cosmopolitan: a check, run as part of
`o//tool/lua/test` (a small Lua or shell test enrolled in
`tool/lua/BUILD.mk` like its siblings), that reads `tool/lua/BUILD.mk`
and asserts every `o//tool/lua/<name>.ok:` rule's recipe ends with
`@touch $@` — fail naming each rule that does not. Alternatively, if the
build already offers a cheaper hook, assert convergence directly: after
the test target completes, every `.ok` named by a rule exists under
`o//tool/lua/`. Pick the one the file's shape makes trivial; the first
reads as a 20-line Lua script.

## Non-goals

- No change to any test rule's recipe beyond what the new check
  reports on the day it lands (fix those in the same PR; #337's own
  omission is fixed on #337).
