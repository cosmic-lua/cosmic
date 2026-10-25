/*
 * Boot mode: the bridge from C to Teal, used when no database is
 * attached yet. It loads the seed (the Lua the pinned release wrote for
 * the files of build/seed.txt) as the first-stage compiler, has that
 * compile the same files from the tree, installs a searcher that compiles
 * a `.tl` straight from the tree with the result, and hands control to
 * [`build.boot`].
 *
 * A shipped binary carries a database, so it can never enter this mode.
 */

#ifndef COSMIC_BOOT_H
#define COSMIC_BOOT_H

#include "lua.h"

/* Runs the bridge. Returns the process's exit status. */
int cosmic_boot (lua_State *L, const char *root, const char *seed_dir, int argc,
                 char **argv);

#endif
