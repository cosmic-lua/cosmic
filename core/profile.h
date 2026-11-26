/*
 * The sampling profiler, for measuring cosmic itself. With
 * COSMIC_PROFILE set to a directory, every cosmic process (and every
 * child it starts, which inherits the variable) writes a profile of its
 * own there as it exits (a child whose environment is given anew gets
 * the variables back from its parent's start, core/coverage.c): `<dir>/<pid>.prof`, or `<pid>-<n>.prof` where
 * that is taken, as after an exec. The directory is made where it is
 * missing. Unset, it costs one getenv as the process starts.
 *
 * A timer drives the samples: COSMIC_PROFILE_HZ a second (997 when
 * unset, and at most the kernel's tick rate for CPU time) of the
 * process's CPU time, or of wall time with
 * COSMIC_PROFILE_CLOCK=wall, which counts waits too. Each tick the
 * signal handler notes the C function the running thread stands in, if
 * any, and arms a hook at that thread's next instruction (core/hook.c),
 * which records the stack. So time in C (a SQLite step, a sort, a
 * search) is seen, charged to that C function under the Lua line that
 * called it.
 *
 * The file is lines of text, each led by a word:
 *
 *   cosmic-profile 1
 *   process <pid> parent <ppid> clock <cpu|wall> hz <n>
 *   command <the command line, joined by spaces>
 *   total wall_ns <n> cpu_ns <n> sampled_us <n> dropped_us <n> other_us <n>
 *   span <names> <count> <wall_ns> <cpu_ns>
 *   sample <frames> <line> <us>
 *
 * A span is a named stretch a program marks ([`Clock.span`],
 * [`Clock.phase`]; the `profile_span_open` call): its line totals the
 * spans of one path, the names of the spans it stood in and its own, each
 * `[name]`, joined by `;`. Its CPU time is the thread's.
 *
 * A sample's frames run from the outermost, joined by `;`, the spans open
 * when it was taken first: a Lua
 * function as `name@source:linedefined`, a C function as `name@[C]`
 * (named `module.field` or `type:method` by where the loaded modules and
 * the registry's metatables hold it). Its line is the innermost Lua line,
 * `source:line`, and its weight is the microseconds on the profile's
 * clock its ticks measured: each tick measures the time since the one
 * before, since a CPU timer fires on the kernel's own tick (every 4 ms on
 * many Linux kernels) whatever rate it is asked for. `dropped_us` is time
 * the tables had no room for; `other_us`, time on a thread that runs no
 * Lua.
 *
 * What it does not see:
 * - Time before the Lua state opens, or after the process starts to
 *   exit. The totals cover the whole process from its start.
 * - Which coroutine resumed the one a sample stands in. A sample holds
 *   the frames of its own coroutine alone.
 * - Lua a thread runs without a resume (a coroutine's close handlers):
 *   its time goes to the thread that resumes next.
 * - A tick that lands as a coroutine yields: that coroutine's budget
 *   countdown (core/coverage.c) starts again in full when it next runs.
 * - A process a signal kills leaves its file empty.
 */

#ifndef COSMIC_PROFILE_H
#define COSMIC_PROFILE_H

#include <stddef.h>

#include "lua.h"

/* Opens the profile's file when COSMIC_PROFILE names a directory, first
 * thing as the process starts: before a sandbox layer holds it, so a
 * sandboxed process writes its profile too. */
void cosmic_profile_prepare (int argc, char **argv);

/* Starts the timer, sampling `L` and the coroutines it runs, where
 * [`cosmic_profile_prepare`] opened a file. */
void cosmic_profile_install (lua_State *L);

/* The `NAME=value` entries of the profile's variables, for a child this
 * process starts to profile itself into the same directory (made
 * absolute): how many, 0 where no profile is taken. Built once, as the
 * profile is prepared; never freed. */
size_t cosmic_profile_entries (char *const **entries);

/* Writes the profile, once, in the process that took it; nothing where
 * none is taken. atexit calls it; a path that leaves by _exit or exec
 * (core/syscalls.c) calls it first. It stops the timer. */
void cosmic_profile_report (void);

#endif
