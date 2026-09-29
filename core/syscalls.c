/* The syscall table's process, time and data half, the module, and the
 * raw process table core/process.h declares. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/mman.h>
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
#include <sys/socket.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
/* _XOPEN_SOURCE intentionally hides these libc escape hatches: syscall,
 * for the calls musl has no wrapper for, and clone, which starts a child
 * on this process's memory (`start_child`). */
extern long syscall (long, ...);
extern int clone (int (*)(void *), void *, int, void *, ...);
#endif
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/utsname.h>

#include "check.h"
#include "coverage.h"
#include "fail.h"
#include "guard.h"
#include "observed.h"
#include "lauxlib.h"
#include "executable.h"
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
  if (cosmic_observing) {
    return cosmic_observed_call(L, COSMIC_OBSERVED_EXECUTABLE,
                                cosmic_query_executable);
  }
  return cosmic_query_executable(L);
}

int cosmic_query_executable (lua_State *L) {
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

COSMIC_SYSCALL(getenv, 1) {
  if (cosmic_observing) {
    return cosmic_observed_call(L, COSMIC_OBSERVED_GETENV, cosmic_query_getenv);
  }
  return cosmic_query_getenv(L);
}

int cosmic_query_getenv (lua_State *L) {
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
  if (cosmic_observing) {
    return cosmic_observed_call(L, COSMIC_OBSERVED_ENVIRON, cosmic_query_environ);
  }
  return cosmic_query_environ(L);
}

int cosmic_query_environ (lua_State *L) {
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
  cosmic_coverage_report(); /* nothing of this image remains to report later */
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_DFL);
  execve(path, argv, given);
  int number = errno;
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_IGN);
  if (given != envp) free(given);
  return cosmic_fail_effect(L, number);
}

static void free_environment (char **envp, lua_Integer count) {
  if (envp == NULL) return;
  for (lua_Integer i = 0; i < count; i++) free(envp[i]);
  free(envp);
}

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

/* The highest descriptor number a child may be handed besides stdio. */
#define CHILD_FD_MAX 255

/* Close every descriptor from `from` up. Cosmic-opened descriptors are
 * CLOEXEC already; this also closes foreign descriptors that are not. */
static void close_child_descriptors (int from, long limit) {
#if defined(__linux__) && defined(SYS_close_range)
  if (syscall(SYS_close_range, (unsigned)from, ~0u, 0u) == 0) return;
#endif
  for (int fd = from; fd < limit; fd++) close(fd);
}

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
 * reach beyond: a unix socket named by a path, and UDP. A sandbox's
 * `unveil` closes the first and the socket paths, and `offline` the rest.
 * TODO: a strict form, for a sandbox that must hold whole, refusing
 * with EOPNOTSUPP where the kernel's ABI or this build's headers leave
 * out a right the ruleset otherwise handles -- truncate below ABI 3,
 * TCP below 4, device ioctls below 5, abstract unix sockets and signals
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
  if (abi >= 4) {
    attr.handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP;
    size = offsetof(struct landlock_ruleset_attr, handled_access_net) +
           sizeof attr.handled_access_net;
  }
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

/* Whether this process can no longer run its own core -- held by
 * `landlock_restrict_execute` to files none of which is beneath it --
 * and so hands its artifact's descriptor on to no child (`handed_on`):
 * none could be a relaunch of it. A worker of `cosmic test` whose
 * module does not declare `tool` is held so (build/confine.tl's
 * `forbid_running`) before its test loads.
 *
 * Such a process is made undumpable too (`keep_artifact`), so what it
 * starts cannot take the descriptor as /proc/<its pid>/fd/<it> -- a
 * host program's `cat /proc/$PPID/fd/254`, which `open`'s refusal, in
 * this core's Lua alone, never sees. Following a link of another
 * process's /proc/<pid> (fd, map_files, cwd, root, exe) asks
 * PTRACE_MODE_READ of it, which an undumpable process grants only to
 * one holding CAP_SYS_PTRACE in the user namespace its memory was made
 * in. None the worker starts holds it: in a sandbox every capability is
 * given up for good before the worker runs (`drop_capabilities`), root
 * as any user, and what it starts has none to gain; unsandboxed it has
 * the program by name anyway. The process itself is its own tracer
 * still, so its /proc/self stays its own to read. What moves is the
 * owner of its /proc/<pid>, which the kernel gives root of that user
 * namespace, or the host's where that has none: a child of it on its
 * memory before exec (`spawn_child`), a process it confines or takes
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

/* Every instruction `pledge_program` writes: the architecture check and
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

/* Makes the directory `path` in the root being built with the mode of
 * the one it stands for, whatever the umask, and one its owner -- the
 * child, once it has given up its capabilities -- can pass through
 * even where the host's let only its group: 0, or an errno. */
static int make_mirrored (const char *path, size_t skip) {
  mode_t mode = mirrored_mode(path, skip) | 0700;
  if (mkdir(path, mode) != 0) return errno;
  if (chmod(path, mode) != 0) return errno;
  return 0;
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
 * stands for (`mirrored_mode`), and its last name a directory, with
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
        mode_t mode = mirrored_mode(target, skip) | 0700;
        if (mkdirat(dir, name, mode) != 0 && errno != EEXIST) number = errno;
        else if (fchmodat(dir, name, mode, 0) != 0) number = errno;
        else next = open_unlinked_directory(dir, name);
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
 * parents as `make_target` does, going through no link and making
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
struct cosmic_mount_attr {
  uint64_t attr_set, attr_clr, propagation, userns_fd;
};

/* Brings up the loopback of the network namespace the child has just made
 * its own, which the kernel makes down: a connection to 127.0.0.1 is then
 * refused, or reaches a listener the child's own processes opened, as
 * on a host, rather than finding no network at all. 0, or an errno. */
static int loopback_up (void) {
  /* A unix socket, which any socket's interface ioctls fall through to,
   * so a parent pledged to no "inet" still starts an offline child. */
  int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return errno;
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
  close(fd);
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
   * (`map_from_outside`), which confines at any depth, as any mapped
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
 * sandbox's own (`run_program` starts one, as `cosmic_sandbox_init`
 * does). Where the kernel refuses one -- a container's runtime masks
 * parts of its /proc, and a user namespace may mount a procfs only
 * where one is wholly visible (mount_too_revealing, which subset=pid
 * does not escape as of Linux 6.18), EPERM; a kernel before 5.8 knows
 * no subset, EINVAL -- the host's /proc is bound there instead,
 * read-only even where given to write, since what it holds to write is
 * the host's (/proc/sys, other processes' entries). `own` says whether
 * the procfs is the child's own. 0, or an errno.
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
 * `must_confine` fails), rather than bind the host's, once
 * no container the tree is tested in masks /proc: CI's Linux legs run
 * with systempaths=unconfined (.github/scripts/leg-container.sh), but a
 * developer's docker may not. Meanwhile a child with the host's /proc
 * cannot confine one of its own (EROFS writing its uid_map there), and
 * sees the host's processes and state, whose pids are not the ones it
 * is in (it is pid 2 of its own namespace). */
static int place_proc (const char *target, int *own) {
  *own = mount("proc", target, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "subset=pid") == 0;
  if (*own) return 0;
  if (errno != EPERM && errno != EINVAL) return errno;
  if (mount("/proc", target, NULL, MS_BIND | MS_REC, NULL) != 0) return errno;
  struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
  if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
    return errno;
  return 0;
}

/* In an unveiled child's program's process (`start_program`), in its
 * namespaces -- user, pid, mount, System V IPC, and the network with
 * `offline` -- before anything else of it:
 * a root of the child's own, with a /tmp of its own unless /tmp or /
 * is among the paths, holding the `count` paths at their own names --
 * read-only, and every mount beneath them too, but where `writable`
 * says; /proc a procfs of its own pid namespace (`place_proc`) -- and
 * nothing else, so a path outside them is not there at all, to stat as
 * to open. The paths are resolved, with no link or `..` left in them;
 * `at` holds, for each bound at a name of the caller's choosing rather
 * than its own, that name, and NULL elsewhere -- where each is placed,
 * its name or its path, a shorter coming before a longer. `names` holds
 * the names they were given by where one differs from its path and it
 * has no `at`, and NULL elsewhere, and each such name is a link in the
 * root to its path, where no path placed holds it already. `root` is an
 * empty directory the parent made to build on; `mapped` says whether
 * the child's user is mapped (`map_ids`); `own` says, once it is built,
 * whether its /proc is a procfs of its own (`place_proc`). The root is
 * this process's own and its working directory's, and every process's
 * in the namespace whose root was the old one. 0, or an errno.
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
                       const char *const *at, const int *writable, int count, int mapped,
                       int *own) {
  int number = 0;
  *own = 0;
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
  int tmp = 1;
  for (int i = 0; i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    if (strcmp(placed, "/tmp") == 0 || strcmp(placed, "/") == 0 ||
        (names[i] != NULL && strcmp(names[i], "/tmp") == 0)) {
      tmp = 0;
    }
  }
  if (tmp) {
    int made = snprintf(target, sizeof target, "%s/tmp", root);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    if (mkdir(target, 01777) != 0) return errno;
    if (mapped ? mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") != 0
               : chmod(target, 01777) != 0 || mount(target, target, NULL, MS_BIND, NULL) != 0)
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
      number = place_proc(target, &own_proc);
      if (number != 0) return number;
      continue;
    }
    if (mount(paths[i], target, NULL, MS_BIND | MS_REC, NULL) != 0) return errno;
    /* A path in the host's /proc is its state, read-only whoever asks:
     * /proc itself too, bound at another name (`at`). */
    if (!writable[i] || strncmp(paths[i], "/proc/", 6) == 0 || strcmp(paths[i], "/proc") == 0) {
      struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
      if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
        return errno;
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

/* In a child that is `offline` and unveils nothing, before anything
 * else of the sandbox: a user namespace of its own, mapping its user
 * and group to themselves, and a network namespace of its own, which
 * has nothing but a loopback, brought up; then it gives up every
 * capability they gave it. It keeps the host's pid namespace, as it
 * keeps the host's filesystem and /proc with it. 0, or an errno. */
static int go_offline (int unmap_root, const char *uid_map, const char *gid_map) {
  if (syscall(SYS_unshare, CLONE_NEWUSER | CLONE_NEWNET) != 0) return errno;
  int mapped = 1;
  int number = map_ids(unmap_root, uid_map, gid_map, &mapped);
  if (number == 0) number = loopback_up();
  if (number == 0) number = drop_capabilities();
  return number;
}
#endif

/* Everything a spawned child reads between starting and exec, made ready
 * by the parent: the child shares the parent's memory on Linux
 * (`spawn_child`), so it allocates nothing and writes nothing of the
 * parent's but the one thing it means to -- the coverage flags of the
 * functions it enters, and on the checked core UBSan's own state -- and
 * reads only this, which the parent holds, unchanged, until the child
 * has exec'd or ended. On Darwin the child is a copy (`start_child`),
 * which holds it to the same rules all the same. */
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
  /* The Landlock ruleset to restrict the child to, or -1. */
  int confine;
  int pledged;
#if defined(PLEDGE_ARCH)
  const struct sock_fprog *pledge;
#endif
  int unveiling;
  int offline;
  const char *root_dir;
  char *const *resolved_paths;
  char *const *given_names;
  const char *const *bound_at;
  const int *unveiled_writable;
  int unveil_count;
  const char *uid_map;
  const char *gid_map;
  /* Whether the child is root in a user namespace not the host's, which
   * may not map root into one of its own. */
  int unmap_root;
  /* With `user`: whether an unveiled child gives root up for `drop_uid`
   * and `drop_gid` (`start_program`), and the maps a process of this
   * one's writes of its namespace from outside (`map_from_outside`),
   * root's and theirs; `uid_map` and `gid_map` then map theirs alone,
   * for the namespace it makes as that user. */
  int dropping;
  uid_t drop_uid;
  gid_t drop_gid;
  const char *outer_uid_map;
  const char *outer_gid_map;
#if defined(__linux__)
  /* For an unveiled child: the tops of the stacks its init and its
   * program start on (`start_unveiled`), and where it writes their
   * pids, the one thing of the parent's it writes besides its coverage
   * flags. */
  char *init_stack;
  char *program_stack;
  /* And, for one that gives root up, the top of the stack the process
   * that maps it from outside runs on (`map_from_outside`). */
  char *helper_stack;
  pid_t *init;
  pid_t *program;
#endif
  /* The parent's signal mask from before it blocked every signal to
   * start the child, which the program is to start with. */
  sigset_t mask;
};

/* One past the highest signal number: Linux's real-time signals end at
 * 64, and Darwin's run to 31. */
#if defined(__linux__)
#define SIGNAL_LIMIT 65
#else
#define SIGNAL_LIMIT 32
#endif

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

/* The rest of a child's start once its sandbox's namespaces are made
 * (`spawn_child`): its process group -- for an unveiled child, a
 * session of its own, and so a group of its own whatever
 * `process_group` says, so the autogroup its writable /proc lets it set
 * (/proc/self/autogroup) is the sandbox's, not its parent's session's --
 * its directory, its descriptors moved from where `pinned` holds them,
 * Landlock's `confined` ruleset and the pledge, the parent's mask, and
 * exec. A failure goes to the parent over `status_fd` as an errno. */
static _Noreturn void run_program (const struct spawn_plan *plan, const int *pinned,
                                   int confined, int status_fd) {
  int top = plan->top;
  int failure = 0;
  if (plan->unveiling) {
    if (setsid() < 0) failure = errno;
  } else if (plan->process_group && setpgid(0, 0) != 0) {
    failure = errno;
  }
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
   * (`place_proc`), once `landlock_ruleset` records which paths a
   * ruleset holds: adding the rule here, in the child, would widen the
   * caller's ruleset for every later child besides, and a ruleset that
   * left /proc out would gain it. Until then a child held to one reads
   * nothing of its own /proc. */
  if (!failure && confined >= 0) {
#if defined(__linux__)
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) failure = errno;
    else if (syscall(SYS_landlock_restrict_self, confined, 0) != 0) failure = errno;
#else
    failure = ENOSYS;
#endif
  }
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
  if (!failure) execve(plan->path, plan->argv, plan->envp);
  if (!failure) failure = errno;
  report_child_error(status_fd, failure);
  _exit(127);
}

#if defined(__linux__)
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

/* What an unveiled child (`start_unveiled`) shares with the init and
 * the program it starts, each on its memory and each while it waits:
 * the plan, and the descriptors `spawn_child` placed; whether its user
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
 * `cosmic_sandbox_init`, holding the started pipe's read end as 0, the
 * ready pipe's write end as 1 and the parent's status pipe's write end
 * as 2, and nothing else -- from / as the host has it still, where a
 * core linked dynamically (the checked one) finds its loader and
 * libraries, whatever the child is given. Its root and directory move
 * to the child's own when the program pivots (`start_program`). A
 * failure before that exec is its errno in the shared `init_error`. */
static _Noreturn int start_init (void *argument) {
  struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = drop_capabilities();
  if (!failure && chdir("/") != 0) failure = errno;
  /* Each source but the status pipe's is above the child's descriptors
   * (`raise_descriptor`), and that one, just above them, is moved
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
 * to hold it (`build_root`), gives up its capabilities, and runs the
 * program (`run_program`). */
static _Noreturn int start_program (void *argument) {
  const struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = 0;
  /* One that gives root up (`spawn`'s `user`) builds its root as root,
   * which reaches what only root may -- root's own files, mapped in its
   * namespace (`map_from_outside`) -- but makes it as that user, as an
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
  if (!failure)
    failure = build_root(plan->root_dir, plan->resolved_paths, plan->given_names,
                         plan->bound_at, plan->unveiled_writable, plan->unveil_count,
                         start->mapped, &own_proc);
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
  run_program(plan, start->pinned, start->confined, start->status_fd);
}

/* What an unveiled child that gives root up (`spawn`'s `user`) shares
 * with the process that maps its user namespace from outside
 * (`map_from_outside`): the plan, the child's pid, its /proc directory,
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
 * user namespace (`start_unveiled`), and so in this one's, as this
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

/* An unveiled child, from where `spawn_child` placed its descriptors:
 * it makes a user namespace of its own, which it maps (`map_ids`), a pid
 * namespace for what it starts, a mount namespace, System V IPC, and
 * with `offline` a network namespace with its loopback up
 * (`loopback_up`). The init it starts first is pid 1 of that namespace
 * (`start_init`); the program it starts next is pid 2, the parent's
 * child (`start_program`): signalled, stopped and reaped as any child
 * is, with the exit status its own, rather than a pid 1's, from which a
 * signal the program does not catch -- a SIGTERM, its own abort() --
 * would be dropped. Its pid is the one `spawn` answers. So the
 * program's own processes see, and signal, none but each other and
 * that init, which ignores them. The init is the parent's child too
 * (CLONE_PARENT), so no subreaper adopts it when this process ends, as
 * one would a stray (`waitpid` ends and reaps it with its program:
 * `end_sandbox_init`), and it ends if the parent does. This
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
  /* Through unshare, not clone's flags, which a container's seccomp
   * profile refuses where it lets unshare through (Docker's default,
   * narrowed as CI's is). Each namespace but the user's is the new
   * user namespace's own. */
  int flags = CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWIPC |
              (plan->offline ? CLONE_NEWNET : 0);
  int failure = 0;
  /* One that gives root up is mapped from outside (`map_from_outside`),
   * by a process started before its namespace is made, and waited for. */
  struct outside_map outside = { plan, (pid_t)syscall(SYS_getpid), -1, -1, -1, ECHILD };
  pid_t helper = -1;
  if (plan->dropping) {
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
  if (!failure && syscall(SYS_unshare, flags) != 0) failure = errno;
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
    failure = map_ids(plan->unmap_root, plan->uid_map, plan->gid_map, &start.mapped);
  if (!failure && plan->offline) failure = loopback_up();
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
#endif

/* The child `cosmic_spawn_unobserved` starts, from its start to exec:
 * on Linux on the parent's memory, through clone(CLONE_VM | CLONE_VFORK)
 * on a stack of its own, the parent stopped until this execs or ends;
 * on Darwin through fork, so on a copy. So it neither allocates nor touches the Lua state, writes only
 * its own stack and descriptors, the kernel's side of the process, and
 * errno (which is the parent's too on Linux; the parent reads none after
 * a start that succeeded) -- and, deliberately, the parent's memory in
 * one place on Linux: the coverage flag of each function it enters
 * (core/coverage.h), so a test is credited with what its child ran, and
 * on the checked core the sanitizer runtime's state (UBSan's report
 * dedup), which a report from here would write; an unveiled one writes
 * its program's pid too (`start_unveiled`). On Darwin those flags
 * land in the copy and are lost with it, so build/c_functions.tl
 * exempts this function there. It leaves by exec or _exit, never by
 * returning, so no atexit handler or stdio flush runs. A failure goes to
 * the parent over the status pipe as an errno. */
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
   * so a closed one stays closed. */
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
#if defined(__linux__)
  if (plan->unveiling) start_unveiled(plan, pinned, confined, status_fd);
  if (plan->offline && (failure = go_offline(plan->unmap_root, plan->uid_map, plan->gid_map)) != 0) {
    report_child_error(status_fd, failure);
    _exit(127);
  }
#endif
  run_program(plan, pinned, confined, status_fd);
}

#if defined(__linux__)
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

/* The sandbox's init, as `start_init` executes this program: pid 1 of
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

/* The stack a Linux child runs `spawn_child` on, above a guard page:
 * the most it needs is `build_root`'s paths and a libc's formatting, well
 * under this, and only the pages it touches are ever made. */
#define SPAWN_STACK_SIZE (256 * 1024)

/* Starts the child `plan` describes, with every signal blocked across
 * its start, so no handler of the parent's runs in the child, which
 * shares its memory on Linux: the child's pid, or -1 and the errno in
 * `error`.
 * Not fork, whose copy of a large parent's page tables costs more than
 * the rest of a start together (4.4 ms of the test runner's 8.2 ms per
 * test at 150 MB), and not posix_spawn, which has no step for a
 * namespace, a pivoted root, Landlock or a seccomp filter. On Linux,
 * clone(CLONE_VM | CLONE_VFORK) rather than vfork: the child runs on a
 * stack of its own, so nothing it calls can overwrite a frame the
 * parent returns to, and the static analyzer has no vfork to refuse.
 * posix_spawn is refused on Linux alone: Darwin's covers every step its
 * child takes (descriptors, cwd through posix_spawn_file_actions_addchdir_np,
 * a process group, the mask and defaults), having no sandbox to set up.
 * Darwin forks: macOS's libc makes vfork a fork anyway (Libc's
 * sys/fork.c: "vfork() is now just fork()"), and a plain fork gives the
 * child all it calls before exec without vfork's undefined behavior, at
 * fork's cost.
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
   * its program's (`start_unveiled`) -- and a fourth for the process
   * that maps one that gives root up (`map_from_outside`) -- each above a
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
  /* TODO: start the child through posix_spawn on Darwin, which covers
   * every step `spawn_child` takes there and spares a large parent
   * fork's copy, as clone spares it on Linux, once a macOS host can run
   * core/syscalls_test.tl and CI's macOS job against it: this path is
   * compiled and started only there. */
  pid = fork();
  if (pid == 0) spawn_child(plan);
  if (pid < 0) *error = errno;
#endif
  sigprocmask(SIG_SETMASK, &plan->mask, NULL);
  return pid;
}

/* Noted before it starts anything: the process table's own `spawn`,
 * called past build.confine's stand-in for it -- through
 * a reference taken before a capture began -- starts a process the
 * observer never judged. */
COSMIC_SYSCALL(spawn, 10) {
  if (cosmic_observing) {
    size_t length = 0;
    const char *path = lua_type(L, 1) == LUA_TSTRING
                           ? lua_tolstring(L, 1, &length)
                           : NULL;
    if (!cosmic_observed_note(COSMIC_OBSERVED_SPAWN, path, length)) {
      return cosmic_fail(L, ENOMEM);
    }
  }
  return cosmic_spawn_unobserved(L);
}

#if defined(__linux__)
/* An unveiled child's init and program, each this process's own child
 * (`start_unveiled`), until the init is reaped: `program` is -1 once the
 * program has been, and `init` once the init has. */
struct sandbox_pair {
  pid_t init;
  pid_t program;
};

/* Every such pair this process has not seen the end of, in `pairs`,
 * `pair_count` of them in room for `pair_room`. Room is made before a
 * child starts (`sandbox_room`), so recording one never fails. */
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
 * an uninterruptible wait -- is kept, for `end_sandbox_inits` to reap
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
 * second was not enough for (`end_sandbox_init`). */
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
 * ends its init (`end_sandbox_init`), and an init's forgets its pair. */
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
 * `Proc.relaunch` does: the retained descriptor, as the descriptor the
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

int cosmic_spawn_unobserved (lua_State *L) {
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
  const char *unveiled[UNVEIL_MAX];
  const char *unveiled_at[UNVEIL_MAX];
  int unveiled_writable[UNVEIL_MAX];
  int unveiling = 0, unveil_count = 0, offline = 0;
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
            unveil_count++;
            lua_pop(L, 1);
          }
        }
        lua_pop(L, 1);
      }
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
      if (!unveiling) return luaL_argerror(L, 10, "a user is given with unveil");
      dropping = 1;
      drop_uid = (uid_t)user;
      drop_gid = (gid_t)group;
    }
    lua_pop(L, 2);
  }
#if !defined(__linux__)
  if (unveiling || offline) return cosmic_fail(L, ENOSYS);
#else
  if (unveiling && !sandbox_room()) return cosmic_fail(L, errno);
#endif
  /* The child maps its own ids, or, giving root up, the user and group
   * it runs as; its namespace is mapped from outside then, with root's
   * beside them (`map_from_outside`). */
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
   * remapping below. */
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
        }
      }
    }
    if (!prepare_error && unveiling) {
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
  char **given = cosmic_coverage_environment(envp);
  struct spawn_plan plan = {
    .path = path, .argv = argv, .envp = given, .cwd = cwd, .source = source, .top = top,
    .status_read = status_read, .status_write = status_write,
    .descriptor_limit = descriptor_limit, .process_group = process_group,
    .confine = confine, .pledged = pledged,
#if defined(PLEDGE_ARCH)
    .pledge = &pledge,
#endif
    .unveiling = unveiling, .offline = offline, .root_dir = root_dir,
    .resolved_paths = resolved_paths, .given_names = given_names, .bound_at = unveiled_at,
    .unveiled_writable = unveiled_writable, .unveil_count = unveil_count,
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
   * and the child set it (`start_program`): whatever it was here, it is
   * put back once the child has exec'd. */
#if defined(__linux__)
  int dumpable = dropping ? prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) : -1;
#endif
  pid_t pid = start_child(&plan, &fork_error);
#if defined(__linux__)
  if ((dumpable == 0 || dumpable == 1) && prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) != dumpable)
    prctl(PR_SET_DUMPABLE, dumpable, 0, 0, 0);
#endif
  close(status_write);
  if (given != envp) free(given);
  if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
  free(argv);
  free(resolved);
  if (pid < 0) {
    close(status_read);
    if (root_dir[0] != '\0') rmdir(root_dir);
    return cosmic_fail(L, fork_error);
  }
  /* An unveiled child has ended once it started its program, which is
   * this process's child in its place (`start_unveiled`), or failed to. */
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
    return cosmic_fail(L, received == sizeof child_error ? child_error :
                       (read_error != 0 ? read_error : EIO));
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
  if (artifact->host) {
    /* A host program is its own launcher: executing it again is enough. */
    lua_createtable(L, 0, 2);
    lua_pushstring(L, physical);
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "host");
    return 1;
  }
  const struct cosmic_portable_entry *selected = &artifact->portable.selected;
  lua_createtable(L, 0, 5);
  lua_pushstring(L, physical);
  lua_setfield(L, -2, "path");
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

#define POLL_MAX 1024

COSMIC_SYSCALL(poll, 3) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer timeout = luaL_checkinteger(L, 3);
  if (timeout < -1 || timeout > INT_MAX)
    return luaL_argerror(L, 3, "timeout is out of range");
  lua_Integer count = (lua_Integer)lua_rawlen(L, 1);
  if (count > POLL_MAX) return luaL_argerror(L, 1, "too many descriptors");
  if ((lua_Integer)lua_rawlen(L, 2) != count)
    return luaL_argerror(L, 2, "one event mask per descriptor");
  struct pollfd fds[POLL_MAX];
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
    fds[i].fd = (int)fd;
    fds[i].events = (short)events;
    fds[i].revents = 0;
    lua_pop(L, 2);
  }
  /* An interrupted wait answers as a wait that found nothing, so the
   * caller's loop gets to look at whatever the signal meant. */
  if (poll(fds, (nfds_t)count, (int)timeout) < 0) {
    if (errno != EINTR) return cosmic_fail(L, errno);
    for (lua_Integer i = 0; i < count; i++) fds[i].revents = 0;
  }
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 0; i < count; i++) {
    lua_pushinteger(L, fds[i].revents);
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

COSMIC_SYSCALL(cpu_count, 0) {
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  lua_pushinteger(L, count < 1 ? 1 : (lua_Integer)count);
  return 1;
}

COSMIC_SYSCALL(uname, 0) {
  struct utsname info;
  if (uname(&info) != 0) {
    return cosmic_fail(L, errno);
  }
  lua_createtable(L, 0, 2);
  lua_pushstring(L, info.sysname);
  lua_setfield(L, -2, "sysname");
  lua_pushstring(L, info.machine);
  lua_setfield(L, -2, "machine");
  return 1;
}

static volatile sig_atomic_t child_cancelled;
static int child_signals_guarded;
static struct sigaction previous_int;
static struct sigaction previous_term;
/* Whether the guard caught each signal: one this process ignored stays
   ignored, as a shell's `&` or `trap '' INT` asked. */
static int int_caught;
static int term_caught;

/* The last signal delivered since the last read wins: a SIGTERM after a
   Ctrl-C a supervised child handled must not be lost to the earlier one.
   Two pending together arrive in the kernel's order, not the sender's. */
static void catch_child_cancel (int number) {
  child_cancelled = number;
}

bool cosmic_signal_caught (void) {
  return child_cancelled != 0;
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

COSMIC_SYSCALL(guard_child_signals, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail_effect(L, errno);
  if (child_signals_guarded) {
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, EBUSY);
  }
  struct sigaction action;
  action.sa_handler = catch_child_cancel;
  child_signal_set(&action.sa_mask);
  action.sa_flags = 0;
  child_cancelled = 0;
  if (sigaction(SIGINT, NULL, &previous_int) != 0 ||
      sigaction(SIGTERM, NULL, &previous_term) != 0) {
    int number = errno;
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, number);
  }
  int_caught = previous_int.sa_handler != SIG_IGN;
  term_caught = previous_term.sa_handler != SIG_IGN;
  if (int_caught && sigaction(SIGINT, &action, NULL) != 0) {
    int number = errno;
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, number);
  }
  if (term_caught && sigaction(SIGTERM, &action, NULL) != 0) {
    int number = errno;
    if (int_caught) sigaction(SIGINT, &previous_int, NULL);
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, number);
  }
  child_signals_guarded = 1;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0) {
    int number = errno;
    if (int_caught) sigaction(SIGINT, &previous_int, NULL);
    if (term_caught) sigaction(SIGTERM, &previous_term, NULL);
    child_signals_guarded = 0;
    return cosmic_fail_effect(L, number);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(unguard_child_signals, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  if (!child_signals_guarded) {
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    lua_pushinteger(L, 0);
    return 1;
  }
  int first = 0;
  if (int_caught && sigaction(SIGINT, &previous_int, NULL) != 0) first = errno;
  if (term_caught && sigaction(SIGTERM, &previous_term, NULL) != 0 && first == 0)
    first = errno;
  int cancelled = child_cancelled;
  child_signals_guarded = 0;
  child_cancelled = 0;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0 && first == 0)
    first = errno;
  if (first != 0) return cosmic_fail(L, first);
  lua_pushinteger(L, cancelled);
  return 1;
}

COSMIC_SYSCALL(cancelled_child_signal, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  int number = child_cancelled;
  child_cancelled = 0;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0)
    return cosmic_fail(L, errno);
  lua_pushinteger(L, number);
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
 * which only the raw `cosmic.internal.process` module holds. */
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
