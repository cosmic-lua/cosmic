/* The syscall table's process, time and data half, the module, and the
 * raw process table core/process.h declares. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#if defined(__linux__)
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
#include <linux/if.h>
#include <linux/sockios.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <stddef.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
/* _XOPEN_SOURCE intentionally hides these libc escape hatches: syscall,
 * for the calls musl has no wrapper for, and clone, which starts a child
 * on this process's memory ([`start_child`]). */
extern long syscall (long, ...);
extern int clone (int (*)(void *), void *, int, void *, ...);
#endif
#if defined(__APPLE__)
#include <spawn.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#endif
#if defined(__x86_64__)
#include <cpuid.h>
#endif
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/utsname.h>

#include "check.h"
#include "coverage.h"
#include "fail.h"
#include "fault.h"
#include "guard.h"
#include "lauxlib.h"
#include "executable.h"
#include "memory.h"
#include "crypto.h"
#include "environment.h"
#include "syscalls.h"
#include "portable.h"
#include "process.h"
#include "startup.h"
#include "store.h"

const char *cosmic_path (lua_State *L, int index) {
  size_t length;
  const char *value = luaL_checklstring(L, index, &length);
  if (memchr(value, '\0', length) != NULL) return NULL;
  return value;
}

COSMIC_SYSCALL(executable, 0) {
  lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_LOGICAL_EXECUTABLE);
  if (lua_isstring(L, -1)) return 1;
  lua_pop(L, 1);
  char resolved[PATH_MAX];
  /* Cleared first: a failure that sets no errno of its own (a path too
   * long for the room) must not report whatever an earlier call left. */
  errno = 0;
  if (!cosmic_executable_path(resolved, sizeof resolved)) {
    int number = errno;
    return cosmic_fail(L, number == 0 ? ENAMETOOLONG : number);
  }
  lua_pushstring(L, resolved);
  return 1;
}

/* Directory-service lookup is confined to the calling process. The
 * buffer bound limits this wrapper, not libc's own work or its latency. */
COSMIC_SYSCALL(user, 1) {
  luaL_checktype(L, 1, LUA_TSTRING);
  size_t length;
  const char *name = luaL_checklstring(L, 1, &length);
  if (length == 0 || memchr(name, '\0', length) != NULL) {
    return luaL_argerror(L, 1, "user name is empty or contains a NUL byte");
  }
  bool oversized = COSMIC_FAULT("getpwnam_r(oversize)");
  struct cosmic_guard *guard = cosmic_guard_push(L, cosmic_free);
  enum { initial_size = 1024, maximum_size = 1024 * 1024 };
  size_t size = initial_size;
  struct passwd entry, *found = NULL;
  for (;;) {
    void *buffer = cosmic_realloc(guard->resource, size);
    if (buffer == NULL) return cosmic_fail(L, ENOMEM);
    guard->resource = buffer;
    int failure;
    if (oversized || COSMIC_FAULT("getpwnam_r(ERANGE)")) failure = ERANGE;
    else if (COSMIC_FAULT("getpwnam_r(missing)")) failure = 0;
    else if (COSMIC_FAULT("getpwnam_r")) failure = EIO;
    else failure = getpwnam_r(name, &entry, buffer, size, &found);
    if (failure == ERANGE && size < maximum_size) {
      size *= 2;
      continue;
    }
    if (failure != 0) return cosmic_fail(L, failure);
    break;
  }
  if (found == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "");
    lua_pushinteger(L, 0);
    return 3;
  }
  uid_t uid = found->pw_uid;
  gid_t gid = found->pw_gid;
  cosmic_guard_release(guard);
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, (lua_Integer)uid);
  lua_setfield(L, -2, "uid");
  lua_pushinteger(L, (lua_Integer)gid);
  lua_setfield(L, -2, "gid");
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
  int status = cosmic_optint(L, 1, 0);
  cosmic_coverage_report(); /* _exit runs no atexit handler */
  _exit(status); /* exits: the process boundary has no caller to return to */
}

COSMIC_SYSCALL(getpid, 0) {
  lua_pushinteger(L, (lua_Integer)getpid());
  return 1;
}

COSMIC_SYSCALL(getpgid, 1) {
  int pid = cosmic_checkint(L, 1);
  if (pid < 0) return luaL_argerror(L, 1, "pid is out of range");
  pid_t group = getpgid((pid_t)pid);
  if (group < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, (lua_Integer)group);
  return 1;
}

COSMIC_SYSCALL(getuid, 0) {
  lua_pushinteger(L, (lua_Integer)getuid());
  return 1;
}

COSMIC_SYSCALL(getgid, 0) {
  lua_pushinteger(L, (lua_Integer)getgid());
  return 1;
}

COSMIC_SYSCALL(getgroups, 0) {
  int count = getgroups(0, NULL);
  if (count < 0) return cosmic_fail(L, errno);
  /* A block Lua owns, so a refused allocation after it leaks nothing.
   * A size of 0 would ask the count again, not list none. */
  gid_t *groups = lua_newuserdatauv(L, (size_t)count * sizeof *groups, 0);
  int listed = count > 0 ? getgroups(count, groups) : 0;
  if (listed < 0) return cosmic_fail(L, errno);
  lua_createtable(L, listed, 0);
  for (int i = 0; i < listed; i++) {
    lua_pushinteger(L, (lua_Integer)groups[i]);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

COSMIC_SYSCALL(dumpable, 1) {
#if defined(__linux__)
  if (!lua_isnoneornil(L, 1)) {
    int set = cosmic_checkint(L, 1);
    if (set != 0 && set != 1) return luaL_argerror(L, 1, "dumpable is set to 0 or 1");
    if (prctl(PR_SET_DUMPABLE, set, 0, 0, 0) != 0) return cosmic_fail(L, errno);
  }
  int now = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
  if (now < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, (lua_Integer)now);
  return 1;
#else
  if (!lua_isnoneornil(L, 1)) (void)cosmic_checkint(L, 1);
  return cosmic_fail(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(clock_gettime, 1) {
  int which = cosmic_checkint(L, 1);
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

COSMIC_SYSCALL(errno_name, 1) {
  const char *name = NULL;
  (void)cosmic_errno_describe(cosmic_checkint(L, 1), &name);
  if (name == NULL) {
    lua_pushnil(L);
  } else {
    lua_pushstring(L, name);
  }
  return 1;
}

COSMIC_SYSCALL(errno_message, 1) {
  lua_pushstring(L, cosmic_errno_describe(cosmic_checkint(L, 1), NULL));
  return 1;
}

COSMIC_SYSCALL(isatty, 1) {
  int fd = cosmic_checkfd(L, 1);
  lua_pushboolean(L, isatty(fd) == 1);
  return 1;
}

COSMIC_SYSCALL(entropy, 1) {
  lua_Integer count = luaL_checkinteger(L, 1);
  luaL_argcheck(L, count >= 0 && count <= COSMIC_ENTROPY_MAX, 1,
                "the count is negative or past 1 MiB");
  luaL_Buffer buffer;
  char *out = luaL_buffinitsize(L, &buffer, (size_t)count);
  int number = cosmic_entropy(out, (size_t)count);
  if (number != 0) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    return cosmic_fail(L, number);
  }
  luaL_pushresultsize(&buffer, (size_t)count);
  return 1;
}

COSMIC_SYSCALL(umask, 1) {
  int mask = cosmic_checkint(L, 1);
  luaL_argcheck(L, mask >= 0 && mask <= 0777, 1, "the mask is not permission bits");
  lua_pushinteger(L, (lua_Integer)umask((mode_t)mask));
  return 1;
}

/* A limit as Lua holds it: none (RLIM_INFINITY, all ones on Linux, which
 * no integer holds) as math.maxinteger, the largest integer Lua holds and
 * RLIM_INFINITY itself on macOS. A finite limit at or past it, which only
 * Linux can hold, reads as none too, since no integer tells it apart. */
static lua_Integer limit_value (rlim_t limit) {
  if (limit == RLIM_INFINITY || limit >= (rlim_t)LUA_MAXINTEGER) return LUA_MAXINTEGER;
  return (lua_Integer)limit;
}

/* The limit argument `index` gives, math.maxinteger for none. */
static rlim_t check_limit (lua_State *L, int index) {
  lua_Integer value = luaL_checkinteger(L, index);
  luaL_argcheck(L, value >= 0, index, "a limit is not negative");
  return value == LUA_MAXINTEGER ? RLIM_INFINITY : (rlim_t)value;
}

/* The most limits one `spawn` takes: one for each resource its
 * `rlimits` names, in RLIMIT_NAMES. */
#define SPAWN_RLIMIT_MAX 5

/* The resources `spawn`'s `rlimits` names, by the key it takes. */
static const struct {
  const char *name;
  int resource;
} RLIMIT_NAMES[SPAWN_RLIMIT_MAX] = {
  { "nofile", RLIMIT_NOFILE }, { "fsize", RLIMIT_FSIZE }, { "cpu", RLIMIT_CPU },
  { "core", RLIMIT_CORE }, { "nproc", RLIMIT_NPROC },
};

COSMIC_SYSCALL(getrlimit, 1) {
  int resource = cosmic_checkint(L, 1);
  struct rlimit limits;
  if (getrlimit(resource, &limits) != 0) return cosmic_fail(L, errno);
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, limit_value(limits.rlim_cur));
  lua_setfield(L, -2, "soft");
  lua_pushinteger(L, limit_value(limits.rlim_max));
  lua_setfield(L, -2, "hard");
  return 1;
}

/* The most a start raises RLIMIT_NOFILE's soft limit to: macOS's
 * OPEN_MAX, past which an older macOS refuses a soft limit. It holds on
 * every system, where the hard limit can be a million or none, because
 * a child on a Linux that closes no range (before 5.9, or where a filter
 * refuses close_range) closes each descriptor up to the soft limit one
 * by one ([`close_child_descriptors`]): a millisecond or two at this
 * bound, against most of a second at a million. */
#define DESCRIPTOR_LIMIT_RAISED 10240

/* RLIMIT_NOFILE's soft limit as this process started with it, while
 * `descriptor_limit_raised` says the start raised it and nothing has set
 * it since: what a program it execs is given back
 * ([`restore_descriptor_limit`]). A Linux child reads them on the
 * parent's memory before exec. */
static rlim_t started_descriptor_limit;
static bool descriptor_limit_raised;

void cosmic_raise_descriptor_limit (void) {
  struct rlimit limits;
  if (getrlimit(RLIMIT_NOFILE, &limits) != 0) return;
  rlim_t target = DESCRIPTOR_LIMIT_RAISED;
  if (limits.rlim_max < target) target = limits.rlim_max;
#if defined(__APPLE__)
  /* macOS refuses a soft limit past kern.maxfilesperproc, or holds the
   * process to it, and that can be set below OPEN_MAX. */
  int most = 0;
  size_t size = sizeof most;
  if (sysctlbyname("kern.maxfilesperproc", &most, &size, NULL, 0) == 0 && most > 0 &&
      (rlim_t)most < target)
    target = (rlim_t)most;
#endif
  if (limits.rlim_cur >= target) return;
  struct rlimit raised = { .rlim_cur = target, .rlim_max = limits.rlim_max };
  if (setrlimit(RLIMIT_NOFILE, &raised) != 0) return;
  started_descriptor_limit = limits.rlim_cur;
  descriptor_limit_raised = true;
}

/* Gives a program about to be exec'd the soft RLIMIT_NOFILE this
 * process started with, where the start raised it, so a host program --
 * a shell's `ulimit -n` -- sees what the user set; a relaunch of this
 * program raises it again. The hard limit stays as it is now, and bounds
 * the soft one where something lowered it since; `least` bounds it
 * from below, where a descriptor numbered under it is yet to be placed
 * ([`spawn_program`]). True where it lowered the limit. A refusal leaves
 * the raised one, which harms no program. */
static bool restore_descriptor_limit (rlim_t least) {
  struct rlimit limits;
  if (!descriptor_limit_raised || getrlimit(RLIMIT_NOFILE, &limits) != 0) return false;
  rlim_t soft = started_descriptor_limit < least ? least : started_descriptor_limit;
  limits.rlim_cur = soft < limits.rlim_max ? soft : limits.rlim_max;
  return setrlimit(RLIMIT_NOFILE, &limits) == 0;
}

COSMIC_SYSCALL(setrlimit, 3) {
  int resource = cosmic_checkint(L, 1);
  struct rlimit limits = { .rlim_cur = check_limit(L, 2), .rlim_max = check_limit(L, 3) };
  if (setrlimit(resource, &limits) != 0) return cosmic_fail_effect(L, errno);
  /* A limit the program set is the one its children get. */
  if (resource == RLIMIT_NOFILE) descriptor_limit_raised = false;
  return cosmic_ok(L);
}

static const char *plain_string (lua_State *L, int index, const char *what) {
  if (lua_type(L, index) != LUA_TSTRING)
    luaL_error(L, "%s must be a string", what);
  size_t length;
  const char *value = lua_tolstring(L, index, &length);
  if (memchr(value, '\0', length) != NULL)
    luaL_error(L, "%s contains a NUL byte", what);
  return value;
}

/* The length of the argv table at `index`, raising unless every entry
 * is a plain string and an array of that many pointers, and its NULL,
 * fits: what `execve` and `spawn` check before allocating anything. */
static size_t checked_argv (lua_State *L, int index) {
  size_t count = lua_rawlen(L, index);
  if (count > (size_t)LUA_MAXINTEGER ||
      count > SIZE_MAX / sizeof(char *) - 1)
    luaL_argerror(L, index, "argv is too large");
  for (size_t i = 1; i <= count; i++) {
    lua_rawgeti(L, index, (lua_Integer)i);
    plain_string(L, -1, "argv entry");
    lua_pop(L, 1);
  }
  return count;
}

/* Raises unless the pair `lua_next` left on top of the stack, from the
 * environment table at `index`, is a plain string name, nonempty and
 * without '=', and a plain string value. */
static void checked_variable (lua_State *L, int index) {
  const char *name = plain_string(L, -2, "environment name");
  plain_string(L, -1, "environment value");
  if (*name == '\0' || strchr(name, '=') != NULL)
    luaL_argerror(L, index, "environment name is empty or contains '='");
}

/* Whether cosmic itself set SIGPIPE to be ignored, so that a program it
 * starts or becomes gets the default disposition back instead of
 * inheriting ours. */
static int sigpipe_ignored_here;

/* The argv and environment arrays are built from the Lua tables, which
 * stay on the stack and so keep every string alive until execve, which
 * frees nothing on success because nothing of this process remains.
 * Every argv entry must already be a string -- a number converted in
 * place would be a string nothing holds -- and everything that can
 * raise is checked before the arrays are allocated; each array is held
 * by a guard all the same, which frees it on every return. */
COSMIC_SYSCALL(execve, 3) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  luaL_checktype(L, 3, LUA_TTABLE);

  size_t count = checked_argv(L, 2);

  /* Each "NAME=value" entry is built by concatenation and kept in a
   * table on the stack, which is what keeps its bytes alive; the key
   * itself is left exactly as lua_next needs it. */
  lua_newtable(L);
  int entries = lua_gettop(L);
  lua_Integer variables = 0;
  lua_pushnil(L);
  while (lua_next(L, 3) != 0) {
    checked_variable(L, 3);
    lua_pushvalue(L, -2);
    lua_pushliteral(L, "=");
    lua_pushvalue(L, -3);
    lua_concat(L, 3);
    lua_rawseti(L, entries, ++variables);
    lua_pop(L, 1);
  }

  struct cosmic_guard *argv_guard = cosmic_guard_push(L, free);
  struct cosmic_guard *envp_guard = cosmic_guard_push(L, free);
  char **argv = calloc(count + 1, sizeof *argv);
  argv_guard->resource = argv;
  char **envp = calloc((size_t)variables + 1, sizeof *envp);
  envp_guard->resource = envp;
  if (argv == NULL || envp == NULL) {
    return cosmic_fail_effect(L, ENOMEM);
  }
  for (size_t i = 1; i <= count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    argv[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  for (lua_Integer i = 1; i <= variables; i++) {
    lua_rawgeti(L, entries, i);
    envp[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  /* The program this process becomes starts with SIGPIPE at its
   * default, as a spawned child does; ignored again if the exec fails. */
  char **given = cosmic_coverage_environment(envp);
  /* Lowered before the report, which credits what lowers it; a report
   * whose file finds no room under the lowered limit is left unwritten. */
  struct rlimit raised;
  bool lowered = getrlimit(RLIMIT_NOFILE, &raised) == 0 && restore_descriptor_limit(0);
  cosmic_coverage_report(); /* nothing of this image remains to report later */
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_DFL);
  execve(path, argv, given);
  int number = errno;
  if (lowered) setrlimit(RLIMIT_NOFILE, &raised);
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_IGN);
  if (given != envp) free(given);
  return cosmic_fail_effect(L, number);
}

static void free_environment (char **envp, lua_Integer count) {
  if (envp == NULL) return;
  for (lua_Integer i = 0; i < count; i++) free(envp[i]);
  free(envp);
}

/* The highest descriptor number a child may be handed besides stdio. */
#define CHILD_FD_MAX 255

#if defined(__linux__)
static int report_child_error (int fd, int number) {
  const char *at = (const char *)&number;
  size_t left = sizeof number;
  while (left > 0) {
    ssize_t put = write(fd, at, left);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) return -1;
    at += put;
    left -= (size_t)put;
  }
  return 0;
}

/* Close every descriptor from `from` up to `limit`. Cosmic-opened
 * descriptors are CLOEXEC already; this also closes foreign descriptors
 * that are not. Where the kernel closes no range, the loop walks up to
 * the soft limit, which the start's raise bounds
 * ([`DESCRIPTOR_LIMIT_RAISED`]). */
static void close_child_descriptors (int from, long limit) {
#if defined(SYS_close_range)
  if (syscall(SYS_close_range, (unsigned)from, ~0u, 0u) == 0) return;
#endif
  for (int fd = from; fd < limit; fd++) close(fd);
}
#endif

#if defined(__linux__)
/* Fixed by the kernel's ABI; a libc or a header older than them may not
 * name them. */
#ifndef O_PATH
#define O_PATH 010000000
#endif
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif

/* What a rule beneath a file, not a directory, may allow. */
#define LANDLOCK_FILE_ACCESS                                                \
  (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |             \
   LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_TRUNCATE |             \
   LANDLOCK_ACCESS_FS_IOCTL_DEV)
#define LANDLOCK_READ_ACCESS                                                \
  (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE |              \
   LANDLOCK_ACCESS_FS_READ_DIR)
#endif

/* A ruleset alone does not hold a child's metadata reads -- Landlock
 * checks opening a file or listing a directory, never stat, access,
 * readlink, statfs or chdir, so a confined child still learns whether a
 * path outside the ruleset is there, and its size and times -- nor its
 * reach beyond: a unix socket named by a path, TCP and UDP. A sandbox's
 * `unveil` closes the first and the socket paths, and `offline` the rest.
 * TCP is left unhandled though Landlock can hold it from ABI 4: held
 * there and not below, a child's connection over loopback would pass
 * on one kernel and fail on another, and `offline` holds it on every
 * one.
 * TODO: a strict form, for a sandbox that must hold whole, refusing
 * with EOPNOTSUPP where the kernel's ABI or this build's headers leave
 * out a right the ruleset otherwise handles -- truncate below ABI 3,
 * device ioctls below 5, abstract unix sockets and signals
 * below 6 or without LANDLOCK_SCOPE_SIGNAL -- once a caller holds a
 * child to a ruleset under build.confine's `must_confine`: today it
 * handles what the kernel knows and says nothing of the rest, so a
 * child on an older kernel may truncate a file it was given only to
 * read. */
COSMIC_SYSCALL(landlock_ruleset, 2) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  for (int t = 1; t <= 2; t++) {
    lua_Integer count = (lua_Integer)lua_rawlen(L, t);
    for (lua_Integer i = 1; i <= count; i++) {
      lua_rawgeti(L, t, i);
      plain_string(L, -1, "path");
      lua_pop(L, 1);
    }
  }
#if defined(__linux__)
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return cosmic_fail(L, abi < 0 ? errno : ENOSYS);
  uint64_t handled = (LANDLOCK_ACCESS_FS_MAKE_SYM << 1) - 1;
  if (abi >= 2) handled |= LANDLOCK_ACCESS_FS_REFER;
  if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (abi >= 5) handled |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
  struct landlock_ruleset_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.handled_access_fs = handled;
  /* A kernel older than a field takes the struct only up to it. */
  size_t size = sizeof attr.handled_access_fs;
#ifdef LANDLOCK_SCOPE_SIGNAL
  if (abi >= 6) {
    /* Nor may it reach a process outside it through an abstract unix
     * socket or a signal. */
    attr.scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET | LANDLOCK_SCOPE_SIGNAL;
    size = offsetof(struct landlock_ruleset_attr, scoped) + sizeof attr.scoped;
  }
#endif
  long made = syscall(SYS_landlock_create_ruleset, &attr, size, 0);
  if (made < 0) return cosmic_fail(L, errno);
  int ruleset = (int)made;
  /* One rule for each path, allowing what its table grants beneath it --
   * as much of that as a file takes, when it is one. Nothing here can
   * raise: every entry was checked to be a plain string above. */
  for (int t = 1; t <= 2; t++) {
    uint64_t access = t == 1 ? LANDLOCK_READ_ACCESS & handled : handled;
    lua_Integer count = (lua_Integer)lua_rawlen(L, t);
    for (lua_Integer i = 1; i <= count; i++) {
      lua_rawgeti(L, t, i);
      const char *path = lua_tostring(L, -1);
      int fd = open(path, O_PATH | O_CLOEXEC);
      lua_pop(L, 1);
      struct stat st;
      int number = 0;
      if (fd < 0 || fstat(fd, &st) != 0) {
        number = errno;
      } else {
        struct landlock_path_beneath_attr beneath = {
          .allowed_access = S_ISDIR(st.st_mode) ? access : access & LANDLOCK_FILE_ACCESS,
          .parent_fd = fd,
        };
        if (syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH,
                    &beneath, 0) != 0) {
          number = errno;
        }
      }
      if (fd >= 0) close(fd);
      if (number != 0) {
        close(ruleset);
        return cosmic_fail(L, number);
      }
    }
  }
  lua_pushinteger(L, ruleset);
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(landlock_abi, 0) {
#if defined(__linux__)
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return cosmic_fail(L, abi < 0 ? errno : ENOSYS);
  lua_pushinteger(L, (lua_Integer)abi);
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}

/* Whether this process can no longer run its own core -- held by
 * `landlock_restrict_execute` to files none of which is beneath it --
 * and so hands its artifact's descriptor on to no child ([`handed_on`]):
 * none could be a relaunch of it. A worker of `cosmic test` whose
 * module does not declare `tool` is held so (build/confine.tl's
 * `forbid_running`) before its test loads.
 *
 * Such a process is made undumpable too ([`keep_artifact`]), so what it
 * starts cannot take the descriptor as /proc/<its pid>/fd/<it> -- a
 * host program's `cat /proc/$PPID/fd/254`, which `open`'s refusal, in
 * this core's Lua alone, never sees. Following a link of another
 * process's /proc/<pid> (fd, map_files, cwd, root, exe) asks
 * PTRACE_MODE_READ of it, which an undumpable process grants only to
 * one holding CAP_SYS_PTRACE in the user namespace its memory was made
 * in. None the worker starts holds it: in a sandbox every capability is
 * given up for good before the worker runs ([`drop_capabilities`]), root
 * as any user, and what it starts has none to gain; unsandboxed it has
 * the program by name anyway. The process itself is its own tracer
 * still, so its /proc/self stays its own to read. What moves is the
 * owner of its /proc/<pid>, which the kernel gives root of that user
 * namespace, or the host's where that has none: a child of it on its
 * memory before exec ([`spawn_child`]), a process it confines or takes
 * offline, is refused writing its /proc/self/uid_map there, where the
 * process is not root (EACCES). A process held so is refused every
 * mount already (Landlock), so what this takes from it is a network
 * namespace of its own without a root of its own, which no test of the
 * tree that does not declare `tool` asks for. A file of its own
 * /proc/self that only its owner may read (environ, auxv) it may no
 * longer read either, where it is not root; no test of the tree does.
 * Nor, undumpable, does it write a core dump when it crashes. */
static bool artifact_kept;

#if defined(__linux__)
/* Marks this process as held from running its core (`artifact_kept`)
 * and undumpable, so nothing it starts reaches its artifact descriptor
 * through /proc. 0, or an errno. */
static int keep_artifact (void) {
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) return errno;
  artifact_kept = true;
  return 0;
}
#endif

#if defined(__linux__)
/* Whether `path` is one of the `count` paths of the list at `index`, or
 * beneath one. */
static bool listed_beneath (lua_State *L, int index, lua_Integer count, const char *path) {
  size_t length = strlen(path);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_rawgeti(L, index, i);
    size_t size = 0;
    const char *listed = lua_tolstring(L, -1, &size);
    bool within = listed != NULL && size <= length &&
                  strncmp(path, listed, size) == 0 &&
                  (path[size] == '\0' || path[size] == '/' ||
                   (size > 0 && listed[size - 1] == '/'));
    lua_pop(L, 1);
    if (within) return true;
  }
  return false;
}
#endif

/* A ruleset that handles running a file, one rule per path, and this
 * process held to it. It handles moving a file to another directory
 * too, granted beneath / in a rule of its own: a ruleset that leaves
 * that unhandled refuses every such rename or link (EXDEV), as the first
 * ABI did, so a kernel without the second is refused; and granted only
 * beneath the paths, a directory made after the hold outside them --
 * one in /tmp, where a program run from beneath /tmp has the walk
 * grant /tmp's entries one by one (build/confine.tl's
 * `forbid_running`) -- would refuse a rename inside it. The kernel
 * still refuses a move that would let a file be run where it could not
 * before. Every entry is
 * checked to be a plain string before the ruleset is made, so nothing
 * after it can raise. */
COSMIC_SYSCALL(landlock_restrict_execute, 1) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer count = (lua_Integer)lua_rawlen(L, 1);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_rawgeti(L, 1, i);
    plain_string(L, -1, "path");
    lua_pop(L, 1);
  }
#if defined(__linux__)
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return cosmic_fail_effect(L, abi < 0 ? errno : ENOSYS);
  if (abi < 2) return cosmic_fail_effect(L, EOPNOTSUPP);
  uint64_t handled = LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_REFER;
  struct landlock_ruleset_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.handled_access_fs = handled;
  long made = syscall(SYS_landlock_create_ruleset, &attr, sizeof attr.handled_access_fs, 0);
  if (made < 0) return cosmic_fail_effect(L, errno);
  int ruleset = (int)made;
  int number = 0;
  for (lua_Integer i = 1; number == 0 && i <= count; i++) {
    lua_rawgeti(L, 1, i);
    const char *path = lua_tostring(L, -1);
    int fd = open(path, O_PATH | O_CLOEXEC);
    lua_pop(L, 1);
    if (fd < 0) {
      number = errno;
    } else {
      struct stat st;
      struct landlock_path_beneath_attr beneath = {
        .allowed_access = handled,
        .parent_fd = fd,
      };
      /* A file takes no rule for what is beneath it. */
      if (fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode)) {
        beneath.allowed_access = LANDLOCK_ACCESS_FS_EXECUTE;
      }
      if (syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0) {
        number = errno;
      }
      close(fd);
    }
  }
  if (number == 0) {
    int fd = open("/", O_PATH | O_CLOEXEC);
    struct landlock_path_beneath_attr beneath = {
      .allowed_access = LANDLOCK_ACCESS_FS_REFER,
      .parent_fd = fd,
    };
    if (fd < 0 ||
        syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0)
      number = errno;
    if (fd >= 0) close(fd);
  }
  /* Whether the process will be held from running its own core, asked
   * before it is held: the answer names no path the ruleset changes. */
  char self[PATH_MAX];
  bool keeps = !cosmic_executable_path(self, sizeof self) || !listed_beneath(L, 1, count, self);
  if (number == 0 && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) number = errno;
  if (number == 0 && syscall(SYS_landlock_restrict_self, ruleset, 0) != 0) number = errno;
  close(ruleset);
  if (number == 0 && keeps) number = keep_artifact();
  if (number != 0) return cosmic_fail_effect(L, number);
  return cosmic_ok(L);
#else
  (void)count;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

#if defined(__linux__)
#if defined(__x86_64__)
#define PLEDGE_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define PLEDGE_ARCH AUDIT_ARCH_AARCH64
#endif
#endif

/* The most instructions a pledge's filter takes. */
#define PLEDGE_MAX 96

#if defined(PLEDGE_ARCH)
/* The calls a pledged child never makes, whatever it promised: each
 * reaches past the process -- into another's memory or descriptors, the
 * mount table, the kernel -- or, like io_uring, makes calls this filter
 * cannot see.
 * TODO: a filter cannot see a path, so /proc/<pid>/mem of a process of
 * the same user is still open to a child pledged but not held to a
 * ruleset; Landlock's own ptrace check closes it, so a sandbox that
 * means to keep a child from other processes takes both. */
static const int pledge_refused[] = {
  __NR_ptrace, __NR_process_vm_readv, __NR_process_vm_writev,
  __NR_mount, __NR_umount2, __NR_pivot_root,
#ifdef __NR_move_mount
  __NR_move_mount, __NR_open_tree, __NR_fsopen, __NR_fsmount, __NR_fsconfig, __NR_fspick,
#endif
  __NR_bpf, __NR_perf_event_open, __NR_kexec_load,
#ifdef __NR_kexec_file_load
  __NR_kexec_file_load,
#endif
  __NR_init_module, __NR_finit_module, __NR_delete_module,
  __NR_add_key, __NR_request_key, __NR_keyctl,
#ifdef __NR_io_uring_setup
  __NR_io_uring_setup, __NR_io_uring_enter, __NR_io_uring_register,
#endif
  __NR_userfaultfd, __NR_setns, __NR_name_to_handle_at, __NR_open_by_handle_at,
#ifdef __NR_pidfd_getfd
  __NR_pidfd_getfd,
#endif
#ifdef __NR_process_madvise
  __NR_process_madvise,
#endif
};

/* Every instruction [`pledge_program`] writes: the architecture check and
 * the call's number (4), the x32 check (2), two for each refused call,
 * and the socket block at its largest (1 + 1 + 2 * 3 + 1 + 1). */
_Static_assert(4 + 2 + 2 * (sizeof pledge_refused / sizeof pledge_refused[0]) + 10 <= PLEDGE_MAX,
               "PLEDGE_MAX is too small for the pledge filter");

/* The filter a pledge holds a child to: a call of another architecture is
 * the end of it, a call `pledge_refused` names fails with EPERM, and a
 * socket may be of the families promised (`unix`, `inet`) and no other.
 * Answers how many instructions it wrote to `out`. */
static int pledge_program (struct sock_filter *out, int unix_ok, int inet_ok) {
  int n = 0;
  const unsigned refuse = SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                           offsetof(struct seccomp_data, arch));
  out[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PLEDGE_ARCH, 1, 0);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                           offsetof(struct seccomp_data, nr));
#if defined(__x86_64__)
  out[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, refuse);
#endif
  for (size_t i = 0; i < sizeof pledge_refused / sizeof pledge_refused[0]; i++) {
    out[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                             (unsigned)pledge_refused[i], 0, 1);
    out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, refuse);
  }
  int families[3];
  int allowed = 0;
  if (unix_ok) families[allowed++] = AF_UNIX;
  if (inet_ok) {
    families[allowed++] = AF_INET;
    families[allowed++] = AF_INET6;
  }
  /* A socket's family is its first argument: past the check, loaded,
   * compared with each promised one, and refused when none matches. */
  unsigned char block = (unsigned char)(1 + 2 * allowed + 1);
  out[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, block);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                           offsetof(struct seccomp_data, args[0]));
  for (int i = 0; i < allowed; i++) {
    out[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)families[i],
                                             0, 1);
    out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  }
  out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, refuse);
  out[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  return n;
}
#endif

/* Whether `name` is absolute with no empty, `.` or `..` component, so it
 * names the same place under another root as under this one. */
static int plain_name (const char *name) {
  if (name[0] != '/') return 0;
  for (const char *at = name; *at != '\0'; at++) {
    if (*at != '/') continue;
    const char *next = at + 1;
    if (*next == '/') return 0;
    if (next[0] == '.' && (next[1] == '/' || next[1] == '\0')) return 0;
    if (next[0] == '.' && next[1] == '.' && (next[2] == '/' || next[2] == '\0')) return 0;
  }
  return 1;
}

#if defined(__linux__)
/* Writes `text` whole to the file at `path`, relative to the directory
 * `dir` holds (AT_FDCWD for this process's own): 0, or an errno. */
static int write_whole_at (int dir, const char *path, const char *text) {
  int fd = openat(dir, path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  size_t left = strlen(text);
  int number = 0;
  while (left > 0) {
    ssize_t put = write(fd, text, left);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) { number = put < 0 ? errno : EIO; break; }
    text += put;
    left -= (size_t)put;
  }
  close(fd);
  return number;
}

/* Writes `text` to the file at `path` whole: 0, or an errno. */
static int write_whole (const char *path, const char *text) {
  return write_whole_at(AT_FDCWD, path, text);
}

/* The mode a directory made at `path` in the root being built takes:
 * that of the one it stands for, `skip` bytes in, the host's own path
 * -- a program may check its directories' modes, as a cache refusing
 * one others can write to does -- or 0755 where the host has none. */
static mode_t mirrored_mode (const char *path, size_t skip) {
  struct stat st;
  if (stat(path + skip, &st) == 0 && S_ISDIR(st.st_mode)) return st.st_mode & 07777;
  return 0755;
}

/* Makes the directory `name` in the one `dir` holds (AT_FDCWD for this
 * process's own) with `mode`, whatever the umask, which is cleared while
 * it does and put back, so no chmod is asked of a child whose filter
 * grants none (a `nest` program, whose start of its own builds a root as
 * this does): a mode with a setuid, setgid or sticky bit is made without
 * them where the filter refuses one, as it does a mode made with them,
 * and the bits the kernel does not make a directory with are set after,
 * where that is allowed. 0, or an errno. */
static int make_directory (int dir, const char *name, mode_t mode) {
  mode_t before = umask(0);
  int number = 0;
  if (mkdirat(dir, name, mode) != 0 && errno != EEXIST) {
    number = errno;
    if (number == EPERM && (mode & 07000) != 0) {
      number = 0;
      mode &= 0777;
      if (mkdirat(dir, name, mode) != 0 && errno != EEXIST) number = errno;
    }
  }
  umask(before);
  if (number == 0 && (mode & 06000) != 0 && fchmodat(dir, name, mode, 0) != 0 && errno != EPERM)
    number = errno;
  return number;
}

/* Makes the directory `path` in the root being built with the mode of
 * the one it stands for, and one its owner -- the child, once it has
 * given up its capabilities -- can pass through even where the host's let
 * only its group: 0, or an errno. */
static int make_mirrored (const char *path, size_t skip) {
  return make_directory(AT_FDCWD, path, mirrored_mode(path, skip) | 0700);
}

/* The directory `name` in the one `dir` holds, opened without following
 * a link: a link there is refused with ELOOP, whatever it leads to. The
 * descriptor, or -1 with errno. */
static int open_unlinked_directory (int dir, const char *name) {
  struct stat st;
  if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)) {
    errno = ELOOP;
    return -1;
  }
  return openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

/* Makes the place a path is bound at: `target`, a path in the root being
 * built, of which the first `skip` bytes name the root. Each directory
 * on the way is made where it is missing, with the mode of the one it
 * stands for ([`mirrored_mode`]), and its last name a directory, with
 * `directory`, or else an empty file, where it is not there -- going
 * through no link. A link on the way or at its end
 * is refused with ELOOP: a name placed beneath a path bound from the
 * host (`at`) could otherwise lead out through a link there, and make
 * a file where the host has the link's target. `target` is written
 * into and put back. 0, or an errno.
 * TODO: bind through the descriptor of the place made (a mount of
 * /proc/self/fd/<n>) rather than its name again, so a link a host
 * process puts on the way between this walk and the mount is not
 * followed either. */
static int make_target (char *target, size_t skip, int directory) {
  char held = target[skip];
  target[skip] = '\0';
  int dir = open(target, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  target[skip] = held;
  if (dir < 0) return errno;
  int number = 0;
  char *name = target + skip + 1;
  while (number == 0) {
    char *end = strchr(name, '/');
    if (end == NULL) break;
    *end = '\0';
    int next = -1;
    if (*name != '\0') {
      next = open_unlinked_directory(dir, name);
      if (next < 0 && errno == ENOENT) {
        number = make_directory(dir, name, mirrored_mode(target, skip) | 0700);
        if (number == 0) next = open_unlinked_directory(dir, name);
      }
      if (number == 0 && next < 0) number = errno;
    }
    *end = '/';
    if (next >= 0) {
      close(dir);
      dir = next;
    }
    name = end + 1;
  }
  if (number == 0 && *name != '\0') {
    struct stat st;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
      if (S_ISLNK(st.st_mode)) number = ELOOP;
    } else if (errno != ENOENT) {
      number = errno;
    } else if (directory) {
      if (mkdirat(dir, name, 0755) != 0 && errno != EEXIST) number = errno;
    } else {
      int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
      if (fd < 0) number = errno;
      else close(fd);
    }
  }
  close(dir);
  return number;
}

/* Makes a link at `path`, under the root being built, to `to`, making its
 * parents as [`make_target`] does, going through no link and making
 * nothing where something already is: 0, or an errno. */
static int make_link (char *path, size_t skip, const char *to) {
  struct stat st;
  for (char *at = path + skip + 1; *at != '\0'; at++) {
    if (*at != '/') continue;
    *at = '\0';
    int number = 0;
    if (lstat(path, &st) != 0) {
      number = errno != ENOENT ? errno : make_mirrored(path, skip);
    } else if (!S_ISDIR(st.st_mode)) {
      number = EEXIST;
    }
    *at = '/';
    if (number == EEXIST) return 0;
    if (number != 0) return number;
  }
  if (symlink(to, path) != 0 && errno != EEXIST) return errno;
  return 0;
}

/* mount_setattr(2), which a libc may not name: making a mount and every
 * mount beneath it read-only at once, as a remount cannot. */
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#define COSMIC_MOUNT_ATTR_RDONLY 0x1
#define COSMIC_MOUNT_ATTR_NOSUID 0x2
#define COSMIC_MOUNT_ATTR_NOEXEC 0x8
struct cosmic_mount_attr {
  uint64_t attr_set, attr_clr, propagation, userns_fd;
};

/* An idmapped mount ([`idmapped_tree`], [`build_root`]): open_tree(2)
 * and move_mount(2), which a libc may not name either. */
#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif
#define COSMIC_MOUNT_ATTR_IDMAP 0x00100000
#define COSMIC_OPEN_TREE_CLONE 1
#define COSMIC_MOVE_MOUNT_F_EMPTY_PATH 4

/* Where in building a policy's sandbox (`spawn`'s `strict`) a child
 * failed, which its errno alone does not say: the status pipe carries
 * the stage above the errno's bits, and `spawn` reads both back to
 * name the remedy. A child that is not strict reports its errno only. */
enum {
  STAGE_NAMESPACE = 1, /* a user, pid, mount or network namespace, or mapping its ids */
  STAGE_PROC,          /* a procfs of its own */
  STAGE_ROOT,          /* the root's mounts */
  STAGE_IDMAP,         /* an idmapped mount of a path, which the plan's `idmap_failed` names */
  STAGE_KIND,          /* a path bound that is a directory or socket the start did not see */
  STAGE_SHIFT = 16,
};

/* `number`, an errno, as the failure of `stage` where `strict` asks for
 * stages. A failure already staged stays as it is. */
static int staged (int strict, int stage, int number) {
  if (!strict || number == 0 || number >> STAGE_SHIFT != 0) return number;
  return (stage << STAGE_SHIFT) | number;
}

/* What to tell the caller of a start that failed at `stage` with `number`
 * (an errno): the remedy, which the errno alone does not name. Isolation
 * needs unprivileged user namespaces, and a procfs of its own needs a
 * container that does not mask /proc. */
static void staged_message (int stage, int number, const char *path, char *message,
                            size_t room) {
  const char *what = cosmic_errno_describe(number, NULL);
  if (stage == STAGE_IDMAP) {
    snprintf(message, room,
             "an idmapped mount of %s was refused (%s): the sandbox's user must write or read "
             "what its owner alone may, which needs a Linux kernel from 5.12, a file system that "
             "supports idmapped mounts (ext4, xfs, btrfs and tmpfs do; an overlay or network file "
             "system may not) and CAP_SYS_ADMIN here: make the path's mode readable and "
             "writable by every user instead", path != NULL ? path : "a grant", what);
  } else if (stage == STAGE_KIND) {
    snprintf(message, room,
             "a path this sandbox binds changed kind between the start's check and the bind (it "
             "became a directory, or a socket no `u` grant names), which would let the program "
             "reach what a host process put there: it is refused, not an error of the file "
             "system (%s)", what);
  } else if (stage == STAGE_PROC) {
    snprintf(message, room,
             "this sandbox's own /proc was refused (%s): a container's runtime masks parts of "
             "/proc, and a user namespace may mount a procfs only where all of it is visible: "
             "run the container with --security-opt systempaths=unconfined (Docker, Podman), "
             "or on a host with no masked /proc; a sandbox never falls back to the host's /proc",
             what);
  } else if (stage == STAGE_NAMESPACE) {
    snprintf(message, room,
             "this sandbox's user, mount, pid or network namespace was refused (%s): isolation "
             "needs unprivileged user namespaces, which %s", what,
             number == ENOSPC
                 ? "this host allows none of: user.max_user_namespaces is 0, raise it"
                 : "this host may refuse: set kernel.unprivileged_userns_clone=1 (Debian), "
                   "kernel.apparmor_restrict_unprivileged_userns=0 or allow `userns` in this "
                   "program's AppArmor profile (Ubuntu 24.04), let a container's seccomp "
                   "profile allow unshare and clone with CLONE_NEWUSER, and start it from a "
                   "process no Landlock ruleset holds");
  } else if (number != EPERM && number != EACCES) {
    snprintf(message, room,
             "this sandbox's root could not be built (%s): a path it binds, or a step of making "
             "its mount points, failed (a link beneath a bound path, a name too long, a path "
             "that went away since the start began)", what);
  } else {
    snprintf(message, room,
             "this sandbox's root could not be built (%s): it needs mounts in a user namespace "
             "of its own, which a container's seccomp or AppArmor profile may refuse, as may "
             "a Landlock ruleset the starting process is held by, and a mapped user, which a "
             "root inside another sandbox lacks", what);
  }
}

/* Brings up the loopback of the network namespace the child has just made
 * its own, which the kernel makes down: a connection to 127.0.0.1 is then
 * refused, or reaches a listener the child's own processes opened, as
 * on a host, rather than finding no network at all. 0, or an errno. */
static int loopback_up (void) {
  /* A unix socket, which any socket's interface ioctls fall through to,
   * so a parent pledged to no "inet" still starts an offline child. Made
   * as a pair, which the promises filter allows where it refuses socket():
   * a program that builds sandboxes (`nest`) starts this one's own. */
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, pair) != 0) return errno;
  int fd = pair[0];
  struct ifreq request;
  memset(&request, 0, sizeof request);
  memcpy(request.ifr_name, "lo", sizeof "lo");
  int number = 0;
  if (ioctl(fd, SIOCGIFFLAGS, &request) != 0) {
    number = errno;
  } else {
    request.ifr_flags |= IFF_UP;
    if (ioctl(fd, SIOCSIFFLAGS, &request) != 0) number = errno;
  }
  close(pair[0]);
  close(pair[1]);
  return number;
}

/* Whether this process is in a user namespace other than the host's:
 * its uid_map maps less than every id to itself. False where it cannot
 * tell, as without /proc. */
static bool inner_user_namespace (void) {
  int fd = open("/proc/self/uid_map", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  char text[128];
  ssize_t got = read(fd, text, sizeof text - 1);
  close(fd);
  if (got <= 0) return false;
  text[got] = '\0';
  unsigned long inside = 0, outside = 0, count = 0;
  if (sscanf(text, "%lu %lu %lu", &inside, &outside, &count) != 3) return false;
  return inside != 0 || outside != 0 || count != 4294967295UL;
}

/* In a child whose user namespace is its own and fresh: maps its user
 * and group to themselves, and refuses it setgroups. `mapped` says
 * whether its user was mapped (see below). 0, or an errno. */
static int map_ids (int unmap_root, const char *uid_map, const char *gid_map, int *mapped) {
  int number = write_whole("/proc/self/setgroups", "deny");
  if (number != 0 && number != ENOENT) return number;
  /* Root inside a user namespace not the host's -- a sandbox's child --
   * may map root only holding CAP_SETFCAP, which it gave up (`unmap_root`
   * says it is such a root): its user stays unmapped, the kernel's
   * overflow id inside, owning what root owns but with no capability to
   * override a file's permissions, as it had none mapped either. Any
   * other refusal is the sandbox's failure. Left unmapped, it confines
   * none of its own in turn: the kernel refuses a user namespace to a
   * user its own does not map. So `spawn`'s `user` runs a root caller's
   * child as a user of its own instead, mapped from outside
   * ([`map_from_outside`]), which confines at any depth, as any mapped
   * child does; `cosmic test` runs root's sandboxed workers so. */
  *mapped = 1;
  if ((number = write_whole("/proc/self/uid_map", uid_map)) != 0) {
    if (number != EPERM || !unmap_root) return number;
    *mapped = 0;
  }
  return write_whole("/proc/self/gid_map", gid_map);
}

/* Gives up every capability a namespace of the child's own gave it, for
 * good: none is left to pass to a program it executes, so a caller's
 * root cannot undo a read-only mount or make one of its own. 0, or an
 * errno. */
static int drop_capabilities (void) {
  for (int cap = 0; cap < 64; cap++) {
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0 && errno != EINVAL) return errno;
  }
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 && errno != EINVAL)
    return errno;
  return 0;
}

/* Puts at `target` in the root being built the /proc given: a procfs
 * of the child's pid namespace, which it must already be in, holding
 * that namespace's processes alone (subset=pid: no /proc/sys, no
 * /proc/sysrq-trigger, nothing of the host's but those processes') --
 * writable, so a process in it can map its ids in a user namespace of
 * its own, and confine one of its own in turn. What it may write there
 * is its own processes', and its session's autogroup, which is the
 * sandbox's own ([`run_program`] starts one, as [`cosmic_sandbox_init`]
 * does). Where the kernel refuses one -- a container's runtime masks
 * parts of its /proc, and a user namespace may mount a procfs only
 * where one is wholly visible (mount_too_revealing, which subset=pid
 * does not escape as of Linux 6.18), EPERM; a kernel before 5.8 knows
 * no subset, EINVAL -- the host's /proc is bound there instead,
 * read-only even where given to write, since what it holds to write is
 * the host's (/proc/sys, other processes' entries) -- unless `strict`,
 * a policy's sandbox, which has no fallback: a refusal is STAGE_PROC's.
 * `own` says whether the procfs is the child's own. 0, or an errno.
 * TODO: keep a child from setting its own audit login id
 * (/proc/self/loginuid), which it may while that is unset (the kernel
 * asks no capability to set an unset one, unless audit's
 * loginuid_immutable is on), so the host's audit log names the uid it
 * chose for what its processes do: a per-process file cannot be bound
 * over in a procfs, so this waits on a way to refuse the write -- a
 * Landlock rule on /proc files, or a seccomp filter able to tell the
 * path -- or on setting it from here to the parent's own, which the
 * kernel only lets a process holding CAP_AUDIT_CONTROL do.
 * TODO: refuse the sandbox where the kernel refuses a procfs of its
 * own (EPERM, which build.confine's `unconfinable` falls back on and
 * `must_confine` fails), rather than bind the host's, as a policy's
 * (`strict`) already does, once
 * no container the tree is tested in masks /proc: CI's Linux legs run
 * with systempaths=unconfined (.github/scripts/leg-container.sh), but a
 * developer's docker may not. Meanwhile a child with the host's /proc
 * cannot confine one of its own (EROFS writing its uid_map there), and
 * sees the host's processes and state, whose pids are not the ones it
 * is in (it is pid 2 of its own namespace). */
static int place_proc (const char *target, int *own, int strict) {
  *own = mount("proc", target, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "subset=pid") == 0;
  if (*own) return 0;
  if (strict) return staged(1, STAGE_PROC, errno);
  if (errno != EPERM && errno != EINVAL) return errno;
  if (mount("/proc", target, NULL, MS_BIND | MS_REC, NULL) != 0) return errno;
  struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
  if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
    return errno;
  return 0;
}

/* In an unveiled child's program's process ([`start_program`]), in its
 * namespaces -- user, pid, mount, System V IPC, and the network with
 * `offline` -- before anything else of it:
 * a root of the child's own, with a /tmp of its own unless /tmp or /
 * is among the paths, holding the `count` paths at their own names --
 * read-only, and every mount beneath them too, but where `writable`
 * says; /proc a procfs of its own pid namespace ([`place_proc`]) -- and
 * nothing else, so a path outside them is not there at all, to stat as
 * to open. The paths are resolved, with no link or `..` left in them;
 * `at` holds, for each bound at a name of the caller's choosing rather
 * than its own, that name, and NULL elsewhere -- where each is placed,
 * its name or its path, a shorter coming before a longer. `names` holds
 * the names they were given by where one differs from its path and it
 * has no `at`, and NULL elsewhere, and each such name is a link in the
 * root to its path, where no path placed holds it already. `root` is an
 * empty directory the parent made to build on; `mapped` says whether
 * the child's user is mapped ([`map_ids`]); `own` says, once it is built,
 * whether its /proc is a procfs of its own ([`place_proc`]). The root is
 * this process's own and its working directory's, and every process's
 * in the namespace whose root was the old one. 0, or an errno.
 * With `strict`, a policy's root: no /tmp but the sized, noexec tmpfs
 * `tmp_bytes` asks for (none for 0, noexec unless `tmp_exec`), a tmpfs of its own to build on
 * ([`staged`]'s STAGE_ROOT where the user is not mapped), a procfs of
 * its own or the failure of the start, and each path `noexec` flags
 * mounted noexec. With `unix_guard`, where a unix socket is allowed below
 * Landlock ABI 9 on the strength of the root alone (COSMIC_HELD_UNIX set
 * for [`root_shows_no_socket`], or a `u` grant), each path bound is checked
 * once placed, on what the mount shows: a directory fails the start, and so
 * does a socket that `unix_ok` (one flag a path) does not name, a `u`
 * grant's. It fails as STAGE_KIND, the path having changed kind since the
 * caller looked, so a path swapped for one in between is not the sandbox's.
 * TODO: remove the directory an unmapped child's root is built on once
 * the child ends: its root and its /tmp are that directory, in its
 * parent's TMPDIR, which `spawn`, returning at the child's exec, leaves
 * behind with what the child wrote to its /tmp. Removing it sooner
 * would take the child's mounts from under it, so this waits on the
 * process table's `waitpid` removing a directory its `spawn` handed the
 * reaped child's pid.
 * A UTS namespace would change nothing a child sees: its host's name
 * and kernel stay what `uname` answers, which no key holds. */
static int build_root (const char *root, char *const *paths, char *const *names,
                       const char *const *at, const int *writable, const int *noexec,
                       const int *idmapped, int count, int mapped, int noexec_scratch, int strict,
                       unsigned long tmp_bytes, int tmp_exec, int unix_guard, const int *unix_ok,
                       int *own) {
  int number = 0;
  *own = 0;
  /* A private writable tmpfs needs a mapped owner. Refuse before an
   * unmapped child's root leaves directories on its host backing. */
  if ((noexec_scratch || strict) && !mapped) return strict ? staged(1, STAGE_ROOT, EPERM) : EPERM;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return errno;
  /* A tmpfs of this namespace takes no file from a user it does not
   * map: an unmapped one builds on `root` itself, which its parent's
   * namespace maps it on. */
  if (mapped ? mount("tmpfs", root, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755") != 0
             : mount(root, root, NULL, MS_BIND, NULL) != 0)
    return errno;
  char target[PATH_MAX];
  /* A /tmp of its own, writable and empty but for the paths given
   * beneath the host's, which a program takes for granted -- unless
   * /tmp or / is given, under its own name or another; mounted first,
   * so a path given beneath the host's /tmp is bound into it. */
  int tmp = strict ? tmp_bytes > 0 : 1;
  for (int i = 0; tmp && i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    if (strcmp(placed, "/tmp") == 0 || strcmp(placed, "/") == 0 ||
        (names[i] != NULL && strcmp(names[i], "/tmp") == 0)) {
      tmp = 0;
    }
  }
  if (tmp) {
    int made = snprintf(target, sizeof target, "%s/tmp", root);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    /* The mode made here never shows: a tmpfs covers it, or the chmod below sets it,
     * and a sticky bit asked of mkdir is one a `nest` program's filter refuses. */
    if (mkdir(target, 0777) != 0) return errno;
    if (strict) {
      /* Writable and so not executable, as a grant `rwc` is, unless the
       * caller asked for one run from (`tmp_exec`, a grant `rwxc`). */
      char options[64];
      snprintf(options, sizeof options, "mode=1777,size=%lu", tmp_bytes);
      if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV | (tmp_exec ? 0 : MS_NOEXEC),
                options) != 0)
        return errno;
    } else if (mapped ? mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") != 0
                      : chmod(target, 01777) != 0 ||
                        mount(target, target, NULL, MS_BIND, NULL) != 0) {
      return errno;
    }
  }
  if (noexec_scratch) {
    int made = snprintf(target, sizeof target, "%s/noexec", root);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    if (mkdir(target, 0777) != 0) return errno;
    /* No host backing path remains reachable through an executable
     * alias, unlike a bind of ordinary scratch. */
    if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=1777") != 0)
      return errno;
  }
  int own_proc = 0;
  for (int i = 0; i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    /* A procfs of its own holds nothing of the host's to bind: a path
     * placed beneath /proc besides it is not there. */
    if (own_proc && strncmp(placed, "/proc/", 6) == 0) continue;
    struct stat st;
    if (stat(paths[i], &st) != 0) return errno;
    int length = snprintf(target, sizeof target, "%s%s", root, placed);
    if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
    if ((number = make_target(target, strlen(root), S_ISDIR(st.st_mode))) != 0) return number;
    if (at[i] == NULL && strcmp(paths[i], "/proc") == 0) {
      number = place_proc(target, &own_proc, strict);
      if (number != 0) return number;
      continue;
    }
    if (idmapped != NULL && idmapped[i] >= 0) {
      if (syscall(SYS_move_mount, idmapped[i], "", AT_FDCWD, target,
                  COSMIC_MOVE_MOUNT_F_EMPTY_PATH) != 0)
        return errno;
    } else if (mount(paths[i], target, NULL, MS_BIND | MS_REC, NULL) != 0) {
      return errno;
    }
    /* A path in the host's /proc is its state, read-only whoever asks:
     * /proc itself too, bound at another name (`at`). */
    if (!writable[i] || strncmp(paths[i], "/proc/", 6) == 0 || strcmp(paths[i], "/proc") == 0) {
      struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
      if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
        return errno;
    }
    if (noexec != NULL && noexec[i]) {
      struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_NOEXEC, 0, 0, 0 };
      if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
        return errno;
    }
    if (unix_guard) {
      /* What the mount shows, not what the path named a moment ago. */
      struct stat shown;
      if (stat(target, &shown) != 0) return errno;
      if (S_ISDIR(shown.st_mode) || (S_ISSOCK(shown.st_mode) && !unix_ok[i]))
        return staged(1, STAGE_KIND, ESTALE);
    }
  }
  for (int i = 0; i < count; i++) {
    if (names[i] == NULL) continue;
    int held = 0;
    for (int j = 0; j < count && !held; j++) {
      const char *placed = at[j] != NULL ? at[j] : paths[j];
      size_t n = strlen(placed);
      held = strncmp(names[i], placed, n) == 0 &&
             (names[i][n] == '/' || names[i][n] == '\0' || n == 1);
    }
    if (held) continue;
    int length = snprintf(target, sizeof target, "%s%s", root, names[i]);
    if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
    if ((number = make_link(target, strlen(root), paths[i])) != 0) return number;
  }
  /* With /proc, the links into it a program expects in /dev, as a
   * container's root has them. */
  /* A /dev given whole has its own, or has none to make. */
  int proc = 0, dev = 0;
  for (int i = 0; i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    proc = proc || (at[i] == NULL && strcmp(paths[i], "/proc") == 0);
    dev = dev || strcmp(placed, "/dev") == 0 || strcmp(placed, "/") == 0;
  }
  static const char *const dev_links[][2] = {
    { "/dev/fd", "/proc/self/fd" }, { "/dev/stdin", "/proc/self/fd/0" },
    { "/dev/stdout", "/proc/self/fd/1" }, { "/dev/stderr", "/proc/self/fd/2" },
  };
  for (size_t i = 0; proc && !dev && i < sizeof dev_links / sizeof dev_links[0]; i++) {
    int made = snprintf(target, sizeof target, "%s%s", root, dev_links[i][0]);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    if ((number = make_link(target, strlen(root), dev_links[i][1])) != 0) return number;
  }
  int length = snprintf(target, sizeof target, "%s/.old", root);
  if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
  if (mkdir(target, 0700) != 0) return errno;
  if (syscall(SYS_pivot_root, root, target) != 0) return errno;
  if (chdir("/") != 0) return errno;
  if (umount2("/.old", MNT_DETACH) != 0) return errno;
  if (rmdir("/.old") != 0) return errno;
  /* Nothing is made at the root itself once it is built. */
  if (mount(NULL, "/", NULL, MS_REMOUNT | MS_BIND | MS_RDONLY | MS_NOSUID | MS_NODEV, NULL) != 0)
    return errno;
  *own = own_proc;
  return 0;
}

/* In an unveiled child's program's process that builds no root
 * ([`start_program`]), in its namespaces: its mounts made private, and
 * a procfs of its own pid namespace over the host's /proc there, so
 * what it reads of /proc is its own sandbox's processes and nothing
 * else, while it keeps the host's filesystem. There is no fallback to
 * the host's /proc: a refusal is STAGE_PROC's. `own` says it is there.
 * 0, or an errno. */
static int mount_proc_only (int *own) {
  *own = 0;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return errno;
  int number = place_proc("/proc", own, 1);
  return number;
}

/* In a child that is `offline` and unveils nothing, before anything
 * else of the sandbox: a user namespace of its own, mapping its user
 * and group to themselves, and a network namespace of its own, which
 * has nothing but a loopback, brought up; then it gives up every
 * capability they gave it. It keeps the host's pid namespace, as it
 * keeps the host's filesystem and /proc with it. 0, or an errno. */
static int go_offline (int unmap_root, const char *uid_map, const char *gid_map, int strict) {
  if (syscall(SYS_unshare, CLONE_NEWUSER | CLONE_NEWNET) != 0)
    return staged(strict, STAGE_NAMESPACE, errno);
  int mapped = 1;
  int number = map_ids(unmap_root, uid_map, gid_map, &mapped);
  if (number == 0) number = loopback_up();
  if (number == 0) number = drop_capabilities();
  return staged(strict, STAGE_NAMESPACE, number);
}
#endif

/* One resource limit a child is held to: `resource` is an RLIMIT_ constant
 * and `value` both its soft and its hard limit. */
struct spawn_rlimit {
  int resource;
  rlim_t value;
};

/* Everything a spawned child reads between starting and exec, made ready
 * by the parent: the child shares the parent's memory on Linux
 * ([`spawn_child`]), so it allocates nothing and writes nothing of the
 * parent's but the one thing it means to -- the coverage flags of the
 * functions it enters, and on the checked core UBSan's own state -- and
 * reads only this, which the parent holds, unchanged, until the child
 * has exec'd or ended. On Darwin the parent hands it to posix_spawn
 * ([`spawn_program`]). */
struct spawn_plan {
  const char *path;
  char **argv;
  char **envp;
  const char *cwd;
  /* source[t] is the parent descriptor the child sees as t, or -1: for
   * 0..2 that means inherit, above that it means closed. */
  const int *source;
  int top;
  int status_read;
  int status_write;
  long descriptor_limit;
  int process_group;
  int credentials;
  uid_t user;
  gid_t group;
  /* The Landlock ruleset to restrict the child to, or -1. */
  int confine;
  int pledged;
#if defined(PLEDGE_ARCH)
  const struct sock_fprog *pledge;
#endif
  /* Whether the child is held to the promises filter (core/promises.c),
   * and to which promises: COSMIC_PROMISE_ bits. */
  int promising;
  unsigned promises;
  /* What else holds the child, as COSMIC_HELD_ bits (core/promises.h): the
   * signal scope of `confine` ([`grants_ruleset`]), and what the child's
   * namespaces make of the calls the filter cannot read. */
  unsigned held;
  /* The socket families it may make (COSMIC_SOCKETS_ bits). */
  unsigned sockets;
  /* The limits to set, last but the filter: `rlimit_count` of them. */
  int rlimit_count;
  const struct spawn_rlimit *rlimits;
  int unveiling;
  int offline;
  int noexec_scratch;
  /* A policy's sandbox ([`staged`], [`build_root`]): the child gives its
   * failures' stages, and its own procfs and tmpfs are Landlock-granted
   * ([`own_rules`]). */
  int strict;
  /* An unveiled child that builds no root: a pid namespace and a procfs
   * of its own over the host's filesystem ([`mount_proc_only`]). */
  int proc_only;
  /* The size of the /tmp of a strict root's own, or 0 for none. */
  unsigned long tmp_bytes;
  int tmp_exec;
  /* Whether a unix socket is allowed below Landlock ABI 9 on the strength
   * of the root alone ([`grants_ruleset`], a `u` grant): [`build_root`] then
   * fails the start for a path it binds that is a directory, or a socket
   * `unveiled_unix` (a flag each path has) does not name. */
  int unix_guard;
  const int *unveiled_unix;
  const char *root_dir;
  char *const *resolved_paths;
  char *const *given_names;
  const char *const *bound_at;
  const int *unveiled_writable;
  const int *unveiled_noexec;
  /* With `dropping`: whether each path is mounted idmapped, so the user
   * the child runs as owns what the path's owner does ([`idmapped_tree`]);
   * and, where the child makes each mount, its descriptor, which it
   * places before its namespaces and [`build_root`] moves into the
   * root, or -1. `idmap_failed` is the index of the path whose mount
   * the child could not make, written by the child, which shares this
   * memory. */
  const int *unveiled_idmap;
  int *idmap_fds;
  int *idmap_failed;
  int unveil_count;
  const char *uid_map;
  const char *gid_map;
  /* Whether the child is root in a user namespace not the host's, which
   * may not map root into one of its own. */
  int unmap_root;
  /* With `user`: whether an unveiled child gives root up for `drop_uid`
   * and `drop_gid` ([`start_program`]), and the maps a process of this
   * one's writes of its namespace from outside ([`map_from_outside`]),
   * root's and theirs; `uid_map` and `gid_map` then map theirs alone,
   * for the namespace it makes as that user. */
  int dropping;
  uid_t drop_uid;
  gid_t drop_gid;
  const char *outer_uid_map;
  const char *outer_gid_map;
#if defined(__linux__)
  /* For an unveiled child: the tops of the stacks its init and its
   * program start on ([`start_unveiled`]), and where it writes their
   * pids, the one thing of the parent's it writes besides its coverage
   * flags. */
  char *init_stack;
  char *program_stack;
  /* And, for one that gives root up, the top of the stack the process
   * that maps it from outside runs on ([`map_from_outside`]). */
  char *helper_stack;
  pid_t *init;
  pid_t *program;
#endif
  /* The parent's signal mask from before it blocked every signal to
   * start the child, which the program is to start with. */
  sigset_t mask;
};

#if defined(__linux__)
/* One past the highest signal number: Linux's real-time signals end at
 * 64. */
#define SIGNAL_LIMIT 65

/* In the child, with every signal blocked: every signal this process
 * catches is set back to its default, so none can run a handler of the
 * parent's -- in the parent's memory -- before exec. One ignored stays
 * ignored across exec, as it would through fork, but SIGPIPE when cosmic
 * itself ignored it. A signal the kernel will not change (SIGKILL,
 * SIGSTOP) or a libc keeps for itself is refused and left alone. */
static void default_signals (void) {
  struct sigaction initial;
  memset(&initial, 0, sizeof initial);
  initial.sa_handler = SIG_DFL;
  sigemptyset(&initial.sa_mask);
  for (int number = 1; number < SIGNAL_LIMIT; number++) {
    struct sigaction current;
    if (sigaction(number, NULL, &current) != 0) continue;
    int reset = current.sa_handler != SIG_DFL && current.sa_handler != SIG_IGN;
    if (number == SIGPIPE && sigpipe_ignored_here) reset = 1;
    if (reset) sigaction(number, &initial, NULL);
  }
}

/* Raw calls only: this child shares the parent's memory, but must not
 * ask libc to coordinate its credential change with parent threads.
 * Clearing all three capability sets also clears ambient capabilities;
 * the bounding set stays unchanged. */
static int set_credentials (const struct spawn_plan *plan) {
  struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct caps[2] = { { 0, 0, 0 }, { 0, 0, 0 } };
  if (syscall(SYS_prctl, PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L) != 0 ||
      syscall(SYS_setgroups, 0, NULL) != 0 ||
      syscall(SYS_setresgid, plan->group, plan->group, plan->group) != 0 ||
      syscall(SYS_setresuid, plan->user, plan->user, plan->user) != 0 ||
      syscall(SYS_capset, &header, caps) != 0) return errno;
  return 0;
}

/* A grant's letters, in the order the plan lists them: "rwxcu". */
enum { GRANT_READ = 1, GRANT_WRITE = 2, GRANT_EXECUTE = 4, GRANT_CREATE = 8, GRANT_UNIX = 16 };

#if defined(__linux__)
static uint64_t grant_rights (unsigned letters, long abi);
#endif

/* What a policy's sandbox ([`build_root`]'s `strict`) makes of its own, which no path
 * the ruleset was built from names -- built after it, in the child --
 * the ruleset is given, so it is not left refusing it: the procfs of its
 * own, to read (a program expects /proc/self), and the sized tmpfs at
 * /tmp, to read, write and create, as a grant `rwc` is (and to execute,
 * as `rwxc` is, with `tmp_exec`). The ruleset is
 * this child's alone, made for its start, so what is added widens no
 * other's. Raw calls only ([`run_program`]). 0, or an errno. */
static int own_rules (const struct spawn_plan *plan, int ruleset, int own_proc) {
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return abi < 0 ? errno : ENOSYS;
  for (int tmp = 0; tmp < 2; tmp++) {
    if (tmp ? plan->tmp_bytes == 0 : !own_proc) continue;
    uint64_t rights = tmp ? grant_rights(GRANT_READ | GRANT_WRITE | GRANT_CREATE |
                                         (plan->tmp_exec ? GRANT_EXECUTE : 0), abi)
                          : grant_rights(GRANT_READ, abi);
    int fd = open(tmp ? "/tmp" : "/proc", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return errno;
    struct landlock_path_beneath_attr beneath = { .allowed_access = rights, .parent_fd = fd };
    int number = syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0
                     ? errno : 0;
    close(fd);
    if (number != 0) return number;
  }
  return 0;
}

/* Holds this process, for good, to the Landlock ruleset `ruleset`: no_new_privs,
 * which the kernel asks of a process without CAP_SYS_ADMIN, and the
 * restriction. 0, or an errno. Raw calls only, for a child that shares its
 * parent's memory ([`run_program`]) and for the process itself
 * (`restrict_self`) alike. */
static int enforce_ruleset (int ruleset) {
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
  if (syscall(SYS_landlock_restrict_self, ruleset, 0) != 0) return errno;
  return 0;
}

/* The rest of a child's start once its sandbox's namespaces are made
 * ([`spawn_child`]): its process group -- for an unveiled child, a
 * session of its own, and so a group of its own whatever
 * `process_group` says, so the autogroup its writable /proc lets it set
 * (/proc/self/autogroup) is the sandbox's, not its parent's session's --
 * its directory, its descriptors moved from where `pinned` holds them,
 * Landlock's `confined` ruleset and the pledge, the parent's mask, and
 * exec. A failure goes to the parent over `status_fd` as an errno. */
static _Noreturn void run_program (const struct spawn_plan *plan, const int *pinned,
                                   int confined, int status_fd, int own_proc) {
  int top = plan->top;
  int failure = 0;
  if (plan->unveiling) {
    if (setsid() < 0) failure = errno;
  } else if (plan->process_group && setpgid(0, 0) != 0) {
    failure = errno;
  }
  if (!failure && plan->credentials) failure = set_credentials(plan);
  if (!failure && plan->cwd != NULL && chdir(plan->cwd) != 0) failure = errno;
  for (int t = 0; !failure && t <= top; t++) {
    if (pinned[t] >= 0) {
      if (dup2(pinned[t], t) < 0) failure = errno;
    } else if (t < 3) {
      /* An inherited stdio descriptor must be as safe for exec as a
       * mapped one. */
      int flags = fcntl(t, F_GETFD);
      if (flags >= 0) {
        if (fcntl(t, F_SETFD, flags & ~FD_CLOEXEC) != 0) failure = errno;
      } else if (errno != EBADF) {
        failure = errno;
      }
    } else {
      close(t);
    }
  }
  /* Confined last, just before exec: what the child and every process
   * it starts may reach is the ruleset's, and nothing lets it off.
   * TODO: let a ruleset that names /proc reach an unveiled child's own
   * /proc, as it reaches the host's where the child has that
   * ([`place_proc`]), once `landlock_ruleset` records which paths a
   * ruleset holds: adding the rule here, in the child, would widen the
   * caller's ruleset for every later child besides, and a ruleset that
   * left /proc out would gain it. Until then a child held to a `ruleset`
   * reads nothing of its own /proc; `grants` are the caller's own, made
   * for this child alone, and a strict one's get it ([`own_rules`]). */
  if (!failure && confined >= 0 && plan->strict && plan->unveiling)
    failure = own_rules(plan, confined, own_proc);
  if (!failure && confined >= 0) failure = enforce_ruleset(confined);
  /* A pledge last of all: the filter would refuse nothing above, but
   * it is the one a later step could trip over. */
  if (!failure && plan->pledged) {
#if defined(PLEDGE_ARCH)
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) failure = errno;
    else if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, plan->pledge) != 0) failure = errno;
#else
    failure = ENOSYS;
#endif
  }
  close_child_descriptors(top + 2, plan->descriptor_limit);
  /* The program starts with the parent's own mask; a signal pending
   * since the start is delivered now, at its default. */
  if (!failure && sigprocmask(SIG_SETMASK, &plan->mask, NULL) != 0) failure = errno;
  /* Lowered last, once every descriptor is moved above `top`, which a
   * lower limit can refuse; what is open above it stays open. */
  if (!failure) restore_descriptor_limit(0);
  /* Set after the restore, which would raise a lowered NOFILE again, and
   * before the filter, which follows every other step. Soft and hard
   * together, so the program cannot raise one again. */
  for (int i = 0; !failure && i < plan->rlimit_count; i++) {
    struct rlimit limits = { .rlim_cur = plan->rlimits[i].value, .rlim_max = plan->rlimits[i].value };
    if (setrlimit(plan->rlimits[i].resource, &limits) != 0) failure = errno;
  }
  /* The promises filter goes last, so no step above is refused by it,
   * and just before exec, which it allows. It is built here because it
   * holds the scheduling calls, and the signals where Landlock does not
   * scope them, to the process's own pid, which only the child has; it
   * follows Landlock so the ruleset is made with calls the filter has
   * not yet limited, and so `held` is what the kernel now holds.
   * PR_SET_MDWE is not set for a child with no `jit`: it is a property
   * of the address space, which this child shares with its parent until
   * exec, so it would hold the parent too.
   * TODO: set PR_SET_MDWE here for a child with no `jit`, once spawn
   * starts it on an address space of its own instead of
   * clone(CLONE_VM). The filter then drops the PROT_EXEC | PROT_BTI
   * mprotect it allows on aarch64 for glibc's loader. */
  if (!failure && plan->promising) failure = cosmic_promises_apply(plan->promises, plan->sockets, plan->held);
  if (!failure) execve(plan->path, plan->argv, plan->envp);
  if (!failure) failure = errno;
  report_child_error(status_fd, failure);
  _exit(127);
}

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

/* What an unveiled child ([`start_unveiled`]) shares with the init and
 * the program it starts, each on its memory and each while it waits:
 * the plan, and the descriptors [`spawn_child`] placed; whether its user
 * is mapped; this program, the pipe ends the init takes, and the
 * errno the init failed with before its exec, which the init writes. */
struct sandbox_start {
  const struct spawn_plan *plan;
  const int *pinned;
  int confined;
  int status_fd;
  int mapped;
  int exe;
  int started;
  int ready;
  int init_error;
};

/* `fd`, or -1 with errno, moved above every descriptor a child is
 * handed (`top` + 2 on) and close-on-exec, at `placed`: so none can
 * land on a descriptor the program is to have, nor reach it. 0, or an
 * errno. */
static int raise_descriptor (int fd, int top, int *placed) {
  *placed = -1;
  if (fd < 0) return errno;
  *placed = fcntl(fd, F_DUPFD_CLOEXEC, top + 2);
  int number = *placed < 0 ? errno : 0;
  close(fd);
  return number;
}

/* The sandbox's init, on the unveiled child's memory from its start to
 * its exec: the first process in the child's pid namespace, it gives up
 * its capabilities and executes this very program as
 * [`cosmic_sandbox_init`], holding the started pipe's read end as 0, the
 * ready pipe's write end as 1 and the parent's status pipe's write end
 * as 2, and nothing else -- from / as the host has it still, where a
 * core linked dynamically (the checked one) finds its loader and
 * libraries, whatever the child is given. Its root and directory move
 * to the child's own when the program pivots ([`start_program`]). A
 * failure before that exec is its errno in the shared `init_error`. */
static _Noreturn int start_init (void *argument) {
  struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = drop_capabilities();
  if (!failure && chdir("/") != 0) failure = errno;
  /* Each source but the status pipe's is above the child's descriptors
   * ([`raise_descriptor`]), and that one, just above them, is moved
   * before 3 is written: so none is overwritten by the moves. */
  const int from[4] = { start->started, start->ready, start->status_fd, start->exe };
  for (int t = 0; !failure && t < 4; t++) {
    if (dup2(from[t], t) < 0) failure = errno;
  }
  if (!failure && fcntl(3, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
  if (!failure) {
    close_child_descriptors(4, plan->descriptor_limit);
    char *argv[] = { (char *)COSMIC_SANDBOX_INIT, NULL };
    char *envp[] = { NULL };
    syscall(SYS_execveat, 3, "", argv, envp, AT_EMPTY_PATH);
    failure = errno;
  }
  start->init_error = failure;
  _exit(127);
}

/* The program's process, on the unveiled child's memory from its start
 * to its exec: the second in the pid namespace, and, started with
 * CLONE_PARENT, the parent's own child, as a child unconfined is. It
 * builds the root, in the pid namespace as a procfs's mounter must be
 * to hold it ([`build_root`]), gives up its capabilities, and runs the
 * program ([`run_program`]). */
static _Noreturn int start_program (void *argument) {
  const struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = 0;
  /* One that gives root up (`spawn`'s `user`) builds its root as root,
   * which reaches what only root may -- root's own files, mapped in its
   * namespace ([`map_from_outside`]) -- but makes it as that user, as an
   * unprivileged caller's child's is made: its filesystem ids are that
   * user's and group's, and the capabilities over files that change
   * takes out of effect are put back. The kernel makes its memory
   * undumpable as its ids or capabilities change, which is made
   * dumpable again each time, so the child's own /proc files are its
   * own to write its maps in; that memory is the parent's too, which
   * puts back what it had once the child has exec'd. */
  if (plan->dropping) {
    syscall(SYS_setfsgid, plan->drop_gid);
    syscall(SYS_setfsuid, plan->drop_uid);
    if ((uid_t)syscall(SYS_setfsuid, (uid_t)-1) != plan->drop_uid ||
        (gid_t)syscall(SYS_setfsgid, (gid_t)-1) != plan->drop_gid)
      failure = EPERM;
    struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct data[2];
    if (!failure && syscall(SYS_capget, &header, data) != 0) failure = errno;
    for (int i = 0; !failure && i < 2; i++) data[i].effective = data[i].permitted;
    if (!failure && syscall(SYS_capset, &header, data) != 0) failure = errno;
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0 && !failure) failure = errno;
  }
  int own_proc = 0;
  if (!failure && plan->proc_only) {
    failure = staged(plan->strict, STAGE_ROOT, mount_proc_only(&own_proc));
  } else if (!failure) {
    failure = staged(plan->strict, STAGE_ROOT,
                     build_root(plan->root_dir, plan->resolved_paths, plan->given_names,
                                plan->bound_at, plan->unveiled_writable, plan->unveiled_noexec,
                                plan->idmap_fds,
                                plan->unveil_count, start->mapped, plan->noexec_scratch,
                                plan->strict, plan->tmp_bytes, plan->tmp_exec, plan->unix_guard, plan->unveiled_unix, &own_proc));
  }
  if (!failure) failure = drop_capabilities();
  /* Then it gives root up for good, its groups first, while it may.
   * Where its /proc is its own, it makes a user namespace as that user,
   * mapping it alone, as an unprivileged caller's child is: root's files
   * are the overflow id's there, and no setuid program of root's runs
   * as root. Where it has the host's, read-only, it could write no map,
   * and stays where root is mapped beside it: so every mount of its
   * root is made nosuid first, which no setuid program runs past. */
  if (!failure && plan->dropping) {
    struct cosmic_mount_attr nosuid = { COSMIC_MOUNT_ATTR_NOSUID, 0, 0, 0 };
    if (syscall(SYS_mount_setattr, AT_FDCWD, "/", AT_RECURSIVE, &nosuid, sizeof nosuid) != 0)
      failure = errno;
  }
  if (!failure && plan->dropping) {
    if (syscall(SYS_setgroups, 0, NULL) != 0 ||
        syscall(SYS_setresgid, plan->drop_gid, plan->drop_gid, plan->drop_gid) != 0 ||
        syscall(SYS_setresuid, plan->drop_uid, plan->drop_uid, plan->drop_uid) != 0)
      failure = errno;
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0 && !failure) failure = errno;
    int mapped = 1;
    if (!failure && own_proc && syscall(SYS_unshare, CLONE_NEWUSER) != 0) failure = errno;
    if (!failure && own_proc) failure = map_ids(0, plan->uid_map, plan->gid_map, &mapped);
    if (!failure && own_proc) failure = drop_capabilities();
  }
  if (failure) {
    report_child_error(start->status_fd, failure);
    _exit(127);
  }
  run_program(plan, start->pinned, start->confined, start->status_fd, own_proc);
}

/* What an unveiled child that gives root up (`spawn`'s `user`) shares
 * with the process that maps its user namespace from outside
 * ([`map_from_outside`]): the plan, the child's pid, its /proc directory,
 * which the child opened itself -- so a map is written to it alone,
 * whatever pid another process may come to have -- the pipe the child
 * says over that it has made the namespace, and the errno the mapping
 * failed with, ECHILD until it is done. */
struct outside_map {
  const struct spawn_plan *plan;
  pid_t child;
  int proc;
  int told;
  int tell;
  int error;
};

/* On the unveiled child's memory, started before the child makes its
 * user namespace ([`start_unveiled`]), and so in this one's, as this
 * process's root: once the child says it has made it -- a byte of 1 --
 * writes its uid_map and gid_map, which map root and the user and group
 * it gives root up for (`outer_uid_map`, `outer_gid_map`). The child
 * could map its own ids alone; a map of more is written by a process
 * holding CAP_SETUID and CAP_SETGID where they are mapped -- and, to
 * map root, CAP_SETFCAP -- which the kernel asks of the opener and the
 * writer both. setgroups stays allowed there, for the child to give up
 * root's groups. The child calls nothing that sets errno, which they
 * share, until this has ended. */
static _Noreturn int map_from_outside (void *argument) {
  struct outside_map *map = argument;
  /* Its own copy of the end the child writes, closed, so a child gone
   * before it said anything ends the read. */
  close(map->tell);
  char byte = 0;
  ssize_t got;
  while ((got = read(map->told, &byte, 1)) < 0 && errno == EINTR) {}
  int failure = got == 1 && byte == 1 ? 0 : ECHILD;
  /* The child is its parent, and waits for it. */
  if (!failure && (pid_t)syscall(SYS_getppid) != map->child) failure = ECHILD;
  const char *const files[2] = { "uid_map", "gid_map" };
  const char *const maps[2] = { map->plan->outer_uid_map, map->plan->outer_gid_map };
  for (int i = 0; !failure && i < 2; i++) failure = write_whole_at(map->proc, files[i], maps[i]);
  map->error = failure;
  _exit(failure ? 127 : 0);
}

/* What [`idmapped_tree`] shares with the process that makes the user
 * namespace the mount is mapped through: the pipe it says over that it
 * has made it, and the one it then waits on until it is ended. */
struct idmap_holder {
  int told;
  int hold;
};

/* On the unveiled child's memory, in a process of its own that
 * [`idmapped_tree`] starts: makes a user namespace, says so with a byte
 * of 1 -- or 0 -- and waits, holding it, until it is killed. */
static _Noreturn int idmap_holder (void *argument) {
  const struct idmap_holder *holder = argument;
  char byte = syscall(SYS_unshare, CLONE_NEWUSER) == 0 ? 1 : 0;
  if (write(holder->told, &byte, 1) != 1) _exit(127);
  while (byte == 1 && read(holder->hold, &byte, 1) < 0 && errno == EINTR) {}
  _exit(0);
}

/* An idmapped mount's map ([`idmapped_tree`]) of `owner` to `drop`, and,
 * where they differ, of `drop` to `owner`: a map takes each id once on
 * either side, so `drop`'s own files cannot show as `drop`'s too, and
 * left out of the map they would refuse every write, whatever their mode;
 * swapped, they show as `owner`'s and are written as their mode lets
 * everyone. */
static void swapped_map (char *text, size_t room, unsigned long owner, unsigned long drop) {
  if (owner == drop) snprintf(text, room, "%lu %lu 1\n", owner, drop);
  else snprintf(text, room, "%lu %lu 1\n%lu %lu 1\n", owner, drop, drop, owner);
}

/* In the unveiled child, before its own namespaces, as the root of
 * this process's own: at `fd` (placed above `top`), a detached copy of
 * the mount tree at `path`, idmapped so that the user and group that
 * own `path` -- the owner of the file the mount shows -- are the user
 * and group `plan` drops to, and every other owner none: what the
 * path's owner may do, the child's user may, and what it creates is
 * the owner's on the host; the drop user's own files show as the
 * owner's ([`swapped_map`]). The mapping is a user namespace of its own,
 * made by [`idmap_holder`] and mapped here, `owner` to the drop user
 * and group, which a mount may be idmapped through only where this
 * process may mount (CAP_SYS_ADMIN where the file system is
 * mounted), so the mount is made here, not by the child, which has no
 * capability there. 0, or an errno. */
static int idmapped_tree (const struct spawn_plan *plan, const char *path, int top, int *fd) {
  *fd = -1;
  struct stat st;
  if (stat(path, &st) != 0) return errno;
  int made[2], held[2];
  if (pipe(made) != 0) return errno;
  if (pipe(held) != 0) {
    int number = errno;
    close(made[0]);
    close(made[1]);
    return number;
  }
  struct idmap_holder holder = { made[1], held[0] };
  int failure = 0;
  pid_t pid = clone(idmap_holder, plan->helper_stack, CLONE_VM | SIGCHLD, &holder);
  close(made[1]);
  close(held[0]);
  if (pid < 0) {
    failure = errno;
  } else {
    char byte = 0;
    ssize_t got;
    while ((got = read(made[0], &byte, 1)) < 0 && errno == EINTR) {}
    if (got != 1 || byte != 1) failure = EPERM;
    char at[64], text[96];
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/setgroups", (int)pid);
      failure = write_whole(at, "deny");
    }
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/uid_map", (int)pid);
      swapped_map(text, sizeof text, (unsigned long)st.st_uid, (unsigned long)plan->drop_uid);
      failure = write_whole(at, text);
    }
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/gid_map", (int)pid);
      swapped_map(text, sizeof text, (unsigned long)st.st_gid, (unsigned long)plan->drop_gid);
      failure = write_whole(at, text);
    }
    int namespace = -1;
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/ns/user", (int)pid);
      namespace = open(at, O_RDONLY | O_CLOEXEC);
      if (namespace < 0) failure = errno;
    }
    if (!failure) {
      int tree = (int)syscall(SYS_open_tree, AT_FDCWD, path,
                              COSMIC_OPEN_TREE_CLONE | O_CLOEXEC | AT_RECURSIVE);
      if (tree < 0) {
        failure = errno;
      } else {
        struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_IDMAP, 0, 0, (uint64_t)namespace };
        if (syscall(SYS_mount_setattr, tree, "", AT_EMPTY_PATH | AT_RECURSIVE, &attr,
                    sizeof attr) != 0) {
          failure = errno;
          close(tree);
        } else {
          failure = raise_descriptor(tree, top, fd);
        }
      }
    }
    if (namespace >= 0) close(namespace);
    kill(pid, SIGKILL);
    int ignored;
    while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
  }
  close(made[0]);
  close(held[1]);
  return failure;
}

/* An unveiled child, from where [`spawn_child`] placed its descriptors:
 * it makes a user namespace of its own, which it maps ([`map_ids`]), a pid
 * namespace for what it starts, a mount namespace, System V IPC, and
 * with `offline` a network namespace with its loopback up
 * ([`loopback_up`]). The init it starts first is pid 1 of that namespace
 * ([`start_init`]); the program it starts next is pid 2, the parent's
 * child ([`start_program`]): signalled, stopped and reaped as any child
 * is, with the exit status its own, rather than a pid 1's, from which a
 * signal the program does not catch -- a SIGTERM, its own abort() --
 * would be dropped. Its pid is the one `spawn` answers. So the
 * program's own processes see, and signal, none but each other and
 * that init, which ignores them. The init is the parent's child too
 * (CLONE_PARENT), so no subreaper adopts it when this process ends, as
 * one would a stray (`waitpid` ends and reaps it with its program:
 * [`end_sandbox_init`]), and it ends if the parent does. This
 * process waits for the init to be past its exec -- until then it
 * shares this memory -- and to have made itself undumpable, so no
 * program of the same user in the sandbox can ptrace it; then it starts
 * the program, and ends when the program has exec'd: the pipe the init
 * reads then ends, once the program's copy of it is closed at exec. A
 * failure goes to the parent over `status_fd` as an errno. */
static _Noreturn void start_unveiled (const struct spawn_plan *plan, const int *pinned,
                                      int confined, int status_fd) {
  struct sandbox_start start = { plan, pinned, confined, status_fd, 1, -1, -1, -1, 0 };
  int top = plan->top;
  /* Each descriptor raised above `top` here is counted in
   * SPAWN_PLACED_ABOVE (core/process.h). */
  /* Through unshare, not clone's flags, which a container's seccomp
   * profile refuses where it lets unshare through (Docker's default,
   * narrowed as CI's is). Each namespace but the user's is the new
   * user namespace's own. */
  int flags = CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWIPC |
              (plan->offline ? CLONE_NEWNET : 0);
  int failure = 0;
  /* One that gives root up is mapped from outside ([`map_from_outside`]),
   * by a process started before its namespace is made, and waited for. */
  struct outside_map outside = { plan, (pid_t)syscall(SYS_getpid), -1, -1, -1, ECHILD };
  pid_t helper = -1;
  /* An idmapped mount is made while this is root where the file system
   * is, with the one stack the user-mapping helper has not yet taken. */
  for (int i = 0; !failure && plan->unveiled_idmap != NULL && i < plan->unveil_count; i++) {
    plan->idmap_fds[i] = -1;
    if (!plan->unveiled_idmap[i]) continue;
    failure = idmapped_tree(plan, plan->resolved_paths[i], top, &plan->idmap_fds[i]);
    if (failure) {
      *plan->idmap_failed = i;
      failure = staged(plan->strict, STAGE_IDMAP, failure);
    }
  }
  if (!failure && plan->dropping) {
    int made[2];
    failure = raise_descriptor(open("/proc/self", O_RDONLY | O_DIRECTORY | O_CLOEXEC), top,
                               &outside.proc);
    if (!failure && pipe(made) != 0) failure = errno;
    if (!failure) {
      failure = raise_descriptor(made[0], top, &outside.told);
      int other = raise_descriptor(made[1], top, &outside.tell);
      if (!failure) failure = other;
    }
    if (!failure) {
      helper = clone(map_from_outside, plan->helper_stack, CLONE_VM | SIGCHLD, &outside);
      if (helper < 0) failure = errno;
    }
  }
  if (!failure && syscall(SYS_unshare, flags) != 0)
    failure = staged(plan->strict, STAGE_NAMESPACE, errno);
  if (helper > 0) {
    char byte = failure ? 0 : 1;
    ssize_t put = write(outside.tell, &byte, 1);
    if (put != 1 && !failure) failure = put < 0 ? errno : EIO;
    close(outside.tell);
    outside.tell = -1;
    int ignored;
    pid_t reaped;
    while ((reaped = waitpid(helper, &ignored, 0)) < 0 && errno == EINTR) {}
    if (reaped < 0 && !failure) failure = errno;
    if (!failure) failure = outside.error;
  }
  if (outside.proc >= 0) close(outside.proc);
  if (outside.told >= 0) close(outside.told);
  if (outside.tell >= 0) close(outside.tell);
  if (!failure && !plan->dropping)
    failure = staged(plan->strict, STAGE_NAMESPACE,
                     map_ids(plan->unmap_root, plan->uid_map, plan->gid_map, &start.mapped));
  if (!failure && plan->offline) failure = staged(plan->strict, STAGE_NAMESPACE, loopback_up());
  if (!failure)
    failure = raise_descriptor(open("/proc/self/exe", O_RDONLY | O_CLOEXEC), top, &start.exe);
  int started[2] = { -1, -1 }, ready[2] = { -1, -1 };
  for (int p = 0; !failure && p < 2; p++) {
    int *ends = p == 0 ? started : ready;
    int made[2];
    if (pipe(made) != 0) {
      failure = errno;
      break;
    }
    failure = raise_descriptor(made[0], top, &ends[0]);
    int other = raise_descriptor(made[1], top, &ends[1]);
    if (!failure) failure = other;
  }
  if (!failure) {
    start.started = started[0];
    start.ready = ready[1];
    pid_t init = clone(start_init, plan->init_stack,
                       CLONE_VM | CLONE_VFORK | CLONE_PARENT | SIGCHLD, &start);
    if (init < 0) {
      failure = errno;
    } else {
      *plan->init = init;
      failure = start.init_error;
    }
  }
  /* Its own copies of what the init took: the ready pipe then ends
   * when the init has answered, or has died. */
  if (started[0] >= 0) close(started[0]);
  if (ready[1] >= 0) close(ready[1]);
  if (start.exe >= 0) close(start.exe);
  if (!failure) {
    int answer = 0;
    size_t received = 0;
    while (received < sizeof answer) {
      ssize_t got = read(ready[0], (char *)&answer + received, sizeof answer - received);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      received += (size_t)got;
    }
    failure = received == sizeof answer ? answer : ECHILD;
  }
  if (ready[0] >= 0) close(ready[0]);
  if (!failure) {
    pid_t program = clone(start_program, plan->program_stack,
                          CLONE_VM | CLONE_VFORK | CLONE_PARENT | SIGCHLD, &start);
    if (program < 0) failure = errno;
    else *plan->program = program;
  }
  if (failure) report_child_error(status_fd, failure);
  _exit(failure ? 127 : 0);
}

/* The child `spawn` starts on Linux, from its start to exec: on the
 * parent's memory, through clone(CLONE_VM | CLONE_VFORK) on a stack of
 * its own, the parent stopped until this execs or ends. So it neither
 * allocates nor touches the Lua state, writes only its own stack and
 * descriptors, the kernel's side of the process, and errno (which is
 * the parent's too; the parent reads none after a start that succeeded)
 * -- and, deliberately, the parent's memory in one place: the coverage
 * flag of each function it enters (core/coverage.h), so a test is
 * credited with what its child ran, and on the checked core the
 * sanitizer runtime's state (UBSan's report dedup), which a report from
 * here would write; an unveiled one writes its program's pid too
 * ([`start_unveiled`]). It leaves by exec or _exit, never by returning,
 * so no atexit handler or stdio flush runs. A failure goes to the
 * parent over the status pipe as an errno. */
static _Noreturn int spawn_child (void *argument) {
  const struct spawn_plan *plan = argument;
  int top = plan->top;
  default_signals();
  close(plan->status_read);
  int failure = 0;
  /* dup2 onto a target can overwrite another mapping's source, so every
   * source is first pinned above everything the child is handed. A
   * source that is its own target is pinned too: the copy is what makes
   * the final dup2 clear CLOEXEC on it. Inherited stdio is left alone,
   * so a closed one stays closed. What is placed above `top` besides the
   * copies is counted in SPAWN_PLACED_ABOVE (core/process.h). */
  int pinned[CHILD_FD_MAX + 1];
  for (int t = 0; t <= top; t++) {
    pinned[t] = -1;
    if (!failure && plan->source[t] >= 0) {
      pinned[t] = fcntl(plan->source[t], F_DUPFD_CLOEXEC, top + 2);
      if (pinned[t] < 0) failure = errno;
    }
  }
  /* The ruleset is pinned with them, before the exec-status descriptor
   * takes top + 1 -- which the ruleset may be -- and before any mapping
   * can land on it. */
  int confined = -1;
  if (!failure && plan->confine >= 0) {
    confined = fcntl(plan->confine, F_DUPFD_CLOEXEC, top + 2);
    if (confined < 0) failure = errno;
  }
  /* The exec-status descriptor sits just above the child's own. */
  int status_fd = plan->status_write;
  if (!failure && status_fd != top + 1) {
    if (dup2(status_fd, top + 1) < 0) {
      failure = errno;
    } else {
      close(status_fd);
      status_fd = top + 1;
    }
  }
  if (!failure && fcntl(status_fd, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
  if (failure) {
    report_child_error(status_fd, failure);
    _exit(127);
  }
  /* The sandbox's own namespaces first: the root the rest resolves in,
   * and mounting, which Landlock and a pledge would refuse. */
  if (plan->unveiling) start_unveiled(plan, pinned, confined, status_fd);
  if (plan->offline && (failure = go_offline(plan->unmap_root, plan->uid_map, plan->gid_map, plan->strict)) != 0) {
    report_child_error(status_fd, failure);
    _exit(127);
  }
  run_program(plan, pinned, confined, status_fd, 0);
}

/* The kind of descriptor `fd` is (S_IFIFO and the like), or 0 where it
 * is none. */
static mode_t descriptor_kind (int fd) {
  struct stat st;
  if (fstat(fd, &st) != 0) return 0;
  return st.st_mode & S_IFMT;
}

bool cosmic_sandbox_init_asked (int argc, char **argv) {
  return argc == 1 && strcmp(argv[0], COSMIC_SANDBOX_INIT) == 0 && getpid() == 1 &&
         (COSMIC_ENVIRON == NULL || COSMIC_ENVIRON[0] == NULL) &&
         descriptor_kind(0) == S_IFIFO && descriptor_kind(1) == S_IFIFO &&
         descriptor_kind(2) == S_IFIFO;
}

/* The sandbox's init, as [`start_init`] executes this program: pid 1 of
 * an unveiled child's pid namespace, which ends, and every process left
 * in it with it, when it does. It starts a session of its own, so the
 * autogroup a process in the sandbox could set through /proc/1 is not
 * its parent's session's; makes itself undumpable, so no process in the
 * sandbox, which has its user, can ptrace it; and ends when its parent
 * does (PR_SET_PDEATHSIG), so the parent's end -- a runner ended by
 * Ctrl-C, or killed -- ends the sandbox too: it holds the parent's
 * status pipe on 2, which the parent reads from until the program has
 * started, so a parent already gone by the time the signal is set is
 * seen there, as a pipe with no reader. It says so -- 0, or an errno --
 * on 1; then it waits for 0 to end, which it does once the program has
 * exec'd or failed to, and for the program, pid 2, to end, reaping
 * meanwhile every process the namespace orphans. Every signal stays
 * blocked, as it started: pid 1 takes none it does not catch from its
 * own namespace, and from outside it only SIGKILL and SIGSTOP. */
_Noreturn void cosmic_sandbox_init (void) {
  sigset_t every;
  sigfillset(&every);
  int failure = 0;
  if (sigprocmask(SIG_SETMASK, &every, NULL) != 0) failure = errno;
  if (!failure && setsid() < 0) failure = errno;
  if (!failure && prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) failure = errno;
  if (!failure && prctl(PR_SET_NAME, COSMIC_SANDBOX_INIT_COMM, 0, 0, 0) != 0) failure = errno;
  if (!failure && prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) failure = errno;
  if (!failure) {
    struct pollfd parent = { 2, POLLOUT, 0 };
    if (poll(&parent, 1, 0) < 0) failure = errno;
    else if (parent.revents & (POLLERR | POLLHUP)) _exit(127);
  }
  close(2);
  /* The kernel's own signal set, one bit per signal: SIGCHLD alone. */
  uint64_t chld = (uint64_t)1 << (SIGCHLD - 1);
  int children = -1;
  if (!failure) {
    children = (int)syscall(SYS_signalfd4, -1, &chld, sizeof chld, O_CLOEXEC);
    if (children < 0) failure = errno;
  }
  report_child_error(1, failure);
  close(1);
  if (failure) _exit(127);
  char byte;
  for (;;) {
    ssize_t got = read(0, &byte, 1);
    if (got == 0 || (got < 0 && errno != EINTR)) break;
  }
  close(0);
  int program = (int)syscall(SYS_pidfd_open, 2, 0);
  if (program < 0 && errno == ESRCH) _exit(0);
  /* Where a filter refuses pidfd_open, the program is looked for every
   * tenth of a second instead: it is there, a zombie too, until the
   * parent reaps it. */
  struct pollfd waiting[2] = { { program, POLLIN, 0 }, { children, POLLIN, 0 } };
  for (;;) {
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    if (program < 0 && kill(2, 0) != 0 && errno == ESRCH) _exit(0);
    if (poll(waiting, 2, program < 0 ? 100 : -1) < 0 && errno != EINTR) _exit(127);
    if (waiting[0].revents != 0) _exit(0);
    if (waiting[1].revents != 0) {
      char info[128];
      if (read(children, info, sizeof info) < 0 && errno != EINTR) _exit(127);
    }
  }
}
#endif

#if !defined(__linux__)
/* Darwin's start ([`start_child`]): posix_spawn, given as its attributes
 * and file actions what Linux's child does itself before exec
 * ([`spawn_child`]), less the sandbox Darwin has none of -- its process
 * group, its directory, its descriptors, the parent's mask, and SIGPIPE
 * at its default where cosmic ignored it; a signal the parent catches
 * the exec itself sets back to its default. Every descriptor not handed
 * on is closed at exec (POSIX_SPAWN_CLOEXEC_DEFAULT): an inherited
 * stdio one is handed on as it is, a closed one staying closed. Each
 * source is copied above `top` first, as Linux's child pins it, so no
 * dup2 overwrites a source a later one reads, and a source that is its
 * own target is moved from a copy, as a dup2 onto itself may leave
 * CLOEXEC set. The kernel takes these steps in the child, which shares nothing
 * of this process's memory, and answers an exec's failure as
 * posix_spawn's own, so the status pipe is never written. The child's
 * pid, or -1 and the errno in `error`. */
static pid_t spawn_program (const struct spawn_plan *plan, int *error) {
  /* Darwin has neither Landlock nor seccomp. */
  if (plan->confine >= 0 || plan->pledged || plan->promising || plan->rlimit_count > 0) {
    *error = ENOSYS;
    return -1;
  }
  /* Given a directory to change to, macOS's posix_spawn can start a
   * program a relative path names and still answer ENOENT, so the path
   * is made absolute first, from where the child resolves it. One longer
   * than PATH_MAX that way is refused, ENAMETOOLONG, though its parts
   * fit; and with a relative directory too, one whose start getcwd
   * cannot name (a directory removed, or one past PATH_MAX) is refused
   * with getcwd's errno, where a child that changed directory first
   * could have run it. */
  const char *path = plan->path;
  char absolute[PATH_MAX];
  if (plan->cwd != NULL && path[0] != '/') {
    char here[PATH_MAX];
    int length = -1;
    if (plan->cwd[0] == '/') {
      length = snprintf(absolute, sizeof absolute, "%s/%s", plan->cwd, path);
    } else if (getcwd(here, sizeof here) == NULL) {
      *error = errno;
      return -1;
    } else {
      length = snprintf(absolute, sizeof absolute, "%s/%s/%s", here, plan->cwd, path);
    }
    if (length < 0 || (size_t)length >= sizeof absolute) {
      *error = ENAMETOOLONG;
      return -1;
    }
    path = absolute;
  }
  int top = plan->top;
  int pinned[CHILD_FD_MAX + 1];
  int failure = 0;
  for (int t = 0; t <= top; t++) {
    pinned[t] = -1;
    if (!failure && plan->source[t] >= 0) {
      pinned[t] = fcntl(plan->source[t], F_DUPFD_CLOEXEC, top + 2);
      if (pinned[t] < 0) failure = errno;
    }
  }
  pid_t pid = -1;
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  if (!failure) failure = posix_spawn_file_actions_init(&actions);
  if (!failure) {
    failure = posix_spawnattr_init(&attributes);
    if (!failure) {
      int flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK;
      if (plan->process_group) flags |= POSIX_SPAWN_SETPGROUP;
      if (sigpipe_ignored_here) flags |= POSIX_SPAWN_SETSIGDEF;
      sigset_t defaults;
      sigemptyset(&defaults);
      sigaddset(&defaults, SIGPIPE);
      failure = posix_spawnattr_setflags(&attributes, (short)flags);
      if (!failure) failure = posix_spawnattr_setsigmask(&attributes, &plan->mask);
      if (!failure) failure = posix_spawnattr_setsigdefault(&attributes, &defaults);
      /* TODO: posix_spawn_file_actions_addchdir, which macOS 26 adds and
       * deprecates this for, once the build's macOS deployment target
       * is 26 or later. */
      if (!failure && plan->cwd != NULL)
        failure = posix_spawn_file_actions_addchdir_np(&actions, plan->cwd);
      for (int t = 0; !failure && t <= top; t++) {
        if (pinned[t] >= 0) {
          /* Apple's libc refuses a copy at OPEN_MAX (10240) or past it,
           * EBADF: one lands there only where every number from `top` + 2
           * to it is open, under a soft limit set past 10240. */
          failure = posix_spawn_file_actions_adddup2(&actions, pinned[t], t);
        } else if (t < 3) {
          if (fcntl(t, F_GETFD) >= 0) failure = posix_spawn_file_actions_addinherit_np(&actions, t);
          else if (errno != EBADF) failure = errno;
        }
      }
      /* posix_spawn has no step for a limit: the child inherits this
       * process's, lowered for the call alone, across which this one
       * thread opens nothing. The kernel's dup2 refuses a target at or
       * past the child's limit, so where the user's is no higher than
       * `top` the child's is `top` + 1, the least that holds what it is
       * handed -- and a child that is this program records that as the
       * limit it started with, which its own host programs get, not the
       * user's: the user's would refuse it the descriptor it is handed.
       * A raise back that is refused leaves this process at the lowered
       * limit, which its children then get as it is. */
      if (!failure) {
        struct rlimit raised;
        bool lowered = getrlimit(RLIMIT_NOFILE, &raised) == 0 &&
                       restore_descriptor_limit((rlim_t)top + 1);
        failure = posix_spawn(&pid, path, &actions, &attributes, plan->argv, plan->envp);
        if (lowered && setrlimit(RLIMIT_NOFILE, &raised) != 0) descriptor_limit_raised = false;
      }
      posix_spawnattr_destroy(&attributes);
    }
    posix_spawn_file_actions_destroy(&actions);
  }
  for (int t = 0; t <= top; t++) {
    if (pinned[t] >= 0) close(pinned[t]);
  }
  if (failure) {
    *error = failure;
    return -1;
  }
  return pid;
}
#endif

/* The stack a Linux child runs [`spawn_child`] on, above a guard page:
 * the most it needs is [`build_root`]'s paths and a libc's formatting, well
 * under this, and only the pages it touches are ever made. */
#define SPAWN_STACK_SIZE (256 * 1024)

/* Starts the child `plan` describes, with every signal blocked across
 * its start, so no handler of the parent's runs in the child, which
 * shares its memory on Linux: the child's pid, or -1 and the errno in
 * `error`.
 * Not fork, whose copy of a large parent's page tables costs more than
 * the rest of a start together (4.4 ms of the test runner's 8.2 ms per
 * test at 150 MB). On Linux, clone(CLONE_VM | CLONE_VFORK): not
 * posix_spawn, which has no step for a namespace, a pivoted root,
 * Landlock or a seccomp filter, and not vfork: the child runs on a
 * stack of its own, so nothing it calls can overwrite a frame the
 * parent returns to, and the static analyzer has no vfork to refuse.
 * On Darwin, which has no sandbox to set up, posix_spawn
 * ([`spawn_program`]), which covers every step a child takes there.
 * Every signal is blocked across the whole start, not only its first
 * steps, so a child hung in setup -- a chdir or an unveiled path on a
 * FUSE or NFS mount that stopped answering -- holds a SIGTERM sent it
 * pending for as long as it hangs, and only SIGKILL ends it. */
static pid_t start_child (struct spawn_plan *plan, int *error) {
  sigset_t every;
  sigfillset(&every);
  if (sigprocmask(SIG_SETMASK, &every, &plan->mask) != 0) {
    *error = errno;
    return -1;
  }
  pid_t pid = -1;
#if defined(__linux__)
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) page = 4096;
  /* One stack, or, for an unveiled child, three: its own, its init's and
   * its program's ([`start_unveiled`]) -- and a fourth for the process
   * that maps one that gives root up ([`map_from_outside`]) -- each above a
   * guard page of its own. */
  size_t each = SPAWN_STACK_SIZE + (size_t)page;
  int stacks = plan->unveiling ? (plan->dropping ? 4 : 3) : 1;
  size_t size = each * (size_t)stacks;
  char *stack = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  int guarded = stack != MAP_FAILED;
  for (int s = 0; guarded && s < stacks; s++) {
    guarded = mprotect(stack + each * (size_t)s, (size_t)page, PROT_NONE) == 0;
  }
  if (stack == MAP_FAILED) {
    *error = errno;
  } else if (!guarded) {
    *error = errno;
    munmap(stack, size);
  } else {
    if (plan->unveiling) {
      plan->init_stack = stack + each * 2;
      plan->program_stack = stack + each * 3;
      if (plan->dropping) plan->helper_stack = stack + each * 4;
    }
    pid = clone(spawn_child, stack + each, CLONE_VM | CLONE_VFORK | SIGCHLD, plan);
    if (pid < 0) *error = errno;
    /* The child has exec'd or ended, and an unveiled one has waited for
     * its init's exec and its program's: every stack is done with. */
    munmap(stack, size);
  }
#else
  pid = spawn_program(plan, error);
#endif
  sigprocmask(SIG_SETMASK, &plan->mask, NULL);
  return pid;
}

#if defined(__linux__)
/* An unveiled child's init and program, each this process's own child
 * ([`start_unveiled`]), until the init is reaped: `program` is -1 once the
 * program has been, and `init` once the init has. */
struct sandbox_pair {
  pid_t init;
  pid_t program;
};

/* Every such pair this process has not seen the end of, in `pairs`,
 * `pair_count` of them in room for `pair_room`. Room is made before a
 * child starts ([`sandbox_room`]), so recording one never fails. */
static struct sandbox_pair *pairs;
static size_t pair_count, pair_room;

/* Room for one more pair: true, or false with errno ENOMEM. */
static bool sandbox_room (void) {
  if (pair_count < pair_room) return true;
  size_t room = pair_room == 0 ? 16 : pair_room * 2;
  struct sandbox_pair *grown = realloc(pairs, room * sizeof *grown);
  if (grown == NULL) {
    errno = ENOMEM;
    return false;
  }
  pairs = grown;
  pair_room = room;
  return true;
}

/* Reaps the init of the pair at `at`, whose program is gone, waiting at
 * most a second: it is sent SIGKILL -- its pid is still its own, not
 * reaped -- which ends every process left in its namespace before the
 * init itself ends, so once it is reaped nothing of the sandbox runs. A
 * pair whose init is reaped is forgotten; one whose init outlasts the
 * second -- a process in the namespace the kernel cannot end, stuck in
 * an uninterruptible wait -- is kept, for [`end_sandbox_inits`] to reap
 * later. */
static void end_sandbox_init (size_t at) {
  pid_t init = pairs[at].init;
  pairs[at].program = -1;
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  int64_t deadline = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec + 1000000000;
  /* Its end is waited for on a pidfd where the kernel gives one, and
   * looked for every tenth of a millisecond where not, until the second
   * is up, however often a signal breaks the wait. */
  int watched = (int)syscall(SYS_pidfd_open, init, 0);
  kill(init, SIGKILL);
  for (;;) {
    int ignored;
    pid_t answer = waitpid(init, &ignored, WNOHANG);
    if (answer == init || (answer < 0 && errno == ECHILD)) {
      pairs[at] = pairs[--pair_count];
      break;
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t left = deadline - ((int64_t)now.tv_sec * 1000000000 + now.tv_nsec);
    if (left <= 0) break;
    if (watched >= 0) {
      struct pollfd ended = { watched, POLLIN, 0 };
      int milliseconds = (int)((left + 999999) / 1000000);
      if (poll(&ended, 1, milliseconds) < 0 && errno != EINTR) break;
    } else {
      struct timespec pause = { 0, left < 100000 ? (long)left : 100000 };
      nanosleep(&pause, NULL);
    }
  }
  if (watched >= 0) close(watched);
}

/* Reaps, without waiting, every init whose program is gone and that a
 * second was not enough for ([`end_sandbox_init`]). */
static void end_sandbox_inits (void) {
  for (size_t at = 0; at < pair_count;) {
    int ignored;
    if (pairs[at].program < 0 && waitpid(pairs[at].init, &ignored, WNOHANG) != 0) {
      pairs[at] = pairs[--pair_count];
    } else {
      at++;
    }
  }
}

/* What a wait that reaped `pid` means for the pairs: a program's reaping
 * ends its init ([`end_sandbox_init`]), and an init's forgets its pair. */
static void sandbox_reaped (pid_t pid) {
  for (size_t at = 0; at < pair_count; at++) {
    if (pairs[at].program == pid) {
      end_sandbox_init(at);
      return;
    }
    if (pairs[at].init == pid) {
      pairs[at] = pairs[--pair_count];
      return;
    }
  }
}
#endif

COSMIC_SYSCALL(sandbox_inits, 0) {
#if defined(__linux__)
  if (pair_count > (size_t)INT_MAX) return luaL_error(L, "too many sandboxes");
  lua_createtable(L, (int)pair_count, 0);
  for (size_t at = 0; at < pair_count; at++) {
    lua_pushinteger(L, (lua_Integer)pairs[at].init);
    lua_rawseti(L, -2, (lua_Integer)at + 1);
  }
#else
  lua_newtable(L);
#endif
  return 1;
}

/* `spawn`'s standard stream argument `arg`: the descriptor the child
 * has in that stream's place, or -1 to inherit it. */
static int stream_source (lua_State *L, int arg) {
  if (lua_isnoneornil(L, arg)) return -1;
  if (!lua_isinteger(L, arg))
    return luaL_argerror(L, arg, "descriptor must be an integer");
  lua_Integer value = lua_tointeger(L, arg);
  if (value < 0 || value > INT_MAX)
    return luaL_argerror(L, arg, "descriptor is out of range");
  cosmic_argfd(L, arg, value);
  return (int)value;
}

/* Whether `spawn`'s descriptor map hands the artifact descriptor on as
 * [`Proc.relaunch`] does: the retained descriptor, as the descriptor the
 * child's environment (argument 3) names its artifact's, from a process
 * that can still run its own core. A child that is this core -- started
 * directly, through a `#!` line naming it, or through a program that
 * runs it (`setsid`) -- adopts it as its own artifact and refuses it to
 * its Lua in turn (core/check.h's `cosmic_checkfd`). Any other program
 * could read the database through it; the hand-on cannot tell which
 * runs, so it holds only where running this program is allowed at all,
 * and so what it carries is a declared input (a `tool`'s): a process
 * held from running its core (`artifact_kept`) is refused it, and so is
 * a map that hands it on as anything but the child's artifact. */
static bool handed_on (lua_State *L, lua_Integer target, lua_Integer fd) {
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact_kept || artifact == NULL || fd != (lua_Integer)artifact->fd ||
      artifact->host || !lua_istable(L, 3))
    return false;
  lua_getfield(L, 3, COSMIC_PORTABLE_ENV_ARTIFACT_FD);
  int exact = 0;
  lua_Integer named = lua_type(L, -1) == LUA_TSTRING ? lua_tointegerx(L, -1, &exact) : 0;
  lua_pop(L, 1);
  return exact && named == target;
}

/* The most grants one `spawn` takes: UNVEIL_MAX's bound on the paths a
 * sandbox names, and, with their letters, about 3 KB of its frame -- a
 * frame that already holds several times that, so these arrays are not
 * worth an allocation a failure path would have to free. No caller
 * grants more than a few dozen. */
#define GRANT_MAX UNVEIL_MAX

#if defined(__linux__)
#ifndef LANDLOCK_ACCESS_FS_RESOLVE_UNIX
#define LANDLOCK_ACCESS_FS_RESOLVE_UNIX (1ULL << 16)
#endif
#define LANDLOCK_ABI_RESOLVE_UNIX 9
/* The headers this core builds with may predate these (ABI 4 and 6). */
#ifndef LANDLOCK_ACCESS_NET_BIND_TCP
#define LANDLOCK_ACCESS_NET_BIND_TCP (1ULL << 0)
#define LANDLOCK_ACCESS_NET_CONNECT_TCP (1ULL << 1)
#endif
#ifndef LANDLOCK_SCOPE_SIGNAL
#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif

/* `struct landlock_ruleset_attr` as the newest kernel has it, so a
 * header older than a field does not leave it out; a kernel older than
 * a field is handed the struct only up to the one it knows. */
struct grants_attr {
  uint64_t handled_access_fs;
  uint64_t handled_access_net;
  uint64_t scoped;
};

/* What the letters allow beneath a path on a kernel of this ABI. A right
 * the ABI lacks is left out, which the ruleset does not handle either.
 * `c` takes no device: LANDLOCK_ACCESS_FS_MAKE_CHAR and _BLOCK are
 * handled and never granted, so a sandboxed program makes no device
 * node, and a device file's ioctls (LANDLOCK_ACCESS_FS_IOCTL_DEV) are
 * refused too, whatever `w` allows of the file. */
static uint64_t grant_rights (unsigned letters, long abi) {
  uint64_t rights = 0;
  if (letters & GRANT_READ) rights |= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
  if (letters & GRANT_WRITE) {
    rights |= LANDLOCK_ACCESS_FS_WRITE_FILE;
    if (abi >= 3) rights |= LANDLOCK_ACCESS_FS_TRUNCATE;
  }
  if (letters & GRANT_EXECUTE) rights |= LANDLOCK_ACCESS_FS_EXECUTE;
  if (letters & GRANT_CREATE) {
    rights |= LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_DIR |
              LANDLOCK_ACCESS_FS_MAKE_SYM | LANDLOCK_ACCESS_FS_MAKE_SOCK |
              LANDLOCK_ACCESS_FS_MAKE_FIFO | LANDLOCK_ACCESS_FS_REMOVE_FILE |
              LANDLOCK_ACCESS_FS_REMOVE_DIR;
    if (abi >= 2) rights |= LANDLOCK_ACCESS_FS_REFER;
  }
  if ((letters & GRANT_UNIX) && abi >= LANDLOCK_ABI_RESOLVE_UNIX)
    rights |= LANDLOCK_ACCESS_FS_RESOLVE_UNIX;
  return rights;
}

/* Every filesystem right a kernel of this ABI knows, up to ABI 9's.
 * TODO: a kernel past ABI 9 has rights this does not handle, so a ruleset
 * built here leaves them allowed: add each as the ABI that brings it is
 * met (refusing a start on a newer kernel instead would break every new
 * one).
 * TODO: share this and the scoping below with `landlock_ruleset`, whose
 * rights stop at ABI 5 and whose scoping this build's headers may leave
 * out, once its callers can take a ruleset that refuses unix sockets by
 * path and signals out of the domain: today that would change what they
 * run under. */
static uint64_t grants_handled (long abi) {
  uint64_t handled = (LANDLOCK_ACCESS_FS_MAKE_SYM << 1) - 1;
  if (abi >= 2) handled |= LANDLOCK_ACCESS_FS_REFER;
  if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (abi >= 5) handled |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
  if (abi >= LANDLOCK_ABI_RESOLVE_UNIX) handled |= LANDLOCK_ACCESS_FS_RESOLVE_UNIX;
  return handled;
}

/* Whether the kernel closes a range of descriptors, as [`close_child_descriptors`]
 * does before it falls back on a loop up to the soft limit, which leaves
 * open a descriptor above it: one the child inherited that opens a directory
 * would then stay, so a root is shown to hold no directory only where this holds. */
static bool close_range_works (void) {
#if defined(SYS_close_range)
  return syscall(SYS_close_range, ~0u, ~0u, 0u) == 0;
#else
  return false;
#endif
}

/* Whether the root a strict start builds from the `count` paths `resolved`
 * (each placed at `at`, or at its own name where that is NULL) shows no
 * directory and no socket file of the host's, and no descriptor the child
 * is handed leads to one: the facts a unix socket is harmless on where no
 * Landlock ABI tells one socket file from another ([`grants_ruleset`]), or
 * no ruleset holds the start at all (`nest`, in spawn).
 * What it shows is its own tmpfs (the root, and /tmp), a procfs of its own
 * pid namespace ([`place_proc`]), and the paths bound: each a file that is
 * not a socket, which a bind shows alone. A directory bound -- /dev, a
 * parent of a socket -- shows whatever a host process put in it, and the
 * /proc of the host, which strict never binds, shows the host's
 * processes' roots.
 * A descriptor handed leads to a directory when it is one, and to a socket
 * file when it was opened O_PATH: /proc/self/fd/N then opens what is
 * beneath it, or connects to it. `source` and `top` are the plan's: the
 * descriptor each of 0 to `top` is, or -1 for the parent's own where
 * that is 0 to 2 and closed above. Each is read through the descriptor the
 * parent holds, which is the child's, not by a name.
 * The paths are read by name here, and again by [`build_root`] once the
 * child binds them, which fails the start for one that is a directory or
 * a socket by then; so this decides, and the child enforces. */
static bool root_shows_no_socket (char *const *resolved, const char *const *at, int count,
                                  const int *source, int top) {
  for (int i = 0; i < count; i++) {
    /* The root's own /proc replaces this one. */
    if (at[i] == NULL && strcmp(resolved[i], "/proc") == 0) continue;
    struct stat st;
    if (stat(resolved[i], &st) != 0 || S_ISDIR(st.st_mode) || S_ISSOCK(st.st_mode)) return false;
  }
  for (int t = 0; t <= top; t++) {
    int fd = source[t] >= 0 ? source[t] : (t < 3 ? t : -1);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) continue;
    int flags = fcntl(fd, F_GETFL);
    if (S_ISDIR(st.st_mode) || (flags >= 0 && (flags & O_PATH) != 0)) return false;
  }
  return true;
}

/* A Landlock ruleset holding a child to `count` grants, as a descriptor,
 * or -1 with the errno in `error` and what to tell the caller in
 * `message`, which names the path or the remedy. `held` is what the
 * ruleset holds that the promises filter relies on (core/promises.h's
 * COSMIC_HELD_ bits): the signal scope (ABI 6), and, where `unix_bound` (a
 * root of the child's own that shows only its grants) and `offline` (a
 * network namespace of its own) too, that a unix socket file is
 * reached only by a `u` grant (ABI 9), or, below it, that the root shows
 * no socket file at all (`unix_tmp`, [`root_shows_no_socket`]).
 *
 * The ruleset handles every filesystem right the kernel's ABI knows, up
 * to ABI 9 ([`grants_handled`]), so what no grant gives is refused: EACCES, and EXDEV for a rename or link
 * between grants that REFER does not allow. Beyond the filesystem it
 * scopes the child where the kernel can: no abstract unix socket and no
 * signal reaches a process outside its domain (ABI 6), and TCP is
 * handled with no rule, so a bind or a connect is refused (ABI 4) --
 * unless `inet`, a child in a network namespace of its own with a
 * loopback it is to use, whose namespace is the hold instead.
 * Below those ABIs the ruleset holds what the kernel's does, and the
 * start does not fail for the rest, except a `u` grant, whose right
 * (ABI 9) nothing else stands in for -- unless `unix_bound`, where the
 * socket is bound into a root of the child's own, which holds no other.
 * TODO: refuse where the kernel's ABI leaves out a right a grant's
 * letters or the scoping rely on, once a policy can ask for a start that
 * must be held whole (`isolate file` and a network namespace stand in
 * for the rights an older kernel lacks): [`cosmic.sandbox`]'s preflight.
 *
 * Each path is opened once, followed through links, with O_PATH, and its
 * rule is added from that descriptor, so the rule is on the file the
 * path named at that moment and a link swapped in later changes nothing.
 * A path that cannot be opened fails the start. A file takes only the
 * rights Landlock allows on one (a directory-only right is EINVAL
 * there); a grant whose letters leave nothing for a file -- `c` on one
 * -- adds no rule.
 *
 * Built here, in the parent, not in the child: the child shares this
 * process's memory (clone with CLONE_VM) and tells the parent only an
 * errno, so a path that does not exist could not be named from it, and
 * an unveiled child resolves paths in a root of its own. It is handed
 * on as the descriptor `ruleset` takes, restricted by the child in
 * [`run_program`] before the promises filter, which follows it.
 * TODO: report a grant whose target (the path of its descriptor, read
 * from /proc/self/fd) differs from its name, once `spawn` can answer the
 * resolutions it made beside the pid and [`cosmic.child`]'s policy start
 * (held_to in cosmic/child.tl) hands them to the caller on the Handle: it
 * prints nothing about grants, and `spawn` answers a pid alone. */
static int grants_ruleset (const char *const *paths, const unsigned *letters, int count,
                           int inet, int unix_bound, int offline, int unix_tmp, char *message,
                           size_t room, int *error, unsigned *held) {
  *held = 0;
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) {
    *error = abi < 0 ? errno : ENOSYS;
    snprintf(message, room,
             "Landlock is not available here (%s): the kernel needs CONFIG_SECURITY_LANDLOCK and "
             "\"landlock\" among its lsm= boot parameter, and a container's seccomp profile must "
             "allow landlock_create_ruleset",
             cosmic_errno_describe(*error, NULL));
    return -1;
  }
  for (int i = 0; i < count; i++) {
    if ((letters[i] & GRANT_UNIX) && abi < LANDLOCK_ABI_RESOLVE_UNIX && !unix_bound) {
      *error = EOPNOTSUPP;
      snprintf(message, room,
               "Landlock ABI %d is needed for a `u` grant (%s); this kernel gives %ld: run a "
               "kernel that does, or give no grant to a unix socket by path",
               LANDLOCK_ABI_RESOLVE_UNIX, paths[i], abi);
      return -1;
    }
  }
  struct grants_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.handled_access_fs = grants_handled(abi);
  size_t size = sizeof attr.handled_access_fs;
  if (abi >= 4 && !inet) {
    attr.handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP;
    size = offsetof(struct grants_attr, handled_access_net) + sizeof attr.handled_access_net;
  }
  if (abi >= 6) {
    attr.scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET | LANDLOCK_SCOPE_SIGNAL;
    size = offsetof(struct grants_attr, scoped) + sizeof attr.scoped;
  }
  if ((attr.scoped & LANDLOCK_SCOPE_SIGNAL) != 0) *held |= COSMIC_HELD_SIGNALS;
  /* socket(AF_UNIX) is let through (COSMIC_HELD_UNIX) where nothing the process
   * can reach by a path is a socket it was not given. Two holds do it:
   *
   * - From ABI 9, Landlock refuses a connect to a socket file no `u` grant
   *   names, whatever the root shows ([`grants_handled`]).
   * - Below it, nothing does: Landlock does not govern a connect to a
   *   pathname socket, which asks only write permission on the file, so
   *   a read-only bind does not stop it, and a network namespace does not
   *   scope pathname sockets. The root alone holds, where it shows no
   *   socket file but the ones the process makes itself (`unix_tmp`: no
   *   directory bound, no socket file bound, no descriptor handed that
   *   opens either): its own tmpfs holds only what the process made, since
   *   a mount that lives in the child's mount namespace alone is one no
   *   host process can put a socket in by any name it can reach; a file
   *   bound shows that file alone; its procfs is its pid namespace's, so
   *   /proc/N/root is the sandbox's own root, and /proc/self/fd/N its own
   *   descriptors. Its mounts are private ([`build_root`]), and the host's
   *   is detached from it by pivot_root, which no process the sandbox has
   *   keeps open: a descriptor handed is checked (above), the rest are
   *   closed.
   *
   * Both need `unix_bound` (a root of its own, not the host's: strict and
   * unveiling, not `proc` alone) and `offline`, a network namespace of its
   * own, which holds the abstract sockets (below ABI 6 nothing else does:
   * an abstract name is the network namespace's, so a host client's is not
   * there to connect to, nor does one the process binds reach a host
   * client; from ABI 6 Landlock's scope refuses them too). The bit is set
   * only from what this start has made and checked, never from what the
   * caller says: `unix_tmp` is read from the descriptors and paths the
   * start holds, and the child enforces it, failing the start where a
   * path it binds is a directory or a socket by the time it does
   * ([`build_root`]).
   * Left out, below ABI 9: a directory of the host bound into the root,
   * which may hold a socket a host service put there (and a `u` grant
   * beside one, which [`cosmic.child`] refuses).
   * TODO: let a root that binds a directory of the host make a unix socket
   * without a `u` grant below Landlock ABI 9, once the kernels the suite
   * runs on give ABI 9: below it nothing tells one socket file of a
   * bound directory from another, so a
   * program that connected to one a host service put there would reach it. */
  if (unix_bound && offline && (abi >= LANDLOCK_ABI_RESOLVE_UNIX || unix_tmp))
    *held |= COSMIC_HELD_UNIX;
  long made = syscall(SYS_landlock_create_ruleset, &attr, size, 0);
  if (made < 0) {
    *error = errno;
    snprintf(message, room, "landlock_create_ruleset: %s", cosmic_errno_describe(*error, NULL));
    return -1;
  }
  int ruleset = (int)made;
  for (int i = 0; i < count; i++) {
    int fd = open(paths[i], O_PATH | O_CLOEXEC);
    struct stat st;
    int number = 0;
    if (fd < 0 || fstat(fd, &st) != 0) {
      number = errno;
    } else {
      uint64_t rights = grant_rights(letters[i], abi);
      if (!S_ISDIR(st.st_mode)) rights &= LANDLOCK_FILE_ACCESS | LANDLOCK_ACCESS_FS_RESOLVE_UNIX;
      struct landlock_path_beneath_attr beneath = { .allowed_access = rights, .parent_fd = fd };
      if (rights != 0 &&
          syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0)
        number = errno;
    }
    if (fd >= 0) close(fd);
    if (number != 0) {
      close(ruleset);
      *error = number;
      snprintf(message, room, "grant %s: %s", paths[i], cosmic_errno_describe(number, NULL));
      return -1;
    }
  }
  return ruleset;
}
#endif

/* The promises the list at stack index `list` names, as COSMIC_PROMISE_
 * bits: a name that is none is an error of argument `arg`. */
static unsigned read_promises (lua_State *L, int list, int arg) {
  unsigned bits = 0;
  lua_Integer promised = (lua_Integer)lua_rawlen(L, list);
  for (lua_Integer i = 1; i <= promised; i++) {
    lua_rawgeti(L, list, i);
    unsigned bit = lua_type(L, -1) == LUA_TSTRING ? cosmic_promise_named(lua_tostring(L, -1)) : 0;
    if (bit == 0) luaL_argerror(L, arg, "a promise is \"fork\", \"jit\", \"fattr\" or \"nest\"");
    bits |= bit;
    lua_pop(L, 1);
  }
  return bits;
}

/* The limits the table at stack index `table` names, by `RLIMIT_NAMES`,
 * into `into`, which holds SPAWN_RLIMIT_MAX: how many. */
static int read_rlimits (lua_State *L, int table, int arg, struct spawn_rlimit *into) {
  int count = 0;
  lua_pushnil(L);
  while (lua_next(L, table) != 0) {
    const char *name = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : "";
    int resource = -1;
    for (size_t n = 0; n < sizeof RLIMIT_NAMES / sizeof RLIMIT_NAMES[0]; n++) {
      if (strcmp(name, RLIMIT_NAMES[n].name) == 0) resource = RLIMIT_NAMES[n].resource;
    }
    if (resource < 0)
      luaL_argerror(L, arg, "an rlimit is \"nofile\", \"fsize\", \"cpu\", \"core\" or \"nproc\"");
    if (!lua_isinteger(L, -1)) luaL_argerror(L, arg, "an rlimit is an integer");
    into[count].resource = resource;
    if (lua_tointeger(L, -1) < 0) luaL_argerror(L, arg, "an rlimit is not negative");
    into[count].value = check_limit(L, -1);
    count++;
    lua_pop(L, 1);
  }
  return count;
}

/* The grants the list at stack index `list` holds, as paths and letter
 * sets, into arrays of GRANT_MAX: how many. The strings stay alive in the
 * list, which the caller keeps on the stack. */
static int read_grants (lua_State *L, int list, int arg, const char **paths, unsigned *letters) {
  int count = 0;
  lua_Integer granted_count = (lua_Integer)lua_rawlen(L, list);
  for (lua_Integer i = 1; i <= granted_count; i++) {
    if (count >= GRANT_MAX) luaL_argerror(L, arg, "too many grants");
    lua_rawgeti(L, list, i);
    if (!lua_istable(L, -1)) luaL_argerror(L, arg, "a grant is a table of path and access");
    lua_pushliteral(L, "path");
    lua_rawget(L, -2);
    const char *grant_path = plain_string(L, -1, "a grant's path");
    if (grant_path[0] == '\0') luaL_argerror(L, arg, "a grant's path is empty");
    lua_pushliteral(L, "access");
    lua_rawget(L, -3);
    const char *access = plain_string(L, -1, "a grant's access");
    static const char order[] = "rwxcu";
    unsigned held = 0;
    for (const char *c = access; *c != '\0'; c++) {
      const char *at = strchr(order, *c);
      if (at == NULL) luaL_argerror(L, arg, "a grant's access is letters of \"rwxcu\"");
      else held |= 1u << (at - order);
    }
    if (held == 0) luaL_argerror(L, arg, "a grant's access names no letter of \"rwxcu\"");
    paths[count] = grant_path;
    letters[count] = held;
    count++;
    lua_pop(L, 3);
  }
  return count;
}

/* The most descriptors `restrict_self` is told to keep. */
#define RESTRICT_KEEP_MAX 256

#if defined(__linux__)

/* Answers `restrict_self`'s refusal: false, `what` formatted, and `number`. */
static int restrict_refused (lua_State *L, int number, const char *format, ...)
    __attribute__((format(printf, 3, 4)));
static int restrict_refused (lua_State *L, int number, const char *format, ...) {
  char message[PATH_MAX + 256];
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(message, sizeof message, format, arguments);
  va_end(arguments);
  lua_pushboolean(L, 0);
  lua_pushstring(L, message);
  lua_pushinteger(L, number);
  return 3;
}

/* The directories and file of this process's /proc a restriction reads,
 * held open from the first one: once Landlock holds the process, a path
 * of /proc is refused it, and a restriction made again must still count
 * the threads, descriptors and children it holds to. They are opened
 * before anything is restricted and read through descriptors, which
 * Landlock checks at open only. `pid` is the process they were opened by:
 * a copy a fork gave another process names its parent's /proc, and is
 * closed, to open afresh where /proc can still be read. Close-on-exec
 * and never listed as a descriptor the program holds
 * ([`unaccounted_descriptor`]). */
static struct {
  pid_t pid;
  int tasks;
  int descriptors;
  int children;
  /* What each descriptor named when it was opened, to tell it from a
   * file the program closed it for and opened in its number. */
  struct stat identity[3];
} inspected = { 0, -1, -1, -1, { { 0 } } };

static void inspected_close (void) {
  if (inspected.tasks >= 0) close(inspected.tasks);
  if (inspected.descriptors >= 0) close(inspected.descriptors);
  if (inspected.children >= 0) close(inspected.children);
  inspected.tasks = inspected.descriptors = inspected.children = -1;
}

/* Whether `fd` still names what `before` recorded: the same file, of the
 * kind a /proc entry is (a directory, or for the children list a regular
 * file) on a procfs, which a file the program put in its number is not. */
static bool inspected_same (int fd, const struct stat *before, bool directory) {
  struct stat now;
  struct statfs system;
  if (fd < 0 || fstat(fd, &now) != 0 || fstatfs(fd, &system) != 0) return false;
  return now.st_dev == before->st_dev && now.st_ino == before->st_ino &&
         (S_ISDIR(now.st_mode) != 0) == directory && (unsigned long)system.f_type == 0x9fa0UL; /* PROC_SUPER_MAGIC */
}

/* Gives up a handle the program replaced, without closing it: the number
 * is the program's now, and the scan of its descriptors counts it. */
static void inspected_forget (int *fd, const struct stat *before, bool directory) {
  if (!inspected_same(*fd, before, directory)) *fd = -1;
}

/* Has the /proc entries to read for this process, as `inspected`: 0, or the
 * errno, with `what` naming the one that could not be opened. A handle the
 * program closed and put another file in the place of is let go and made
 * again, which fails once Landlock holds the process: the restriction then
 * fails closed rather than trust it. */
static int inspected_open (const char **what) {
  pid_t self = getpid();
  if (inspected.pid == self) {
    inspected_forget(&inspected.tasks, &inspected.identity[0], true);
    inspected_forget(&inspected.descriptors, &inspected.identity[1], true);
    inspected_forget(&inspected.children, &inspected.identity[2], false);
    if (inspected.tasks >= 0 && inspected.descriptors >= 0 && inspected.children >= 0) return 0;
    /* What is left of the three is still ours. */
  }
  inspected_close();
  inspected.pid = self;
  *what = "/proc/self/task";
  inspected.tasks = open(*what, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (inspected.tasks >= 0) {
    *what = "/proc/self/fd";
    inspected.descriptors = open(*what, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  }
  if (inspected.descriptors >= 0) {
    *what = "/proc/thread-self/children";
    inspected.children = open(*what, O_RDONLY | O_CLOEXEC);
  }
  int failure = 0;
  if (inspected.children < 0) failure = errno;
  else if (fstat(inspected.tasks, &inspected.identity[0]) != 0 ||
           fstat(inspected.descriptors, &inspected.identity[1]) != 0 ||
           fstat(inspected.children, &inspected.identity[2]) != 0)
    failure = errno;
  if (failure == 0) return 0;
  inspected_close();
  return failure;
}

/* A stream over the directory `directory`, held open, read from its
 * start: its own descriptor is a duplicate, which `closedir` closes. */
static DIR *inspected_listing (int directory) {
  int copy = fcntl(directory, F_DUPFD_CLOEXEC, 3);
  if (copy < 0) return NULL;
  DIR *listing = fdopendir(copy);
  if (listing == NULL) {
    close(copy);
    return NULL;
  }
  rewinddir(listing);
  return listing;
}

/* How many threads this process has, counted from /proc/self/task, or -1
 * with the errno that refused it. A restriction binds the thread that makes
 * it and the threads it starts afterwards, not the ones already running. */
static int thread_count (int *error) {
  DIR *tasks = inspected_listing(inspected.tasks);
  if (tasks == NULL) {
    *error = errno;
    return -1;
  }
  int count = 0;
  struct dirent *entry;
  while ((entry = readdir(tasks)) != NULL) {
    if (entry->d_name[0] >= '0' && entry->d_name[0] <= '9') count++;
  }
  closedir(tasks);
  return count;
}

/* The pid of a child of this thread not yet reaped, or 0 for none, or -1
 * with the errno in `error` where the list cannot be read. The list is
 * read from its start, and its first number is all that is asked. */
static long first_child (int *error) {
  char text[32];
  ssize_t got;
  do { got = pread(inspected.children, text, sizeof text - 1, 0); } while (got < 0 && errno == EINTR);
  if (got < 0) {
    *error = errno;
    return -1;
  }
  text[got] = '\0';
  char *end;
  long pid = strtol(text, &end, 10);
  return end == text ? 0 : pid;
}

/* The first descriptor above 2 that is open, is not one of the `kept`
 * the caller names and is not one the runtime keeps itself
 * (`cosmic_store_holds_descriptor`, and `inspected`), or -1 for none; -2
 * with the errno in `error` where it cannot be listed. The stream's own
 * descriptor is not counted. */
static int unaccounted_descriptor (lua_State *L, const int *kept, int kept_count, int *error) {
  DIR *open_files = inspected_listing(inspected.descriptors);
  if (open_files == NULL) {
    *error = errno;
    return -2;
  }
  int own = dirfd(open_files);
  int found = -1;
  struct dirent *entry;
  while ((entry = readdir(open_files)) != NULL) {
    if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
    long number = strtol(entry->d_name, NULL, 10);
    if (number <= 2 || number > INT_MAX || number == own || number == inspected.tasks ||
        number == inspected.descriptors || number == inspected.children)
      continue;
    bool accounted = false;
    for (int i = 0; i < kept_count; i++) accounted = accounted || kept[i] == number;
    if (accounted || cosmic_store_holds_descriptor(L, (int)number)) continue;
    if (found < 0 || number < found) found = (int)number;
  }
  closedir(open_files);
  return found;
}

/* What lowering `resource`'s limits to at most `value`, soft and hard,
 * needs, never raising either: `target` is the limits as they are to be,
 * and `changes` whether that differs from what they are. 0, or the errno
 * of reading them. Planned before anything is changed, so a restriction
 * that fails later has set no limit. */
static int plan_limit (int resource, rlim_t value, struct rlimit *target, bool *changes) {
  struct rlimit limits;
  if (getrlimit(resource, &limits) != 0) return errno;
  *target = limits;
  if (target->rlim_cur > value) target->rlim_cur = value;
  if (target->rlim_max > value) target->rlim_max = value;
  *changes = target->rlim_cur != limits.rlim_cur || target->rlim_max != limits.rlim_max;
  return 0;
}
#endif

COSMIC_SYSCALL(restrict_self, 2) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int kept[RESTRICT_KEEP_MAX];
  int kept_count = 0;
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_Integer listed = (lua_Integer)lua_rawlen(L, 2);
    for (lua_Integer i = 1; i <= listed; i++) {
      if (kept_count >= RESTRICT_KEEP_MAX) return luaL_argerror(L, 2, "too many descriptors");
      lua_rawgeti(L, 2, i);
      if (!lua_isinteger(L, -1)) return luaL_argerror(L, 2, "a descriptor is an integer");
      lua_Integer fd = lua_tointeger(L, -1);
      if (fd < 0 || fd > INT_MAX) return luaL_argerror(L, 2, "descriptor is out of range");
      cosmic_argfd(L, 2, fd);
      kept[kept_count++] = (int)fd;
      lua_pop(L, 1);
    }
  }
  unsigned promise_bits = 0;
  struct spawn_rlimit rlimits[SPAWN_RLIMIT_MAX];
  int rlimit_count = 0;
  const char *grant_paths[GRANT_MAX];
  unsigned grant_letters[GRANT_MAX];
  int grant_count = 0;
  lua_pushliteral(L, "promises");
  lua_rawget(L, 1);
  if (!lua_istable(L, -1)) return luaL_argerror(L, 1, "promises must be a list");
  promise_bits = read_promises(L, lua_gettop(L), 1);
  if (promise_bits & COSMIC_PROMISE_NEST)
    return luaL_argerror(L, 1, "the \"nest\" promise is a child's: it needs a root and pid "
                         "namespace of its own, which a running process is not in");
  lua_pop(L, 1);
  lua_pushliteral(L, "rlimits");
  lua_rawget(L, 1);
  if (!lua_istable(L, -1)) return luaL_argerror(L, 1, "rlimits must be a table");
  rlimit_count = read_rlimits(L, lua_gettop(L), 1, rlimits);
  lua_pop(L, 1);
  lua_pushliteral(L, "grants");
  lua_rawget(L, 1);
  if (!lua_istable(L, -1)) return luaL_argerror(L, 1, "grants must be a list");
  grant_count = read_grants(L, lua_gettop(L), 1, grant_paths, grant_letters);
  /* The grants stay on the stack: their strings are what the paths point at. */
#if defined(__linux__)
  for (int i = 0; i < kept_count; i++) {
    if (fcntl(kept[i], F_GETFD) < 0)
      return restrict_refused(L, errno, "descriptor %d, which fds names, is not open", kept[i]);
  }
  int error = 0;
  const char *unreadable = "";
  error = inspected_open(&unreadable);
  if (error != 0)
    return restrict_refused(L, error, "this process cannot be inspected (%s: %s): a process "
                            "restricted already reads no /proc, and one forked from it "
                            "cannot be counted",
                            unreadable, cosmic_errno_describe(error, NULL));
  long child = first_child(&error);
  if (child < 0)
    return restrict_refused(L, error, "the children of this process cannot be listed "
                            "(/proc/thread-self/children: %s)", cosmic_errno_describe(error, NULL));
  if (child > 0)
    return restrict_refused(L, ECHILD, "this process has a child, pid %ld, not waited for: end "
                            "it and wait for it first, since a restriction holds what a process "
                            "starts after it, not what it started", child);
  /* TODO: give the refusal of a second thread below a test, once the core
   * can start a thread a test may use: no test reaches it today. */
  int threads = thread_count(&error);
  if (threads < 0)
    return restrict_refused(L, error, "the threads of this process cannot be counted "
                            "(/proc/self/task: %s)", cosmic_errno_describe(error, NULL));
  if (threads > 1)
    return restrict_refused(L, EBUSY, "this process has %d threads: a restriction holds the "
                            "thread that makes it, not the others", threads);
  int open_fd = unaccounted_descriptor(L, kept, kept_count, &error);
  if (open_fd == -2)
    return restrict_refused(L, error, "the descriptors of this process cannot be listed "
                            "(/proc/self/fd: %s)", cosmic_errno_describe(error, NULL));
  if (open_fd >= 0)
    return restrict_refused(L, EBADF, "descriptor %d is open and not named in fds: close it, or "
                            "name it to keep it", open_fd);
  struct {
    struct rlimit target;
    bool changes;
  } planned[SPAWN_RLIMIT_MAX] = {0};
  for (int i = 0; i < rlimit_count; i++) {
    error = plan_limit(rlimits[i].resource, rlimits[i].value, &planned[i].target,
                       &planned[i].changes);
    if (error != 0)
      return restrict_refused(L, error, "getrlimit: %s", cosmic_errno_describe(error, NULL));
  }
  char message[PATH_MAX + 512];
  unsigned held = 0;
  int ruleset = grants_ruleset(grant_paths, grant_letters, grant_count, 0, 0, 0, 0, message,
                               sizeof message, &error, &held);
  if (ruleset < 0) return restrict_refused(L, error, "%s", message);
  /* Limits first, since the filter refuses setrlimit. A limit that is
   * already at least as low asks for no call, so a restriction repeated
   * with the limits it first set passes under the filter it made. */
  bool nofile_moved = false;
  bool limits_moved = false;
  static const char partly[] = "; the process is now partly restricted";
  for (int i = 0; i < rlimit_count; i++) {
    if (!planned[i].changes) continue;
    if (setrlimit(rlimits[i].resource, &planned[i].target) != 0) {
      error = errno;
      close(ruleset);
      return restrict_refused(L, error, "setrlimit: %s%s", cosmic_errno_describe(error, NULL),
                              limits_moved ? partly : "");
    }
    limits_moved = true;
    if (rlimits[i].resource == RLIMIT_NOFILE) nofile_moved = true;
  }
  /* A limit the program set is the one its children get. */
  if (nofile_moved) descriptor_limit_raised = false;
  error = enforce_ruleset(ruleset);
  close(ruleset);
  if (error != 0)
    return restrict_refused(L, error, "landlock_restrict_self: %s%s",
                            cosmic_errno_describe(error, NULL), limits_moved ? partly : "");
  /* Last, as in a child: the filter allows Landlock and the filter's own
   * installation, so a later restriction narrows both. */
  error = cosmic_promises_apply(promise_bits, 0, held);
  if (error != 0)
    return restrict_refused(L, error, "seccomp filter: %s%s", cosmic_errno_describe(error, NULL),
                            partly);
  return cosmic_ok(L);
#else
  (void)promise_bits;
  (void)rlimits;
  (void)rlimit_count;
  (void)grant_paths;
  (void)grant_letters;
  (void)grant_count;
  (void)kept;
  (void)kept_count;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(spawn, 11) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  if (!lua_isnoneornil(L, 3)) luaL_checktype(L, 3, LUA_TTABLE);
  const char *cwd = lua_isnoneornil(L, 4) ? NULL : plain_string(L, 4, "cwd");
  /* source[t] is the parent descriptor the child sees as t, or -1: for
   * 0..2 that means inherit, above that it means closed. */
  int source[CHILD_FD_MAX + 1];
  for (int i = 0; i <= CHILD_FD_MAX; i++) source[i] = -1;
  source[0] = stream_source(L, 5);
  source[1] = stream_source(L, 6);
  source[2] = stream_source(L, 7);
  int process_group = lua_toboolean(L, 8);
  int top = 2;
  if (!lua_isnoneornil(L, 9)) {
    luaL_checktype(L, 9, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 9) != 0) {
      if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
        return luaL_argerror(L, 9, "descriptors must map integers to integers");
      lua_Integer target = lua_tointeger(L, -2);
      lua_Integer value = lua_tointeger(L, -1);
      if (target < 3 || target > CHILD_FD_MAX)
        return luaL_argerror(L, 9, "a child descriptor must be 3 to 255");
      if (value < 0 || value > INT_MAX)
        return luaL_argerror(L, 9, "descriptor is out of range");
      if (!handed_on(L, target, value)) cosmic_argfd(L, 9, value);
      source[target] = (int)value;
      if (target > top) top = (int)target;
      lua_pop(L, 1);
    }
  }
  for (int t = 0; t <= top; t++) {
    if (source[t] >= 0 && fcntl(source[t], F_GETFD) < 0)
      return cosmic_fail(L, errno);
  }
  int confine = -1;
  int pledged = 0, unix_ok = 0, inet_ok = 0;
  int promising = 0;
  unsigned promise_bits = 0;
  struct spawn_rlimit rlimits[SPAWN_RLIMIT_MAX];
  int rlimit_count = 0;
  const char *grant_paths[GRANT_MAX];
  unsigned grant_letters[GRANT_MAX];
  int granting = 0, grant_count = 0;
  const char *unveiled[UNVEIL_MAX];
  const char *unveiled_at[UNVEIL_MAX];
  int unveiled_writable[UNVEIL_MAX];
  int unveiling = 0, unveil_count = 0, offline = 0, noexec_scratch = 0;
  int unveiled_noexec[UNVEIL_MAX];
  int unveiled_idmap[UNVEIL_MAX];
  int idmap_fds[UNVEIL_MAX];
  int idmap_failed = -1;
  char idmap_path[PATH_MAX];
  idmap_path[0] = '\0';
  int idmapping = 0;
  int strict = 0, proc_only = 0;
  unsigned sockets = 0;
  unsigned long tmp_bytes = 0;
  int tmp_exec = 0;
  int dropping = 0;
  uid_t drop_uid = 0;
  gid_t drop_gid = 0;
  if (!lua_isnoneornil(L, 10)) {
    luaL_checktype(L, 10, LUA_TTABLE);
    lua_pushliteral(L, "ruleset");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_isinteger(L, -1))
        return luaL_argerror(L, 10, "a ruleset must be a descriptor");
      lua_Integer value = lua_tointeger(L, -1);
      if (value < 0 || value > INT_MAX)
        return luaL_argerror(L, 10, "the ruleset's descriptor is out of range");
      cosmic_argfd(L, 10, value);
      confine = (int)value;
    }
    lua_pop(L, 1);
    if (confine >= 0 && fcntl(confine, F_GETFD) < 0) return cosmic_fail(L, errno);
    lua_pushliteral(L, "pledge");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "a pledge must be a list of promises");
      pledged = 1;
      lua_Integer promises = (lua_Integer)lua_rawlen(L, -1);
      for (lua_Integer i = 1; i <= promises; i++) {
        lua_rawgeti(L, -1, i);
        const char *promise = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
        if (strcmp(promise, "unix") == 0) unix_ok = 1;
        else if (strcmp(promise, "inet") == 0) inet_ok = 1;
        else return luaL_argerror(L, 10, "a promise is \"unix\" or \"inet\"");
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "promises");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "promises must be a list");
      promising = 1;
      promise_bits = read_promises(L, lua_gettop(L), 10);
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "sockets");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "sockets must be a list");
      if (!promising) return luaL_argerror(L, 10, "sockets require promises");
      lua_Integer families = (lua_Integer)lua_rawlen(L, -1);
      for (lua_Integer i = 1; i <= families; i++) {
        lua_rawgeti(L, -1, i);
        const char *family = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
        if (strcmp(family, "unix") == 0) sockets |= COSMIC_SOCKETS_UNIX;
        else if (strcmp(family, "inet") == 0) sockets |= COSMIC_SOCKETS_INET;
        else return luaL_argerror(L, 10, "a socket family is \"unix\" or \"inet\"");
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "strict");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1) && !lua_isboolean(L, -1))
      return luaL_argerror(L, 10, "strict must be a boolean");
    strict = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_pushliteral(L, "proc");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1) && !lua_isboolean(L, -1))
      return luaL_argerror(L, 10, "proc must be a boolean");
    proc_only = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_pushliteral(L, "rlimits");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "rlimits must be a table");
      rlimit_count = read_rlimits(L, lua_gettop(L), 10, rlimits);
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "grants");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "grants must be a list");
      if (confine >= 0) return luaL_argerror(L, 10, "grants and a ruleset exclude each other");
      granting = 1;
      grant_count = read_grants(L, lua_gettop(L), 10, grant_paths, grant_letters);
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "unveil");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "unveil must be a table");
      unveiling = 1;
      for (int w = 0; w < 2; w++) {
        lua_pushstring(L, w == 0 ? "reads" : "writes");
        lua_rawget(L, -2);
        if (!lua_isnil(L, -1)) {
          if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "unveiled paths must be a list");
          lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
          for (lua_Integer i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, i);
            const char *unveil_path = plain_string(L, -1, "unveiled path");
            if (unveil_path[0] != '/')
              return luaL_argerror(L, 10, "an unveiled path must be absolute");
            if (unveil_count >= UNVEIL_MAX)
              return luaL_argerror(L, 10, "too many unveiled paths");
            unveiled[unveil_count] = unveil_path;
            unveiled_at[unveil_count] = NULL;
            unveiled_writable[unveil_count] = w;
            unveiled_noexec[unveil_count] = 0;
            unveiled_idmap[unveil_count] = 0;
            unveil_count++;
            lua_pop(L, 1);
          }
        }
        lua_pop(L, 1);
      }
      /* Paths with more said of each than `reads` and `writes` can: where
       * it is bound, and whether it may not execute. */
      lua_pushliteral(L, "binds");
      lua_rawget(L, -2);
      if (!lua_isnil(L, -1)) {
        if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "unveil's binds must be a list");
        lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
        for (lua_Integer i = 1; i <= n; i++) {
          lua_rawgeti(L, -1, i);
          if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "a bind is a table");
          if (unveil_count >= UNVEIL_MAX) return luaL_argerror(L, 10, "too many unveiled paths");
          lua_pushliteral(L, "path");
          lua_rawget(L, -2);
          const char *bind_path = plain_string(L, -1, "a bind's path");
          if (bind_path[0] != '/') return luaL_argerror(L, 10, "a bind's path must be absolute");
          lua_pushliteral(L, "at");
          lua_rawget(L, -3);
          const char *bind_at = NULL;
          if (!lua_isnil(L, -1)) {
            bind_at = plain_string(L, -1, "the name a bind is at");
            size_t length = strlen(bind_at);
            if (!plain_name(bind_at) || length < 2 || bind_at[length - 1] == '/')
              return luaL_argerror(L, 10, "a bind is at an absolute name, plain, and not /");
            if (strcmp(bind_at, "/.old") == 0 || strncmp(bind_at, "/.old/", 6) == 0)
              return luaL_argerror(L, 10, "a bind is at no name beneath /.old");
            for (int j = 0; j < unveil_count; j++) {
              if (unveiled_at[j] != NULL && strcmp(unveiled_at[j], bind_at) == 0)
                return luaL_argerror(L, 10, "two paths are bound at one name");
            }
          }
          lua_pushliteral(L, "writable");
          lua_rawget(L, -4);
          unveiled_writable[unveil_count] = lua_toboolean(L, -1);
          lua_pushliteral(L, "noexec");
          lua_rawget(L, -5);
          unveiled_noexec[unveil_count] = lua_toboolean(L, -1);
          lua_pushliteral(L, "idmap");
          lua_rawget(L, -6);
          unveiled_idmap[unveil_count] = lua_toboolean(L, -1);
          if (unveiled_idmap[unveil_count]) idmapping = 1;
          unveiled[unveil_count] = bind_path;
          unveiled_at[unveil_count] = bind_at;
          unveil_count++;
          lua_pop(L, 6);
        }
      }
      lua_pop(L, 1);
      lua_pushliteral(L, "tmp");
      lua_rawget(L, -2);
      if (!lua_isnil(L, -1)) {
        if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) < 1)
          return luaL_argerror(L, 10, "unveil's tmp is a size in bytes, at least 1");
        tmp_bytes = (unsigned long)lua_tointeger(L, -1);
      }
      lua_pop(L, 1);
      lua_pushliteral(L, "tmp_exec");
      lua_rawget(L, -2);
      if (!lua_isnil(L, -1)) {
        if (!lua_isboolean(L, -1)) return luaL_argerror(L, 10, "unveil's tmp_exec must be a boolean");
        tmp_exec = lua_toboolean(L, -1);
      }
      lua_pop(L, 1);
      /* The name each path given is bound at instead of its own. */
      lua_pushliteral(L, "at");
      lua_rawget(L, -2);
      if (!lua_isnil(L, -1)) {
        if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "unveil's at must be a table");
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
          const char *given = plain_string(L, -2, "a path unveil's at names");
          const char *name = plain_string(L, -1, "the name a path is bound at");
          size_t length = strlen(name);
          if (!plain_name(name) || length < 2 || name[length - 1] == '/')
            return luaL_argerror(L, 10, "a path is bound at an absolute name, plain, and not /");
          /* The root's own: where the old root is put aside as it pivots. */
          if (strcmp(name, "/.old") == 0 || strncmp(name, "/.old/", 6) == 0)
            return luaL_argerror(L, 10, "a path is bound at no name beneath /.old");
          for (int i = 0; i < unveil_count; i++) {
            if (unveiled_at[i] != NULL && strcmp(unveiled_at[i], name) == 0)
              return luaL_argerror(L, 10, "two paths are bound at one name");
          }
          int found = 0;
          for (int i = 0; i < unveil_count; i++) {
            if (strcmp(unveiled[i], given) == 0) {
              unveiled_at[i] = name;
              found = 1;
            }
          }
          if (!found) return luaL_argerror(L, 10, "unveil's at names a path not unveiled");
          lua_pop(L, 1);
        }
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "noexec_scratch");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -1) && !lua_isboolean(L, -1))
      return luaL_argerror(L, 10, "noexec_scratch must be a boolean");
    noexec_scratch = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (noexec_scratch && !unveiling)
      return luaL_argerror(L, 10, "noexec_scratch requires unveil");
    lua_pushliteral(L, "offline");
    lua_rawget(L, 10);
    offline = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_pushliteral(L, "user");
    lua_rawget(L, 10);
    lua_pushliteral(L, "group");
    lua_rawget(L, 10);
    if (!lua_isnil(L, -2) || !lua_isnil(L, -1)) {
      if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
        return luaL_argerror(L, 10, "a user and its group are integers, each with the other");
      lua_Integer user = lua_tointeger(L, -2), group = lua_tointeger(L, -1);
      if (user <= 0 || user >= (lua_Integer)UINT32_MAX || group <= 0 ||
          group >= (lua_Integer)UINT32_MAX)
        return luaL_argerror(L, 10, "a user and its group are 1 to 4294967294");
      if (!unveiling && !proc_only)
        return luaL_argerror(L, 10, "a user is given with unveil or proc");
      dropping = 1;
      drop_uid = (uid_t)user;
      drop_gid = (gid_t)group;
    }
    lua_pop(L, 2);
    if (idmapping && !dropping) return luaL_argerror(L, 10, "a bind's idmap requires a user");
    if (proc_only && unveiling) return luaL_argerror(L, 10, "proc and unveil exclude each other");
    if (tmp_bytes != 0 && !unveiling) return luaL_argerror(L, 10, "unveil's tmp requires unveil");
    if (tmp_bytes != 0 && !strict) return luaL_argerror(L, 10, "unveil's tmp requires strict");
    if (tmp_exec && tmp_bytes == 0) return luaL_argerror(L, 10, "unveil's tmp_exec requires tmp");
    if (sockets != 0 && !offline)
      return luaL_argerror(L, 10, "sockets require offline: the network namespace is their hold");
    /* What `nest` leaves to the child's own root and pid namespace: its files, which Landlock
     * would hold but for the mounts it refuses, and its signals, which the filter lets reach
     * any pid. */
    if ((promise_bits & COSMIC_PROMISE_NEST) && !(strict && unveiling))
      return luaL_argerror(L, 10, "the \"nest\" promise needs strict and unveil: the root and "
                           "pid namespace of its own that hold its files and signals");
    /* A pid namespace and a procfs of its own are an unveiled child's, with no paths to bind. */
    if (proc_only) unveiling = 1;
  }
  int credentials = !lua_isnoneornil(L, 11);
  uid_t credential_user = 0;
  gid_t credential_group = 0;
  if (credentials) {
    luaL_checktype(L, 11, LUA_TTABLE);
    lua_pushliteral(L, "user");
    lua_rawget(L, 11);
    lua_pushliteral(L, "group");
    lua_rawget(L, 11);
    if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
      return luaL_argerror(L, 11, "credentials need integer user and group");
    lua_Integer user = lua_tointeger(L, -2), group = lua_tointeger(L, -1);
    if (user <= 0 || user >= (lua_Integer)UINT32_MAX || group <= 0 ||
        group >= (lua_Integer)UINT32_MAX)
      return luaL_argerror(L, 11, "credentials user and group are 1 to 4294967294");
    if (unveiling || offline || dropping)
      return luaL_argerror(L, 11, "credentials exclude sandbox unveil, offline, user and group");
    credential_user = (uid_t)user;
    credential_group = (gid_t)group;
    lua_pop(L, 2);
  }
#if defined(__linux__)
  int credential_dumpable = -1;
  if (credentials) {
    credential_dumpable = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
    if (credential_dumpable < 0) return cosmic_fail(L, errno);
    if (credential_dumpable != 0 && credential_dumpable != 1) return cosmic_fail(L, ENOTSUP);
  }
#endif
#if !defined(__linux__)
  if (unveiling || offline || credentials || granting) return cosmic_fail(L, ENOSYS);
#else
  if (unveiling && !sandbox_room()) return cosmic_fail(L, errno);
#endif
  /* The child maps its own ids, or, giving root up, the user and group
   * it runs as; its namespace is mapped from outside then, with root's
   * beside them ([`map_from_outside`]). */
  unsigned long own_uid = (unsigned long)geteuid(), own_gid = (unsigned long)getegid();
  unsigned long child_uid = dropping ? (unsigned long)drop_uid : own_uid;
  unsigned long child_gid = dropping ? (unsigned long)drop_gid : own_gid;
  char uid_map[64], gid_map[64], outer_uid_map[96], outer_gid_map[96];
  snprintf(uid_map, sizeof uid_map, "%lu %lu 1\n", child_uid, child_uid);
  snprintf(gid_map, sizeof gid_map, "%lu %lu 1\n", child_gid, child_gid);
  snprintf(outer_uid_map, sizeof outer_uid_map, "%lu %lu 1\n%lu %lu 1\n", own_uid, own_uid,
           child_uid, child_uid);
  snprintf(outer_gid_map, sizeof outer_gid_map, "%lu %lu 1\n%lu %lu 1\n", own_gid, own_gid,
           child_gid, child_gid);
#if defined(PLEDGE_ARCH)
  struct sock_filter pledge_filter[PLEDGE_MAX];
  struct sock_fprog pledge = { 0, pledge_filter };
  if (pledged) pledge.len = (unsigned short)pledge_program(pledge_filter, unix_ok, inet_ok);
#else
  (void)unix_ok;
  (void)inet_ok;
#endif
  long descriptor_limit = sysconf(_SC_OPEN_MAX);
  if (descriptor_limit < 0) descriptor_limit = 1024;

  if (lua_rawlen(L, 2) == 0) {
    return luaL_argerror(L, 2, "argv is empty");
  }
  /* Validate everything that can raise before allocating native memory. */
  size_t argc = checked_argv(L, 2);

  lua_Integer envc = 0;
  if (!lua_isnoneornil(L, 3)) {
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      checked_variable(L, 3);
      envc++;
      lua_pop(L, 1);
    }
  }

  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (argv == NULL) return cosmic_fail(L, ENOMEM);
  for (size_t i = 1; i <= argc; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    argv[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  char **envp = COSMIC_ENVIRON;
  if (!lua_isnoneornil(L, 3)) {
    envp = calloc((size_t)envc + 1, sizeof *envp);
    if (envp == NULL) { free(argv); return cosmic_fail(L, ENOMEM); }
    lua_Integer at = 0;
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      size_t name_len, value_len;
      const char *name = lua_tolstring(L, -2, &name_len);
      const char *value = lua_tolstring(L, -1, &value_len);
      char *entry = malloc(name_len + value_len + 2);
      if (entry == NULL) {
        lua_pop(L, 2);
        free_environment(envp, at);
        free(argv);
        return cosmic_fail(L, ENOMEM);
      }
      memcpy(entry, name, name_len);
      entry[name_len] = '=';
      memcpy(entry + name_len + 1, value, value_len + 1);
      envp[at++] = entry;
      lua_pop(L, 1);
    }
  }

  int status_pipe[2];
  if (pipe(status_pipe) != 0) {
    int number = errno; if (!lua_isnoneornil(L, 3)) free_environment(envp, envc); free(argv);
    return cosmic_fail(L, number);
  }
  /* Move both ends clear of every descriptor the child is handed, so
   * closed parent stdio cannot make a pipe end collide with the
   * remapping below. These ends, and the descriptors the child moves
   * above its own (the pinned and confining ones -- on Darwin this
   * process copies the pinned ones -- and [`raise_descriptor`]'s), go
   * to `top` + 2 and up -- 257 and up for a relaunch, which hands the
   * child 255 (cosmic/proc.tl's CORE_FD) -- which F_DUPFD refuses past
   * RLIMIT_NOFILE's soft limit: EINVAL at it, EMFILE just under it;
   * SPAWN_PLACED_ABOVE (core/process.h) counts them. A start raises
   * that limit past macOS's default of 256
   * ([`cosmic_raise_descriptor_limit`]); a hard limit that low still
   * refuses a relaunch, which cosmic.child's `start` says. Darwin's
   * start never writes the pipe ([`spawn_program`]), whose read ends at
   * once there; it is made all the same, so a start meets the limit
   * where it does on Linux and the count holds on both. */
  int promote_error = 0;
  int status_read = fcntl(status_pipe[0], F_DUPFD_CLOEXEC, top + 2);
  if (status_read < 0) promote_error = errno;
  int status_write = fcntl(status_pipe[1], F_DUPFD_CLOEXEC, top + 2);
  if (status_write < 0 && promote_error == 0) promote_error = errno;
  close(status_pipe[0]);
  close(status_pipe[1]);
  if (status_read < 0 || status_write < 0) {
    if (status_read >= 0) close(status_read);
    if (status_write >= 0) close(status_write);
    if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
    free(argv);
    return cosmic_fail(L, promote_error);
  }
  /* What an unveiled child resolves in a root of its own is resolved here
   * first, while this process's filesystem is still the one its names
   * mean: each unveiled path with no link or `..` left in it, a shorter
   * before a longer so one inside another lands on top of it; the program
   * and the directory to run in made absolute from this one's; and an
   * empty directory to build the root on. Made last, after everything
   * that can fail, and released once the child has started or failed to. */
  char root_dir[PATH_MAX];
  root_dir[0] = '\0';
  char *resolved = NULL;
  char *resolved_paths[UNVEIL_MAX], *given_names[UNVEIL_MAX];
  char path_abs[PATH_MAX], cwd_abs[PATH_MAX];
  if (unveiling || offline) {
    int prepare_error = 0;
    char here[PATH_MAX];
    if (getcwd(here, sizeof here) == NULL) prepare_error = errno;
    if (!prepare_error && path[0] != '/') {
      int length = snprintf(path_abs, sizeof path_abs, "%s/%s", here, path);
      if (length < 0 || (size_t)length >= sizeof path_abs) prepare_error = ENAMETOOLONG;
      path = path_abs;
    }
    if (!prepare_error && (cwd == NULL || cwd[0] != '/')) {
      int length = snprintf(cwd_abs, sizeof cwd_abs, "%s/%s", here, cwd == NULL ? "." : cwd);
      if (length < 0 || (size_t)length >= sizeof cwd_abs) prepare_error = ENAMETOOLONG;
      cwd = cwd_abs;
    }
    /* TODO: bind each path from the descriptor [`grants_ruleset`] opened for
     * its grant (a mount of /proc/self/fd/<n>), not from its path
     * resolved again here, so a grant's one resolution makes the Landlock
     * rule, the bind and the report, as the sandbox design has it, once
     * `spawn` hands [`build_root`] the grants' descriptors and answers the
     * resolutions it made. A link a host process swaps in between the two
     * resolutions fails closed: the rule is on the file the grant named,
     * so Landlock refuses what the swapped path holds. */
    if (!prepare_error && unveil_count > 0) {
      resolved = malloc((size_t)unveil_count * 2 * PATH_MAX);
      if (resolved == NULL) prepare_error = ENOMEM;
      for (int i = 0; !prepare_error && i < unveil_count; i++) {
        resolved_paths[i] = resolved + (size_t)i * 2 * PATH_MAX;
        given_names[i] = NULL;
        if (realpath(unveiled[i], resolved_paths[i]) == NULL) {
          prepare_error = errno;
          break;
        }
        /* The name given, less a trailing slash, where it differs. */
        size_t n = strlen(unveiled[i]);
        while (n > 1 && unveiled[i][n - 1] == '/') n--;
        if (n >= PATH_MAX) {
          prepare_error = ENAMETOOLONG;
          break;
        }
        char *name = resolved_paths[i] + PATH_MAX;
        memcpy(name, unveiled[i], n);
        name[n] = '\0';
        if (unveiled_at[i] == NULL && plain_name(name) && strcmp(name, resolved_paths[i]) != 0)
          given_names[i] = name;
      }
      /* Each where it is placed, a shorter first, so one placed inside
       * another lands on top of it. */
      for (int i = 1; !prepare_error && i < unveil_count; i++) {
        for (int j = i; j > 0 &&
                        strlen(unveiled_at[j] != NULL ? unveiled_at[j] : resolved_paths[j]) <
                        strlen(unveiled_at[j - 1] != NULL ? unveiled_at[j - 1] : resolved_paths[j - 1]);
             j--) {
          char *p = resolved_paths[j];
          resolved_paths[j] = resolved_paths[j - 1];
          resolved_paths[j - 1] = p;
          char *q = given_names[j];
          given_names[j] = given_names[j - 1];
          given_names[j - 1] = q;
          const char *a = unveiled_at[j];
          unveiled_at[j] = unveiled_at[j - 1];
          unveiled_at[j - 1] = a;
          int w = unveiled_writable[j];
          unveiled_writable[j] = unveiled_writable[j - 1];
          unveiled_writable[j - 1] = w;
          int x = unveiled_noexec[j];
          unveiled_noexec[j] = unveiled_noexec[j - 1];
          unveiled_noexec[j - 1] = x;
          int m = unveiled_idmap[j];
          unveiled_idmap[j] = unveiled_idmap[j - 1];
          unveiled_idmap[j - 1] = m;
        }
      }
    }
    if (!prepare_error && noexec_scratch) {
      for (int i = 0; i < unveil_count; i++) {
        const char *placed = unveiled_at[i] != NULL ? unveiled_at[i] : resolved_paths[i];
        const char *name = given_names[i];
        if (strcmp(placed, "/") == 0 || strcmp(placed, "/noexec") == 0 ||
            strncmp(placed, "/noexec/", 8) == 0 ||
            (name != NULL && (strcmp(name, "/noexec") == 0 ||
                             strncmp(name, "/noexec/", 8) == 0))) {
          prepare_error = EINVAL;
          break;
        }
      }
    }
    if (!prepare_error && unveiling && !proc_only) {
      const char *base = getenv("TMPDIR");
      if (base == NULL || base[0] != '/') base = "/tmp";
      int length = snprintf(root_dir, sizeof root_dir, "%s/cosmic-root-XXXXXX", base);
      if (length < 0 || (size_t)length >= sizeof root_dir) prepare_error = ENAMETOOLONG;
      else if (mkdtemp(root_dir) == NULL) prepare_error = errno;
      if (prepare_error) root_dir[0] = '\0';
    }
    if (prepare_error) {
      free(resolved);
      close(status_read);
      close(status_write);
      if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
      free(argv);
      return cosmic_fail(L, prepare_error);
    }
  }
  int unmap_root = 0;
#if defined(__linux__)
  unmap_root = (unveiling || offline) && inner_user_namespace() && geteuid() == 0;
#endif
  /* Built last of what can fail, so the one cleanup below serves it: a
   * ruleset to close is the only thing past here that is not the
   * environment's. */
  int grant_error = 0;
  /* What else holds the child (core/promises.h's COSMIC_HELD_ bits). Only a
   * ruleset made from `grants` says what it handles: a `ruleset` descriptor
   * carries no record of it.
   * TODO: let a child held to a `ruleset` descriptor signal its own
   * processes under the promises filter, once the descriptor can say
   * whether its ruleset scopes signals (COSMIC_HELD_SIGNALS); until
   * then its filter holds the signal calls to the child's starting pid. */
  unsigned held = 0;
  char grant_message[PATH_MAX + 512];
  int unix_guard = 0;
  int unveiled_unix[UNVEIL_MAX];
  memset(unveiled_unix, 0, sizeof unveiled_unix);
#if defined(__linux__)
  /* A start that promises `nest` has no ruleset ([`cosmic.child`] gives it no
   * grants), so the root alone holds its unix sockets, at any Landlock ABI: it
   * gets COSMIC_HELD_UNIX where [`root_shows_no_socket`] holds, and the child
   * checks that ([`build_root`]'s `unix_guard`), as for a ruleset below ABI 9.
   * It may build roots and mount, and none reaches a socket the host has:
   * - Its mount namespace holds what this start bound, each a file that is
   *   no socket, and its own tmpfs and procfs. The host's root was detached
   *   by pivot_root ([`build_root`]), and no descriptor leads to it
   *   ([`root_shows_no_socket`]). Mounts it makes, in a mount namespace or a
   *   user namespace of its own, copy that and add what the kernel lets a
   *   user namespace's root mount (tmpfs, procfs, overlay of what it sees,
   *   mqueue, devpts): none shows a socket file of the host's. The
   *   mounts it copies are locked, so none is unmounted to show what is
   *   beneath. A sysfs, which the filter cannot refuse by its type, needs
   *   one already visible, as the kernel's `fs_fully_visible` asks, and
   *   holds no socket file in any case.
   * - Its procfs is of its own pid namespace, which an unveiled start
   *   always makes ([`start_unveiled`]): /proc/N/root, cwd and fd/N are
   *   the sandbox's own, not a host process's. A procfs it mounts shows
   *   that namespace or one it made, and it holds no descriptor of another
   *   (setns is refused, and it was handed none that leads to one).
   * - open_by_handle_at and name_to_handle_at are not in the filter, and
   *   its capabilities are over its own user namespace alone, so it cannot
   *   decode a handle of a host file.
   * - Abstract sockets are the network namespace's, which `offline` makes
   *   and the filter's refusal of setns keeps it in: a namespace it
   *   makes beside it is another of its own, never the host's.
   * A descriptor handed that is a connected socket reaches what it was
   * connected to, as it would from any start: the caller handed it. */
  int nesting = (promise_bits & COSMIC_PROMISE_NEST) != 0;
  int unix_tmp = (granting || nesting) && strict && unveiling && !proc_only && offline &&
                 close_range_works() &&
                 root_shows_no_socket(resolved_paths, unveiled_at, unveil_count, source, top);
  if (granting) {
    /* A `u` grant's socket is the one a bind may show. */
    for (int i = 0; i < unveil_count; i++) {
      for (int j = 0; j < grant_count; j++) {
        char real[PATH_MAX];
        if ((grant_letters[j] & GRANT_UNIX) && realpath(grant_paths[j], real) != NULL &&
            strcmp(real, resolved_paths[i]) == 0)
          unveiled_unix[i] = 1;
      }
    }
    long version = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    unix_guard = strict && unveiling && !proc_only && offline && version < LANDLOCK_ABI_RESOLVE_UNIX &&
                 (unix_tmp || (sockets & COSMIC_SOCKETS_UNIX) != 0);
    confine = grants_ruleset(grant_paths, grant_letters, grant_count,
                             (sockets & COSMIC_SOCKETS_INET) != 0, strict && unveiling && !proc_only,
                             offline, unix_tmp, grant_message, sizeof grant_message, &grant_error,
                             &held);
  }
  if (nesting && unix_tmp) {
    held |= COSMIC_HELD_UNIX;
    unix_guard = 1;
  }
  /* The namespaces the child makes itself ([`start_unveiled`], [`go_offline`]):
   * a user namespace, whose capabilities the kernel does not take for the
   * initial one's, so it cannot raise a hard limit; and for an unveiled
   * child a pid namespace of its own. */
  if (unveiling || offline) held |= COSMIC_HELD_LIMITS;
  if (unveiling) held |= COSMIC_HELD_PIDS;
#endif
  (void)grant_count; /* only the Linux build holds a child to its grants */
  if (grant_error != 0) {
    close(status_read);
    close(status_write);
    if (root_dir[0] != '\0') rmdir(root_dir);
    if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
    free(argv);
    free(resolved);
    lua_pushnil(L);
    lua_pushstring(L, grant_message);
    lua_pushinteger(L, grant_error);
    return 3;
  }
  char **given = cosmic_coverage_environment(envp);
  struct spawn_plan plan = {
    .path = path, .argv = argv, .envp = given, .cwd = cwd, .source = source, .top = top,
    .status_read = status_read, .status_write = status_write,
    .descriptor_limit = descriptor_limit, .process_group = process_group,
    .credentials = credentials, .user = credential_user, .group = credential_group,
    .confine = confine, .pledged = pledged,
#if defined(PLEDGE_ARCH)
    .pledge = &pledge,
#endif
    .promising = promising, .promises = promise_bits, .held = held,
    .rlimit_count = rlimit_count, .rlimits = rlimits,
    .unveiling = unveiling, .offline = offline, .noexec_scratch = noexec_scratch,
    .strict = strict, .proc_only = proc_only, .tmp_bytes = tmp_bytes, .tmp_exec = tmp_exec, .unix_guard = unix_guard,
    .unveiled_unix = unveiled_unix,
    .sockets = sockets,
    .unveiled_noexec = unveiled_noexec, .root_dir = root_dir,
    .resolved_paths = resolved_paths, .given_names = given_names, .bound_at = unveiled_at,
    .unveiled_writable = unveiled_writable, .unveil_count = unveil_count,
    .unveiled_idmap = idmapping ? unveiled_idmap : NULL, .idmap_fds = idmapping ? idmap_fds : NULL,
    .idmap_failed = &idmap_failed,
    .uid_map = uid_map, .gid_map = gid_map, .unmap_root = unmap_root,
    .dropping = dropping, .drop_uid = drop_uid, .drop_gid = drop_gid,
    .outer_uid_map = outer_uid_map, .outer_gid_map = outer_gid_map,
  };
  pid_t program = -1;
#if defined(__linux__)
  pid_t init = -1;
  plan.init = &init;
  plan.program = &program;
  end_sandbox_inits();
#endif
  int fork_error = 0;
  /* A child that gives root up shares this process's memory while its
   * ids change, which makes that memory dumpable or not as the kernel
   * and the child set it ([`start_program`]): whatever it was here, it is
   * put back once the child has exec'd. */
#if defined(__linux__)
  int dumpable = dropping ? prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) : -1;
#endif
  pid_t pid = start_child(&plan, &fork_error);
  /* The child has its own copy of the ruleset's descriptor from its
   * start, or never started. */
  if (granting) close(confine);
#if defined(__linux__)
  int restore_error = 0;
  if (credentials) {
    int current = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
    if (current < 0) restore_error = errno;
    else if (current != credential_dumpable &&
             prctl(PR_SET_DUMPABLE, credential_dumpable, 0, 0, 0) != 0) restore_error = errno;
  }
  /* TODO: check namespace-drop restoration too, with cleanup retaining
   * ownership of its intermediate child, init and program on failure. */
  if ((dumpable == 0 || dumpable == 1) && prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) != dumpable)
    prctl(PR_SET_DUMPABLE, dumpable, 0, 0, 0);
#endif
  close(status_write);
  if (given != envp) free(given);
  if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
  free(argv);
  if (idmap_failed >= 0 && idmap_failed < unveil_count)
    snprintf(idmap_path, sizeof idmap_path, "%s", resolved_paths[idmap_failed]);
  free(resolved);
#if defined(__linux__)
  if (restore_error != 0) {
    /* Exec may already have succeeded. Keep ownership until the child
     * and its owned group are ended, even though no pid is returned. */
    if (pid > 0) {
      if (process_group) kill(-pid, SIGKILL);
      kill(pid, SIGKILL);
      int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
    }
    close(status_read);
    return cosmic_fail(L, restore_error);
  }
#endif
  if (pid < 0) {
    close(status_read);
    if (root_dir[0] != '\0') rmdir(root_dir);
    return cosmic_fail(L, fork_error);
  }
  /* An unveiled child has ended once it started its program, which is
   * this process's child in its place ([`start_unveiled`]), or failed to. */
  if (unveiling) {
    int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
    pid = program;
#if defined(__linux__)
    /* Room was made before the child started, but a finalizer the Lua
     * calls since then ran could have spawned into it: where there is
     * none left and no more to be had, the init is ended at once, and
     * its program with it, rather than left unrecorded, where nothing
     * would ever reap it. */
    if (init > 0 && (pair_count < pair_room || sandbox_room())) {
      pairs[pair_count++] = (struct sandbox_pair){ init, program };
      if (program < 0) end_sandbox_init(pair_count - 1);
    } else if (init > 0) {
      kill(init, SIGKILL);
    }
#endif
  }

  int child_error = 0;
  size_t received = 0;
  int read_error = 0;
  while (received < sizeof child_error) {
    ssize_t got = read(status_read, (char *)&child_error + received,
                       sizeof child_error - received);
    if (got > 0) { received += (size_t)got; continue; }
    if (got == 0) break;
    if (errno == EINTR) continue;
    read_error = errno;
    break;
  }
  close(status_read);
  if (root_dir[0] != '\0') rmdir(root_dir);
  if (received != 0 || read_error != 0 || pid < 0) {
    int ignored; while (pid > 0 && waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
#if defined(__linux__)
    if (pid > 0) sandbox_reaped(pid);
#endif
    int number = received == sizeof child_error ? child_error : (read_error != 0 ? read_error : EIO);
#if defined(__linux__)
    if (strict && number >> STAGE_SHIFT != 0) {
      char message[PATH_MAX + 512];
      staged_message(number >> STAGE_SHIFT, number & ((1 << STAGE_SHIFT) - 1),
                     idmap_path[0] != '\0' ? idmap_path : NULL, message, sizeof message);
      lua_pushnil(L);
      lua_pushstring(L, message);
      lua_pushinteger(L, number & ((1 << STAGE_SHIFT) - 1));
      return 3;
    }
#endif
    if (granting && number == EACCES) {
      /* The likeliest cause: the program, or the loader or interpreter
       * it names, was not granted `rx`. */
      lua_pushnil(L);
      lua_pushfstring(L, "%s: a child held to `grants` needs an `rx` grant for its program, and "
                      "for the interpreter or loader that program names", cosmic_errno_describe(number, NULL));
      lua_pushinteger(L, number);
      return 3;
    }
    return cosmic_fail(L, number);
  }
  lua_pushinteger(L, (lua_Integer)pid);
  return 1;
}

COSMIC_SYSCALL(waitpid, 2) {
  lua_Integer value = luaL_checkinteger(L, 1);
  if (value == 0 || value < -INT_MAX || value > INT_MAX)
    return luaL_argerror(L, 1, "pid is out of range");
  pid_t pid = (pid_t)value;
  int nohang = lua_toboolean(L, 2);
  /* The answer and its keys are made before the wait, and filling a
   * table sized for them allocates nothing: a child the wait reaped
   * cannot be reaped again, so a raise after it would lose its status. */
  lua_createtable(L, 0, 3);
  lua_pushliteral(L, "signal");
  lua_pushliteral(L, "code");
  lua_pushliteral(L, "pid");
  int status;
  pid_t answer;
  do { answer = waitpid(pid, &status, nohang ? WNOHANG : 0); }
  while (answer < 0 && errno == EINTR);
  if (answer < 0) return cosmic_fail(L, errno);
#if defined(__linux__)
  if (answer > 0) sandbox_reaped(answer);
  end_sandbox_inits();
#endif
  lua_pushinteger(L, answer);
  lua_rawset(L, -5);
  lua_pushinteger(L, answer > 0 && WIFEXITED(status) ? WEXITSTATUS(status) : -1);
  lua_rawset(L, -4);
  lua_pushinteger(L, answer > 0 && WIFSIGNALED(status) ? WTERMSIG(status) : -1);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(exit_watch, 1) {
  lua_Integer value = luaL_checkinteger(L, 1);
  if (value <= 0 || value > INT_MAX) return luaL_argerror(L, 1, "pid is out of range");
#if defined(__linux__)
  /* pidfd_open sets close-on-exec itself. */
  int watch = (int)syscall(SYS_pidfd_open, (pid_t)value, 0);
  if (watch < 0) return cosmic_fail(L, errno);
#elif defined(__APPLE__)
  int watch = kqueue();
  if (watch < 0) return cosmic_fail(L, errno);
  /* A kqueue is not inherited across fork, but may be across a spawn's
   * exec: it is closed there. One thread and no fork before the flag is
   * set, so no child can take it meanwhile. The exit, once it comes,
   * stays queued, as nothing reads the queue, and so the queue stays
   * readable.
   * TODO: confirm on a Darwin host whether XNU's proc_exit posts
   * NOTE_EXIT before it marks the process a zombie, as its source reads;
   * if so, the queue is readable a moment before waitpid can reap the
   * child, and a wait in cosmic.child that finds no status looks again
   * at once, spinning through its run until it can. The fix would be a
   * blocking waitpid there, the exit being underway. */
  struct kevent change;
  EV_SET(&change, (uintptr_t)value, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, NULL);
  if (fcntl(watch, F_SETFD, FD_CLOEXEC) != 0 || kevent(watch, &change, 1, NULL, 0, NULL) != 0) {
    int number = errno;
    close(watch);
    return cosmic_fail(L, number);
  }
#else
  return cosmic_fail(L, ENOSYS);
#endif
  /* Nothing between the open and its push can raise: pushing an integer
   * allocates nothing. */
  lua_pushinteger(L, watch);
  return 1;
}

COSMIC_SYSCALL(kill, 2) {
  lua_Integer pid_value = luaL_checkinteger(L, 1);
  lua_Integer signal_value = luaL_checkinteger(L, 2);
  if (pid_value == 0 || pid_value < -INT_MAX || pid_value > INT_MAX)
    return luaL_argerror(L, 1, "pid is out of range");
  if (signal_value < 0 || signal_value > INT_MAX)
    return luaL_argerror(L, 2, "signal is out of range");
  pid_t pid = (pid_t)pid_value;
  int signal = (int)signal_value;
  if (kill(pid, signal) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

/* What [`cosmic_process_entered`] recorded: the working directory, ""
 * where it could not be read. */
static char entered_directory[PATH_MAX];

void cosmic_process_entered (void) {
  if (getcwd(entered_directory, sizeof entered_directory) == NULL) entered_directory[0] = '\0';
}

/* Sets field `cwd` of the table on top to the directory this process
 * started in, where it was read. */
static void set_cwd (lua_State *L) {
  if (entered_directory[0] == '\0') return;
  lua_pushstring(L, entered_directory);
  lua_setfield(L, -2, "cwd");
}

static void set_decimal (lua_State *L, const char *name, uint64_t value) {
  char text[32];
  snprintf(text, sizeof text, "%llu", (unsigned long long)value);
  lua_pushstring(L, text);
  lua_setfield(L, -2, name);
}

COSMIC_SYSCALL(relaunch, 2) {
  lua_Integer artifact_to = luaL_checkinteger(L, 1);
  lua_Integer core_to = luaL_checkinteger(L, 2);
  if (artifact_to < 3 || artifact_to > 255 || core_to < 3 || core_to > 255 ||
      artifact_to == core_to)
    return luaL_argerror(L, 1, "the child descriptors must differ, from 3 to 255");
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact == NULL) return cosmic_fail(L, ENOSYS);
  char physical[PATH_MAX];
  errno = 0; /* as for executable */
  if (!cosmic_executable_path(physical, sizeof physical)) {
    int number = errno;
    return cosmic_fail(L, number == 0 ? ENAMETOOLONG : number);
  }
  if (artifact->split) {
    /* A core run against a database starts again as it was: the core and
     * the database's absolute path, with no descriptor and no environment
     * to hand on. */
    lua_createtable(L, 0, 3);
    lua_pushstring(L, physical);
    lua_setfield(L, -2, "path");
    lua_pushstring(L, artifact->logical_path);
    lua_setfield(L, -2, "database");
    set_cwd(L);
    return 1;
  }
  if (artifact->host) {
    /* A host program is its own launcher: executing it again is enough. */
    lua_createtable(L, 0, 3);
    lua_pushstring(L, physical);
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "host");
    set_cwd(L);
    return 1;
  }
  const struct cosmic_portable_entry *selected = &artifact->portable.selected;
  lua_createtable(L, 0, 6);
  lua_pushstring(L, physical);
  lua_setfield(L, -2, "path");
  set_cwd(L);
  lua_pushstring(L, artifact->logical_path);
  lua_setfield(L, -2, "artifact");
  lua_pushinteger(L, artifact->fd);
  lua_setfield(L, -2, "artifact_fd");
  lua_createtable(L, 0, 7);
  set_decimal(L, COSMIC_PORTABLE_ENV_ARTIFACT_FD, (uint64_t)artifact_to);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_FD, (uint64_t)core_to);
  set_decimal(L, COSMIC_PORTABLE_ENV_TARGET_ID, selected->target_id);
  set_decimal(L, COSMIC_PORTABLE_ENV_CONFIGURATION_ID, selected->configuration_id);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_OFFSET, selected->offset);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_LENGTH, selected->length);
  char digest[COSMIC_PORTABLE_SHA256_LENGTH * 2 + 1];
  cosmic_hex(digest, selected->sha256, COSMIC_PORTABLE_SHA256_LENGTH);
  lua_pushstring(L, digest);
  lua_setfield(L, -2, COSMIC_PORTABLE_ENV_CORE_SHA256);
  lua_setfield(L, -2, "environment");
  /* The descriptor is opened last, into a slot the table already has
   * room for, so no raise can come between it and the answer. */
  lua_pushliteral(L, "core_fd");
  int core_fd = cosmic_executable_fd();
  if (core_fd < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, core_fd);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(pipe, 0) {
  /* The answer and its keys are made before the pipe, and filling a
   * table sized for them allocates nothing: a raise after the pipe
   * would leak both ends. */
  lua_createtable(L, 0, 2);
  lua_pushliteral(L, "writer");
  lua_pushliteral(L, "reader");
  int ends[2];
  if (pipe(ends) != 0) return cosmic_fail(L, errno);
  /* One thread and no fork between these calls, so setting CLOEXEC
   * after the fact cannot leak an end into a child. */
  for (int i = 0; i < 2; i++) {
    if (fcntl(ends[i], F_SETFD, FD_CLOEXEC) != 0) {
      int number = errno;
      close(ends[0]);
      close(ends[1]);
      return cosmic_fail(L, number);
    }
  }
  lua_pushinteger(L, ends[0]);
  lua_rawset(L, -4);
  lua_pushinteger(L, ends[1]);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(dup, 1) {
  int fd = cosmic_checkfd(L, 1);
  int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (copy < 0) return cosmic_fail(L, errno);
  /* Nothing between the copy and its push can raise: pushing an integer
   * allocates nothing, so the copy cannot leak. */
  lua_pushinteger(L, copy);
  return 1;
}

COSMIC_SYSCALL(fd_flags, 1) {
  int fd = cosmic_checkfd(L, 1);
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, flags);
  return 1;
}

COSMIC_SYSCALL(dup2, 2) {
  int fd = cosmic_checkfd(L, 1);
  int to = cosmic_checkfd(L, 2);
  int made;
  do { made = dup2(fd, to); } while (made < 0 && errno == EINTR);
  if (made < 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(set_nonblocking, 2) {
  int fd = cosmic_checkfd(L, 1);
  int on = lua_toboolean(L, 2);
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return cosmic_fail_effect(L, errno);
  flags = on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
  if (fcntl(fd, F_SETFL, flags) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

/* One entry of `poll`'s argument: its descriptor, and where it is in
 * the argument, so the entries sorted by descriptor can be answered in
 * place. */
struct poll_entry {
  int fd;
  int at;
};

/* Orders entries by descriptor; the order among one descriptor's
 * entries does not matter. */
static int poll_entry_order (const void *a, const void *b) {
  const struct poll_entry *left = a, *right = b;
  return (left->fd > right->fd) - (left->fd < right->fd);
}

/* The kernel is given each descriptor once, asked for every event any
 * of its entries wants, and each entry answers what happened masked to
 * its own events, as Linux answers a descriptor given twice: macOS
 * answers only one entry of such a descriptor and leaves the other 0,
 * so no caller could give one twice there. -1 is left out, and
 * answers 0. */
COSMIC_SYSCALL(poll, 3) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer timeout = luaL_checkinteger(L, 3);
  if (timeout < -1 || timeout > INT_MAX)
    return luaL_argerror(L, 3, "timeout is out of range");
  lua_Integer count = (lua_Integer)lua_rawlen(L, 1);
  if (count > INT_MAX) return luaL_argerror(L, 1, "too many descriptors");
  if ((lua_Integer)lua_rawlen(L, 2) != count)
    return luaL_argerror(L, 2, "one event mask per descriptor");
  size_t each = sizeof(struct pollfd) + sizeof(struct poll_entry) + sizeof(int) + sizeof(short);
  /* A block Lua owns, not a C allocation: a refused descriptor below
   * raises part-way through filling it, and the collector takes it. Its
   * parts are laid out from the widest alignment down. */
  char *block = lua_newuserdatauv(L, (size_t)count * each, 0);
  struct pollfd *fds = (struct pollfd *)block;
  struct poll_entry *entries = (struct poll_entry *)(fds + count);
  int *slot = (int *)(entries + count);
  short *wanted = (short *)(slot + count);
  int watched = 0;
  for (lua_Integer i = 0; i < count; i++) {
    lua_rawgeti(L, 1, i + 1);
    lua_rawgeti(L, 2, i + 1);
    if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
      return luaL_argerror(L, 1, "descriptors and masks must be integers");
    lua_Integer fd = lua_tointeger(L, -2);
    lua_Integer events = lua_tointeger(L, -1);
    if (fd < -1 || fd > INT_MAX || events < 0 || events > SHRT_MAX)
      return luaL_argerror(L, 1, "descriptor or mask is out of range");
    cosmic_argfd(L, 1, fd);
    wanted[i] = (short)events;
    slot[i] = -1;
    if (fd >= 0) {
      entries[watched].fd = (int)fd;
      entries[watched].at = (int)i;
      watched++;
    }
    lua_pop(L, 2);
  }
  qsort(entries, (size_t)watched, sizeof *entries, poll_entry_order);
  nfds_t given = 0;
  for (int k = 0; k < watched; k++) {
    if (given == 0 || fds[given - 1].fd != entries[k].fd) {
      fds[given].fd = entries[k].fd;
      fds[given].events = 0;
      fds[given].revents = 0;
      given++;
    }
    fds[given - 1].events = (short)(fds[given - 1].events | wanted[entries[k].at]);
    slot[entries[k].at] = (int)(given - 1);
  }
  /* An interrupted wait answers as a wait that found nothing, so the
   * caller's loop gets to look at whatever the signal meant. */
  if (poll(fds, given, (int)timeout) < 0) {
    if (errno != EINTR) return cosmic_fail(L, errno);
    for (nfds_t k = 0; k < given; k++) fds[k].revents = 0;
  }
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 0; i < count; i++) {
    short answer = 0;
    if (slot[i] >= 0)
      answer = (short)(fds[slot[i]].revents & (wanted[i] | POLLERR | POLLHUP | POLLNVAL));
    lua_pushinteger(L, answer);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

COSMIC_SYSCALL(subreaper, 0) {
#if defined(__linux__) && defined(PR_SET_CHILD_SUBREAPER)
  if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0)
    return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

#if defined(__linux__)
/* Reads the file at `path` whole into a block of the core's C heap,
 * which the caller frees, and its length into `used`: 0, or the errno
 * that refused it, ENOMEM for a block refused. It calls nothing of
 * Lua's, so its descriptor is closed before a caller's Lua call can
 * raise. */
static int read_whole (const char *path, char **text, size_t *used) {
  *text = NULL;
  *used = 0;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  size_t room = 4096, have = 0;
  char *block = cosmic_malloc(room);
  int failure = block == NULL ? ENOMEM : 0;
  while (failure == 0) {
    if (have == room) {
      char *grown = room > SIZE_MAX / 2 ? NULL : cosmic_realloc(block, room * 2);
      if (grown == NULL) {
        failure = ENOMEM;
        break;
      }
      block = grown;
      room *= 2;
    }
    ssize_t got = read(fd, block + have, room - have);
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) failure = errno;
    if (got <= 0) break;
    have += (size_t)got;
  }
  close(fd);
  if (failure != 0) {
    cosmic_free(block);
    return failure;
  }
  *text = block;
  *used = have;
  return 0;
}

/* Whether the list of ranges `text` holds, as /proc/<pid>/uid_map and
 * gid_map write them -- a line each of the first id inside, the first
 * outside and how many -- maps `id` inside. */
static bool id_mapped (const char *text, size_t used, uint64_t id) {
  for (size_t at = 0; at < used;) {
    uint64_t field[3] = { 0, 0, 0 };
    int fields = 0;
    while (at < used && text[at] != '\n') {
      if (text[at] < '0' || text[at] > '9') {
        at++;
        continue;
      }
      /* Held below 2^40, past every id and count, so it cannot wrap. */
      uint64_t value = 0;
      while (at < used && text[at] >= '0' && text[at] <= '9') {
        if (value < ((uint64_t)1 << 40)) value = value * 10 + (uint64_t)(text[at] - '0');
        at++;
      }
      if (fields < 3) field[fields] = value;
      fields++;
    }
    at++;
    if (fields == 3 && id >= field[0] && id - field[0] < field[2]) return true;
  }
  return false;
}
#endif

COSMIC_SYSCALL(children, 0) {
#if defined(__linux__)
  /* The list is read whole into a C block before anything is pushed;
   * the block is the guard's from then on. */
  struct cosmic_guard *guard = cosmic_guard_push(L, cosmic_free);
  char *text;
  size_t used;
  int failure = read_whole("/proc/thread-self/children", &text, &used);
  if (failure != 0) return cosmic_fail(L, failure);
  guard->resource = text;
  lua_newtable(L);
  lua_Integer count = 0;
  for (size_t at = 0; at < used;) {
    if (text[at] < '0' || text[at] > '9') {
      at++;
      continue;
    }
    /* A number past any pid names no process, and is skipped. */
    lua_Integer pid = 0;
    bool fits = true;
    while (at < used && text[at] >= '0' && text[at] <= '9') {
      if (fits) pid = pid * 10 + (text[at] - '0');
      if (pid > INT_MAX) fits = false;
      at++;
    }
    if (!fits) continue;
    lua_pushinteger(L, pid);
    lua_rawseti(L, -2, ++count);
  }
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(maps_id, 1) {
  lua_Integer id = luaL_checkinteger(L, 1);
  luaL_argcheck(L, id >= 0 && id < (lua_Integer)UINT32_MAX, 1, "not an id");
#if defined(__linux__)
  static const char *const maps[] = { "/proc/self/uid_map", "/proc/self/gid_map" };
  for (int m = 0; m < 2; m++) {
    char *text;
    size_t used;
    int failure = read_whole(maps[m], &text, &used);
    if (failure != 0) return cosmic_fail_effect(L, failure);
    bool mapped = id_mapped(text, used, (uint64_t)id);
    cosmic_free(text);
    /* setuid's answer for an id this namespace does not map. */
    if (!mapped) return cosmic_fail_effect(L, EINVAL);
  }
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(may_map_ids, 0) {
#if defined(__linux__)
  if (geteuid() != 0) return cosmic_fail_effect(L, EPERM);
  struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct data[2];
  if (syscall(SYS_capget, &header, data) != 0) return cosmic_fail_effect(L, errno);
  uint32_t needed = (1u << CAP_SETGID) | (1u << CAP_SETUID) | (1u << CAP_SETFCAP);
  if ((data[0].effective & needed) != needed) return cosmic_fail_effect(L, EPERM);
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

#if defined(__linux__)
/* The stack each of `own_proc`'s two children runs on, above a guard
 * page of its own. */
#define OWN_PROC_STACK_SIZE (64 * 1024)

/* What `own_proc`'s first child is handed: the ids it maps, whether it
 * may be left unmapped, as `spawn` decides for an unveiled child, and
 * the stack its own child runs on. */
struct own_proc_probe {
  const char *uid_map;
  const char *gid_map;
  int unmap_root;
  char *mounter_stack;
};

/* `own_proc`'s second child, pid 1 of the first's pid namespace: mounts
 * a procfs of it as [`place_proc`] does, on the /proc of a mount
 * namespace made private first, so neither mount reaches the parent's.
 * It exits 0, or with the errno that refused it. */
static _Noreturn int mount_own_proc (void *unused) {
  (void)unused;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) _exit(errno & 0xff);
  if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "subset=pid") != 0)
    _exit(errno & 0xff);
  _exit(0);
}

/* `own_proc`'s first child, on the parent's memory with every signal
 * blocked, as [`start_child`]'s is: makes its namespaces as
 * [`start_unveiled`] does -- through unshare, which a container's
 * seccomp profile lets through where it refuses clone's namespace
 * flags -- maps its ids as [`map_ids`] does for such a child, and starts
 * [`mount_own_proc`] in them. It exits with what that one exited with,
 * or the errno that refused a step before it. */
static _Noreturn int try_own_proc (void *argument) {
  const struct own_proc_probe *probe = argument;
  if (syscall(SYS_unshare, CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS) != 0) _exit(errno & 0xff);
  int mapped;
  int failure = map_ids(probe->unmap_root, probe->uid_map, probe->gid_map, &mapped);
  if (failure) _exit(failure & 0xff);
  pid_t mounter = clone(mount_own_proc, probe->mounter_stack, CLONE_VM | CLONE_VFORK | SIGCHLD,
                        NULL);
  if (mounter < 0) _exit(errno & 0xff);
  int status = 0;
  pid_t reaped;
  while ((reaped = waitpid(mounter, &status, 0)) < 0 && errno == EINTR) {}
  if (reaped < 0) _exit(errno & 0xff);
  _exit(WIFEXITED(status) ? WEXITSTATUS(status) : ECHILD);
}
#endif

COSMIC_SYSCALL(own_proc, 0) {
#if defined(__linux__)
  char uid_map[64], gid_map[64];
  snprintf(uid_map, sizeof uid_map, "%lu %lu 1\n", (unsigned long)geteuid(),
           (unsigned long)geteuid());
  snprintf(gid_map, sizeof gid_map, "%lu %lu 1\n", (unsigned long)getegid(),
           (unsigned long)getegid());
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) page = 4096;
  size_t each = OWN_PROC_STACK_SIZE + (size_t)page, size = 2 * each;
  char *stack = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (stack == MAP_FAILED) return cosmic_fail_effect(L, errno);
  int failure = 0;
  for (int s = 0; !failure && s < 2; s++) {
    if (mprotect(stack + each * (size_t)s, (size_t)page, PROT_NONE) != 0) failure = errno;
  }
  struct own_proc_probe probe = {
    uid_map, gid_map, inner_user_namespace() && geteuid() == 0, stack + 2 * each,
  };
  sigset_t every, before;
  sigfillset(&every);
  if (!failure && sigprocmask(SIG_SETMASK, &every, &before) != 0) failure = errno;
  pid_t child = -1;
  if (!failure) {
    child = clone(try_own_proc, stack + each, CLONE_VM | CLONE_VFORK | SIGCHLD, &probe);
    if (child < 0) failure = errno;
    sigprocmask(SIG_SETMASK, &before, NULL);
  }
  munmap(stack, size);
  if (failure) return cosmic_fail_effect(L, failure);
  int status = 0;
  pid_t reaped;
  while ((reaped = waitpid(child, &status, 0)) < 0 && errno == EINTR) {}
  if (reaped < 0) return cosmic_fail_effect(L, errno);
  if (!WIFEXITED(status)) return cosmic_fail_effect(L, ECHILD);
  if (WEXITSTATUS(status) != 0) return cosmic_fail_effect(L, WEXITSTATUS(status));
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(sandbox_platform, 0) {
#if defined(__linux__)
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(ignore_sigpipe, 0) {
  struct sigaction previous;
  if (sigaction(SIGPIPE, NULL, &previous) != 0)
    return cosmic_fail_effect(L, errno);
  if (previous.sa_handler != SIG_DFL) return cosmic_ok(L);
  struct sigaction ignore;
  memset(&ignore, 0, sizeof ignore);
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  if (sigaction(SIGPIPE, &ignore, NULL) != 0)
    return cosmic_fail_effect(L, errno);
  sigpipe_ignored_here = 1;
  return cosmic_ok(L);
}

COSMIC_SYSCALL(unix_socket, 0) {
#if defined(SOCK_CLOEXEC)
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
#endif
  if (fd < 0) return cosmic_fail(L, errno);
#if !defined(SOCK_CLOEXEC)
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
    int failure = errno;
    close(fd);
    return cosmic_fail(L, failure);
  }
#endif
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(cpu_count, 0) {
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  lua_pushinteger(L, count < 1 ? 1 : (lua_Integer)count);
  return 1;
}

/* The features `cpu_features` answers, by /proc/cpuinfo's names, in
 * byte order, each with where this processor says it has it: a bit of
 * cpuid leaf 1's ECX on x86_64, and of the auxiliary vector's AT_HWCAP
 * on Linux's aarch64; a name sysctlbyname answers 1 for on Darwin's. */
#if defined(__aarch64__) && defined(__APPLE__)
struct cpu_feature {
  const char *name;
  const char *sysctl;
};

static const struct cpu_feature cpu_features[] = {
  { "aes", "hw.optional.arm.FEAT_AES" }, { "asimd", "hw.optional.AdvSIMD" },
  { "crc32", "hw.optional.armv8_crc32" }, { "pmull", "hw.optional.arm.FEAT_PMULL" },
};
#elif defined(__x86_64__) || (defined(__aarch64__) && defined(__linux__))
struct cpu_feature {
  const char *name;
  unsigned bit;
};

#if defined(__x86_64__)
static const struct cpu_feature cpu_features[] = {
  { "aes", 25 }, { "pclmulqdq", 1 }, { "sse4_1", 19 }, { "ssse3", 9 },
};
#else
static const struct cpu_feature cpu_features[] = {
  { "aes", 3 }, { "asimd", 1 }, { "crc32", 7 }, { "pmull", 4 },
};
#endif
#endif

COSMIC_SYSCALL(cpu_features, 0) {
  lua_newtable(L);
#if defined(__aarch64__) && defined(__APPLE__)
  lua_Integer count = 0;
  for (size_t f = 0; f < sizeof cpu_features / sizeof *cpu_features; f++) {
    int value = 0;
    size_t size = sizeof value;
    if (sysctlbyname(cpu_features[f].sysctl, &value, &size, NULL, 0) != 0 || value != 1)
      continue;
    lua_pushstring(L, cpu_features[f].name);
    lua_rawseti(L, -2, ++count);
  }
#elif defined(__x86_64__) || (defined(__aarch64__) && defined(__linux__))
  unsigned long bits = 0;
#if defined(__x86_64__)
  unsigned int eax, ebx, ecx, edx;
  if (__get_cpuid(1, &eax, &ebx, &ecx, &edx)) bits = ecx;
#else
  bits = getauxval(AT_HWCAP);
#endif
  lua_Integer count = 0;
  for (size_t f = 0; f < sizeof cpu_features / sizeof *cpu_features; f++) {
    if (((bits >> cpu_features[f].bit) & 1) == 0) continue;
    lua_pushstring(L, cpu_features[f].name);
    lua_rawseti(L, -2, ++count);
  }
#endif
  return 1;
}

bool cosmic_mountinfo_local_flock (const char *text, size_t used, const char *device) {
  size_t device_length = strlen(device);
  for (size_t at = 0; at < used;) {
    size_t end = at;
    while (end < used && text[end] != '\n') end++;
    /* Its fields, space-separated: the third the device, and after a
     * lone "-" at the seventh or later, the type, the source and the
     * filesystem's own options. */
    size_t start[64], length[64];
    int fields = 0;
    for (size_t f = at; f < end && fields < 64;) {
      size_t stop = f;
      while (stop < end && text[stop] != ' ') stop++;
      start[fields] = f;
      length[fields] = stop - f;
      fields++;
      f = stop + 1;
    }
    at = end + 1;
    if (fields <= 2 || length[2] != device_length ||
        memcmp(text + start[2], device, device_length) != 0)
      continue;
    for (int sep = 6; sep + 3 < fields; sep++) {
      if (length[sep] != 1 || text[start[sep]] != '-') continue;
      const char *options = text + start[sep + 3];
      size_t size = length[sep + 3];
      for (size_t o = 0; o < size;) {
        size_t stop = o;
        while (stop < size && options[stop] != ',') stop++;
        size_t word = stop - o;
        if ((word == 16 && memcmp(options + o, "local_lock=flock", 16) == 0) ||
            (word == 14 && memcmp(options + o, "local_lock=all", 14) == 0))
          return true;
        o = stop + 1;
      }
      break;
    }
  }
  return false;
}

COSMIC_SYSCALL(flock_kind, 1) {
  int fd = cosmic_checkfd(L, 1);
#if defined(__linux__)
  struct statfs filesystem;
  if (fstatfs(fd, &filesystem) != 0) return cosmic_fail(L, errno);
  uint32_t magic = (uint32_t)filesystem.f_type;
  /* SMB's client, CIFS_SUPER_MAGIC and SMB2_SUPER_MAGIC, makes every
   * flock a whole-file fcntl lock. */
  if (magic == 0xFF534D42u || magic == 0xFE534D42u) {
    lua_pushliteral(L, "shared");
    return 1;
  }
  /* NFS_SUPER_MAGIC's does too, unless mounted with local_lock "flock"
   * or "all", which only the mount's options in /proc/self/mountinfo
   * say: the lines of this file's filesystem are those whose third
   * field is its device. Where none says, it is taken for NFS's default,
   * local_lock=none. */
  if (magic != 0x6969u) {
    lua_pushliteral(L, "apart");
    return 1;
  }
  struct stat status;
  if (fstat(fd, &status) != 0) return cosmic_fail(L, errno);
  char device[32];
  int wrote = snprintf(device, sizeof device, "%u:%u", major(status.st_dev), minor(status.st_dev));
  if (wrote < 0 || (size_t)wrote >= sizeof device) return cosmic_fail(L, EOVERFLOW);
  char *text;
  size_t used;
  int failure = read_whole("/proc/self/mountinfo", &text, &used);
  if (failure == ENOMEM) return cosmic_fail(L, failure);
  bool local = failure == 0 && cosmic_mountinfo_local_flock(text, used, device);
  cosmic_free(text);
  lua_pushstring(L, local ? "apart" : "shared");
  return 1;
#else
  /* Asked of the descriptor only so one not open fails as it does on
   * Linux: Darwin and the BSDs keep a flock and fcntl locks in one
   * list, whatever the file. */
  struct stat status;
  if (fstat(fd, &status) != 0) return cosmic_fail(L, errno);
  lua_pushliteral(L, "shared");
  return 1;
#endif
}

COSMIC_SYSCALL(uname, 0) {
  struct utsname info;
  if (uname(&info) != 0) {
    return cosmic_fail(L, errno);
  }
  lua_createtable(L, 0, 3);
  lua_pushstring(L, info.sysname);
  lua_setfield(L, -2, "sysname");
  lua_pushstring(L, info.release);
  lua_setfield(L, -2, "release");
  lua_pushstring(L, info.machine);
  lua_setfield(L, -2, "machine");
  return 1;
}

/* The signals the guards have caught, as one stamp: how many, times
 * SIGNAL_STAMP_UNIT, plus the number of the last. One word, so a reader
 * sees a count with the signal that goes with it, and the handler moves
 * it without a lock. It is never reset: a guard asks whether it moved
 * since the stamp that guard last read. It wraps only past 2^57
 * signals. */
static _Atomic long long child_signal_stamp;
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "a signal handler may move only a lock-free atomic");
_Static_assert(SIGINT < SIGNAL_STAMP_UNIT && SIGTERM < SIGNAL_STAMP_UNIT,
               "a stamp holds the last signal's number below its unit");
/* The wake pipe's write end while a guard is open, and -1 otherwise:
 * the handler writes a byte there for a task of cosmic.poll that
 * waits on the read end. */
static volatile sig_atomic_t child_signal_wake = -1;
static int child_signal_read_end = -1;
/* How many guards are open: the first installs the handler, and the
 * last restores what the first found. */
static int child_guard_depth;
/* The stamp the innermost guard last read, which [`cosmic_signal_caught`]
 * asks after. */
static long long child_signal_read_to;
static struct sigaction previous_int;
static struct sigaction previous_term;
/* Whether the guard caught each signal: one this process ignored stays
   ignored, as a shell's `&` or `trap '' INT` asked. */
static int int_caught;
static int term_caught;

/* The last signal delivered wins: a SIGTERM after a Ctrl-C a supervised
   child handled must not be lost to the earlier one. Two pending
   together arrive in the kernel's order, not the sender's. A full pipe
   is readable already, so the byte it refuses is not missed. */
static void catch_child_cancel (int number) {
  int saved = errno;
  long long seen = atomic_load(&child_signal_stamp);
  long long next;
  do {
    next = (seen / SIGNAL_STAMP_UNIT + 1) * SIGNAL_STAMP_UNIT + number;
  } while (!atomic_compare_exchange_weak(&child_signal_stamp, &seen, next));
  int wake = child_signal_wake;
  if (wake >= 0) {
    ssize_t wrote = write(wake, "", 1);
    (void)wrote;
  }
  errno = saved;
}

bool cosmic_signal_caught (void) {
  return child_guard_depth > 0 &&
         atomic_load(&child_signal_stamp) != child_signal_read_to;
}

int64_t cosmic_now_ms (void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int cosmic_wait_slice (int64_t deadline) {
  if (deadline < 0) return COSMIC_WAIT_SLICE_MS;
  int64_t remaining = deadline - cosmic_now_ms();
  if (remaining <= 0) return 0;
  return remaining < COSMIC_WAIT_SLICE_MS ? (int)remaining : COSMIC_WAIT_SLICE_MS;
}

int cosmic_paused (int64_t deadline, int64_t *pause) {
  if (cosmic_signal_caught()) return EINTR;
  int most = cosmic_wait_slice(deadline);
  if (most == 0) return ETIMEDOUT;
  int64_t ms = *pause < most ? *pause : most;
  *pause = *pause * 2 < COSMIC_WAIT_SLICE_MS ? *pause * 2 : COSMIC_WAIT_SLICE_MS;
  struct timespec ts = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000L };
  nanosleep(&ts, NULL);
  return cosmic_signal_caught() ? EINTR : 0;
}

static void child_signal_set (sigset_t *set) {
  sigemptyset(set);
  sigaddset(set, SIGINT);
  sigaddset(set, SIGTERM);
}

/* The wake pipe, both ends close-on-exec and non-blocking, so the
 * handler never blocks on a full one: 0, or the errno that refused it.
 * One thread and no fork between these calls, so setting CLOEXEC after
 * the fact cannot leak an end into a child. */
static int open_wake_pipe (int ends[2]) {
  if (pipe(ends) != 0) return errno;
  for (int i = 0; i < 2; i++) {
    int flags = fcntl(ends[i], F_GETFL);
    if (flags < 0 || fcntl(ends[i], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(ends[i], F_SETFL, flags | O_NONBLOCK) != 0) {
      int number = errno;
      close(ends[0]);
      close(ends[1]);
      return number;
    }
  }
  return 0;
}

/* The first guard's opening, with both signals blocked: the wake pipe,
 * then the handler for each signal this process does not ignore. 0, or
 * the errno that refused it, with nothing left changed. */
static int install_child_guard (void) {
  int ends[2];
  int failure = open_wake_pipe(ends);
  if (failure != 0) return failure;
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = catch_child_cancel;
  child_signal_set(&action.sa_mask);
  if (sigaction(SIGINT, NULL, &previous_int) != 0 ||
      sigaction(SIGTERM, NULL, &previous_term) != 0)
    failure = errno;
  if (failure == 0) {
    int_caught = previous_int.sa_handler != SIG_IGN;
    term_caught = previous_term.sa_handler != SIG_IGN;
    child_signal_wake = ends[1];
    if (int_caught && sigaction(SIGINT, &action, NULL) != 0) {
      failure = errno;
    } else if (term_caught && sigaction(SIGTERM, &action, NULL) != 0) {
      failure = errno;
      if (int_caught) sigaction(SIGINT, &previous_int, NULL);
    }
  }
  if (failure != 0) {
    child_signal_wake = -1;
    close(ends[0]);
    close(ends[1]);
    return failure;
  }
  child_signal_read_end = ends[0];
  return 0;
}

/* The last guard's closing, with both signals blocked: the dispositions
 * the first found, and the wake pipe closed. 0, or the errno of the
 * first disposition that could not be restored. */
static int uninstall_child_guard (void) {
  int first = 0;
  if (int_caught && sigaction(SIGINT, &previous_int, NULL) != 0) first = errno;
  if (term_caught && sigaction(SIGTERM, &previous_term, NULL) != 0 && first == 0)
    first = errno;
  int wake = child_signal_wake;
  child_signal_wake = -1;
  close(wake);
  close(child_signal_read_end);
  child_signal_read_end = -1;
  return first;
}

COSMIC_SYSCALL(guard_child_signals, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  int failure = child_guard_depth == 0 ? install_child_guard() : 0;
  long long outer_read_to = child_signal_read_to;
  if (failure == 0) {
    child_guard_depth++;
    child_signal_read_to = atomic_load(&child_signal_stamp);
  }
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0 && failure == 0) {
    failure = errno;
    child_guard_depth--;
    child_signal_read_to = outer_read_to;
    if (child_guard_depth == 0) uninstall_child_guard();
  }
  if (failure != 0) return cosmic_fail(L, failure);
  lua_pushinteger(L, child_signal_read_to);
  return 1;
}

COSMIC_SYSCALL(unguard_child_signals, 1) {
  lua_Integer read_to = luaL_checkinteger(L, 1);
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  long long stamp = atomic_load(&child_signal_stamp);
  int first = 0;
  if (child_guard_depth > 0) {
    child_guard_depth--;
    if (child_guard_depth == 0) first = uninstall_child_guard();
    else child_signal_read_to = read_to;
  }
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0 && first == 0)
    first = errno;
  if (first != 0) return cosmic_fail(L, first);
  lua_pushinteger(L, stamp);
  return 1;
}

COSMIC_SYSCALL(child_signal_read, 1) {
  luaL_checktype(L, 1, LUA_TBOOLEAN);
  long long stamp = atomic_load(&child_signal_stamp);
  if (lua_toboolean(L, 1)) child_signal_read_to = stamp;
  lua_pushinteger(L, stamp);
  return 1;
}

COSMIC_SYSCALL(child_signal_fd, 0) {
  lua_pushinteger(L, child_signal_read_end);
  return 1;
}

/* The modules are filled from the headers' own entries (core/syscalls.h's
 * X-macros), each a statement here: an entry there is a function or a
 * constant of the table, and nothing else is. */
#undef COSMIC_SYSCALL
#undef COSMIC_CONSTANT
#define COSMIC_SYSCALL(name, arity)                                      \
  lua_pushcfunction(L, cosmic_sys_##name);                               \
  lua_setfield(L, -2, #name)
#define COSMIC_CONSTANT(name)                                            \
  lua_pushinteger(L, name);                                              \
  lua_setfield(L, -2, #name);

/* core/process.h's calls and the numbers `poll` takes and gives back,
 * which only the raw [`cosmic.internal.process`] module holds. */
int cosmic_open_process (lua_State *L) {
  lua_newtable(L);
#include "process.h"
  return 1;
}

/* The calls, and the numbers a caller passes back in, which come from
 * this libc, so a Teal module never carries a platform's constant of its
 * own. */
int cosmic_open_syscalls (lua_State *L) {
  lua_newtable(L);
#include "syscalls.h"
  return 1;
}
