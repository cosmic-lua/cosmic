/* The syscall table's file and directory half. */

#if defined(__APPLE__)
/* Darwin hides mkdtemp, a POSIX call, once _XOPEN_SOURCE narrows the
 * headers below __DARWIN_C_FULL; asking for the full level back is what
 * this system calls opting back in, not an extension of its own. */
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700
/* A directory entry's type, which readdir fills on both systems, is a
 * BSD extension musl shows only when asked. */
#define _DEFAULT_SOURCE

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "check.h"
#include "fail.h"
#include "guard.h"
#include "lauxlib.h"
#include "syscalls.h"

/* The one place the two systems name the same field differently. macOS
 * keeps a timespec once _DARWIN_C_SOURCE asks for the full header level
 * mkdtemp also needs, and Linux always did. */
#if defined(__APPLE__)
#define COSMIC_MTIME_SECONDS(st) ((st).st_mtimespec.tv_sec)
#define COSMIC_MTIME_NANOSECONDS(st) ((st).st_mtimespec.tv_nsec)
#else
#define COSMIC_MTIME_SECONDS(st) ((st).st_mtim.tv_sec)
#define COSMIC_MTIME_NANOSECONDS(st) ((st).st_mtim.tv_nsec)
#endif

static void push_field(lua_State *L, const char *name, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, name);
}

static void push_stat(lua_State *L, const struct stat *st) {
  lua_createtable(L, 0, 10);
  push_field(L, "size", (lua_Integer)st->st_size);
  push_field(L, "mode", (lua_Integer)st->st_mode);
  push_field(L, "mtime", (lua_Integer)COSMIC_MTIME_SECONDS(*st));
  push_field(L, "mtime_ns", (lua_Integer)COSMIC_MTIME_NANOSECONDS(*st));
  push_field(L, "ino", (lua_Integer)st->st_ino);
  push_field(L, "dev", (lua_Integer)st->st_dev);
  push_field(L, "nlink", (lua_Integer)st->st_nlink);
  push_field(L, "uid", (lua_Integer)st->st_uid);
  push_field(L, "gid", (lua_Integer)st->st_gid);

  const char *kind = "other";
  if (S_ISREG(st->st_mode)) {
    kind = "file";
  } else if (S_ISDIR(st->st_mode)) {
    kind = "dir";
  } else if (S_ISLNK(st->st_mode)) {
    kind = "link";
  }
  lua_pushstring(L, kind);
  lua_setfield(L, -2, "kind");
}

COSMIC_SYSCALL(open, 3) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  int flags = cosmic_checkint(L, 2);
  int mode = cosmic_optint(L, 3, 0644);
  int fd;
  do {
    /* Every descriptor this table opens is close-on-exec: there is no
     * spawn in M1, but a child process is never handed a file it was
     * not given on purpose. */
    fd = open(path, flags | O_CLOEXEC, (mode_t)mode);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(open_temporary, 2) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  int mode = cosmic_optint(L, 2, 0644);
  static unsigned long serial;
  char temporary[PATH_MAX];

  for (unsigned int attempt = 0; attempt < 100; attempt++) {
    unsigned long number = ++serial;
    int length = snprintf(temporary, sizeof temporary, "%s.writing.%ld.%lu",
                          path, (long)getpid(), number);
    if (length < 0 || (size_t)length >= sizeof temporary) {
      return cosmic_fail(L, ENAMETOOLONG);
    }
    int fd;
    do {
      fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                (mode_t)mode);
    } while (fd < 0 && errno == EINTR);
    if (fd >= 0) {
      lua_createtable(L, 0, 2);
      push_field(L, "fd", (lua_Integer)fd);
      lua_pushstring(L, temporary);
      lua_setfield(L, -2, "path");
      return 1;
    }
    if (errno != EEXIST) {
      return cosmic_fail(L, errno);
    }
  }
  return cosmic_fail(L, EEXIST);
}

COSMIC_SYSCALL(close, 1) {
  int fd = cosmic_checkint(L, 1);
  if (close(fd) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(read, 2) {
  int fd = cosmic_checkint(L, 1);
  lua_Integer count = luaL_checkinteger(L, 2);
  if (count < 0) {
    return luaL_argerror(L, 2, "count is negative");
  }
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, (size_t)count);
  ssize_t got;
  do {
    got = read(fd, into, (size_t)count);
  } while (got < 0 && errno == EINTR);
  if (got < 0) {
    int number = errno;
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    return cosmic_fail(L, number);
  }
  luaL_pushresultsize(&buffer, (size_t)got);
  return 1;
}

COSMIC_SYSCALL(pread, 3) {
  int fd = cosmic_checkint(L, 1);
  lua_Integer count = luaL_checkinteger(L, 2);
  lua_Integer offset = luaL_checkinteger(L, 3);
  if (count < 0) {
    return luaL_argerror(L, 2, "count is negative");
  }
  if (offset < 0) {
    return luaL_argerror(L, 3, "offset is negative");
  }
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, (size_t)count);
  ssize_t got;
  do {
    got = pread(fd, into, (size_t)count, (off_t)offset);
  } while (got < 0 && errno == EINTR);
  if (got < 0) {
    int number = errno;
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    return cosmic_fail(L, number);
  }
  luaL_pushresultsize(&buffer, (size_t)got);
  return 1;
}

COSMIC_SYSCALL(write, 2) {
  int fd = cosmic_checkint(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  ssize_t put;
  do {
    put = write(fd, data, len);
  } while (put < 0 && errno == EINTR);
  if (put < 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, (lua_Integer)put);
  return 1;
}

COSMIC_SYSCALL(lseek, 3) {
  int fd = cosmic_checkint(L, 1);
  lua_Integer offset = luaL_checkinteger(L, 2);
  int whence = cosmic_checkint(L, 3);
  off_t at = lseek(fd, (off_t)offset, whence);
  if (at < 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, (lua_Integer)at);
  return 1;
}

COSMIC_SYSCALL(fstat, 1) {
  int fd = cosmic_checkint(L, 1);
  struct stat st;
  if (fstat(fd, &st) != 0) {
    return cosmic_fail(L, errno);
  }
  push_stat(L, &st);
  return 1;
}

COSMIC_SYSCALL(stat, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  struct stat st;
  if (stat(path, &st) != 0) {
    return cosmic_fail(L, errno);
  }
  push_stat(L, &st);
  return 1;
}

COSMIC_SYSCALL(lstat, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  struct stat st;
  if (lstat(path, &st) != 0) {
    return cosmic_fail(L, errno);
  }
  push_stat(L, &st);
  return 1;
}

COSMIC_SYSCALL(mkdir, 2) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  int mode = cosmic_optint(L, 2, 0755);
  if (mkdir(path, (mode_t)mode) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(rmdir, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  if (rmdir(path) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(unlink, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  if (unlink(path) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(rename, 2) {
  const char *from = cosmic_path(L, 1);
  if (from == NULL) return cosmic_fail_effect(L, EINVAL);
  const char *to = cosmic_path(L, 2);
  if (to == NULL) return cosmic_fail_effect(L, EINVAL);
  if (rename(from, to) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(chmod, 2) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  int mode = cosmic_checkint(L, 2);
  if (chmod(path, (mode_t)mode) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

static void release_dir(void *dir) { closedir(dir); }

COSMIC_SYSCALL(readdir, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  /* Filling the table allocates, and an allocation can raise: the guard
   * closes the directory then, and on every return. */
  struct cosmic_guard *guard = cosmic_guard_push(L, release_dir);
  DIR *dir = opendir(path);
  if (dir == NULL) {
    return cosmic_fail(L, errno);
  }
  guard->resource = dir;
  /* opendir's close-on-exec default is not guaranteed across the libc
   * this core links; asking outright costs one call and leaves nothing
   * to a platform's discretion. */
  fcntl(dirfd(dir), F_SETFD, FD_CLOEXEC);
  lua_newtable(L);
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (entry == NULL) {
      if (errno != 0) {
        int number = errno;
        lua_pop(L, 1);
        return cosmic_fail(L, number);
      }
      break;
    }
    if (entry->d_name[0] == '.' &&
        (entry->d_name[1] == '\0' ||
         (entry->d_name[1] == '.' && entry->d_name[2] == '\0'))) {
      continue;
    }
    /* The entry says what it is for free on every filesystem that
     * matters; a link, or a filesystem that does not say, is resolved
     * with one stat that follows, so a link counts as its target. */
    const char *kind = "other";
    if (entry->d_type == DT_DIR) {
      kind = "dir";
    } else if (entry->d_type == DT_REG) {
      kind = "file";
    } else if (entry->d_type == DT_LNK || entry->d_type == DT_UNKNOWN) {
      struct stat st;
      if (fstatat(dirfd(dir), entry->d_name, &st, 0) == 0) {
        if (S_ISDIR(st.st_mode)) {
          kind = "dir";
        } else if (S_ISREG(st.st_mode)) {
          kind = "file";
        }
      }
    }
    lua_pushstring(L, kind);
    lua_setfield(L, -2, entry->d_name);
  }
  return 1;
}

COSMIC_SYSCALL(getcwd, 0) {
  char room[PATH_MAX];
  if (getcwd(room, sizeof room) == NULL) {
    return cosmic_fail(L, errno);
  }
  lua_pushstring(L, room);
  return 1;
}

COSMIC_SYSCALL(chdir, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  if (chdir(path) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(realpath, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  char room[PATH_MAX];
  if (realpath(path, room) == NULL) {
    return cosmic_fail(L, errno);
  }
  lua_pushstring(L, room);
  return 1;
}

COSMIC_SYSCALL(mkdtemp, 1) {
  size_t len;
  const char *template = luaL_checklstring(L, 1, &len);
  if (memchr(template, '\0', len) != NULL) return cosmic_fail(L, EINVAL);
  if (len >= PATH_MAX) {
    return luaL_argerror(L, 1, "template is too long");
  }
  /* Linux refuses a template without the six X's; macOS takes it and
   * makes that exact directory, name and all, which is no temporary
   * directory at all. Refusing it here is what makes the call the same
   * on both. */
  if (len < 6 || strcmp(template + len - 6, "XXXXXX") != 0) {
    return luaL_argerror(L, 1, "template does not end in XXXXXX");
  }
  char room[PATH_MAX];
  memcpy(room, template, len + 1);
  if (mkdtemp(room) == NULL) {
    return cosmic_fail(L, errno);
  }
  lua_pushstring(L, room);
  return 1;
}

COSMIC_SYSCALL(symlink, 2) {
  const char *target = cosmic_path(L, 1);
  if (target == NULL) return cosmic_fail_effect(L, EINVAL);
  const char *path = cosmic_path(L, 2);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  if (symlink(target, path) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(readlink, 1) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  char room[PATH_MAX];
  ssize_t got = readlink(path, room, sizeof room);
  if (got < 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushlstring(L, room, (size_t)got);
  return 1;
}

COSMIC_SYSCALL(utimens, 3) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  lua_Integer atime_s = luaL_checkinteger(L, 2);
  lua_Integer mtime_s = luaL_checkinteger(L, 3);
  struct timespec times[2];
  times[0].tv_sec = (time_t)atime_s;
  times[0].tv_nsec = 0;
  times[1].tv_sec = (time_t)mtime_s;
  times[1].tv_nsec = 0;
  if (utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(fsync, 1) {
  int fd = cosmic_checkint(L, 1);
  if (fsync(fd) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}
