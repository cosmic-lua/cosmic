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
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
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
#include "fault.h"
#include "guard.h"
#include "memory.h"
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

COSMIC_SYSCALL(getuid, 0) {
  lua_pushinteger(L, (lua_Integer)getuid());
  return 1;
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
  int fd = cosmic_checkint(L, 1);
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

  size_t count = lua_rawlen(L, 2);
  if (count > (size_t)LUA_MAXINTEGER ||
      count > SIZE_MAX / sizeof(char *) - 1)
    return luaL_argerror(L, 2, "argv is too large");
  for (size_t i = 1; i <= count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    plain_string(L, -1, "argv entry");
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
    const char *name = plain_string(L, -2, "environment name");
    plain_string(L, -1, "environment value");
    if (*name == '\0' || strchr(name, '=') != NULL)
      return luaL_argerror(L, 3, "environment name is empty or contains '='");
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
 * `unveil` closes the first and the socket paths, and `offline` the rest. */
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

/* The most paths a sandbox unveils. */
#define UNVEIL_MAX 64

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
/* Writes `text` to the file at `path` whole: 0, or an errno. */
static int write_whole (const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
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

/* Makes every directory `path` names but its last, as `mkdir -p` does,
 * writing into `path` and putting it back, each with the mode of the one
 * it stands for (`mirrored_mode`): 0, or an errno. */
static int make_parents (char *path, size_t skip) {
  for (char *at = path + skip + 1; *at != '\0'; at++) {
    if (*at != '/') continue;
    *at = '\0';
    int number = make_mirrored(path, skip);
    *at = '/';
    if (number != 0 && number != EEXIST) return number;
  }
  return 0;
}

/* Makes a link at `path`, under the root being built, to `to`, making its
 * parents as `make_parents` does but going through no link and making
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
struct cosmic_mount_attr {
  uint64_t attr_set, attr_clr, propagation, userns_fd;
};

/* In the child, before anything else of the sandbox: a user namespace of
 * its own, mapping its user and group to themselves; with `offline`, a
 * network namespace of its own, which has nothing but a loopback that is
 * down; and with `unveiling`, System V IPC of its own, and a root of
 * its own in a mount namespace, with a /tmp of its own unless /tmp or
 * / is among the paths,
 * holding the `count` paths at their own names -- read-only, and every
 * mount beneath them too, but where `writable` says -- and nothing else,
 * so a path outside them is not there at all, to stat as to open. The
 * paths are resolved, with no link or `..` left in them, and a shorter
 * comes before a longer; `names` holds the names they were given by where
 * one differs from its path, and NULL elsewhere, and each such name is a
 * link in the root to its path, where no path given holds it already.
 * `root` is an empty directory the parent made to build on. Last, the child gives up every capability the namespace gave
 * it, so a caller's root cannot undo a read-only mount or make one of its
 * own. 0, or an errno.
 * TODO: a pid namespace too, so an unveiled /proc shows the child's own
 * processes rather than the host's; the child that unshares one is not
 * in it, so this waits on starting the program from a second fork. A
 * UTS namespace would change nothing a child sees: its host's name and
 * kernel stay what `uname` answers, which no key holds. */
static int unveil (const char *root, char *const *paths, char *const *names,
                   const int *writable, int count, int unveiling, int offline, const char *uid_map, const char *gid_map) {
  int flags = CLONE_NEWUSER | (unveiling ? CLONE_NEWNS | CLONE_NEWIPC : 0) |
              (offline ? CLONE_NEWNET : 0);
  if (syscall(SYS_unshare, flags) != 0) return errno;
  int number = write_whole("/proc/self/setgroups", "deny");
  if (number != 0 && number != ENOENT) return number;
  if ((number = write_whole("/proc/self/uid_map", uid_map)) != 0) return number;
  if ((number = write_whole("/proc/self/gid_map", gid_map)) != 0) return number;
  if (unveiling) {
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return errno;
    if (mount("tmpfs", root, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755") != 0) return errno;
    char target[PATH_MAX];
    /* A /tmp of its own, writable and empty but for the paths given
     * beneath the host's, which a program takes for granted -- unless
     * /tmp or / is given, under its own name or another; mounted first,
     * so a path given beneath the host's /tmp is bound into it. */
    int tmp = 1;
    for (int i = 0; i < count; i++) {
      if (strcmp(paths[i], "/tmp") == 0 || strcmp(paths[i], "/") == 0 ||
          (names[i] != NULL && strcmp(names[i], "/tmp") == 0)) {
        tmp = 0;
      }
    }
    if (tmp) {
      int made = snprintf(target, sizeof target, "%s/tmp", root);
      if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
      if (mkdir(target, 01777) != 0) return errno;
      if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") != 0) return errno;
    }
    for (int i = 0; i < count; i++) {
      struct stat st;
      if (stat(paths[i], &st) != 0) return errno;
      int length = snprintf(target, sizeof target, "%s%s", root, paths[i]);
      if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
      struct stat there;
      if (lstat(target, &there) != 0) {
        if ((number = make_parents(target, strlen(root))) != 0) return number;
        if (S_ISDIR(st.st_mode)) {
          if (mkdir(target, 0755) != 0 && errno != EEXIST) return errno;
        } else {
          int fd = open(target, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
          if (fd < 0) return errno;
          close(fd);
        }
      }
      if (mount(paths[i], target, NULL, MS_BIND | MS_REC, NULL) != 0) return errno;
      if (!writable[i]) {
        struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
        if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
          return errno;
      }
    }
    for (int i = 0; i < count; i++) {
      if (names[i] == NULL) continue;
      int held = 0;
      for (int j = 0; j < count && !held; j++) {
        size_t n = strlen(paths[j]);
        held = strncmp(names[i], paths[j], n) == 0 &&
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
      proc = proc || strcmp(paths[i], "/proc") == 0;
      dev = dev || strcmp(paths[i], "/dev") == 0 || strcmp(paths[i], "/") == 0;
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
  }
  for (int cap = 0; cap < 64; cap++) {
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0 && errno != EINVAL) return errno;
  }
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 && errno != EINVAL)
    return errno;
  return 0;
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
  const int *unveiled_writable;
  int unveil_count;
  const char *uid_map;
  const char *gid_map;
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
 * dedup), which a report from here would write. On Darwin those flags
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
  if (plan->unveiling || plan->offline) {
    failure = unveil(plan->root_dir, plan->resolved_paths, plan->given_names,
                     plan->unveiled_writable, plan->unveil_count, plan->unveiling,
                     plan->offline, plan->uid_map, plan->gid_map);
  }
#endif
  if (!failure && plan->process_group && setpgid(0, 0) != 0) failure = errno;
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
   * it starts may reach is the ruleset's, and nothing lets it off. */
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

/* The stack a Linux child runs `spawn_child` on, above a guard page:
 * the most it needs is `unveil`'s paths and a libc's formatting, well
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
  size_t size = SPAWN_STACK_SIZE + (size_t)page;
  char *stack = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (stack == MAP_FAILED) {
    *error = errno;
  } else if (mprotect(stack, (size_t)page, PROT_NONE) != 0) {
    *error = errno;
    munmap(stack, size);
  } else {
    pid = clone(spawn_child, stack + size, CLONE_VM | CLONE_VFORK | SIGCHLD, plan);
    if (pid < 0) *error = errno;
    /* The child has exec'd or ended: its stack is done with. */
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
 * called past build.filesystem_observations' stand-in for it -- through
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

int cosmic_spawn_unobserved (lua_State *L) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  if (!lua_isnoneornil(L, 3)) luaL_checktype(L, 3, LUA_TTABLE);
  const char *cwd = lua_isnoneornil(L, 4) ? NULL : plain_string(L, 4, "cwd");
  /* source[t] is the parent descriptor the child sees as t, or -1: for
   * 0..2 that means inherit, above that it means closed. */
  int source[CHILD_FD_MAX + 1];
  for (int i = 0; i <= CHILD_FD_MAX; i++) source[i] = -1;
  for (int i = 0; i < 3; i++) {
    if (lua_isnoneornil(L, 5 + i)) continue;
    if (!lua_isinteger(L, 5 + i))
      return luaL_argerror(L, 5 + i, "descriptor must be an integer");
    lua_Integer value = lua_tointeger(L, 5 + i);
    if (value < 0 || value > INT_MAX)
      return luaL_argerror(L, 5 + i, "descriptor is out of range");
    source[i] = (int)value;
  }
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
  int unveiled_writable[UNVEIL_MAX];
  int unveiling = 0, unveil_count = 0, offline = 0;
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
            unveiled_writable[unveil_count] = w;
            unveil_count++;
            lua_pop(L, 1);
          }
        }
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    lua_pushliteral(L, "offline");
    lua_rawget(L, 10);
    offline = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
#if !defined(__linux__)
  if (unveiling || offline) return cosmic_fail(L, ENOSYS);
#endif
  char uid_map[64], gid_map[64];
  snprintf(uid_map, sizeof uid_map, "%lu %lu 1\n", (unsigned long)geteuid(),
           (unsigned long)geteuid());
  snprintf(gid_map, sizeof gid_map, "%lu %lu 1\n", (unsigned long)getegid(),
           (unsigned long)getegid());
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

  size_t argc = lua_rawlen(L, 2);
  if (argc == 0) {
    return luaL_argerror(L, 2, "argv is empty");
  }
  if (argc > (size_t)LUA_MAXINTEGER ||
      argc > SIZE_MAX / sizeof(char *) - 1)
    return luaL_argerror(L, 2, "argv is too large");
  /* Validate everything that can raise before allocating native memory. */
  for (size_t i = 1; i <= argc; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    plain_string(L, -1, "argv entry");
    lua_pop(L, 1);
  }

  lua_Integer envc = 0;
  if (!lua_isnoneornil(L, 3)) {
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      const char *name = plain_string(L, -2, "environment name");
      plain_string(L, -1, "environment value");
      if (*name == '\0' || strchr(name, '=') != NULL)
        return luaL_argerror(L, 3, "environment name is empty or contains '='");
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
        if (plain_name(name) && strcmp(name, resolved_paths[i]) != 0) given_names[i] = name;
      }
      for (int i = 1; !prepare_error && i < unveil_count; i++) {
        for (int j = i; j > 0 && strlen(resolved_paths[j]) < strlen(resolved_paths[j - 1]); j--) {
          char *p = resolved_paths[j];
          resolved_paths[j] = resolved_paths[j - 1];
          resolved_paths[j - 1] = p;
          char *q = given_names[j];
          given_names[j] = given_names[j - 1];
          given_names[j - 1] = q;
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
    .resolved_paths = resolved_paths, .given_names = given_names,
    .unveiled_writable = unveiled_writable, .unveil_count = unveil_count,
    .uid_map = uid_map, .gid_map = gid_map,
  };
  int fork_error = 0;
  pid_t pid = start_child(&plan, &fork_error);
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
  if (received != 0 || read_error != 0) {
    int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
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
  int fd = cosmic_checkint(L, 1);
  int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (copy < 0) return cosmic_fail(L, errno);
  /* Nothing between the copy and its push can raise: pushing an integer
   * allocates nothing, so the copy cannot leak. */
  lua_pushinteger(L, copy);
  return 1;
}

COSMIC_SYSCALL(fd_flags, 1) {
  int fd = cosmic_checkint(L, 1);
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, flags);
  return 1;
}

COSMIC_SYSCALL(dup2, 2) {
  int fd = cosmic_checkint(L, 1);
  int to = cosmic_checkint(L, 2);
  int made;
  do { made = dup2(fd, to); } while (made < 0 && errno == EINTR);
  if (made < 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(set_nonblocking, 2) {
  int fd = cosmic_checkint(L, 1);
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
