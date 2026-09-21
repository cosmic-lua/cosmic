/*
 * The Lua environment cosmic runs programs in: the pure libraries and
 * nothing that reaches outside the process. Files, streams, environment,
 * time and processes are cosmic modules over the syscall table, so one
 * call behaves the same on both systems and the sandbox has one door.
 */

#ifndef COSMIC_SURFACE_H
#define COSMIC_SURFACE_H

#include "lua.h"

/* The registry key holding the libraries that are not globals: `io`,
 * `os`, and `debug`. Each is a strictly more dangerous surface than an
 * ordinary sandboxed program needs, so each is taken out of reach here
 * regardless of whether anything currently fetches it back out. */
#define COSMIC_PRIVATE "cosmic.private"

/* Creates the state and opens the surface. `logical_executable` is the path a
 * program can execute to relaunch this same logical artifact. Returns NULL
 * when there is no memory for a state at all. */
lua_State *cosmic_surface_open(const char *logical_executable);

#endif
