## Evidence

The title's premise is wrong in a useful way: `.inc` files ARE in the
dependency scan. At origin/master `3892e562`, `tool/net/BUILD.mk:11`
sets `TOOL_NET_INCS = $(filter %.inc,$(TOOL_NET_FILES))`, the root
`Makefile:428-433` writes `INCS` into `o/$(MODE)/incs.txt` and feeds
`srcs.txt hdrs.txt incs.txt` to `build/bootstrap/mkdeps`, and
`tool/build/mkdeps.c:145-158` treats every extension outside its
source list (`c s S cc c++ cpp cu m`) as a header, so `tool/net/
fetch.inc` and `counters.inc` get edges like any `.h`. What is
missing is the INCLUDING file: `tool/net/BUILD.mk:9` filters
`tool/net/lfetch.c` out of `TOOL_NET_SRCS` (it compiles against
Mbed TLS 3.6 and links only into the lua binary), so it never reaches
`$(SRCS)` (`Makefile:410`) or `srcs.txt`, and `mkdeps` scans only
the files on its command line (`LoadRelationships`, `mkdeps.c:487+`).
Result: `o/$(MODE)/depend` carries NO edges for `lfetch.o` — not for
`fetch.inc`, and not for any of the 40 `#include` lines in
`lfetch.c` either. The symptom PR #310's builder hit (edit
`fetch.inc`, `make o//tool/lua/test`, stale `lfetch.o`) was patched
by hand afterwards: `tool/lua/BUILD.mk:40-45` now lists
`tool/net/fetch.inc` as an explicit prerequisite of `lfetch.o`, with
a comment naming exactly this cause. That closes one edge of ~40 and
leaves every header `lfetch.c` includes (Mbed TLS, libc, Lua) stale
on edit. Re-measure at pull time on a built tree: `grep -c
'tool/net/lfetch.o' o//depend` (expected 0) versus `grep -c
'tool/net/lsqlite3.o' o//depend` (non-zero), and `grep -n lfetch
tool/lua/BUILD.mk`.

## Change

One PR on cosmic-lua/cosmopolitan, two parts:

1. Put `tool/net/lfetch.c` into the scan without putting it back into
   `TOOL_NET_SRCS`'s object list: a source variable that the root
   `SRCS` aggregate sees (a `TOOL_LUA_*_SRCS` entry in
   `tool/lua/BUILD.mk`, the package that owns the object, or an
   `EXTRA_SRCS`-style hook if `build/definitions.mk` already has one),
   so `srcs.txt` lists it and `o/$(MODE)/depend` gains its edges; keep
   the object's explicit rule and its Mbed TLS flags exactly as they
   are; then delete the hand-listed `tool/net/fetch.inc` prerequisite
   and its comment at `tool/lua/BUILD.mk:40-45`, since `depend` now
   carries it.
2. A gate so the next filtered-out source cannot repeat this: a small
   test enrolled in `tool/lua/BUILD.mk` (own `@touch $@`) that reads
   `o/$(MODE)/srcs.txt` and asserts every `.c` under `tool/net`,
   `tool/lua` and `third_party/lua/cosmo` that has an object rule in
   this build appears in it, failing by path.

## Non-goals

- Not the `%I` bug (PR #310).
- No change to `mkdeps.c` or to how other packages declare sources;
  the fix is one package's declaration and one gate.

## Acceptance

- After `make o//tool/lua/test` on the PR head: `grep
  'o/$(MODE)/tool/net/lfetch.o' o//depend` (with MODE expanded) lists
  `tool/net/fetch.inc` and lfetch.c's headers; `touch
  tool/net/fetch.inc && make o//tool/lua/lua` recompiles `lfetch.o`
  (visible in the make output), and so does touching one header
  `lfetch.c` includes.
- Mutation: re-adding the `filter-out` for a second file (e.g.
  `lcov.c`) with no compensating entry makes the new gate fail naming
  `tool/net/lcov.c`.
- `make -j$(nproc) o//tool/lua/test` green.
