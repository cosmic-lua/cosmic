/*
 * The Lua environment cosmic runs programs in: the pure libraries and
 * nothing that reaches outside the process. Files, streams, environment,
 * time and processes are cosmic modules over the syscall table, so one
 * call behaves the same on both systems and the sandbox has one door.
 */

#ifndef COSMIC_SURFACE_H
#define COSMIC_SURFACE_H

#include <stdbool.h>

#include "lua.h"

/* Creates the state and opens the surface. `logical_executable` is the path a
 * program can execute to relaunch this same logical artifact. Returns NULL
 * when there is no memory for a state at all, or when the VM cannot hold the
 * list of the C functions whose calls run no finalizer, which only a change
 * to the standard library could make so (`mark_inert`). */
lua_State *cosmic_surface_open (const char *logical_executable);

/* Names the C function at `idx`, a light one or a closure's, one whose
 * calls from Lua code run no pending finalizer, as the checker counts it
 * as running no code of the program
 * (patch/lua/26-finalizers-at-c-calls-inert-gc.txt). A value that is no
 * C function is left as it is. False only when the VM's list is full. */
bool cosmic_surface_set_inert (lua_State *L, int idx);

/* Closes a state cosmic_surface_open made, and frees the big blocks its
 * allocator kept for reuse. */
void cosmic_surface_close (lua_State *L);

/* If `name` is a library the surface removed (io, os, debug), pushes
 * what to write instead and returns true; otherwise pushes nothing and
 * returns false. */
bool cosmic_surface_push_removed_library (lua_State *L, const char *name);

#endif
