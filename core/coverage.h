/*
 * The native line-coverage collector: hit accounting done in C, behind
 * the same trust gate the raw debug binding used before it (see
 * core/store.c, core/surface.c). A Lua line hook that calls back into
 * Lua per line -- debug.getinfo included -- costs one Lua call and one
 * table/string build per line executed; this does the same accounting
 * with plain C API calls instead, at a small fraction of the cost.
 */

#ifndef COSMIC_COVERAGE_H
#define COSMIC_COVERAGE_H

#include "lua.h"

/* Pushes a small table {start = <cfunction>, stop = <cfunction>} onto
 * the stack. `start` installs a line hook and begins a fresh, empty
 * collection; `stop` removes the hook and returns everything collected
 * since, as {string: {integer: boolean}} keyed by each hit's chunk
 * short_src. Registered as the raw value behind `cosmic.internal.debug`
 * (core/surface.c), the same trust-gated handoff `cosmic.store` and
 * `cosmic.sqlite` get through core/store.c's `store_searcher`. */
void cosmic_coverage_install(lua_State *L);

#endif
