## What this container is

`test/tool/net/**` in whilp/cosmopolitan is 40 checks that do not run.
This container settles what happens to them and carries the children
that do it.

The original finding (from refining 3IMYolFx) stands: with
`#include "libc/sysv/consts/clock.h"` added to `tool/net/lfuncs.c` —
landed since, as `3c36bc35` / #275 — the lane compiles and links
clean, and then 12 of its 40 checks fail when run.

## The decision, and why the evidence settles it

The item opened with two options: (1) re-aim the lane at
`o//tool/lua/lua`, repairing the ten environment-independent failures,
or (2) retire `test/tool/net/**` as redbean's. **Neither is right on
its own.** Measured 2026-08-25 against whilp/cosmopolitan `3c36bc35`,
the twelve failures and the twenty-eight passes want opposite answers,
so the lane splits rather than being kept or dropped whole.

**The failures are not drift. They assert contracts this fork
deliberately replaced, so there is nothing to repair.**

Four of the ten (`futex`, `mapshared`, `spinlock`, `sysconf`) fail on
`attempt to call a nil value (method 'errno')`, one `:errno()` call
each:

```
$ for f in futex mapshared spinlock sysconf; do \
    grep -c 'errno()' test/tool/net/${f}_test.lua; done
1 1 1 1
```

That method is redbean's error object. This fork returns `nil,
err:string, errno:integer` instead, and says so in a test that already
gates:

```
$ grep -n 'errno' tool/lua/test_unix_errno.lua
20:-- errno is a plain integer usable directly (no :errno() method needed)
21:assert(math.type(errno) == "integer", "errno is an integer")
```

Two more (`lfetchstream`, `readlink`) fail with `module 'cosmo' not
found`: `cosmo` is registered by `tool/lua/lcosmo.c`, which redbean
does not link, so those tests are aimed at the wrong binary by
construction. `lfuncs_test`'s missing `UnescapeParam` global and
`argon2_test`'s missing `variants` field are the same divergence seen
from the binding side — redbean exposes globals where the fork
namespaces under `cosmo.*`.

Rewriting these to the fork's contract does not recover coverage; it
reproduces `tool/lua/test_unix_errno.lua`, which exists.

Two of the twelve are not the repo's: `lfetch_test` and
`lfetchstream_test` need a real network and every inner failure in the
measuring sandbox read `badcert_not_trusted`, a re-terminated TLS
egress. They are retired with the rest either way; nobody should call
them broken on that evidence.

**But twenty-eight checks pass, and some of that coverage exists
nowhere else.** The JSON conformance corpus is the clear case — the
JSONTestSuite and json.org bodies are vendored inline:

```
$ wc -l test/tool/net/jsontestsuite_pass_test.lua \
        test/tool/net/jsontestsuite_fail1_test.lua \
        test/tool/net/ljson_test.lua
340  437  228
```

`tool/lua/test_data_formats.lua` (288 lines) is the fork's only json
test and it is a CONTRACT test, not a corpus one: array metatables,
`NaN`/`Infinity` rejection, empty-collection round-tripping. It
adversarially exercises nothing. Dropping the corpus would lose real
coverage of a parser cosmic's G5 names as fuzz-critical.

**So: retire the redbean-contract half, salvage what the fork's own
gate does not already cover.** Nothing is deleted before the salvage
lands — the children are ordered by a `blocked_by` edge to guarantee
it.

## Why the lane can be retired rather than fixed in place

`o//tool/lua/test` is already the gate, in the workflows and in the
prose:

```
$ grep -rn 'test/tool/net\|tool/lua/test' .github/workflows/
.github/workflows/pr.yml:26:      o/x86_64/tool/lua/test \
.github/workflows/release.yml:38: o/x86_64/tool/lua/test \
```

`test/tool/net` appears in no workflow. AGENTS.md already names
`make -j$(nproc) o//tool/lua/test` as "correctness gates before any
PR". And exactly one reference to the lane exists outside itself:

```
$ grep -rn 'test/tool/net' --include=*.mk --include=*.yml --include=*.md . \
    | grep -v '^./test/tool/net'
./test/tool/BUILD.mk:9:		o/$(MODE)/test/tool/net		\
```

So the lane has been dead for as long as it has failed to compile, and
retiring it costs one line in `test/tool/BUILD.mk` plus the directory.

This also answers the second question 3IMYolFx opened and this item
inherited — whether `o//test/tool/net` belongs in this repo's CI. It
does not; the salvaged tests join `o//tool/lua/test`, which is already
there.

## The children

1. **Audit and salvage** — inventory the 28 passing checks against
   `tool/lua/test_*.lua`, port what is not already covered (the json
   corpus at minimum) into `tool/lua/`, wired into the `tool/lua/test`
   target. The inventory is research the salvage cannot be sized
   without, so it is that child's first deliverable.
2. **Retire the lane** — delete `test/tool/net/**` and its
   `test/tool/BUILD.mk:9` reference. Blocked by (1).

## Outcome test for this container

`ls test/tool/net` reports no such directory; `grep -rn 'test/tool/net'`
over the tree has no matches; `make -j$(nproc) o//tool/lua/test` passes
and its check count is strictly greater than it is today, by the number
of salvaged checks.

## Open question for the goal owner

The pick above is mine, made from the measurements quoted, because the
loop had nobody to ask. It is cheap to reverse while child 2 is
blocked: nothing is deleted until the salvage lands. If the fork wants
`test/tool/net/**` kept and re-aimed as a second lane after all, say so
and child 2 becomes a re-aim instead of a deletion.
