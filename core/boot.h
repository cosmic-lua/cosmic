/*
 * Boot mode: the bridge from C to Teal, used when no database is
 * attached yet. It loads the vendored Teal compiler in an environment
 * built over the syscall table, installs a searcher that compiles a
 * `.tl` straight from the tree, and hands control to `build.boot`.
 *
 * A shipped binary carries a database, so it can never enter this mode.
 */

#ifndef COSMIC_BOOT_H
#define COSMIC_BOOT_H

#include "lua.h"

/* Runs the bridge. Returns the process's exit status. */
int cosmic_boot (lua_State *L, const char *root, const char *tl_dir, int argc,
                 char **argv);

#endif
