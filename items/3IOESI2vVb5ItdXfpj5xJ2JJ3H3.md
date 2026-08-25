Promise 1 says the C layer runs under sanitizers in CI; no
whilp/cosmopolitan workflow does (measured 2026-08-25: `grep -rin
"asan|ubsan|sanitiz" .github/workflows/` in that repo matches
nothing). The fork already carries the mode: `MODE=dbg` enables
UBSan (`-fsanitize=undefined`, build/config.mk "Debug Mode"
stanza). Add a CI lane to whilp/cosmopolitan's pr.yml running the
Lua binding tests under it — `make MODE=dbg o//tool/lua/test` — so
undefined behavior in tool/net/*.c and third_party/lua surfaces on
every PR. Research half: confirm whether an address-sanitizer mode
still exists in the fork (only ubsan is visible in build/config.mk)
and record what the dbg-mode test run costs in CI minutes before
gating on it.
