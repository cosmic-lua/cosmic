## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#347. At
`f96adf44`, `third_party/lua/cosmo/lunix.c`'s `LuaUnixIsatty`
(`lunix.c:2955-2965`) checks `rc == -1` after `isatty(fd)` and returns
the `nil, error, errno` tuple on that path — but Cosmopolitan's
`isatty()` returns only 0 or 1 (`libc/calls/isatty.c`: every failure
collapses to 0 with errno set), so the branch is unreachable. That is
why item 3IiFcAtW (PR #307) retyped the annotation to `@return
boolean`, why `help.txt` says `└─→ bool`, and why #347's gate made the
lunix.c comment say the same: three documents now describe a binding
whose source still carries a failure path none of them admit. #307's
spec named the C-side fix (surface EBADF/EPERM as a real failure
tuple) as a follow-up it deliberately did not adopt; no item carries
it. Re-measure at pull time: `sed -n '2950,2966p'
third_party/lua/cosmo/lunix.c` and `grep -n 'return' libc/calls/isatty.c`.

## Change

Decide in refinement, then build one of:

1. Delete the dead `rc == -1` branch so the C matches the three
   documents (no contract change; `definitions.lua` untouched).
2. Adopt #307's named follow-up: make `LuaUnixIsatty` distinguish
   ENOTTY (false) from EBADF/EPERM (failure tuple), which is a
   contract change — `definitions.lua`, `help.txt` and the lunix.c
   comment in the same commit, a conformance probe in the same PR, and
   cosmic's `cosmic.fd`/wrapper regen as its own follow-on item.

Either way the annotation, `help.txt`, the lunix.c shape comment and
the C body must agree when the PR lands, and
`make -j$(nproc) o//tool/lua/test` stays green.

## Non-goals

- No other binding changes.
