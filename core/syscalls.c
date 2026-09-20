/* The syscall table's process, time and data half, and the module. */

#define _XOPEN_SOURCE 700

#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "fail.h"
#include "lauxlib.h"
#include "locate.h"
#include "miniz.h"
#include "crypto.h"
#include "syscalls.h"

#if defined(__APPLE__)
#include <crt_externs.h>
#define COSMIC_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define COSMIC_ENVIRON environ
#endif

COSMIC_SYSCALL(executable, 0) {
  lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_LOGICAL_EXECUTABLE);
  if (lua_isstring(L, -1)) return 1;
  lua_pop(L, 1);
  char resolved[PATH_MAX];
  if (!cosmic_executable_path(resolved, sizeof resolved)) {
    return cosmic_fail(L, errno == 0 ? ENAMETOOLONG : errno);
  }
  lua_pushstring(L, resolved);
  return 1;
}

COSMIC_SYSCALL(getenv, 1) {
  const char *name = luaL_checkstring(L, 1);
  const char *value = getenv(name);
  if (value == NULL) {
    lua_pushnil(L);
  } else {
    lua_pushstring(L, value);
  }
  return 1;
}

COSMIC_SYSCALL(environ, 0) {
  lua_newtable(L);
  char **at = COSMIC_ENVIRON;
  for (; at != NULL && *at != NULL; at++) {
    const char *entry = *at;
    const char *split = entry;
    while (*split != '\0' && *split != '=') {
      split++;
    }
    if (*split != '=') {
      continue;
    }
    lua_pushlstring(L, entry, (size_t)(split - entry));
    lua_pushstring(L, split + 1);
    lua_settable(L, -3);
  }
  return 1;
}

COSMIC_SYSCALL(exit, 1) {
  int status = (int)luaL_optinteger(L, 1, 0);
  _exit(status); /* exits: the process boundary has no caller to return to */
}

COSMIC_SYSCALL(getpid, 0) {
  lua_pushinteger(L, (lua_Integer)getpid());
  return 1;
}

COSMIC_SYSCALL(clock_gettime, 1) {
  int which = (int)luaL_checkinteger(L, 1);
  struct timespec now;
  if (clock_gettime((clockid_t)which, &now) != 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, (lua_Integer)now.tv_sec * 1000000000 +
                         (lua_Integer)now.tv_nsec);
  return 1;
}

COSMIC_SYSCALL(nanosleep, 1) {
  lua_Integer nanoseconds = luaL_checkinteger(L, 1);
  if (nanoseconds < 0) {
    return luaL_argerror(L, 1, "the duration is negative");
  }
  struct timespec want = {
      .tv_sec = (time_t)(nanoseconds / 1000000000),
      .tv_nsec = (long)(nanoseconds % 1000000000),
  };
  struct timespec left;
  while (nanosleep(&want, &left) != 0) {
    if (errno != EINTR) {
      return cosmic_fail_effect(L, errno);
    }
    want = left;
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(isatty, 1) {
  int fd = (int)luaL_checkinteger(L, 1);
  lua_pushboolean(L, isatty(fd) == 1);
  return 1;
}

/* An algorithm nobody has heard of is an argument-shape error and
 * raises; the library refusing a hash it advertises is a bug, and
 * raises too. Neither is a runtime failure a caller could handle. */
static int hashed(lua_State *L, int status, const unsigned char *digest,
                  size_t len) {
  if (status == -1) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  if (status != 0) {
    return luaL_error(L, "the digest failed with status %d", status);
  }
  lua_pushlstring(L, (const char *)digest, len);
  return 1;
}

COSMIC_SYSCALL(digest, 2) {
  const char *name = luaL_checkstring(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_len = 0;
  int status = cosmic_digest(name, data, len, digest, &digest_len);
  return hashed(L, status, digest, digest_len);
}

COSMIC_SYSCALL(hmac, 3) {
  const char *name = luaL_checkstring(L, 1);
  size_t key_len;
  const char *key = luaL_checklstring(L, 2, &key_len);
  size_t len;
  const char *data = luaL_checklstring(L, 3, &len);
  unsigned char mac[COSMIC_DIGEST_MAX];
  size_t mac_len = 0;
  int status = cosmic_hmac(name, key, key_len, data, len, mac, &mac_len);
  return hashed(L, status, mac, mac_len);
}

/* The argv and environment arrays are built from the Lua tables, which
 * stay on the stack and so keep every string alive until execve, which
 * frees nothing on success because nothing of this process remains. */
COSMIC_SYSCALL(execve, 3) {
  const char *path = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  luaL_checktype(L, 3, LUA_TTABLE);

  lua_Integer count = luaL_len(L, 2);
  char **argv = calloc((size_t)count + 1, sizeof *argv);
  if (argv == NULL) {
    return cosmic_fail(L, ENOMEM);
  }
  for (lua_Integer i = 1; i <= count; i++) {
    lua_geti(L, 2, i);
    argv[i - 1] = (char *)luaL_checkstring(L, -1);
    lua_pop(L, 1);
  }

  /* Each "NAME=value" entry is built by concatenation and kept in a
   * table on the stack, which is what keeps its bytes alive; the key
   * itself is left exactly as lua_next needs it. */
  lua_newtable(L);
  int entries = lua_gettop(L);
  lua_Integer variables = 0;
  lua_pushnil(L);
  while (lua_next(L, 3) != 0) {
    luaL_checktype(L, -2, LUA_TSTRING);
    lua_pushvalue(L, -2);
    lua_pushliteral(L, "=");
    lua_pushvalue(L, -3);
    lua_concat(L, 3);
    lua_seti(L, entries, ++variables);
    lua_pop(L, 1);
  }
  char **envp = calloc((size_t)variables + 1, sizeof *envp);
  if (envp == NULL) {
    free(argv);
    return cosmic_fail(L, ENOMEM);
  }
  for (lua_Integer i = 1; i <= variables; i++) {
    lua_geti(L, entries, i);
    envp[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  execve(path, argv, envp);
  int number = errno;
  free(envp);
  free(argv);
  return cosmic_fail(L, number);
}

COSMIC_SYSCALL(deflate, 1) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  mz_ulong room = mz_compressBound((mz_ulong)len);
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, room);
  int rc = mz_compress2((unsigned char *)into, &room,
                        (const unsigned char *)data, (mz_ulong)len,
                        MZ_BEST_COMPRESSION);
  if (rc != MZ_OK) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, mz_error(rc));
    lua_pushinteger(L, rc);
    return 3;
  }
  luaL_pushresultsize(&buffer, room);
  return 1;
}

COSMIC_SYSCALL(inflate, 2) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  lua_Integer size = luaL_checkinteger(L, 2);
  if (size < 0) {
    return luaL_argerror(L, 2, "the expanded size is negative");
  }
  mz_ulong room = (mz_ulong)size;
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, room);
  int rc = mz_uncompress((unsigned char *)into, &room,
                         (const unsigned char *)data, (mz_ulong)len);
  if (rc != MZ_OK) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, mz_error(rc));
    lua_pushinteger(L, rc);
    return 3;
  }
  luaL_pushresultsize(&buffer, room);
  return 1;
}

#define ENTRY(name) {#name, cosmic_sys_##name}

static const luaL_Reg table[] = {
    ENTRY(open),     ENTRY(open_temporary), ENTRY(close),
    ENTRY(read),     ENTRY(pread),          ENTRY(write),
    ENTRY(lseek),
    ENTRY(fstat),    ENTRY(stat),          ENTRY(lstat),
    ENTRY(mkdir),    ENTRY(rmdir),         ENTRY(unlink),
    ENTRY(rename),   ENTRY(chmod),         ENTRY(readdir),
    ENTRY(getcwd),   ENTRY(chdir),         ENTRY(realpath),
    ENTRY(mkdtemp),  ENTRY(executable),    ENTRY(getenv),
    ENTRY(environ),  ENTRY(exit),          ENTRY(getpid),
    ENTRY(clock_gettime), ENTRY(nanosleep), ENTRY(isatty),
    ENTRY(digest),   ENTRY(hmac),          ENTRY(deflate),
    ENTRY(inflate),  ENTRY(execve),
    {NULL, NULL},
};

struct constant {
  const char *name;
  lua_Integer value;
};

/* The numbers a caller passes back in. They come from this libc, so a
 * Teal module never carries a platform's constant of its own. */
static const struct constant constants[] = {
    {"O_RDONLY", O_RDONLY},
    {"O_WRONLY", O_WRONLY},
    {"O_RDWR", O_RDWR},
    {"O_CREAT", O_CREAT},
    {"O_EXCL", O_EXCL},
    {"O_TRUNC", O_TRUNC},
    {"O_APPEND", O_APPEND},
    {"SEEK_SET", SEEK_SET},
    {"SEEK_CUR", SEEK_CUR},
    {"SEEK_END", SEEK_END},
    {"CLOCK_REALTIME", CLOCK_REALTIME},
    {"CLOCK_MONOTONIC", CLOCK_MONOTONIC},
    {"ENOENT", ENOENT},
    {"EEXIST", EEXIST},
    {"EACCES", EACCES},
    {"EINTR", EINTR},
    {"EISDIR", EISDIR},
    {"ENOTDIR", ENOTDIR},
    {"ENOTEMPTY", ENOTEMPTY},
    {"EAGAIN", EAGAIN},
    {"EPIPE", EPIPE},
    {"EXDEV", EXDEV},
    {NULL, 0},
};

int cosmic_open_syscalls(lua_State *L) {
  luaL_newlib(L, table);
  for (const struct constant *c = constants; c->name != NULL; c++) {
    lua_pushinteger(L, c->value);
    lua_setfield(L, -2, c->name);
  }
  return 1;
}
