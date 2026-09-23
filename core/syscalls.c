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
#include "sha256.h"
#include "syscalls.h"

#if defined(__APPLE__)
#include <crt_externs.h>
#define COSMIC_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define COSMIC_ENVIRON environ
#endif

COSMIC_SYSCALL(executable, 0) {
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

COSMIC_SYSCALL(sha256, 1) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  unsigned char digest[32];
  cosmic_sha256(data, len, digest);
  lua_pushlstring(L, (const char *)digest, sizeof digest);
  return 1;
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

COSMIC_SYSCALL(inflate_raw, 2) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  lua_Integer size = luaL_checkinteger(L, 2);
  if (size < 0) {
    return luaL_argerror(L, 2, "the expanded size is negative");
  }
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, (size_t)size);
  size_t got = tinfl_decompress_mem_to_mem(into, (size_t)size, data, len, 0);
  if (got == TINFL_DECOMPRESS_MEM_TO_MEM_FAILED) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "the stream is not raw deflate, or expands past size");
    lua_pushinteger(L, -1);
    return 3;
  }
  luaL_pushresultsize(&buffer, got);
  return 1;
}

#define ENTRY(name) {#name, cosmic_sys_##name}

static const luaL_Reg table[] = {
    ENTRY(open),     ENTRY(close),         ENTRY(read),
    ENTRY(pread),    ENTRY(write),         ENTRY(lseek),
    ENTRY(fstat),    ENTRY(stat),          ENTRY(lstat),
    ENTRY(mkdir),    ENTRY(rmdir),         ENTRY(unlink),
    ENTRY(rename),   ENTRY(chmod),         ENTRY(readdir),
    ENTRY(getcwd),   ENTRY(chdir),         ENTRY(realpath),
    ENTRY(mkdtemp),  ENTRY(executable),    ENTRY(getenv),
    ENTRY(environ),  ENTRY(exit),          ENTRY(getpid),
    ENTRY(clock_gettime), ENTRY(nanosleep), ENTRY(isatty),
    ENTRY(sha256),   ENTRY(deflate),       ENTRY(inflate),
    ENTRY(inflate_raw),
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
