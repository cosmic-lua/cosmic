/* The syscall table's process, time and data half, the module, and the
 * raw process table core/process.h declares. Starting children is
 * core/spawn.c's, and what holds a child or this process is
 * core/sandbox_root.c's and core/sandbox_rules.c's. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
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
#include <netinet/in.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#if defined(__linux__)
#include <linux/capability.h>
#include <linux/landlock.h>
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
 * on this process's memory (core/spawn.c's `start_child`). */
extern long syscall (long, ...);
extern int clone (int (*)(void *), void *, int, void *, ...);
#endif
#if defined(__APPLE__)
#include <spawn.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
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
#include "rand.h"
#include "startup.h"
#include "store.h"
#include "sandbox.h"

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

COSMIC_SYSCALL(stream_pair, 0) {
  lua_createtable(L, 2, 0);
  int pair[2];
#if defined(__linux__)
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) return cosmic_fail(L, errno);
#else
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return cosmic_fail(L, errno);
  if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(pair[1], F_SETFD, FD_CLOEXEC) != 0) {
    int failure = errno;
    close(pair[0]); close(pair[1]);
    return cosmic_fail(L, failure);
  }
#endif
  lua_pushinteger(L, pair[0]); lua_rawseti(L, -2, 1);
  lua_pushinteger(L, pair[1]); lua_rawseti(L, -2, 2);
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

COSMIC_SYSCALL(ttyname, 1) {
  int fd = cosmic_checkfd(L, 1);
  char name[PATH_MAX];
  int failure = ttyname_r(fd, name, sizeof name);
  if (failure != 0) return cosmic_fail(L, failure);
  lua_pushstring(L, name);
  return 1;
}

/* Allocate every Lua value before either descriptor: filling this sized
 * table and returning integer descriptors cannot raise after acquisition. */
COSMIC_SYSCALL(openpty, 0) {
  lua_createtable(L, 0, 2);
  lua_pushliteral(L, "slave");
  lua_pushliteral(L, "master");
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0) return cosmic_fail(L, errno);
  int failure = 0;
  int slave = -1;
  if (grantpt(master) != 0 || unlockpt(master) != 0) failure = errno;
  if (!failure) {
    /* cosmic is single-threaded, so the name stays valid until open. */
    char *name = ptsname(master);
    if (name == NULL) failure = errno;
    else {
      slave = open(name, O_RDWR | O_NOCTTY);
      if (slave < 0) failure = errno;
    }
  }
  /* One thread and no exec between these calls: portable CLOEXEC setup
   * cannot hand either descriptor to another process. */
  if (!failure && (fcntl(master, F_SETFD, FD_CLOEXEC) != 0 ||
                   fcntl(slave, F_SETFD, FD_CLOEXEC) != 0)) failure = errno;
  if (failure) {
    close(master);
    if (slave >= 0) close(slave);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, master);
  lua_rawset(L, -4);
  lua_pushinteger(L, slave);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(tcgetattr, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct termios state;
  memset(&state, 0, sizeof state);
  if (tcgetattr(fd, &state) != 0) return cosmic_fail(L, errno);
  lua_pushlstring(L, (const char *)&state, sizeof state);
  return 1;
}

COSMIC_SYSCALL(tcsetattr, 2) {
  int fd = cosmic_checkfd(L, 1);
  size_t size;
  const char *bytes = luaL_checklstring(L, 2, &size);
  luaL_argcheck(L, size == sizeof(struct termios), 2, "not a terminal state from tcgetattr");
  struct termios state;
  memcpy(&state, bytes, sizeof state);
  if (tcsetattr(fd, TCSANOW, &state) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(tcraw, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct termios state;
  if (tcgetattr(fd, &state) != 0) return cosmic_fail_effect(L, errno);
  /* POSIX does not specify cfmakeraw; spell the same flags on both hosts. */
  state.c_iflag &= (tcflag_t)~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
  state.c_oflag &= (tcflag_t)~OPOST;
  state.c_lflag &= (tcflag_t)~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
  state.c_cflag &= (tcflag_t)~(CSIZE | PARENB);
  state.c_cflag |= CS8;
  state.c_cc[VMIN] = 1;
  state.c_cc[VTIME] = 0;
  if (tcsetattr(fd, TCSANOW, &state) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(tcflush, 1) {
  int fd = cosmic_checkfd(L, 1);
  if (tcflush(fd, TCIOFLUSH) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(winsize, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct winsize size;
  memset(&size, 0, sizeof size);
  if (ioctl(fd, TIOCGWINSZ, &size) != 0) return cosmic_fail(L, errno);
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, size.ws_row);
  lua_setfield(L, -2, "rows");
  lua_pushinteger(L, size.ws_col);
  lua_setfield(L, -2, "columns");
  return 1;
}

COSMIC_SYSCALL(setwinsize, 3) {
  int fd = cosmic_checkfd(L, 1);
  int rows = cosmic_checkint(L, 2), columns = cosmic_checkint(L, 3);
  luaL_argcheck(L, rows >= 0 && rows <= USHRT_MAX, 2, "rows are outside 0..65535");
  luaL_argcheck(L, columns >= 0 && columns <= USHRT_MAX, 3, "columns are outside 0..65535");
  struct winsize size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns };
  if (ioctl(fd, TIOCSWINSZ, &size) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(controlling_terminal, 1) {
  int fd = cosmic_checkfd(L, 1);
  /* Refuse a non-terminal before changing the caller's session. A later
   * refusal may leave the new session: callers use this only pre-exec. */
  struct termios state;
  if (tcgetattr(fd, &state) != 0) return cosmic_fail_effect(L, errno);
  if (setsid() < 0) return cosmic_fail_effect(L, errno);
  if (ioctl(fd, TIOCSCTTY, 0) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
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

COSMIC_SYSCALL(rand_draw, 5) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer kind = luaL_checkinteger(L, 2);
  luaL_argcheck(L, kind >= COSMIC_RAND_FLOAT && kind <= COSMIC_RAND_GAMMA, 2, "the kind is not 0, 1 or 2");
  lua_Integer count = luaL_checkinteger(L, 3);
  luaL_argcheck(L, count >= 0 && count <= COSMIC_RAND_BULK_MAX, 3,
                "the count is negative or past 1048576");
  double first = (double)luaL_checknumber(L, 4), second = (double)luaL_checknumber(L, 5);
  if (kind == COSMIC_RAND_NORMAL) {
    luaL_argcheck(L, isfinite(first) && isfinite(second) && second >= 0.0, 4,
                  "a normal's mean and stddev must be finite, stddev not negative");
  } else if (kind == COSMIC_RAND_GAMMA) {
    luaL_argcheck(L, isfinite(first) && isfinite(second) && first > 0.0 && second > 0.0, 4,
                  "a gamma's shape and scale must be finite and positive");
  }
  struct cosmic_rand generator;
  for (int word = 0; word < 4; word++) {
    if (lua_rawgeti(L, 1, word + 1) != LUA_TNUMBER || !lua_isinteger(L, -1))
      return luaL_argerror(L, 1, "the state is not four integers");
    generator.s[word] = (uint64_t)lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  /* The table is made at its size before the first draw, so storing a
   * value cannot allocate or raise with the generator half advanced. */
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_pushnumber(L, cosmic_rand_next(&generator, (enum cosmic_rand_kind)kind, first, second));
    lua_rawseti(L, -2, i);
  }
  /* The four slots exist, read above, so storing back cannot allocate. */
  for (int word = 0; word < 4; word++) {
    lua_pushinteger(L, (lua_Integer)generator.s[word]);
    lua_rawseti(L, 1, word + 1);
  }
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
rlim_t check_limit (lua_State *L, int index) {
  lua_Integer value = luaL_checkinteger(L, index);
  luaL_argcheck(L, value >= 0, index, "a limit is not negative");
  return value == LUA_MAXINTEGER ? RLIM_INFINITY : (rlim_t)value;
}

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
 * by one (core/spawn.c's `close_child_descriptors`): a millisecond or two at this
 * bound, against most of a second at a million. */
#define DESCRIPTOR_LIMIT_RAISED 10240

/* RLIMIT_NOFILE's soft limit as this process started with it, while
 * `descriptor_limit_raised` says the start raised it and nothing has set
 * it since: what a program it execs is given back
 * ([`restore_descriptor_limit`]). A Linux child reads them on the
 * parent's memory before exec. */
static rlim_t started_descriptor_limit;
bool descriptor_limit_raised;

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

/* The limits [`restore_descriptor_limit`] sets, in `limits`, without
 * setting them: false where the start raised nothing to restore. */
bool restored_descriptor_limit (rlim_t least, struct rlimit *limits) {
  if (!descriptor_limit_raised || getrlimit(RLIMIT_NOFILE, limits) != 0) return false;
  rlim_t soft = started_descriptor_limit < least ? least : started_descriptor_limit;
  limits->rlim_cur = soft < limits->rlim_max ? soft : limits->rlim_max;
  return true;
}

/* Gives a program about to be exec'd the soft RLIMIT_NOFILE this
 * process started with, where the start raised it, so a host program --
 * a shell's `ulimit -n` -- sees what the user set; a relaunch of this
 * program raises it again. The hard limit stays as it is now, and bounds
 * the soft one where something lowered it since; `least` bounds it
 * from below, where a descriptor numbered under it is yet to be placed
 * (core/spawn.c's `spawn_program`). True where it lowered the limit. A refusal leaves
 * the raised one, which harms no program. */
bool restore_descriptor_limit (rlim_t least) {
  struct rlimit limits;
  return restored_descriptor_limit(least, &limits) && setrlimit(RLIMIT_NOFILE, &limits) == 0;
}

COSMIC_SYSCALL(setrlimit, 3) {
  int resource = cosmic_checkint(L, 1);
  struct rlimit limits = { .rlim_cur = check_limit(L, 2), .rlim_max = check_limit(L, 3) };
  if (setrlimit(resource, &limits) != 0) return cosmic_fail_effect(L, errno);
  /* A limit the program set is the one its children get. */
  if (resource == RLIMIT_NOFILE) descriptor_limit_raised = false;
  return cosmic_ok(L);
}

const char *plain_string (lua_State *L, int index, const char *what) {
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
size_t checked_argv (lua_State *L, int index) {
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
void checked_variable (lua_State *L, int index) {
  const char *name = plain_string(L, -2, "environment name");
  plain_string(L, -1, "environment value");
  if (*name == '\0' || strchr(name, '=') != NULL)
    luaL_argerror(L, index, "environment name is empty or contains '='");
}

/* Whether cosmic itself set SIGPIPE to be ignored, so that a program it
 * starts or becomes gets the default disposition back instead of
 * inheriting ours. */
int sigpipe_ignored_here;

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

COSMIC_SYSCALL(fd_status, 1) {
  int fd = cosmic_checkfd(L, 1);
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, flags);
  return 1;
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

COSMIC_SYSCALL(memory_available, 0) {
#if defined(__APPLE__)
  mach_port_t host = mach_host_self();
  vm_statistics64_data_t pages;
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  kern_return_t counted = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&pages, &count);
  vm_size_t page = 0;
  kern_return_t sized = host_page_size(host, &page);
  mach_port_deallocate(mach_task_self(), host);
  if (counted != KERN_SUCCESS || sized != KERN_SUCCESS) return cosmic_fail(L, EIO);
  /* The speculative pages are read ahead from files and counted free:
   * taken off once, in case the files' count holds them too. Where it
   * does not, the answer is low by them. */
  uint64_t available = (uint64_t)pages.free_count + (uint64_t)pages.external_page_count +
                       (uint64_t)pages.purgeable_count;
  uint64_t speculative = (uint64_t)pages.speculative_count;
  available = available > speculative ? available - speculative : 0;
  lua_pushinteger(L, (lua_Integer)(available * (uint64_t)page));
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}

/* The features `cpu_features` answers, by /proc/cpuinfo's names, in
 * byte order, each with where this processor says it has it: a bit of
 * a register of a cpuid leaf on x86_64, and of the auxiliary vector's
 * AT_HWCAP on Linux's aarch64; a name sysctlbyname answers 1 for on
 * Darwin's. */
#if defined(__aarch64__) && defined(__APPLE__)
struct cpu_feature {
  const char *name;
  const char *sysctl;
};

static const struct cpu_feature cpu_features[] = {
  { "aes", "hw.optional.arm.FEAT_AES" }, { "asimd", "hw.optional.AdvSIMD" },
  { "crc32", "hw.optional.armv8_crc32" }, { "pmull", "hw.optional.arm.FEAT_PMULL" },
  { "sha2", "hw.optional.arm.FEAT_SHA256" }, { "sha512", "hw.optional.armv8_2_sha512" },
};
#elif defined(__x86_64__)
struct cpu_feature {
  const char *name;
  unsigned leaf;
  unsigned subleaf;
  unsigned reg; /* 0 eax, 1 ebx, 2 ecx */
  unsigned bit;
};

/* core/vector.c chooses its int8 kernel by the last four of leaf 7 (and
 * by the operating system's saved vector state, which cpuid does not say:
 * a kernel that saves none lists fewer in /proc/cpuinfo than cpuid does,
 * and the kernels answer alike, so a key that holds the cpuid bits is
 * enough). patch/mbedtls's SHA-256 takes `sha_ni` with `sse4_1` and
 * `ssse3`. */
static const struct cpu_feature cpu_features[] = {
  { "aes", 1, 0, 2, 25 }, { "avx512_vnni", 7, 0, 2, 11 }, { "avx512f", 7, 0, 1, 16 },
  { "avx512vl", 7, 0, 1, 31 }, { "avx_vnni", 7, 1, 0, 4 }, { "pclmulqdq", 1, 0, 2, 1 },
  { "sha_ni", 7, 0, 1, 29 }, { "sse4_1", 1, 0, 2, 19 }, { "ssse3", 1, 0, 2, 9 },
};
#elif defined(__aarch64__) && defined(__linux__)
struct cpu_feature {
  const char *name;
  unsigned bit;
};

static const struct cpu_feature cpu_features[] = {
  { "aes", 3 }, { "asimd", 1 }, { "crc32", 7 }, { "pmull", 4 }, { "sha2", 6 }, { "sha512", 21 },
};
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
#elif defined(__x86_64__)
  lua_Integer count = 0;
  for (size_t f = 0; f < sizeof cpu_features / sizeof *cpu_features; f++) {
    unsigned int registers[4];
    /* A leaf the processor lacks answers none of its features. */
    if (!__get_cpuid_count(cpu_features[f].leaf, cpu_features[f].subleaf, &registers[0],
                           &registers[1], &registers[2], &registers[3])) {
      continue;
    }
    if (((registers[cpu_features[f].reg] >> cpu_features[f].bit) & 1) == 0) continue;
    lua_pushstring(L, cpu_features[f].name);
    lua_rawseti(L, -2, ++count);
  }
#elif defined(__aarch64__) && defined(__linux__)
  unsigned long bits = getauxval(AT_HWCAP);
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

#if defined(__APPLE__)
static void ifaddrs_release (void *resource) {
  freeifaddrs(resource);
}

/* How many leading one bits the `size` bytes of `mask` from `offset` hold.
 * Darwin's kernel shortens a netmask's sockaddr to its last nonzero byte
 * (its sa_len says how far), so a byte past sa_len is zero, not read. */
static lua_Integer netmask_prefix (const struct sockaddr *mask, size_t offset, size_t size) {
  const unsigned char *bytes = (const unsigned char *)mask;
  size_t held = mask->sa_len;
  lua_Integer bits = 0;
  for (size_t i = offset; i < offset + size && i < held; i++) {
    unsigned byte = bytes[i];
    while (byte & 0x80u) {
      bits++;
      byte = (byte << 1) & 0xffu;
    }
    if (bytes[i] != 0xff) break;
  }
  return bits;
}
#endif

COSMIC_SYSCALL(getifaddrs, 0) {
#if defined(__APPLE__)
  struct cosmic_guard *guard = cosmic_guard_push(L, ifaddrs_release);
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) != 0) return cosmic_fail(L, errno);
  guard->resource = list;
  lua_newtable(L);
  lua_Integer count = 0;
  for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
    if (entry->ifa_addr == NULL) continue;
    sa_family_t family = entry->ifa_addr->sa_family;
    char text[INET6_ADDRSTRLEN];
    lua_Integer prefix = 0;
    if (family == AF_INET) {
      const struct sockaddr_in *v4 = (const struct sockaddr_in *)entry->ifa_addr;
      if (inet_ntop(AF_INET, &v4->sin_addr, text, sizeof text) == NULL) return cosmic_fail(L, errno);
      if (entry->ifa_netmask != NULL) {
        prefix = netmask_prefix(entry->ifa_netmask, offsetof(struct sockaddr_in, sin_addr), sizeof v4->sin_addr);
      }
    } else if (family == AF_INET6) {
      struct in6_addr address = ((const struct sockaddr_in6 *)entry->ifa_addr)->sin6_addr;
      /* Darwin's kernel keeps a link-local address's interface index in
       * its second group (KAME's embedded scope); the address itself has
       * zeros there. */
      if (IN6_IS_ADDR_LINKLOCAL(&address)) {
        address.s6_addr[2] = 0;
        address.s6_addr[3] = 0;
      }
      if (inet_ntop(AF_INET6, &address, text, sizeof text) == NULL) return cosmic_fail(L, errno);
      if (entry->ifa_netmask != NULL) {
        prefix = netmask_prefix(entry->ifa_netmask, offsetof(struct sockaddr_in6, sin6_addr), sizeof address);
      }
    } else {
      continue;
    }
    lua_createtable(L, 0, 6);
    lua_pushstring(L, entry->ifa_name);
    lua_setfield(L, -2, "name");
    lua_pushstring(L, family == AF_INET ? "ipv4" : "ipv6");
    lua_setfield(L, -2, "family");
    lua_pushstring(L, text);
    lua_setfield(L, -2, "address");
    lua_pushinteger(L, prefix);
    lua_setfield(L, -2, "prefix");
    lua_pushboolean(L, (entry->ifa_flags & IFF_UP) != 0);
    lua_setfield(L, -2, "up");
    lua_pushboolean(L, (entry->ifa_flags & IFF_LOOPBACK) != 0);
    lua_setfield(L, -2, "loopback");
    lua_rawseti(L, -2, ++count);
  }
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
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
