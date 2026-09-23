/*
 * Test instruments, as `cosmic.internal.testing`. The checked core
 * carries them (core/testing_checked.c): a failing allocator, which is
 * how a test reaches the paths a Lua call takes when an allocation
 * fails, and a count of the statements left open on the store's
 * databases. Every other core carries core/testing.c, which answers
 * with its configuration's name and nothing else, so no shipped core
 * has an allocator a program can make fail.
 */

#ifndef COSMIC_TESTING_H
#define COSMIC_TESTING_H

#include "lua.h"

/* Pushes the module table. */
int cosmic_open_testing (lua_State *L);

#endif
