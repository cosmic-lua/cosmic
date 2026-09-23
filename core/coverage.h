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
 * snapshot = <cfunction>, ...} onto the stack. `start` installs a line
 * hook and begins a fresh, empty collection; `stop` removes the hook and
 * returns every line collected since; `snapshot` reads a copy of every
 * line collected so far without touching the hook or the collection, for
 * a caller that wants to look while collection keeps running. A C
 * function's lines are how a test is seen to reach it, in a core built
 * with COSMIC_NATIVE_COVERAGE. `stop` and `snapshot` describe hits the
 * same way: {string: {integer: boolean}}, keyed by each chunk's full source
 * name (with an initial @ stripped). In a core built with
 * COSMIC_NATIVE_COVERAGE they also hold the core's own C, by repository
 * path (core/syscalls.c), and `lines` answers every C line that could be
 * hit, in that same form -- empty in any other core. Registered
 * as the raw value behind `cosmic.internal.debug` (core/surface.c),
 * the same trust-gated handoff `cosmic.store` and `cosmic.sqlite` get
 * through core/store.c's `store_searcher`. */
void cosmic_coverage_install (lua_State *L);

/* Pushes {budget = <cfunction>}: `budget(count)` arms a budget of `count`
 * VM instructions on the calling coroutine, raising "instruction budget
 * exceeded" once they are spent, and `budget()` disarms it. It shares the
 * one hook with collection, which stays as it was. The raw value behind
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
