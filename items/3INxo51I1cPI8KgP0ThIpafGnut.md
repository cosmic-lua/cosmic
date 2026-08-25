Found while refining 3IMYolFx, which asked whether the missing
`CLOCK_MONOTONIC` include is the whole fix for `o//test/tool/net`. It is
not. With the include added, the lane COMPILES and LINKS clean, and then
12 of its 40 checks fail when run.

Measured 2026-08-25 against whilp/cosmopolitan master `354c17e0`, with
`#include "libc/sysv/consts/clock.h"` added to `tool/net/lfuncs.c` and
nothing else changed:

    $ make -k -j$(nproc) o//test/tool/net
    ...
    redbean: test/tool/net/argon2_test.lua:19: attempt to index a nil value (field 'variants')
    redbean: test/tool/net/futex_test.lua:101: attempt to call a nil value (method 'errno')
    redbean: test/tool/net/lfetch_test.lua:1058: Some tests failed
    redbean: test/tool/net/lfetchstream_test.lua:20: module 'cosmo' not found:
    redbean: test/tool/net/lfuncs_test.lua:40: attempt to call a nil value (global 'UnescapeParam')
    redbean: test/tool/net/lre_test.lua:23: assertion failed!
    redbean: test/tool/net/lunix_test.lua:187: UnixTest failed (o/tmp/o/tmp/lunix_test.10007)
    redbean: test/tool/net/mapshared_test.lua:77: attempt to call a nil value (method 'errno')
    redbean: test/tool/net/readlink_test.lua:23: module 'cosmo.unix' not found:
    redbean: test/tool/net/slurp_test.lua:49: SlurpTest failed (o/tmp/o/tmp/lunix_test.10041)
    redbean: test/tool/net/spinlock_test.lua:62: attempt to call a nil value (method 'errno')
    redbean: test/tool/net/sysconf_test.lua:51: attempt to call a nil value (method 'errno')

    $ ls o//test/tool/net/*.runs | wc -l
    28

Two of the twelve are this sandbox, not the repo: `lfetch_test` and
`lfetchstream_test` need a real network, and every one of their inner
failures here reads `badcert_not_trusted` — a re-terminated TLS egress.
Those two need re-measuring on a runner with plain egress before anyone
calls them broken.

The other TEN are environment-independent, and they share one shape: the
tests were written against the Lua surface `o//tool/lua/lua` exposes and
run against `o//tool/net/redbean`, which exposes a different one.
`module 'cosmo' not found` and `module 'cosmo.unix' not found` are the
plainest evidence — the `cosmo` module is registered by
`tool/lua/lcosmo.c`, which redbean does not link. `UnescapeParam` as a
missing global, `variants` as a missing argon2 field, and `:errno()` as
a missing method on three separate objects are the same drift seen from
the binding side.

The decision this needs is which of two, and it is a real fork question
rather than a repair to schedule:

1. **Re-aim the lane at `o//tool/lua/lua`**, where these tests' surface
   actually lives, and keep the golden assertions that still mean
   something. `tool/lua/` already carries its own `test_*.lua` suite and
   its own `.ok` rules, so this may be a merge into that suite rather
   than a second lane.
2. **Retire `test/tool/net/**` as redbean's**, on the reading that this
   fork keeps the C core and the Lua bindings while redbean itself is
   upstream's product, and let `o//tool/lua/test` remain the whole
   correctness gate — as AGENTS.md already says it is.

Either answer settles the second question 3IMYolFx opened and this item
inherits: whether `o//test/tool/net` belongs in this repo's CI. It
cannot join CI as it stands, because it would be red on arrival. Under
option 1 the re-aimed lane is a CI candidate; under option 2 there is no
lane to add.

Sizing note for whoever refines this: option 1 is ten independent test
repairs plus a BUILD.mk change, which is a container, not a slice.
