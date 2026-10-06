/*
 * The raw calls a sandbox's own setup makes, each answering true, or
 * false, a message and the errno (ENOSYS off Linux), as a binding of a
 * runtime failure does (core/fail.h). Nothing here confines or checks
 * beyond the arguments: a caller without the privilege for one is
 * refused by the kernel.
 */

/* glibc declares unshare and setns only to _GNU_SOURCE. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "namespace_calls.h"

#include <errno.h>
#include <stddef.h>
#include <unistd.h>
#if defined(__linux__)
#include <sched.h>
#include <sys/mount.h>
#endif

#include "check.h"
#include "fail.h"
#include "lauxlib.h"

/* mount(source, target, fstype, flags, data): source, fstype and data may
 * be nil, for NULL. */
static int namespace_mount (lua_State *L) {
  const char *source = luaL_optstring(L, 1, NULL);
  const char *target = luaL_checkstring(L, 2);
  const char *fstype = luaL_optstring(L, 3, NULL);
  lua_Integer flags = luaL_checkinteger(L, 4);
  const char *data = luaL_optstring(L, 5, NULL);
  luaL_argcheck(L, flags >= 0, 4, "mount flags are not negative");
#if defined(__linux__)
  if (mount(source, target, fstype, (unsigned long)flags, data) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
#else
  (void)source;
  (void)target;
  (void)fstype;
  (void)data;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

/* umount2(target, flags). */
static int namespace_umount2 (lua_State *L) {
  const char *target = luaL_checkstring(L, 1);
  int flags = cosmic_checkint(L, 2);
#if defined(__linux__)
  if (umount2(target, flags) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  (void)target;
  (void)flags;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

/* unshare(flags). */
static int namespace_unshare (lua_State *L) {
  int flags = cosmic_checkint(L, 1);
#if defined(__linux__)
  if (unshare(flags) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  (void)flags;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

/* setns(fd, nstype). */
static int namespace_setns (lua_State *L) {
  int fd = cosmic_checkfd(L, 1);
  int nstype = cosmic_checkint(L, 2);
#if defined(__linux__)
  if (setns(fd, nstype) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  (void)fd;
  (void)nstype;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

/* chroot(path), then chdir("/") where it succeeds: a root the working
 * directory is outside of confines nothing. */
static int namespace_chroot (lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#if defined(__linux__)
  if (chroot(path) != 0 || chdir("/") != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  (void)path;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

static const luaL_Reg calls[] = {
  {"mount", namespace_mount},
  {"umount2", namespace_umount2},
  {"unshare", namespace_unshare},
  {"setns", namespace_setns},
  {"chroot", namespace_chroot},
  {NULL, NULL},
};

void cosmic_add_namespace_calls (lua_State *L) {
  luaL_setfuncs(L, calls, 0);
}
