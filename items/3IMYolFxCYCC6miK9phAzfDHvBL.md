Found while implementing 3IHHK1Bj, whose Acceptance names
`make -j$(nproc) o//test/tool/net` as a gate. That target does not
build on whilp/cosmopolitan master — the failure is on the base, not
in any change:

    $ cd whilp/cosmopolitan            # clean tree at 5bfcf79d
    $ make o//tool/net/lfuncs.o
    tool/net/lfuncs.c:575:37: error: 'CLOCK_MONOTONIC' undeclared
      (first use in this function); did you mean 'TIME_MONOTONIC'?
      575 |   pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
    make: *** [build/rules.mk:30: o//tool/net/lfuncs.o] Error 1

Reproduced 2026-08-24 with the working tree's changes stashed, so it
is not caused by anything in flight. `LuaResolveIpTimeout` uses
`CLOCK_MONOTONIC` without the header that declares it
(`libc/sysv/consts/clock.h` — the file's other includes do not pull it
in); `o//tool/lua/lua` and `o//tool/lua/test` compile a different
object set and are unaffected, which is why the repo's stated
correctness gate stays green while the redbean lane cannot build at
all.

The consequence for the board: every golden assertion under
`test/tool/net/**` is currently unrunnable, so a change that touches
those files can only be verified assertion-by-assertion against
`o//tool/lua/lua`. That is what 3IHHK1Bj's PR had to do.

Two questions a refinement pass should settle: whether the missing
include is the whole fix, and whether `o//test/tool/net` belongs in
this repo's CI so a base breakage of this size cannot sit unnoticed.
