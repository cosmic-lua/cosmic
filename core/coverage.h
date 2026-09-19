/*
 * The native line-coverage collector: hit accounting done in C, behind
 * the same trust gate the raw debug binding used before it (see
 * core/store.c, core/surface.c). A Lua line hook that calls back into
 * Lua per line -- debug.getinfo included -- costs one Lua call and one
 * table/string build per line executed; this does the same accounting
 * with native hit bitsets instead, materializing Lua tables only when read.
 */

#ifndef COSMIC_COVERAGE_H
#define COSMIC_COVERAGE_H

#include "lua.h"

/* Install once on the main thread, before running any Lua code. The collector
 * reserves Lua's extraspace for its state-lifetime pointer; new coroutines
 * inherit that pointer. The userdata itself stays rooted in the registry.
 *
 * Pushes a small table {start = <cfunction>, stop = <cfunction>,
 * snapshot = <cfunction>} onto the stack. `start` installs a line hook
 * and begins a fresh, empty collection; `stop` removes the hook and
 * returns everything collected since; `snapshot` reads a copy of
 * everything collected so far without touching the hook or the
 * collection, for a caller that wants to look while collection keeps
 * running. All three describe hits the same way: {string:
 * {integer: boolean}}, keyed by each chunk's full source name (with an initial
 * @ stripped). Registered
 * as the raw value behind `cosmic.internal.debug` (core/surface.c),
 * the same trust-gated handoff `cosmic.store` and `cosmic.sqlite` get
 * through core/store.c's `store_searcher`. */
void cosmic_coverage_install(lua_State *L);

#endif
