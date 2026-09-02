## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#355 (item 3IitgVz8,
the lfetch.c dependency scan). `tool/lua/BUILD.mk` compiles
`third_party/lua/cosmo/lua.main.c` into
`o/$(MODE)/tool/lua/lua.main.o` through an explicit cross-directory
rule (`-DLUA_COSMO`), but `mkdeps` maps that source to
`o/$(MODE)/third_party/lua/cosmo/lua.main.o` (which is where its edge
block lands), so the object the lua binary actually links has no
header edges: `grep -c 'o//tool/lua/lua.main.o' o//depend` is 0 on
#355's head, and a header edit reuses the stale object. The cause
differs from 3IitgVz8's (the object path differs from the source's,
not a missing scan), so the `srcs.txt` gate #355 adds cannot catch
it. Re-measure at pull time on a built tree: the grep above, then
`touch third_party/lua/cosmo/lua.h-or-any-included-header && make
o//tool/lua/lua` and read whether `lua.main.o` recompiles.

## Change

One PR on cosmic-lua/cosmopolitan: give `lua.main.o` real edges —
either compile it at the path `mkdeps` derives (`o/$(MODE)/third_party/
lua/cosmo/lua.main.o`, with the `-DLUA_COSMO` flag as a `private
CFLAGS` on that object) and link that, or add an explicit
`o/$(MODE)/tool/lua/lua.main.o: $(o/$(MODE)/third_party/lua/cosmo/
lua.main.o's edge sources)` alias in `tool/lua/BUILD.mk`. Prefer the
first: one object, one path, `depend` carries it. Extend the
`test_srcs_scan.lua` gate from #355 to also assert that every object
`tool/lua/lua` links has a `depend` block, failing by object path.

## Non-goals

- No change to `mkdeps.c`.
- No change to which flags `lua.main.c` is compiled with.
