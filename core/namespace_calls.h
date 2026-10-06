/*
 * The raw calls a sandbox's own setup makes -- mount, umount2, unshare,
 * setns, chroot -- as members of [`cosmic.internal.testing`], so a test
 * can ask whether a program inside a sandbox is refused them. Every core
 * carries them, unlike the rest of that table (core/testing.h).
 */

#ifndef COSMIC_NAMESPACE_CALLS_H
#define COSMIC_NAMESPACE_CALLS_H

#include "lua.h"

/* Sets the calls as fields of the table on top of the stack. */
void cosmic_add_namespace_calls (lua_State *L);

#endif
