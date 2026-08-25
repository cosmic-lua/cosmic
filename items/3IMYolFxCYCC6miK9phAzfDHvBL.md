## Goal

G5 — adversarial verification. `tool/net/lfuncs.c` is 1316 lines of Lua
binding code that compiles in one of its two configurations and fails to
compile at all in the other, so the whole redbean lane — `-Wall -Werror`
included — has covered none of it since 2026-07-19. Restoring the
compile is upstream of every other form of verification over that file,
and it is what makes the lane's remaining breakage workable at all
(see Non-goals).

This is `whilp/cosmopolitan`, not `whilp/cosmic`; the PR lands there.

## Evidence

Measured 2026-08-25 against `whilp/cosmopolitan` master `354c17e0`, in a
clean tree (`git status --short` empty).

**The breakage reproduces on master.**

```
$ make -j$(nproc) o//tool/net/lfuncs.o
tool/net/lfuncs.c:575:37: error: 'CLOCK_MONOTONIC' undeclared
  (first use in this function); did you mean 'TIME_MONOTONIC'?
  575 |   pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
make: *** [build/rules.mk:30: o//tool/net/lfuncs.o] Error 1
$ echo $?
2
```

**The cause is one missing include.** `LuaResolveIpTimeout` uses
`CLOCK_MONOTONIC` twice and the file never includes the header that
declares it:

```
$ grep -c CLOCK_MONOTONIC tool/net/lfuncs.c
2
$ grep -n CLOCK_MONOTONIC tool/net/lfuncs.c
575:  pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
589:  clock_gettime(CLOCK_MONOTONIC, &deadline);
$ grep -c 'libc/sysv/consts/clock.h' tool/net/lfuncs.c
0
$ ls libc/sysv/consts/clock.h
libc/sysv/consts/clock.h
```

Three other `tool/net` translation units already include it explicitly
(`redbean.c`, `stampd.c`, `drift.c`), so the header is the file's own to
name and nothing about it is unusual.

**Introduced 2026-07-19, fork-local:**

```
$ git log --oneline -1 -L 575,575:tool/net/lfuncs.c
120e27db lua: bounded ResolveIp and ifreq flag ioctl bindings (#145, #146) (#199)
```

**Why the repo's stated gate stays green.** `tool/lua/lfuncs3.c` is two
lines — `#define USE_MBEDTLS3` then `#include "tool/net/lfuncs.c"` — and
`o//tool/lua/lua` links `o//tool/lua/lfuncs3.o`, never
`o//tool/net/lfuncs.o` (`tool/lua/BUILD.mk:28`). The same source
therefore compiles under the `USE_MBEDTLS3` include block
(`tool/net/lfuncs.c:72-78`), which reaches the declaration transitively,
and fails without it. So the fork's Lua binary has been depending on an
accidental transitive include for the same two lines the redbean lane
refuses.

**The include is the whole COMPILE fix, and not the whole lane fix.**
With `#include "libc/sysv/consts/clock.h"` added and nothing else
changed, every object and binary in the lane builds:

```
$ make -j$(nproc) o//test/tool/net/redbean-tester.dbg   # exit 0
$ make -j$(nproc) o//tool/lua/test                      # exit 0, 29 .ok files
```

and then 12 of the lane's 40 checks FAIL when run
(`make -k -j$(nproc) o//test/tool/net`, 28 `.runs` produced). Those
failures are captured as their own item — see Non-goals — and are not
this slice's to fix.

## Change

One file, one added line: `tool/net/lfuncs.c` (1316 lines today; this
repo has no per-file cap, so headroom is not the question — surgical
diff size is, per AGENTS.md).

Add exactly this line, and nothing else:

```c
#include "libc/sysv/consts/clock.h"
```

Its position is line 54, between `#include "libc/sysv/consts/af.h"`
(`:53` today) and `#include "libc/sysv/consts/ipproto.h"` (`:54` today).
That keeps the file's existing alphabetical ordering inside the
`libc/sysv/consts/` group, which is how `redbean.c`, `stampd.c` and
`drift.c` order theirs.

No other edit. `LuaResolveIpTimeout`'s body does not change, no existing
include moves, and no `#ifdef` is touched.

## Non-goals

- **Do not fix any `test/tool/net/*_test.lua` failure**, and do not
  touch `test/tool/net/**` at all. Twelve of the lane's checks fail
  after this diff for reasons that have nothing to do with
  `CLOCK_MONOTONIC` — the tests were written against the `cosmo` module
  surface `o//tool/lua/lua` exposes and are run against
  `o//tool/net/redbean`, which does not link `tool/lua/lcosmo.c`. That
  is item `3INxo51I`, which also carries the decision about whether the
  lane is re-aimed or retired.
- **Do not add `o//test/tool/net` to `.github/workflows/pr.yml`** or any
  other workflow. The lane is red on arrival, so it cannot join CI until
  `3INxo51I` is answered; the second question the original capture
  raised is settled there, not here.
- **Do not touch `tool/net/definitions.lua`.** No binding contract
  moves: this diff adds no declaration, changes no return shape, and
  removes no constant, so the annotation ratchet has nothing to see and
  cosmic's generated types do not move.
- **Do not touch `tool/lua/lfuncs3.c`, `tool/lua/lcosmo.c`,
  `tool/lua/BUILD.mk`, or `test/tool/net/BUILD.mk`.** The accidental
  transitive include under `USE_MBEDTLS3` is worth knowing about (see
  Evidence) but this diff fixes it by making the dependency explicit in
  `lfuncs.c`, which is the surgical form; auditing the other
  configuration's includes is not in scope.
- **Do not reorder, remove, or reformat any existing `#include`** in
  `tool/net/lfuncs.c`. AGENTS.md forbids drive-by reformatting because
  the fork stays mergeable with upstream jart/cosmopolitan.
- **Do not bump cosmic's `3p/cosmos/cosmos_pin.tl`** or make any change
  in `whilp/cosmic`. This repairs a build lane and changes no shipped
  binary's behaviour — `o//tool/lua/lua` compiled the same two lines
  before and after — so there is nothing downstream to re-pin.

## Acceptance

All commands run verbatim from the `whilp/cosmopolitan` repo root and
write only into `o/`, which is not committed.

- `make -j$(nproc) o//tool/net/lfuncs.o` exits 0. Today it exits 2 with
  `tool/net/lfuncs.c:575:37: error: 'CLOCK_MONOTONIC' undeclared`.
- `make -j$(nproc) o//test/tool/net/redbean-tester.dbg` exits 0 — the
  whole redbean lane compiles and links again. Today it exits 2 on the
  same `lfuncs.o` error.
- `make -j$(nproc) o//tool/lua/test` exits 0, the repo's stated
  correctness gate (AGENTS.md), unchanged by this diff. It is green
  today and must stay green.
- `grep -c 'libc/sysv/consts/clock.h' tool/net/lfuncs.c` is 1 (0 today).
- `grep -c CLOCK_MONOTONIC tool/net/lfuncs.c` is 2 (2 today — unchanged;
  no use is added or removed).
- `git diff --stat master -- tool/net/lfuncs.c` reports `1 insertion(+)`
  and `0 deletions`, and `git diff --name-only master` names exactly
  `tool/net/lfuncs.c` and nothing else.
- `sed -n '53,55p' tool/net/lfuncs.c` prints the three
  `libc/sysv/consts/` includes in the order `af.h`, `clock.h`,
  `ipproto.h`.

`make -j$(nproc) o//test/tool/net` is deliberately NOT an acceptance
command: it still exits 2 after this diff, on the twelve test failures
Non-goals hands to `3INxo51I`. Quote its `-k` failure list in the PR as
context, not as a gate.

A cold first build downloads the cosmocc toolchain into `.cosmocc/`, so
the first of these commands needs a network; the rest are hermetic.

## Enablement

none needed. Every fact above was measured in this repo during the
refinement pass that asserts it, including the fix: the include was
added, `o//tool/net/lfuncs.o`, `o//test/tool/net/redbean-tester.dbg` and
`o//tool/lua/test` were all built green with it, the lane was then run
under `-k` to enumerate what remains, and the edit was reverted, leaving
the tree clean. So the claiming session is re-running measurements
already taken rather than discovering the shape of the work. The one
thing it must not assume is that the lane goes green — it does not, by
construction, and `3INxo51I` is where that lives.
