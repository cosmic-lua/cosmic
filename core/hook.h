/*
 * Lua's one hook slot, shared. A thread has one hook function, one event
 * mask and one instruction count, and three parts of the core want them:
 * coverage counts lines (core/coverage.c), the instruction budget counts
 * instructions (core/coverage.c), and the profiler takes a sample at the
 * instruction after its timer fires (core/profile.c). Each asks here for
 * what it wants, and the one hook this installs gives each event to the
 * part it is for, so none turns another off.
 */

#ifndef COSMIC_HOOK_H
#define COSMIC_HOOK_H

#include "lua.h"

/* Sets what coverage and the budget want of the calling thread `L`, and
 * of the threads it makes from now on, which inherit its hook: lines
 * while `lines` is set, and a count event every `budget` instructions
 * while it is above 0. Neither clears a sample the profiler armed. */
void cosmic_hook_set (lua_State *L, int lines, int budget);

/* Arms a count event at `L`'s next instruction, for the profiler, and
 * keeps what `L` had to give back after it. Safe in a signal handler: it
 * does nothing while the hook runs, or while [`cosmic_hook_set`] changes
 * it, and the caller's ticks wait for the next arm. */
void cosmic_hook_arm (lua_State *L);

/* What each part does with its events, defined where the part is. */
void cosmic_coverage_line (lua_State *L, lua_Debug *ar);
void cosmic_coverage_count (lua_State *L);
void cosmic_profile_sample (lua_State *L);
/* The signal the profiler's timer sends, or 0 while none runs: blocked
 * while [`cosmic_hook_set`] changes a thread's hook. */
int cosmic_profile_signal (void);

#endif
