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
#include "psa/crypto.h"
#include "syscalls.h"

/* The one place the two systems name the same field differently. macOS
 * keeps a timespec once _DARWIN_C_SOURCE asks for the full header level
 * mkdtemp also needs, and Linux always did. */
#if defined(__APPLE__)
#define COSMIC_MTIME_SECONDS(st) ((st).st_mtimespec.tv_sec)
#define COSMIC_MTIME_NANOSECONDS(st) ((st).st_mtimespec.tv_nsec)
#define COSMIC_ATIME_SECONDS(st) ((st).st_atimespec.tv_sec)
#define COSMIC_ATIME_NANOSECONDS(st) ((st).st_atimespec.tv_nsec)
#define COSMIC_CTIME_SECONDS(st) ((st).st_ctimespec.tv_sec)
#define COSMIC_CTIME_NANOSECONDS(st) ((st).st_ctimespec.tv_nsec)
#else
#define COSMIC_MTIME_SECONDS(st) ((st).st_mtim.tv_sec)
#define COSMIC_MTIME_NANOSECONDS(st) ((st).st_mtim.tv_nsec)
#define COSMIC_ATIME_SECONDS(st) ((st).st_atim.tv_sec)
#define COSMIC_ATIME_NANOSECONDS(st) ((st).st_atim.tv_nsec)
#define COSMIC_CTIME_SECONDS(st) ((st).st_ctim.tv_sec)
#define COSMIC_CTIME_NANOSECONDS(st) ((st).st_ctim.tv_nsec)
#endif

static void push_field (lua_State *L, const char *name, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, name);
}

static void push_stat (lua_State *L, const struct stat *st) {
  lua_createtable(L, 0, 12);
  push_field(L, "size", (lua_Integer)st->st_size);
  push_field(L, "mode", (lua_Integer)st->st_mode);
  push_field(L, "mtime", (lua_Integer)COSMIC_MTIME_SECONDS(*st));
  push_field(L, "mtime_ns", (lua_Integer)COSMIC_MTIME_NANOSECONDS(*st));
  push_field(L, "atime", (lua_Integer)COSMIC_ATIME_SECONDS(*st));
  push_field(L, "atime_ns", (lua_Integer)COSMIC_ATIME_NANOSECONDS(*st));
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
    /* Every descriptor this table opens is close-on-exec: a child
     * process is never handed a file it was not given on purpose. */
    fd = open(path, flags | O_CLOEXEC, (mode_t)mode);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* The answer is built before the file is opened, with "fd" already a
 * key, so that setting the descriptor into it allocates nothing: an
 * allocation that raised while the descriptor was open would leak it. */
COSMIC_SYSCALL(open_temporary, 2) {
  const char *path = cosmic_path(L, 1);
  if (path == NULL) return cosmic_fail(L, EINVAL);
  int mode = cosmic_optint(L, 2, 0644);
  static unsigned long serial;
  char temporary[PATH_MAX];
  lua_createtable(L, 0, 2);
  push_field(L, "fd", -1);

  for (unsigned int attempt = 0; attempt < 100; attempt++) {
    unsigned long number = ++serial;
    int length = snprintf(temporary, sizeof temporary, "%s.writing.%ld.%lu",
                          path, (long)getpid(), number);
    if (length < 0 || (size_t)length >= sizeof temporary) {
      return cosmic_fail(L, ENAMETOOLONG);
    }
    lua_pushstring(L, temporary);
    lua_setfield(L, -2, "path");
    int fd;
    do {
      fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                (mode_t)mode);
    } while (fd < 0 && errno == EINTR);
    if (fd >= 0) {
      push_field(L, "fd", (lua_Integer)fd);
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

/* Up to this many bytes, a read's buffer is what it asked for. */
#define READ_SMALL ((lua_Integer)1 << 16)
/* The most one read of anything but a regular file asks for. */
#define READ_STREAM ((lua_Integer)1 << 20)

/* How many of `count` bytes one read of `fd` at `offset` (or, when
 * negative, at its own position) asks for, which is what its buffer
 * costs: a count past what the read could answer is never allocated,
 * so a huge count is no out-of-memory and a small file no huge buffer.
 * A regular file answers at most what is left of it -- but never less
 * than READ_SMALL, since a file that says it is empty or small (the
 * ones under /proc) may hold more -- and anything else at most
 * READ_STREAM. A read may always answer short, so a caller that loops
 * until the empty string sees the same bytes either way. */
static size_t read_room (int fd, lua_Integer count, off_t offset) {
  if (count <= READ_SMALL) return (size_t)count;
  lua_Integer room = READ_STREAM;
  struct stat st;
  if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
    if (offset < 0) offset = lseek(fd, 0, SEEK_CUR);
    if (offset >= 0) {
      lua_Integer left =
          st.st_size > offset ? (lua_Integer)(st.st_size - offset) : 0;
      room = left > READ_SMALL ? left : READ_SMALL;
    }
  }
  return (size_t)(count < room ? count : room);
}

COSMIC_SYSCALL(read, 2) {
  int fd = cosmic_checkint(L, 1);
  lua_Integer count = luaL_checkinteger(L, 2);
  if (count < 0) {
    return luaL_argerror(L, 2, "count is negative");
  }
  size_t room = read_room(fd, count, -1);
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, room);
  ssize_t got;
  do {
    got = read(fd, into, room);
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
  size_t room = read_room(fd, count, (off_t)offset);
  luaL_Buffer buffer;
  char *into = luaL_buffinitsize(L, &buffer, room);
  ssize_t got;
  do {
    got = pread(fd, into, room, (off_t)offset);
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

static void release_dir (void *dir) { closedir(dir); }

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
  int dir_fd = dirfd(dir);
  if (dir_fd >= 0) {
    fcntl(dir_fd, F_SETFD, FD_CLOEXEC);
  }
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
      if (dir_fd >= 0 && fstatat(dir_fd, entry->d_name, &st, 0) == 0) {
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
  /* readlink truncates silently: a target that fills the whole room may
   * have been cut short. Neither Linux nor macOS stores one that long,
   * so no test can reach this. */
  if ((size_t)got >= sizeof room) return cosmic_fail(L, ENAMETOOLONG);
  lua_pushlstring(L, room, (size_t)got);
  return 1;
}

/* Arguments `index` (whole seconds since the epoch) and `index + 1`
 * (the nanoseconds after them, 0 when absent) as a timespec, the shape
 * a Stat reports a time in; UTIME_OMIT when the seconds are nil or
 * absent. Nanoseconds outside [0, 1e9), or given without seconds,
 * raise. */
static struct timespec time_or_omit (lua_State *L, int index) {
  struct timespec at;
  if (lua_isnoneornil(L, index)) {
    luaL_argcheck(L, lua_isnoneornil(L, index + 1), index + 1,
                  "nanoseconds without seconds");
    at.tv_sec = 0;
    at.tv_nsec = UTIME_OMIT;
    return at;
  }
  lua_Integer seconds = luaL_checkinteger(L, index);
  lua_Integer ns = luaL_optinteger(L, index + 1, 0);
  luaL_argcheck(L, ns >= 0 && ns < 1000000000, index + 1,
                "nanoseconds outside [0, 1000000000)");
  at.tv_sec = (time_t)seconds;
  at.tv_nsec = (long)ns;
  return at;
}

COSMIC_SYSCALL(utimensat, 5) {
  const char *path = cosmic_path(L, 1);
  luaL_argcheck(L, !lua_isnoneornil(L, 2) || !lua_isnoneornil(L, 4), 2,
                "neither an access nor a modification time");
  struct timespec times[2];
  times[0] = time_or_omit(L, 2);
  times[1] = time_or_omit(L, 4);
  if (path == NULL) return cosmic_fail_effect(L, EINVAL);
  if (utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW) != 0) {
    return cosmic_fail_effect(L, errno);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(ftruncate, 2) {
  int fd = cosmic_checkint(L, 1);
  lua_Integer length = luaL_checkinteger(L, 2);
  luaL_argcheck(L, length >= 0, 2, "the length is negative");
  if (ftruncate(fd, (off_t)length) != 0) {
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

/* A walk of a tree for `tree_digest`: the digest being built, whether
 * files are hashed by their contents, the devices whose every answer is
 * the same or random, and whether it has met anything else that
 * answers from past the tree. */
struct tree_walk {
  psa_hash_operation_t hash;
  int contents;
  dev_t inert[3];
  int inert_count;
  int special;
  int failed;
};

/* Feeds `len` bytes of `data` into the walk's digest. */
static void tree_feed (struct tree_walk *walk, const void *data, size_t len) {
  if (walk->failed) return;
  if (psa_hash_update(&walk->hash, data, len) != PSA_SUCCESS) walk->failed = 1;
}

/* One entry's line: its name below the tree, length first so no name
 * can run into the next field, what it is, and what is said of it. */
static void tree_line (struct tree_walk *walk, const char *name, char kind,
                       const char *said) {
  char head[32];
  int made = snprintf(head, sizeof head, "%zu:", strlen(name));
  tree_feed(walk, head, (size_t)made);
  tree_feed(walk, name, strlen(name));
  char mark[3] = {' ', kind, ' '};
  tree_feed(walk, mark, sizeof mark);
  tree_feed(walk, said, strlen(said));
  tree_feed(walk, "\n", 1);
}

/* What `lstat` says of an entry that can change without its name
 * changing: its type and permissions, size, times of change, and where
 * it lives. */
static void tree_stamp (const struct stat *st, char *out, size_t size) {
  snprintf(out, size, "%lo %lld %lld.%09ld %lld.%09ld %llu %llu",
           (unsigned long)st->st_mode, (long long)st->st_size,
           (long long)COSMIC_MTIME_SECONDS(*st), (long)COSMIC_MTIME_NANOSECONDS(*st),
           (long long)COSMIC_CTIME_SECONDS(*st), (long)COSMIC_CTIME_NANOSECONDS(*st),
           (unsigned long long)st->st_ino, (unsigned long long)st->st_dev);
}

/* The hex sha256 of the file at `path`'s contents into `out`, or its
 * error. */
static void tree_file_digest (const char *path, char out[80]) {
  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) {
    snprintf(out, 80, "error %d", errno);
    return;
  }
  psa_hash_operation_t hash = PSA_HASH_OPERATION_INIT;
  int number = psa_hash_setup(&hash, PSA_ALG_SHA_256) == PSA_SUCCESS ? 0 : EIO;
  unsigned char chunk[65536];
  while (number == 0) {
    ssize_t got = read(fd, chunk, sizeof chunk);
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) number = errno;
    if (got <= 0) break;
    if (psa_hash_update(&hash, chunk, (size_t)got) != PSA_SUCCESS) number = EIO;
  }
  close(fd);
  unsigned char digest[32];
  size_t length = 0;
  if (number == 0 &&
      psa_hash_finish(&hash, digest, sizeof digest, &length) != PSA_SUCCESS) {
    number = EIO;
  }
  if (number != 0) {
    psa_hash_abort(&hash);
    snprintf(out, 80, "error %d", number);
    return;
  }
  for (size_t i = 0; i < length; i++) snprintf(out + 2 * i, 3, "%02x", digest[i]);
}

static int tree_name_order (const void *a, const void *b) {
  return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Walks the entry at `path`, whose name below the tree starts `skip`
 * bytes in, and everything beneath it, into the digest; `path` has room
 * for PATH_MAX bytes and is put back as it was. */
static void tree_walk_entry (struct tree_walk *walk, char *path, size_t skip) {
  const char *name = path + skip;
  char said[PATH_MAX + 128];
  struct stat st;
  if (lstat(path, &st) != 0) {
    snprintf(said, sizeof said, "error %d", errno);
    tree_line(walk, name, '!', said);
    return;
  }
  tree_stamp(&st, said, sizeof said);
  if (S_ISLNK(st.st_mode)) {
    ssize_t got = readlink(path, said, sizeof said - 1);
    if (got < 0) snprintf(said, sizeof said, "error %d", errno);
    else said[got] = '\0';
    tree_line(walk, name, 'l', said);
    return;
  }
  if (S_ISREG(st.st_mode)) {
    if (walk->contents) {
      char digest[80];
      tree_file_digest(path, digest);
      snprintf(said, sizeof said, "%lo %s", (unsigned long)st.st_mode, digest);
    }
    tree_line(walk, name, 'f', said);
    return;
  }
  if (!S_ISDIR(st.st_mode)) {
    int inert = 0;
    for (int i = 0; S_ISCHR(st.st_mode) && i < walk->inert_count; i++) {
      inert = inert || st.st_rdev == walk->inert[i];
    }
    if (!inert) walk->special = 1;
    tree_line(walk, name, 'o', said);
    return;
  }
  if (walk->contents) snprintf(said, sizeof said, "%lo", (unsigned long)st.st_mode);
  tree_line(walk, name, 'd', said);
  DIR *dir = opendir(path);
  if (dir == NULL) {
    snprintf(said, sizeof said, "unlisted %d", errno);
    tree_line(walk, name, '!', said);
    return;
  }
  char **names = NULL;
  size_t count = 0, room = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (entry == NULL) {
      if (errno != 0) {
        snprintf(said, sizeof said, "unlisted %d", errno);
        tree_line(walk, name, '!', said);
      }
      break;
    }
    if (entry->d_name[0] == '.' &&
        (entry->d_name[1] == '\0' ||
         (entry->d_name[1] == '.' && entry->d_name[2] == '\0'))) {
      continue;
    }
    if (count == room) {
      size_t more = room == 0 ? 64 : room * 2;
      char **grown = realloc(names, more * sizeof *names);
      if (grown == NULL) {
        walk->failed = 1;
        break;
      }
      names = grown;
      room = more;
    }
    names[count] = strdup(entry->d_name);
    if (names[count] == NULL) {
      walk->failed = 1;
      break;
    }
    count++;
  }
  closedir(dir);
  if (count > 1) qsort(names, count, sizeof *names, tree_name_order);
  size_t length = strlen(path);
  for (size_t i = 0; i < count; i++) {
    size_t more = strlen(names[i]);
    if (!walk->failed && length + 1 + more < PATH_MAX) {
      path[length] = '/';
      memcpy(path + length + 1, names[i], more + 1);
      tree_walk_entry(walk, path, skip);
      path[length] = '\0';
    } else if (!walk->failed) {
      tree_line(walk, name, '!', "too long");
    }
    free(names[i]);
  }
  free(names);
}

COSMIC_SYSCALL(tree_digest, 2) {
  const char *given = cosmic_path(L, 1);
  if (given == NULL) return cosmic_fail(L, EINVAL);
  int contents = lua_toboolean(L, 2);
  char path[PATH_MAX];
  size_t length = strlen(given);
  if (length >= sizeof path) return cosmic_fail(L, ENAMETOOLONG);
  memcpy(path, given, length + 1);
  while (length > 1 && path[length - 1] == '/') path[--length] = '\0';
  struct stat st;
  if (lstat(path, &st) != 0) return cosmic_fail(L, errno);
  struct tree_walk walk = { PSA_HASH_OPERATION_INIT, contents, {0}, 0, 0, 0 };
  static const char *const inert[] = { "/dev/null", "/dev/zero", "/dev/urandom" };
  for (size_t i = 0; i < sizeof inert / sizeof *inert; i++) {
    struct stat device;
    if (stat(inert[i], &device) == 0 && S_ISCHR(device.st_mode)) {
      walk.inert[walk.inert_count++] = device.st_rdev;
    }
  }
  if (psa_hash_setup(&walk.hash, PSA_ALG_SHA_256) != PSA_SUCCESS) return cosmic_fail(L, EIO);
  tree_walk_entry(&walk, path, length);
  unsigned char digest[32];
  size_t made = 0;
  if (walk.failed ||
      psa_hash_finish(&walk.hash, digest, sizeof digest, &made) != PSA_SUCCESS) {
    psa_hash_abort(&walk.hash);
    return cosmic_fail(L, walk.failed ? ENOMEM : EIO);
  }
  char hex[65];
  for (size_t i = 0; i < made; i++) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
  lua_createtable(L, 0, 2);
  lua_pushstring(L, hex);
  lua_setfield(L, -2, "digest");
  lua_pushboolean(L, walk.special);
  lua_setfield(L, -2, "special");
  return 1;
}
