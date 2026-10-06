/* A counting `assert`, as [`cosmic.internal.assertions`]: what the test
 * worker installs as the global `assert`, so a test's calls to it can be
 * counted. It is a C function because `assert` is one: a Lua function that
 * replaced it would turn `return assert(false, "m")` into a tail call and
 * lose the caller's frame, whose position a failure reports. */

#ifndef COSMIC_ASSERTIONS_H
#define COSMIC_ASSERTIONS_H

#include "lua.h"

/* Pushes the table of `assert`, `count` and `reset`, declared by
 * cosmic/internal/assertions.d.tl. Its count lives in the registry, so
 * every closure of one state shares it. */
int cosmic_open_assertions (lua_State *L);

#endif
