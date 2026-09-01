## Goal

An incremental edit to `tool/net/fetch.inc` (or any other header
`tool/net/lfetch.c` includes) must cause `o/$(MODE)/tool/net/lfetch.o`
to rebuild. Today it does not: the object is rebuilt only when
`lfetch.c` itself changes, so a developer iterating on `fetch.inc` —
the file carrying most of `cosmo.Fetch`'s logic — can run a stale
binary without any signal that the edit never took effect.

## Evidence

Measured 2026-09-01 against cosmic-lua/cosmopolitan master `9ca98b646`.

`tool/net/BUILD.mk:7-9` deliberately excludes `lfetch.c` from the
package's source list (it needs Mbed TLS 3.6 flags and links only into
the lua binary):

```
# lfetch.c is compiled against Mbed TLS 3.6 and linked only into the
# lua binary (see tool/lua/BUILD.mk); redbean uses fetch.inc directly
TOOL_NET_SRCS = $(filter-out tool/net/lfetch.c,$(filter %.c,$(TOOL_NET_FILES)))
```

`tool/lua/BUILD.mk:35` names `o/$(MODE)/tool/net/lfetch.o` only in
`TOOL_LUA_LUA_MODULES`; no `*.mk` in the tree carries an explicit
compile rule or header-dependency line for it:

```
$ grep -rln 'lfetch.o' --include='*.mk' .
./tool/lua/BUILD.mk
```

The consequence: the object is built by the generic `%.o: %.c` pattern
rule, and its header edges come only from the mkdeps-generated
`o/$(MODE)/depend`, which is derived from the SRCS lists that exclude
`lfetch.c` — so no `lfetch.o: tool/net/fetch.inc` edge exists, and an
incremental `make` after editing `fetch.inc` alone rebuilds nothing.

Observed live during the review of PR #314's mutation test: disabling
the `Proxy-Authorization` construction in `tool/net/fetch.inc` and
re-running `make o//tool/lua/test` changed nothing until
`touch tool/net/lfetch.c` forced the rebuild — the mutation appeared
to "pass" until the workaround was found.

## Change

Give `lfetch.o` its missing header dependencies without re-admitting
`lfetch.c` into `TOOL_NET_SRCS` (the Mbed TLS 3.6 exclusion is
deliberate and stays). The least mechanism that makes an edit to
`fetch.inc` rebuild `lfetch.o` wins — e.g. an explicit dependency line
beside the module list in `tool/lua/BUILD.mk`
(`o/$(MODE)/tool/net/lfetch.o: tool/net/fetch.inc ...` for the headers
`lfetch.c` includes), or wiring `lfetch.c` into whatever list mkdeps
scans without changing which package compiles/links it. Investigate
which of the two the build system's own conventions prefer before
choosing; the repo keeps diffs surgical.

## Non-goals

- No change to which flags `lfetch.c` compiles under or which binary
  links it — the Mbed TLS 3.6 arrangement `tool/net/BUILD.mk:7-8`
  documents is untouched.
- No general mkdeps rework; this is one object's missing edges.

## Acceptance

- From a built tree: `touch tool/net/fetch.inc && make
  o//tool/net/lfetch.o` recompiles the object (today it is a no-op).
- A content edit to `fetch.inc` followed by `make -j$(nproc)
  o//tool/lua/test` runs the tests against a binary carrying the edit,
  with no manual `touch`.
- `make -j$(nproc) o//tool/lua/test` still passes from clean.
