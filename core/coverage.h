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
 * Pushes the collector's table onto the stack. Its members, and what
 * each answers, are cosmic/internal/debug.d.tl's, which
 * core/declarations_test.tl holds to what this registers. A C
 * function's lines are how a test is seen to reach it, in a core built
 * with COSMIC_NATIVE_COVERAGE. Registered as the raw value behind
 * `cosmic.internal.debug` (core/surface.c), the same trust-gated handoff
 * `cosmic.store` and `cosmic.sqlite` get through core/store.c's
 * `store_searcher`. */
void cosmic_coverage_install (lua_State *L);

/* Pushes the instruction budget's table, declared by
 * cosmic/internal/budget.d.tl. It shares the one hook with collection,
 * which stays as it was. The raw value behind
 * `build.fuzz` (core/store.c), and nothing else's. */
int cosmic_open_budget (lua_State *L);

/* `envp`, or, once processes this one starts are to report their C to a
 * test (`children`), a new array of the same entries plus the name that
 * tells them where: free it, not its entries, when it differs from `envp`.
 * Built before a fork, since the child may not allocate. */
char **cosmic_coverage_environment (char **envp);

/* In a process a test started, arranges for it to report the C it runs
 * (`cosmic_coverage_report`) and hides how from everything after. Called
 * first thing, before startup can fail, so a process that ends in its
 * own startup -- a refused portable launch -- still reports; install
 * calls it too, and a second call does nothing. */
void cosmic_coverage_prepare (void);

/* In a process a test started, writes the C it has run to the test's
 * directory; does nothing in any other. Runs at exit, and before `_exit`
 * and `execve`, which end this image without it. */
void cosmic_coverage_report (void);

#endif
