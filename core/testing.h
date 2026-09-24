/*
 * Test instruments, as `cosmic.internal.testing`. The checked core
 * carries them (core/testing_checked.c): a failing allocator, which is
 * how a test reaches the paths a Lua call takes when an allocation
 * fails, and the counted C heap (core/memory.h) that draws from the
 * same count; a count of the statements left open on the store's
 * databases and of the HTTP transfers alive; and the fault points of
 * core/fault.h. Every other core carries core/testing.c, which answers
 * with its configuration's name and registers the same instruments as
 * stand-ins that raise, so the table cosmic/internal/testing.d.tl
 * declares is every core's and no shipped core has an allocator a
 * program can make fail.
 */

#ifndef COSMIC_TESTING_H
#define COSMIC_TESTING_H

#include "lua.h"

/* Pushes the module table. */
int cosmic_open_testing (lua_State *L);

#endif
