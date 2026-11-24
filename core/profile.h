/*
 * A sampling profiler of Lua code, for measuring cosmic itself. With
 * COSMIC_PROFILE set to a path, the Lua state the core opens counts
 * instructions, and every COSMIC_PROFILE_PERIOD of them (1000 when unset)
 * records the stack of Lua and C functions it stands in. As the process
 * exits (returning from main, [`Proc.exit`], or an exec) it writes the
 * stacks to a new file `<path>.<pid>` (`<path>.<pid>.<n>` where that is
 * taken, as after an exec), one line each, in the folded form
 * flame graph tools read: frames from the outermost, joined by `;`, a
 * space and how many samples stood in that stack. Unset, it costs one
 * getenv when the state opens. Any cosmic program honors it, and its
 * children inherit it, each writing a file of its own.
 *
 * What it does not see:
 * - Time in C. A sample counts instructions.
 * - Anything while coverage or the instruction budget holds the state's
 *   one hook slot (core/coverage.c): startup coverage keeps the slot and
 *   nothing is profiled, and the first `start`, `stop` or budget of
 *   either takes it for the rest of the process.
 * - The code that resumed a coroutine. Each coroutine counts its own
 *   instructions, so one that runs fewer than the period is never
 *   sampled, and a sample in one holds its own frames alone.
 *
 * TODO: give the hook slot to both, a profile and coverage or a budget,
 * if a profile of the tests (whose workers set a budget) is ever wanted.
 */

#ifndef COSMIC_PROFILE_H
#define COSMIC_PROFILE_H

#include "lua.h"

/* Installs the count hook on `L` when COSMIC_PROFILE names a path. */
void cosmic_profile_install (lua_State *L);

/* Writes the profile, once, in the process that took it; nothing where
 * none is taken. atexit calls it; a path that leaves by _exit or exec
 * (core/syscalls.c) calls it first. */
void cosmic_profile_report (void);

#endif
