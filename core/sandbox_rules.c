/* What holds a process: Landlock's rights and the ruleset `grants`
 * make, the Seatbelt profile and the trampoline that applies it on
 * macOS, and `restrict_self`, which holds this process itself. */

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
 * and so hands its artifact's descriptor on to no child (core/spawn.c's `handed_on`):
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
 * given up for good before the worker runs (core/sandbox_root.c's `drop_capabilities`), root
 * as any user, and what it starts has none to gain; unsandboxed it has
 * the program by name anyway. The process itself is its own tracer
 * still, so its /proc/self stays its own to read. What moves is the
 * owner of its /proc/<pid>, which the kernel gives root of that user
 * namespace, or the host's where that has none: a child of it on its
 * memory before exec (core/sandbox_root.c's `spawn_child`), a process it confines or takes
 * offline, is refused writing its /proc/self/uid_map there, where the
 * process is not root (EACCES). A process held so is refused every
 * mount already (Landlock), so what this takes from it is a network
 * namespace of its own without a root of its own, which no test of the
 * tree that does not declare `tool` asks for. A file of its own
 * /proc/self that only its owner may read (environ, auxv) it may no
 * longer read either, where it is not root; no test of the tree does.
 * Nor, undumpable, does it write a core dump when it crashes. */
bool artifact_kept;

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
   * before it is held: what it finds names no path the ruleset changes. */
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

#if defined(__APPLE__)

/* Past every RLIMIT_ resource Darwin has (the most is 9): setrlimit
 * itself fails with EINVAL for one in between, and this keeps the cast to
 * `int` honest. */
#define TRAMPOLINE_RESOURCE_MAX 32

/* `text` as the whole of an unsigned decimal number. */
static bool trampoline_number (const char *text, unsigned long long *into) {
  if (text[0] < '0' || text[0] > '9') return false;
  char *end;
  errno = 0;
  *into = strtoull(text, &end, 10);
  return errno == 0 && *end == '\0';
}

bool cosmic_trampoline_asked (int argc, char **argv) {
  unsigned long long status;
  struct stat held;
  return argc >= TRAMPOLINE_LEAST && strcmp(argv[0], COSMIC_TRAMPOLINE) == 0 &&
         trampoline_number(argv[1], &status) && status <= (unsigned long long)CHILD_FD_MAX + 1 &&
         fstat((int)status, &held) == 0 && S_ISFIFO(held.st_mode);
}

/* Writes the whole of `bytes` to `fd`, as far as it can be. */
static bool trampoline_write (int fd, const void *bytes, size_t length) {
  const char *at = bytes;
  while (length > 0) {
    ssize_t put = write(fd, at, length);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) return false;
    at += put;
    length -= (size_t)put;
  }
  return true;
}

/* A trampoline's failure, which ends it: the errno and then, where there
 * is one, the text of the refusal, on the status pipe, which the parent
 * reads to its end (the spawn binding). Where the pipe cannot be
 * written the parent would take the start for a success, so the trampoline
 * kills itself instead, and the program is a child that died of a signal
 * and never ran. */
static _Noreturn void trampoline_fail (int status, int number, const char *message) {
  if (!trampoline_write(status, &number, sizeof number)) {
    cosmic_coverage_report();
    kill(getpid(), SIGKILL);
    _exit(127);
  }
  if (message != NULL) {
    size_t length = strlen(message);
    trampoline_write(status, message, length < TRAMPOLINE_MESSAGE_MAX ? length : TRAMPOLINE_MESSAGE_MAX);
  }
  cosmic_coverage_report();
  _exit(127);
}

/* The system's own symbol `name`, which libSystem carries but no header
 * the build has declares, as an address. */
static void *seatbelt_symbol (const char *name) {
  return dlsym(RTLD_DEFAULT, name);
}

typedef void (*seatbelt_free_function) (char *error);

/* libsystem_sandbox's private sandbox_init_with_parameters, or NULL where
 * this system has none. Found at run time, so the build needs no SDK
 * header for it, and where it is not found a start that needs it fails
 * rather than runs unconfined.
 * TODO: fall back to /usr/bin/sandbox-exec, which applies a profile and
 * executes a program too, once a macOS release is seen to lack the symbol:
 * every release the macOS leg runs on has it. A refusal of a profile is
 * never retried either way. */
seatbelt_init_function seatbelt_init (void) {
  void *symbol = seatbelt_symbol("sandbox_init_with_parameters");
  seatbelt_init_function function = NULL;
  memcpy(&function, &symbol, sizeof function);
  return function;
}

static seatbelt_free_function seatbelt_release (void) {
  void *symbol = seatbelt_symbol("sandbox_free_error");
  seatbelt_free_function function = NULL;
  memcpy(&function, &symbol, sizeof function);
  return function;
}

/* Whether this process holds itself to a Seatbelt profile already
 * (`restrict_self`). macOS refuses a second profile to a process (EPERM),
 * so neither a second restriction nor a child's own profile, which the
 * trampoline would apply beneath this one, is tried once one holds: each
 * is refused in words first. A process forked from this one has both the
 * profile and this flag; one it executes has the profile alone, and the
 * system refuses it a second. */
static bool seatbelt_held;

typedef int (*seatbelt_check_function) (pid_t pid, const char *operation, int type, ...);

/* Whether a Seatbelt profile holds this process, as told by
 * libsystem_sandbox's sandbox_check called with no operation
 * (SANDBOX_FILTER_NONE, 0): one it was started under -- a policy's
 * child, which the trampoline's profile holds -- as well as one it
 * applied (`seatbelt_held`). 1 where one does,
 * 0 where none does or the system has no sandbox_check (which a system
 * with sandbox_init has), and -1 with the errno in `error` where
 * sandbox_check fails, which tells neither. */
int seatbelt_holding (int *error) {
  if (seatbelt_held) return 1;
  void *symbol = seatbelt_symbol("sandbox_check");
  seatbelt_check_function check = NULL;
  memcpy(&check, &symbol, sizeof check);
  if (check == NULL) return 0;
  errno = 0;
  int answer = check(getpid(), NULL, 0);
  if (answer < 0) {
    *error = errno != 0 ? errno : EPERM;
    return -1;
  }
  return answer != 0;
}

/* Applies the Seatbelt `profile` to this process, with `parameters` (names
 * and values alternating, then NULL): 0, or the errno of the refusal, with
 * the reason in `text` (of `size` bytes). Shared by the trampoline and every
 * other start that confines a process, so none words a refusal otherwise. */
static int apply_seatbelt (const char *profile, const char *const parameters[], char *text,
                           size_t size) {
  seatbelt_init_function init = seatbelt_init();
  if (init == NULL) {
    snprintf(text, size, "sandbox_init_with_parameters is missing");
    return ENOSYS;
  }
  char *error = NULL;
  errno = 0;
  if (init(profile, 0, parameters, &error) == 0) return 0;
  int failure = errno != 0 ? errno : EINVAL;
  snprintf(text, size, "sandbox_init_with_parameters: %s", error != NULL ? error : "refused the profile");
  seatbelt_free_function release = seatbelt_release();
  if (error != NULL && release != NULL) release(error);
  return failure;
}

_Noreturn void cosmic_trampoline (int argc, char **argv) {
  cosmic_coverage_prepare();
  unsigned long long number = 0, session = 0, restore = 0, limit_count = 0, parameter_count = 0;
  /* [`cosmic_trampoline_asked`] found the descriptor to be a number. */
  trampoline_number(argv[1], &number);
  int status = (int)number;
  int failure = 0;
  char message[TRAMPOLINE_MESSAGE_MAX + 1];
  message[0] = '\0';
  bool restoring = strcmp(argv[3], "-") != 0;
  if (!trampoline_number(argv[2], &session) || (restoring && !trampoline_number(argv[3], &restore)) ||
      !trampoline_number(argv[4], &limit_count) || !trampoline_number(argv[5], &parameter_count) ||
      limit_count > SPAWN_RLIMIT_MAX || parameter_count > 2 * SEATBELT_PARAMETER_MAX)
    failure = EINVAL;
  size_t first_parameter = TRAMPOLINE_LIMITS + 2 * (size_t)limit_count;
  size_t program = first_parameter + (size_t)parameter_count;
  if (!failure && (size_t)argc < program + 1) failure = EINVAL;
  /* Closed when the program is executed, so the parent's read of the pipe
   * ends then; any other descriptor of this process is the program's. */
  if (!failure && fcntl(status, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
  /* Which step failed, in the text the parent reads with the errno. */
  const char *step = "";
  /* A confined program leads a session with no terminal, so it can neither
   * open the caller's through /dev/tty nor push input into it; the session is
   * a group of its own as well. */
  if (!failure && session) {
    step = "setsid";
    if (setsid() < 0) failure = errno;
  }
  /* The terminal a program is given is acquired here, before the profile,
   * which holds no one to open it: the session leader's open of a terminal
   * without O_NOCTTY makes it the controlling one on BSD, TIOCSCTTY does
   * where that open found it another session's already, and a bare setsid
   * leaves the program with none (/dev/tty is ENXIO) however the profile
   * grants it. The descriptors 0 to 2 hold the slave already. */
  const char *terminal = argv[7];
  if (!failure && terminal[0] != '\0') {
    step = "terminal";
    /* Nonblocking, so that a path that is no terminal (a FIFO) cannot hold
     * the start; and it must be the terminal descriptor 0 holds, which the
     * caller's contract names as the controlling one. */
    int fd = open(terminal, O_RDWR | O_NONBLOCK);
    struct stat opened, standard;
    if (fd < 0) {
      failure = errno;
    } else {
      if (!isatty(fd) || fstat(fd, &opened) != 0 || fstat(0, &standard) != 0 ||
          opened.st_rdev != standard.st_rdev)
        failure = ENOTTY;
      else if (tcgetsid(fd) != getsid(0) && ioctl(fd, TIOCSCTTY, 0) != 0) failure = errno;
      close(fd);
    }
  }
  /* As a Linux child does, in this order: the descriptor limit the program
   * started with, then the limits it is held to. */
  if (!failure && restoring) {
    step = "setrlimit";
    struct rlimit limits;
    if (getrlimit(RLIMIT_NOFILE, &limits) != 0) {
      failure = errno;
    } else {
      limits.rlim_cur = (rlim_t)restore < limits.rlim_max ? (rlim_t)restore : limits.rlim_max;
      if (setrlimit(RLIMIT_NOFILE, &limits) != 0) failure = errno;
    }
  }
  for (unsigned long long i = 0; !failure && i < limit_count; i++) {
    unsigned long long resource, value;
    step = "setrlimit";
    if (!trampoline_number(argv[TRAMPOLINE_LIMITS + 2 * i], &resource) ||
        !trampoline_number(argv[TRAMPOLINE_LIMITS + 2 * i + 1], &value) ||
        resource >= TRAMPOLINE_RESOURCE_MAX) {
      failure = EINVAL;
    } else {
      struct rlimit limits = { .rlim_cur = (rlim_t)value, .rlim_max = (rlim_t)value };
      if (setrlimit((int)resource, &limits) != 0) failure = errno;
    }
  }
  /* The program reports the C it runs to a test, which the profile may
   * not let it write: so the coverage of what is run here is reported
   * before the profile, which every line of this function up to now has
   * entered, and the environment it is given carries the report's name. */
  char **given = COSMIC_ENVIRON;
  if (!failure) given = cosmic_coverage_environment(COSMIC_ENVIRON);
  cosmic_coverage_report();
  const char *profile = argv[6];
  if (!failure && profile[0] != '\0') {
    step = "sandbox_init_with_parameters";
    /* Names and values, alternating, then NULL. */
    const char *parameters[2 * SEATBELT_PARAMETER_MAX + 1];
    for (size_t i = 0; i < (size_t)parameter_count; i++) parameters[i] = argv[first_parameter + i];
    parameters[parameter_count] = NULL;
    failure = apply_seatbelt(profile, parameters, message, sizeof message);
  }
  if (!failure) {
    step = "execve";
    execve(argv[program], argv + program + 1, given);
    failure = errno;
  }
  if (message[0] == '\0' && step[0] != '\0') snprintf(message, sizeof message, "%s", step);
  trampoline_fail(status, failure, message[0] != '\0' ? message : NULL);
}
#endif

#if defined(__linux__)

/* What the letters allow beneath a path on a kernel of this ABI. A right
 * the ABI lacks is left out, which the ruleset does not handle either.
 * `c` takes no device: LANDLOCK_ACCESS_FS_MAKE_CHAR and _BLOCK are
 * handled and never granted, so a sandboxed program makes no device
 * node, and a device file's ioctls (LANDLOCK_ACCESS_FS_IOCTL_DEV) are
 * refused too, whatever `w` allows of the file. */
uint64_t grant_rights (unsigned letters, long abi) {
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
 * one). */
static uint64_t grants_handled (long abi) {
  uint64_t handled = (LANDLOCK_ACCESS_FS_MAKE_SYM << 1) - 1;
  if (abi >= 2) handled |= LANDLOCK_ACCESS_FS_REFER;
  if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (abi >= 5) handled |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
  if (abi >= LANDLOCK_ABI_RESOLVE_UNIX) handled |= LANDLOCK_ACCESS_FS_RESOLVE_UNIX;
  return handled;
}

/* Whether the root a strict start builds from the `count` paths `resolved`
 * (each placed at `at`, or at its own name where that is NULL) shows no
 * directory and no socket file of the host's, and no descriptor the child
 * is handed leads to one: the facts a unix socket is harmless on where no
 * Landlock ABI tells one socket file from another ([`grants_ruleset`]), or
 * no ruleset holds the start at all (`nest`, in spawn).
 * What it shows is its own tmpfs (the root, and /tmp), a procfs of its own
 * pid namespace (core/sandbox_root.c's `place_proc`), and the paths bound: each a file that is
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
 * The paths are read by name here, and again by `build_root` (core/sandbox_root.c) once the
 * child binds them, which fails the start for one that is a directory or
 * a socket by then; so this decides, and the child enforces. */
bool root_shows_no_socket (char *const *resolved, const char *const *at, int count,
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
 * COSMIC_HELD_ bits): truncation (ABI 3), the signal scope (ABI 6),
 * and, where `unix_bound` (a root of the child's own that shows only its
 * grants) and `offline` (a network namespace of its own) too, that a unix
 * socket file is reached only by a `u` grant (ABI 9), or, below it, that
 * the root shows no socket file at all (`unix_tmp`,
 * [`root_shows_no_socket`]).
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
 * Below ABI 3 the promises filter holds truncation instead, refusing
 * what an open's write right does not hold (COSMIC_HELD_TRUNCATE).
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
 * on as the plan's `confine`, restricted by the child in
 * `run_program` (core/sandbox_root.c) before the promises filter, which follows it.
 * TODO: report a grant whose target (the path of its descriptor, read
 * from /proc/self/fd) differs from its name, once `spawn` can return the
 * resolutions it made beside the pid and [`cosmic.child`]'s policy start
 * (held_to in cosmic/child.tl) hands them to the caller on the Handle: it
 * prints nothing about grants, and `spawn` returns a pid alone. */
int grants_ruleset (const char *const *paths, const unsigned *letters, int count,
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
  if ((attr.handled_access_fs & LANDLOCK_ACCESS_FS_TRUNCATE) != 0) *held |= COSMIC_HELD_TRUNCATE;
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
   *   descriptors. Its mounts are private (core/sandbox_root.c's `build_root`), and the host's
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
   * (core/sandbox_root.c's `build_root`).
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

/* The layer a cosmic child's core applies to itself at boot: the grants
 * `text` names (COSMIC_SANDBOX_LAYER, which [`cosmic.child`]'s start of a
 * policy's cosmic program sets), each "<letters> <length>:<path>\n", as a
 * Landlock ruleset, and the no-x filter (core/promises.c's `cosmic_no_x_apply`) where no
 * grant has `x`. The start held the child to the policy and its start
 * files, the core's own `rx` among them; this second layer is the policy
 * alone, so the kernel, which holds the process to both, holds it to the
 * policy: a policy with no `x` runs no program, this core included.
 * It handles every filesystem right the ABI has and no network or scope:
 * the start's layer holds those, and a scope here would cut the child off
 * from what the start set up beside it. Run before any module loads, on
 * one thread, with no_new_privs set by the start (set again here). 0, or
 * an errno with why in `message`. */
int cosmic_boot_layer_apply (const char *text, char *message, size_t room) {
  message[0] = '\0';
  size_t length = strlen(text);
  char *copy = malloc(length + 1);
  if (copy == NULL) {
    snprintf(message, room, "no memory for the grants");
    return ENOMEM;
  }
  memcpy(copy, text, length + 1);
  const char *paths[GRANT_MAX];
  unsigned letters[GRANT_MAX];
  int count = 0;
  bool runs = false;
  char *at = copy;
  static const char order[] = "rwxcu";
  while (*at != '\0') {
    if (count >= GRANT_MAX) {
      free(copy);
      snprintf(message, room, "more than %d grants", GRANT_MAX);
      return E2BIG;
    }
    unsigned held = 0;
    while (*at != '\0' && *at != ' ') {
      const char *letter = strchr(order, *at);
      if (letter == NULL) break;
      held |= 1u << (letter - order);
      at++;
    }
    char *end = NULL;
    unsigned long long size = 0;
    if (*at == ' ') {
      errno = 0;
      size = strtoull(at + 1, &end, 10);
      if (errno != 0) end = NULL;
    }
    if (held == 0 || end == NULL || end == at + 1 || *end != ':' || size == 0 ||
        size > (unsigned long long)(copy + length - (end + 1)) || end[1 + size] != '\n') {
      free(copy);
      snprintf(message, room, "grant %d is not \"<letters> <length>:<path>\" and a newline",
               count + 1);
      return EINVAL;
    }
    char *path = end + 1;
    path[size] = '\0';
    paths[count] = path;
    letters[count] = held;
    if (held & GRANT_EXECUTE) runs = true;
    count++;
    at = path + size + 1;
  }
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) {
    int number = abi < 0 ? errno : ENOSYS;
    free(copy);
    snprintf(message, room, "Landlock is not available here (%s)",
             cosmic_errno_describe(number, NULL));
    return number;
  }
  struct grants_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.handled_access_fs = grants_handled(abi);
  long made = syscall(SYS_landlock_create_ruleset, &attr, sizeof attr.handled_access_fs, 0);
  if (made < 0) {
    int number = errno;
    free(copy);
    snprintf(message, room, "landlock_create_ruleset: %s", cosmic_errno_describe(number, NULL));
    return number;
  }
  int ruleset = (int)made;
  for (int i = 0; i < count; i++) {
    int fd = open(paths[i], O_PATH | O_CLOEXEC);
    struct stat st;
    int number = 0;
    if (fd < 0 || fstat(fd, &st) != 0) {
      number = errno;
      /* A grant the child cannot open (gone since the start, or beneath a
       * directory its user cannot search) gives it nothing to reach, and a
       * rule left out only narrows, so it is skipped. */
      if (number == ENOENT || number == EACCES || number == ELOOP || number == ENOTDIR) number = 0;
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
      snprintf(message, room, "grant %s: %s", paths[i], cosmic_errno_describe(number, NULL));
      free(copy);
      return number;
    }
  }
  free(copy);
  int failure = 0;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) failure = errno;
  if (!failure && syscall(SYS_landlock_restrict_self, ruleset, 0) != 0) failure = errno;
  close(ruleset);
  if (failure) {
    snprintf(message, room, "landlock_restrict_self: %s", cosmic_errno_describe(failure, NULL));
    return failure;
  }
  /* Where no filter is built for this architecture (ENOSYS), Landlock's
   * EXECUTE, which no rule grants, still refuses every execve of a file. */
  if (!runs) {
    failure = cosmic_no_x_apply();
    if (failure == ENOSYS) failure = 0;
    if (failure) {
      snprintf(message, room, "exec filter: %s", cosmic_errno_describe(failure, NULL));
      return failure;
    }
  }
  return 0;
}

#endif

/* The promises the list at stack index `list` names, as COSMIC_PROMISE_
 * bits: a name that is none is an error of argument `arg`. */
unsigned read_promises (lua_State *L, int list, int arg) {
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

/* The resources `spawn`'s `rlimits` names, by the key it takes. */
static const struct {
  const char *name;
  int resource;
} RLIMIT_NAMES[SPAWN_RLIMIT_MAX] = {
  { "nofile", RLIMIT_NOFILE }, { "fsize", RLIMIT_FSIZE }, { "cpu", RLIMIT_CPU },
  { "core", RLIMIT_CORE }, { "nproc", RLIMIT_NPROC },
};

/* The limits the table at stack index `table` names, by `RLIMIT_NAMES`,
 * into `into`, which holds SPAWN_RLIMIT_MAX: how many. */
int read_rlimits (lua_State *L, int table, int arg, struct spawn_rlimit *into) {
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
int read_grants (lua_State *L, int list, int arg, const char **paths, unsigned *letters) {
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

/* Returns `restrict_self`'s refusal: false, `what` formatted, and `number`. */
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

#if defined(__linux__)

/* The directories and file of this process's /proc a restriction reads,
 * held open from the first one: once Landlock holds the process, a path
 * of /proc is refused it, and a restriction made again must still count
 * the threads, descriptors and children it holds to. They are opened
 * before anything is restricted and read through descriptors, which
 * Landlock checks at open only. `inspected_by` is the process they
 * were opened by. Close-on-exec
 * and never listed as a descriptor the program holds
 * ([`unaccounted_descriptor`]). */
static struct {
  int tasks;
  int descriptors;
  int children;
  /* What each descriptor named when it was opened, to tell it from a
   * file the program closed it for and opened in its number. */
  struct stat identity[3];
} inspected = { -1, -1, -1, { { 0 } } };

pid_t inspected_by = 0;

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
 * fails closed rather than trust it. A copy a fork gave is let go so too
 * before the rest are closed, so a file the program put in its number --
 * one it names in fds, as a restriction asks -- stays open. */
static int inspected_open (const char **what) {
  pid_t self = getpid();
  inspected_forget(&inspected.tasks, &inspected.identity[0], true);
  inspected_forget(&inspected.descriptors, &inspected.identity[1], true);
  inspected_forget(&inspected.children, &inspected.identity[2], false);
  if (inspected_by == self && inspected.tasks >= 0 && inspected.descriptors >= 0 &&
      inspected.children >= 0)
    return 0;
  /* What is left of the three still names what it did. */
  inspected_close();
  inspected_by = self;
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

#endif

#if defined(__APPLE__)
/* The pid of a child of this process not yet reaped (libproc lists a
 * zombie among them), or 0 for none, or -1 with the errno in `error` where
 * they cannot be listed. Only the first is asked. */
static pid_t darwin_first_child (int *error) {
  pid_t pids[16];
  int count = proc_listchildpids(getpid(), pids, (int)sizeof pids);
  if (count < 0) {
    *error = errno;
    return -1;
  }
  return count > 0 ? pids[0] : 0;
}

/* The first descriptor above 2 that is open, is not one of the `kept` the
 * caller names and is not one the runtime keeps itself
 * (`cosmic_store_holds_descriptor`, core/store.c), or -1 for none; -2 with the errno in
 * `error` where they cannot be listed. libproc lists them, into a buffer a
 * guard on the stack holds, since the store's check calls into Lua; the
 * list is asked again, a few times, while it fills the room it is given. */
static int darwin_unaccounted_descriptor (lua_State *L, const int *kept, int kept_count,
                                          int *error) {
  struct cosmic_guard *guard = cosmic_guard_push(L, cosmic_free);
  pid_t self = getpid();
  for (int tries = 0; tries < 4; tries++) {
    int estimate = proc_pidinfo(self, PROC_PIDLISTFDS, 0, NULL, 0);
    if (estimate < 0) {
      *error = errno;
      return -2;
    }
    size_t room = (size_t)estimate + 32 * sizeof(struct proc_fdinfo);
    if (room > INT_MAX) room = INT_MAX;
    void *buffer = cosmic_realloc(guard->resource, room);
    if (buffer == NULL) {
      *error = ENOMEM;
      return -2;
    }
    guard->resource = buffer;
    int got = proc_pidinfo(self, PROC_PIDLISTFDS, 0, buffer, (int)room);
    if (got < 0) {
      *error = errno;
      return -2;
    }
    if ((size_t)got >= room) continue;
    const struct proc_fdinfo *listed = buffer;
    int found = -1;
    for (size_t i = 0; i < (size_t)got / sizeof *listed; i++) {
      int fd = listed[i].proc_fd;
      if (fd <= 2 || (found >= 0 && fd >= found)) continue;
      bool accounted = false;
      for (int k = 0; k < kept_count; k++) accounted = accounted || kept[k] == fd;
      if (!accounted && !cosmic_store_holds_descriptor(L, fd)) found = fd;
    }
    cosmic_guard_release(guard);
    return found;
  }
  *error = EAGAIN;
  return -2;
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
  lua_pushliteral(L, "seatbelt");
  lua_rawget(L, 1);
#if defined(__APPLE__)
  /* On Darwin the profile is the restriction: its text holds the paths and
   * what the promises allow, so `grants` and `promises` name nothing of
   * their own. The profile, its parameters and their strings stay on the
   * stack, as the grants do. */
  if (!lua_istable(L, -1))
    return luaL_argerror(L, 1, "seatbelt must be a table of a profile and its parameters: on "
                         "macOS a restriction is a Seatbelt profile");
  if (grant_count > 0 || promise_bits != 0)
    return luaL_argerror(L, 1, "grants and promises are the seatbelt profile's on macOS");
  int seatbelt = lua_gettop(L);
  lua_pushliteral(L, "profile");
  lua_rawget(L, seatbelt);
  const char *profile = plain_string(L, -1, "a seatbelt profile");
  if (profile[0] == '\0') return luaL_argerror(L, 1, "a seatbelt profile is empty");
  const char *parameters[2 * SEATBELT_PARAMETER_MAX + 1];
  int parameter_count = 0;
  lua_pushliteral(L, "parameters");
  lua_rawget(L, seatbelt);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1))
      return luaL_argerror(L, 1, "a seatbelt's parameters are a table of names and values");
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      if (lua_type(L, -2) != LUA_TSTRING)
        return luaL_argerror(L, 1, "a seatbelt parameter's name must be a string");
      if (parameter_count >= 2 * SEATBELT_PARAMETER_MAX)
        return luaL_argerror(L, 1, "too many seatbelt parameters");
      parameters[parameter_count++] = plain_string(L, -2, "a seatbelt parameter's name");
      parameters[parameter_count++] = plain_string(L, -1, "a seatbelt parameter's value");
      lua_pop(L, 1);
    }
  }
  parameters[parameter_count] = NULL;
#else
  if (!lua_isnil(L, -1))
    return luaL_argerror(L, 1, "seatbelt is macOS's: this system holds a process by Landlock "
                         "and seccomp");
  lua_pop(L, 1);
#endif
  for (int i = 0; i < kept_count; i++) {
    if (fcntl(kept[i], F_GETFD) < 0)
      return restrict_refused(L, errno, "descriptor %d, which fds names, is not open", kept[i]);
  }
#if defined(__linux__)
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
  /* Grants that give `x` nowhere run no program: Landlock refuses the
   * file, and a filter of its own refuses execve and execveat first, a
   * second layer that holds where the ruleset does not reach. */
  bool runs = false;
  for (int i = 0; i < grant_count; i++) runs = runs || (grant_letters[i] & GRANT_EXECUTE) != 0;
  if (!runs) {
    error = cosmic_no_x_apply();
    if (error != 0)
      return restrict_refused(L, error, "exec filter: %s%s", cosmic_errno_describe(error, NULL),
                              partly);
  }
  return cosmic_ok(L);
#elif defined(__APPLE__)
  /* A profile holds the whole process, every thread of it, so unlike
   * Landlock's ruleset no other thread refuses it; a child started before
   * it and a descriptor open before it are what it does not hold. */
  int error = 0;
  int holding = seatbelt_holding(&error);
  if (holding < 0)
    return restrict_refused(L, error, "whether a Seatbelt profile holds this process cannot be "
                            "told (sandbox_check: %s)", cosmic_errno_describe(error, NULL));
  if (holding > 0)
    return restrict_refused(L, EPERM, "this process is held by a Seatbelt profile already, "
                            "one it applied or was started under: macOS applies one profile "
                            "to a process and refuses a second");
  pid_t child = darwin_first_child(&error);
  if (child < 0)
    return restrict_refused(L, error, "the children of this process cannot be listed "
                            "(proc_listchildpids: %s)", cosmic_errno_describe(error, NULL));
  if (child > 0)
    return restrict_refused(L, ECHILD, "this process has a child, pid %ld, not waited for: end "
                            "it and wait for it first, since a restriction holds what a process "
                            "starts after it, not what it started", (long)child);
  int open_fd = darwin_unaccounted_descriptor(L, kept, kept_count, &error);
  if (open_fd == -2)
    return restrict_refused(L, error, "the descriptors of this process cannot be listed "
                            "(proc_pidinfo: %s)", cosmic_errno_describe(error, NULL));
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
  bool limits_moved = false;
  for (int i = 0; i < rlimit_count; i++) {
    if (!planned[i].changes) continue;
    if (setrlimit(rlimits[i].resource, &planned[i].target) != 0) {
      error = errno;
      return restrict_refused(L, error, "setrlimit: %s%s", cosmic_errno_describe(error, NULL),
                              limits_moved ? "; the process is now partly restricted" : "");
    }
    limits_moved = true;
    if (rlimits[i].resource == RLIMIT_NOFILE) descriptor_limit_raised = false;
  }
  char message[PATH_MAX + 256];
  error = apply_seatbelt(profile, parameters, message, sizeof message);
  if (error != 0)
    return restrict_refused(L, error, "%s%s", message,
                            limits_moved ? "; the process is now partly restricted" : "");
  seatbelt_held = true;
  return cosmic_ok(L);
#else
  (void)promise_bits;
  (void)rlimits;
  (void)rlimit_count;
  (void)grant_paths;
  (void)grant_letters;
  (void)grant_count;
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

#if defined(__linux__)
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
    /* The errno setuid fails with for an id this namespace does not map. */
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
 * a procfs of it as `place_proc` (core/sandbox_root.c) does, on the /proc of a mount
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
 * blocked, as `start_child` (core/spawn.c)'s is: makes its namespaces as
 * `start_unveiled` (core/sandbox_root.c) does -- through unshare, which a container's
 * seccomp profile lets through where it refuses clone's namespace
 * flags -- maps its ids as `map_ids` (core/sandbox_root.c) does for such a child, and starts
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
