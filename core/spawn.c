/* Starting and owning children: the plan a start is made from, the
 * child it starts (by clone on Linux, posix_spawn on Darwin), `spawn`,
 * waiting, signals, `relaunch`, `fork`, the subreaper and the guard of
 * child signals. */

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
 * on this process's memory ([`start_child`]). */
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

/* Whether `name` is absolute with no empty, `.` or `..` component, so it
 * names the same place under another root as under this one. */
static bool plain_name (const char *name) {
  if (name[0] != '/') return false;
  for (const char *at = name; *at != '\0'; at++) {
    if (*at != '/') continue;
    const char *next = at + 1;
    if (*next == '/') return false;
    if (next[0] == '.' && (next[1] == '/' || next[1] == '\0')) return false;
    if (next[0] == '.' && next[1] == '.' && (next[2] == '/' || next[2] == '\0')) return false;
  }
  return true;
}

static void free_environment (char **envp, lua_Integer count) {
  if (envp == NULL) return;
  for (lua_Integer i = 0; i < count; i++) free(envp[i]);
  free(envp);
}

#if defined(__linux__)
int report_child_error (int fd, int number) {
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
 * (core/syscalls.c's `DESCRIPTOR_LIMIT_RAISED`). */
void close_child_descriptors (int from, long limit) {
#if defined(SYS_close_range)
  if (syscall(SYS_close_range, (unsigned)from, ~0u, 0u) == 0) return;
#endif
  for (int fd = from; fd < limit; fd++) close(fd);
}
#endif

#if !defined(__linux__)
/* Darwin's start ([`start_child`]): posix_spawn, given as its attributes
 * and file actions what Linux's child does itself before exec
 * (core/sandbox_root.c's `spawn_child`), less the sandbox Darwin has none of -- its process
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
 * posix_spawn's own, so the status pipe is never written -- but for a
 * start that needs a step posix_spawn has none for: limits, a Seatbelt
 * profile, or a terminal to acquire. That one starts this program as
 * a trampoline instead (core/sandbox_rules.c's `cosmic_trampoline`), handed the status pipe,
 * which executes the program last and reports there what stopped it; a
 * profile's or a terminal's start leads a session, which replaces the process group. The child's
 * pid, or -1 and the errno in `error`. */
static pid_t spawn_program (const struct spawn_plan *plan, int *error) {
  /* Darwin has neither Landlock nor seccomp. */
  if (plan->confine >= 0 || plan->promising) {
    *error = ENOSYS;
    return -1;
  }
  bool terminal = plan->terminal_path != NULL;
  /* A terminal is acquired by the session leader that opens it, so its
   * start leads a session whatever the profile. */
  bool leads_session = plan->seatbelt_profile != NULL || terminal;
  bool trampolined = plan->rlimit_count > 0 || leads_session;
  /* A profile is applied by the system's own call, found before the child
   * starts so that a system without it fails the start here, ENOSYS. */
  if (plan->seatbelt_profile != NULL && seatbelt_init() == NULL) {
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
  /* A trampoline start runs this program's core, as the system has it
   * (the launcher a script or artifact names is none), with the arguments
   * `cosmic_trampoline` (core/sandbox_rules.c) reads, and each is made here, where this process
   * may allocate: a number of its own for the descriptor, the limit to
   * give the program back, and each limit. */
  const char *launch = path;
  char *const *launch_argv = plan->argv;
  char **words = NULL;
  char core[PATH_MAX];
  char numbers[5 + 2 * SPAWN_RLIMIT_MAX][24];
  if (!failure && trampolined) {
    size_t count = 0;
    while (plan->argv[count] != NULL) count++;
    size_t room = TRAMPOLINE_LIMITS + 2 * (size_t)plan->rlimit_count +
                  (size_t)plan->seatbelt_parameter_count + 1 + count + 1;
    errno = 0;
    words = calloc(room, sizeof *words);
    if (words == NULL) {
      failure = ENOMEM;
    } else if (!cosmic_executable_path(core, sizeof core)) {
      failure = errno != 0 ? errno : ENAMETOOLONG;
    } else {
      /* The limit the program started with comes back to it, as its
       * limit would be where `restore_descriptor_limit` (core/syscalls.c) lowers this
       * process's own for a start that has no trampoline. */
      struct rlimit restored;
      bool restoring = restored_descriptor_limit((rlim_t)top + 1, &restored);
      snprintf(numbers[0], sizeof numbers[0], "%d", top + 1);
      if (restoring)
        snprintf(numbers[1], sizeof numbers[1], "%llu", (unsigned long long)restored.rlim_cur);
      snprintf(numbers[2], sizeof numbers[2], "%d", plan->rlimit_count);
      snprintf(numbers[3], sizeof numbers[3], "%d", plan->seatbelt_parameter_count);
      size_t at = 0;
      words[at++] = (char *)COSMIC_TRAMPOLINE;
      words[at++] = numbers[0];
      words[at++] = (char *)(leads_session ? "1" : "0");
      words[at++] = restoring ? numbers[1] : (char *)"-";
      words[at++] = numbers[2];
      words[at++] = numbers[3];
      words[at++] = (char *)(plan->seatbelt_profile != NULL ? plan->seatbelt_profile : "");
      words[at++] = (char *)(terminal ? plan->terminal_path : "");
      for (int i = 0; i < plan->rlimit_count; i++) {
        char *resource = numbers[4 + 2 * i], *value = numbers[5 + 2 * i];
        snprintf(resource, sizeof numbers[0], "%d", plan->rlimits[i].resource);
        snprintf(value, sizeof numbers[0], "%llu", (unsigned long long)plan->rlimits[i].value);
        words[at++] = resource;
        words[at++] = value;
      }
      for (int i = 0; i < plan->seatbelt_parameter_count; i++)
        words[at++] = (char *)plan->seatbelt_parameters[i];
      words[at++] = (char *)path;
      for (size_t i = 0; i < count; i++) words[at++] = plan->argv[i];
      launch = core;
      launch_argv = words;
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
      if (plan->process_group && !leads_session) flags |= POSIX_SPAWN_SETPGROUP;
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
      /* A trampoline holds the status pipe, above the program's own
       * descriptors where the program has none (core/sandbox_rules.c's `cosmic_trampoline`). */
      if (!failure && trampolined)
        failure = posix_spawn_file_actions_adddup2(&actions, plan->status_write, top + 1);
      /* posix_spawn has no step for a limit: the child inherits this
       * process's, lowered for the call alone, across which this one
       * thread opens nothing. The kernel's dup2 refuses a target at or
       * past the child's limit, so where the user's is no higher than
       * `top` the child's is `top` + 1, the least that holds what it is
       * handed -- and a child that is this program records that as the
       * limit it started with, which its own host programs get, not the
       * user's: the user's would refuse it the descriptor it is handed.
       * A raise back that is refused leaves this process at the lowered
       * limit, which its children then get as it is. A trampoline is
       * handed the limit to lower itself to instead, before it applies
       * the profile, whose own work opens files. */
      if (!failure && trampolined) {
        failure = posix_spawn(&pid, launch, &actions, &attributes, launch_argv, plan->envp);
      } else if (!failure) {
        struct rlimit raised;
        bool lowered = getrlimit(RLIMIT_NOFILE, &raised) == 0 &&
                       restore_descriptor_limit((rlim_t)top + 1);
        failure = posix_spawn(&pid, launch, &actions, &attributes, launch_argv, plan->envp);
        if (lowered && setrlimit(RLIMIT_NOFILE, &raised) != 0) descriptor_limit_raised = false;
      }
      posix_spawnattr_destroy(&attributes);
    }
    posix_spawn_file_actions_destroy(&actions);
  }
  free(words);
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

/* The stack a Linux child runs `spawn_child` (core/sandbox_root.c) on, above a guard page:
 * the most it needs is `build_root` (core/sandbox_root.c)'s paths and a libc's formatting, well
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
   * its program's (core/sandbox_root.c's `start_unveiled`) -- and a fourth for the process
   * that maps one that gives root up (core/sandbox_root.c's `map_from_outside`) -- each above a
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
 * (core/sandbox_root.c's `start_unveiled`), until the init is reaped: `program` is -1 once the
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

/* What `spawn`'s descriptor arguments ask: the standard streams
 * (arguments 5 to 7) and the map of the rest (argument 9). `source[t]`
 * is the parent descriptor the child sees as t, or -1: for 0..2 that
 * means inherit, above that it means closed. `*top` is the highest child
 * descriptor named, at least 2. Raises for a malformed argument; answers
 * 0, or the errno of a descriptor named that is not open. */
static int read_descriptors (lua_State *L, int *source, int *top) {
  for (int i = 0; i <= CHILD_FD_MAX; i++) source[i] = -1;
  source[0] = stream_source(L, 5);
  source[1] = stream_source(L, 6);
  source[2] = stream_source(L, 7);
  *top = 2;
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
      if (target > *top) *top = (int)target;
      lua_pop(L, 1);
    }
  }
  for (int t = 0; t <= *top; t++) {
    if (source[t] >= 0 && fcntl(source[t], F_GETFD) < 0) return errno;
  }
  return 0;
}

/* What `spawn`'s sandbox (argument 10) and credentials (argument 11)
 * ask, read and checked before anything is made for the child. The
 * strings it points at are those of the tables given, which stay on the
 * stack for the call. */
struct spawn_options {
  int promising;
  unsigned promise_bits;
  /* The socket families the child may make (COSMIC_SOCKETS_ bits). */
  unsigned sockets;
  struct spawn_rlimit rlimits[SPAWN_RLIMIT_MAX];
  int rlimit_count;
  int granting;
  int grant_count;
  const char *grant_paths[GRANT_MAX];
  unsigned grant_letters[GRANT_MAX];
  /* Each unveiled path, the name it is bound at instead of its own or
   * NULL, and what is said of it. */
  int unveiling;
  int unveil_count;
  const char *unveiled[UNVEIL_MAX];
  const char *unveiled_at[UNVEIL_MAX];
  int unveiled_writable[UNVEIL_MAX];
  int unveiled_noexec[UNVEIL_MAX];
  int unveiled_idmap[UNVEIL_MAX];
  int idmapping;
  int offline;
  int online;
  int noexec_scratch;
  /* The relay's channel, or -1 for none, and its two ports. */
  int relay_channel;
  int relay_ports[2];
#if defined(__APPLE__)
  /* Where the profile's text and its parameters, names and values
   * alternating, are: in the strings of the tables given. */
  const char *seatbelt_profile;
  const char *seatbelt_words[2 * SEATBELT_PARAMETER_MAX];
  int seatbelt_count;
#endif
  int strict;
  int proc_only;
  unsigned long tmp_bytes;
  int tmp_exec;
  /* The user and group an unveiled child gives root up for. */
  int dropping;
  uid_t drop_uid;
  gid_t drop_gid;
  /* The user and group a child that is not sandboxed runs as. */
  int credentials;
  uid_t credential_user;
  gid_t credential_group;
};

/* The name an unveiled path is bound at, the string at -1 (`what`
 * names it in an error): absolute, plain, not /, beneath no /.old (the
 * root's own, where the old root is put aside as it pivots), and not
 * one another path is bound at already. */
static const char *bound_name (lua_State *L, const struct spawn_options *o, const char *what,
                               const char *refused, const char *old_refused) {
  const char *name = plain_string(L, -1, what);
  size_t length = strlen(name);
  if (!plain_name(name) || length < 2 || name[length - 1] == '/')
    luaL_argerror(L, 10, refused);
  if (strcmp(name, "/.old") == 0 || strncmp(name, "/.old/", 6) == 0)
    luaL_argerror(L, 10, old_refused);
  for (int j = 0; j < o->unveil_count; j++) {
    if (o->unveiled_at[j] != NULL && strcmp(o->unveiled_at[j], name) == 0)
      luaL_argerror(L, 10, "two paths are bound at one name");
  }
  return name;
}

/* Reads the sandbox's `unveil`, the table on top, into `o`. Raises for a
 * malformed one. */
static void read_unveil (lua_State *L, struct spawn_options *o) {
  o->unveiling = 1;
  for (int w = 0; w < 2; w++) {
    lua_pushstring(L, w == 0 ? "reads" : "writes");
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1)) {
      if (!lua_istable(L, -1)) luaL_argerror(L, 10, "unveiled paths must be a list");
      lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
      for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, -1, i);
        const char *unveil_path = plain_string(L, -1, "unveiled path");
        if (unveil_path[0] != '/') luaL_argerror(L, 10, "an unveiled path must be absolute");
        if (o->unveil_count >= UNVEIL_MAX) luaL_argerror(L, 10, "too many unveiled paths");
        o->unveiled[o->unveil_count] = unveil_path;
        o->unveiled_at[o->unveil_count] = NULL;
        o->unveiled_writable[o->unveil_count] = w;
        o->unveiled_noexec[o->unveil_count] = 0;
        o->unveiled_idmap[o->unveil_count] = 0;
        o->unveil_count++;
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
    if (!lua_istable(L, -1)) luaL_argerror(L, 10, "unveil's binds must be a list");
    lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, -1, i);
      if (!lua_istable(L, -1)) luaL_argerror(L, 10, "a bind is a table");
      if (o->unveil_count >= UNVEIL_MAX) luaL_argerror(L, 10, "too many unveiled paths");
      lua_pushliteral(L, "path");
      lua_rawget(L, -2);
      const char *bind_path = plain_string(L, -1, "a bind's path");
      if (bind_path[0] != '/') luaL_argerror(L, 10, "a bind's path must be absolute");
      lua_pushliteral(L, "at");
      lua_rawget(L, -3);
      const char *bind_at = NULL;
      if (!lua_isnil(L, -1))
        bind_at = bound_name(L, o, "the name a bind is at",
                             "a bind is at an absolute name, plain, and not /",
                             "a bind is at no name beneath /.old");
      int at = o->unveil_count;
      lua_pushliteral(L, "writable");
      lua_rawget(L, -4);
      o->unveiled_writable[at] = lua_toboolean(L, -1);
      lua_pushliteral(L, "noexec");
      lua_rawget(L, -5);
      o->unveiled_noexec[at] = lua_toboolean(L, -1);
      lua_pushliteral(L, "idmap");
      lua_rawget(L, -6);
      o->unveiled_idmap[at] = lua_toboolean(L, -1);
      if (o->unveiled_idmap[at]) o->idmapping = 1;
      o->unveiled[at] = bind_path;
      o->unveiled_at[at] = bind_at;
      o->unveil_count++;
      lua_pop(L, 6);
    }
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "tmp");
  lua_rawget(L, -2);
  if (!lua_isnil(L, -1)) {
    if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) < 1)
      luaL_argerror(L, 10, "unveil's tmp is a size in bytes, at least 1");
    o->tmp_bytes = (unsigned long)lua_tointeger(L, -1);
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "tmp_exec");
  lua_rawget(L, -2);
  if (!lua_isnil(L, -1)) {
    if (!lua_isboolean(L, -1)) luaL_argerror(L, 10, "unveil's tmp_exec must be a boolean");
    o->tmp_exec = lua_toboolean(L, -1);
  }
  lua_pop(L, 1);
  /* The name each path given is bound at instead of its own. */
  lua_pushliteral(L, "at");
  lua_rawget(L, -2);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) luaL_argerror(L, 10, "unveil's at must be a table");
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      const char *given = plain_string(L, -2, "a path unveil's at names");
      const char *name = bound_name(L, o, "the name a path is bound at",
                                    "a path is bound at an absolute name, plain, and not /",
                                    "a path is bound at no name beneath /.old");
      int found = 0;
      for (int i = 0; i < o->unveil_count; i++) {
        if (strcmp(o->unveiled[i], given) == 0) {
          o->unveiled_at[i] = name;
          found = 1;
        }
      }
      if (!found) luaL_argerror(L, 10, "unveil's at names a path not unveiled");
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
}

/* Reads the sandbox's `relay`, the table on top, into `o`. Raises for a
 * malformed one; answers 0, or the errno of a channel that is not open. */
static int read_relay (lua_State *L, struct spawn_options *o) {
  lua_pushliteral(L, "fd");
  lua_rawget(L, -2);
  if (!lua_isinteger(L, -1)) return luaL_argerror(L, 10, "relay's fd must be a descriptor");
  lua_Integer channel = lua_tointeger(L, -1);
  /* Below 3 it would be a stdio descriptor the child may leave inherited. */
  if (channel < 3 || channel > INT_MAX)
    return luaL_argerror(L, 10, "relay's fd is out of range: 3 or more");
  cosmic_argfd(L, 10, channel);
  o->relay_channel = (int)channel;
  lua_pop(L, 1);
  lua_pushliteral(L, "ports");
  lua_rawget(L, -2);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1) || lua_rawlen(L, -1) != 2)
      return luaL_argerror(L, 10, "relay's ports are two ports");
    for (int i = 0; i < 2; i++) {
      lua_rawgeti(L, -1, i + 1);
      if (!lua_isinteger(L, -1)) return luaL_argerror(L, 10, "a relay port is an integer");
      lua_Integer port = lua_tointeger(L, -1);
      if (port < 1 || port > 65535) return luaL_argerror(L, 10, "a relay port is 1 to 65535");
      o->relay_ports[i] = (int)port;
      lua_pop(L, 1);
    }
    if (o->relay_ports[0] == o->relay_ports[1])
      return luaL_argerror(L, 10, "a relay's two ports differ");
  }
  lua_pop(L, 1);
  if (!o->offline)
    return luaL_argerror(L, 10, "relay requires offline: its listeners are bound in the "
                         "network namespace of the child's own");
  if (fcntl(o->relay_channel, F_GETFD) < 0) return errno;
  return 0;
}

/* The boolean `key` of the sandbox, false where it is nil. Raises for
 * any other value. */
static int sandbox_flag (lua_State *L, const char *key, const char *refused) {
  lua_pushstring(L, key);
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1) && !lua_isboolean(L, -1)) luaL_argerror(L, 10, refused);
  int value = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return value;
}

#if defined(__APPLE__)
/* Reads the sandbox's `seatbelt`, the table on top, into `o`. Raises for
 * a malformed one; answers 0, or the results it pushed where this
 * process cannot give a child a profile of its own. */
static int read_seatbelt (lua_State *L, struct spawn_options *o) {
  if (!lua_istable(L, -1))
    return luaL_argerror(L, 10, "seatbelt must be a table of a profile and its parameters");
  lua_pushliteral(L, "profile");
  lua_rawget(L, -2);
  o->seatbelt_profile = plain_string(L, -1, "a seatbelt profile");
  if (o->seatbelt_profile[0] == '\0') return luaL_argerror(L, 10, "a seatbelt profile is empty");
  /* Before anything is made for the child: the trampoline's profile
   * would be a second one in a process this one's profile holds. */
  int unknown = 0;
  int holding = seatbelt_holding(&unknown);
  if (holding != 0) {
    lua_pushnil(L);
    if (holding > 0)
      lua_pushliteral(L, "this process is held by a Seatbelt profile, one it applied "
                      "(Sandbox.restrict) or was started under, and macOS applies no "
                      "second profile to a child of it: start the child without a "
                      "policy, held by this process's own profile");
    else
      lua_pushfstring(L, "whether a Seatbelt profile holds this process cannot be told "
                      "(sandbox_check: %s), and a child's profile would be a second one "
                      "where one does", cosmic_errno_describe(unknown, NULL));
    lua_pushinteger(L, holding > 0 ? EPERM : unknown);
    return 3;
  }
  lua_pushliteral(L, "parameters");
  lua_rawget(L, -3);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1))
      return luaL_argerror(L, 10, "a seatbelt's parameters are a table of names and values");
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      if (lua_type(L, -2) != LUA_TSTRING)
        return luaL_argerror(L, 10, "a seatbelt parameter's name must be a string");
      if (o->seatbelt_count >= 2 * SEATBELT_PARAMETER_MAX)
        return luaL_argerror(L, 10, "too many seatbelt parameters");
      o->seatbelt_words[o->seatbelt_count++] = plain_string(L, -2, "a seatbelt parameter's name");
      o->seatbelt_words[o->seatbelt_count++] = plain_string(L, -1, "a seatbelt parameter's value");
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 2);
  return 0;
}
#endif

/* Reads `spawn`'s sandbox, argument 10, into `o`, and checks the options
 * against each other. Raises for a malformed or contradictory one;
 * answers 0, or the results it pushed for a start refused. */
static int read_sandbox (lua_State *L, struct spawn_options *o) {
  luaL_checktype(L, 10, LUA_TTABLE);
  /* Options a caller once had, refused rather than passed over: a child
   * started without the hold its caller asked for would run unconfined. */
  static const char *const gone[] = { "ruleset", "pledge" };
  for (size_t i = 0; i < sizeof gone / sizeof gone[0]; i++) {
    lua_pushstring(L, gone[i]);
    int given = lua_rawget(L, 10) != LUA_TNIL;
    lua_pop(L, 1);
    if (given)
      return luaL_argerror(L, 10, "a sandbox's `ruleset` and `pledge` are gone: hold the child "
                                  "with `grants` and `promises`");
  }
  lua_pushliteral(L, "promises");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "promises must be a list");
    o->promising = 1;
    o->promise_bits = read_promises(L, lua_gettop(L), 10);
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "sockets");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "sockets must be a list");
    if (!o->promising) return luaL_argerror(L, 10, "sockets require promises");
    lua_Integer families = (lua_Integer)lua_rawlen(L, -1);
    for (lua_Integer i = 1; i <= families; i++) {
      lua_rawgeti(L, -1, i);
      const char *family = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
      if (strcmp(family, "unix") == 0) o->sockets |= COSMIC_SOCKETS_UNIX;
      else if (strcmp(family, "inet") == 0) o->sockets |= COSMIC_SOCKETS_INET;
      else return luaL_argerror(L, 10, "a socket family is \"unix\" or \"inet\"");
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  o->strict = sandbox_flag(L, "strict", "strict must be a boolean");
  o->proc_only = sandbox_flag(L, "proc", "proc must be a boolean");
  lua_pushliteral(L, "rlimits");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "rlimits must be a table");
    o->rlimit_count = read_rlimits(L, lua_gettop(L), 10, o->rlimits);
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "seatbelt");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
#if defined(__APPLE__)
    int refused = read_seatbelt(L, o);
    if (refused != 0) return refused;
#else
    return luaL_argerror(L, 10, "seatbelt is macOS's: this system holds a child by Landlock "
                         "and seccomp");
#endif
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "grants");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "grants must be a list");
    o->granting = 1;
    o->grant_count = read_grants(L, lua_gettop(L), 10, o->grant_paths, o->grant_letters);
  }
  lua_pop(L, 1);
  lua_pushliteral(L, "unveil");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "unveil must be a table");
    read_unveil(L, o);
  }
  lua_pop(L, 1);
  o->noexec_scratch = sandbox_flag(L, "noexec_scratch", "noexec_scratch must be a boolean");
  if (o->noexec_scratch && !o->unveiling)
    return luaL_argerror(L, 10, "noexec_scratch requires unveil");
  lua_pushliteral(L, "offline");
  lua_rawget(L, 10);
  o->offline = lua_toboolean(L, -1);
  lua_pop(L, 1);
  o->online = sandbox_flag(L, "online", "online must be a boolean");
  lua_pushliteral(L, "relay");
  lua_rawget(L, 10);
  if (!lua_isnil(L, -1)) {
    if (!lua_istable(L, -1)) return luaL_argerror(L, 10, "relay must be a table");
    int error = read_relay(L, o);
    if (error != 0) return cosmic_fail(L, error);
  }
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
    if (!o->unveiling && !o->proc_only)
      return luaL_argerror(L, 10, "a user is given with unveil or proc");
    o->dropping = 1;
    o->drop_uid = (uid_t)user;
    o->drop_gid = (gid_t)group;
  }
  lua_pop(L, 2);
  if (o->idmapping && !o->dropping) return luaL_argerror(L, 10, "a bind's idmap requires a user");
  if (o->proc_only && o->unveiling) return luaL_argerror(L, 10, "proc and unveil exclude each other");
  if (o->tmp_bytes != 0 && !o->unveiling) return luaL_argerror(L, 10, "unveil's tmp requires unveil");
  if (o->tmp_bytes != 0 && !o->strict) return luaL_argerror(L, 10, "unveil's tmp requires strict");
  if (o->tmp_exec && o->tmp_bytes == 0) return luaL_argerror(L, 10, "unveil's tmp_exec requires tmp");
  if (o->online && o->offline) return luaL_argerror(L, 10, "online and offline exclude each other");
  if (o->online && o->sockets != COSMIC_SOCKETS_INET)
    return luaL_argerror(L, 10, "online needs sockets of \"inet\" alone: it is what it gives");
  if (o->sockets != 0 && !o->offline && !o->online)
    return luaL_argerror(L, 10, "sockets require offline, the network namespace that holds them, "
                         "or online, which says nothing does");
  /* What `nest` leaves to the child's own root and pid namespace: its files, which Landlock
   * would hold but for the mounts it refuses, and its signals, which the filter lets reach
   * any pid. */
  if ((o->promise_bits & COSMIC_PROMISE_NEST) && !(o->strict && o->unveiling))
    return luaL_argerror(L, 10, "the \"nest\" promise needs strict and unveil: the root and "
                         "pid namespace of its own that hold its files and signals");
  /* A pid namespace and a procfs of its own are an unveiled child's, with no paths to bind. */
  if (o->proc_only) o->unveiling = 1;
  return 0;
}

/* Reads `spawn`'s credentials, argument 11, into `o`. Raises for
 * malformed ones, or ones a sandbox excludes. */
static void read_credentials (lua_State *L, struct spawn_options *o) {
  luaL_checktype(L, 11, LUA_TTABLE);
  lua_pushliteral(L, "user");
  lua_rawget(L, 11);
  lua_pushliteral(L, "group");
  lua_rawget(L, 11);
  if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
    luaL_argerror(L, 11, "credentials need integer user and group");
  lua_Integer user = lua_tointeger(L, -2), group = lua_tointeger(L, -1);
  if (user <= 0 || user >= (lua_Integer)UINT32_MAX || group <= 0 ||
      group >= (lua_Integer)UINT32_MAX)
    luaL_argerror(L, 11, "credentials user and group are 1 to 4294967294");
  if (o->unveiling || o->offline || o->dropping)
    luaL_argerror(L, 11, "credentials exclude sandbox unveil, offline, user and group");
  o->credentials = 1;
  o->credential_user = (uid_t)user;
  o->credential_group = (gid_t)group;
  lua_pop(L, 2);
}

/* Where an unveiled or offline child's root is made, and what is put
 * in it: the buffers `struct spawn_plan` points into, which last
 * until the child has started or failed to. */
struct spawn_root {
  char root_dir[PATH_MAX];
  char *resolved;
  char *resolved_paths[UNVEIL_MAX];
  char *given_names[UNVEIL_MAX];
  char path_abs[PATH_MAX];
  char cwd_abs[PATH_MAX];
};

/* What an unveiled child resolves in a root of its own is resolved here
 * first, while this process's filesystem is still the one its names
 * mean: each unveiled path with no link or `..` left in it, a shorter
 * before a longer so one inside another lands on top of it; the program
 * and the directory to run in made absolute from this one's; and an
 * empty directory to build the root on. Made last, after everything
 * that can fail. Answers 0, or the errno it failed with, having freed
 * what it made (`r->root_dir` is then empty). `*path_given` and
 * `*cwd_given` are pointed at `r`'s copies where they are made absolute. */
static int resolve_root (const char **path_given, const char **cwd_given, struct spawn_options *o,
                         struct spawn_root *r) {
  const char *path = *path_given, *cwd = *cwd_given;
  int prepare_error = 0;
  char here[PATH_MAX];
  if (getcwd(here, sizeof here) == NULL) prepare_error = errno;
  if (!prepare_error && path[0] != '/') {
    int length = snprintf(r->path_abs, sizeof r->path_abs, "%s/%s", here, path);
    if (length < 0 || (size_t)length >= sizeof r->path_abs) prepare_error = ENAMETOOLONG;
    path = r->path_abs;
  }
  if (!prepare_error && (cwd == NULL || cwd[0] != '/')) {
    int length = snprintf(r->cwd_abs, sizeof r->cwd_abs, "%s/%s", here, cwd == NULL ? "." : cwd);
    if (length < 0 || (size_t)length >= sizeof r->cwd_abs) prepare_error = ENAMETOOLONG;
    cwd = r->cwd_abs;
  }
  /* TODO: bind each path from the descriptor `grants_ruleset` (core/sandbox_rules.c) opened for
   * its grant (a mount of /proc/self/fd/<n>), not from its path
   * resolved again here, so a grant's one resolution makes the Landlock
   * rule, the bind and the report, as the sandbox design has it, once
   * `spawn` hands `build_root` (core/sandbox_root.c) the grants' descriptors and answers the
   * resolutions it made. A link a host process swaps in between the two
   * resolutions fails closed: the rule is on the file the grant named,
   * so Landlock refuses what the swapped path holds. */
  if (!prepare_error && o->unveil_count > 0) {
    r->resolved = malloc((size_t)o->unveil_count * 2 * PATH_MAX);
    if (r->resolved == NULL) prepare_error = ENOMEM;
    for (int i = 0; !prepare_error && i < o->unveil_count; i++) {
      r->resolved_paths[i] = r->resolved + (size_t)i * 2 * PATH_MAX;
      r->given_names[i] = NULL;
      if (realpath(o->unveiled[i], r->resolved_paths[i]) == NULL) {
        prepare_error = errno;
        break;
      }
      /* The name given, less a trailing slash, where it differs. */
      size_t n = strlen(o->unveiled[i]);
      while (n > 1 && o->unveiled[i][n - 1] == '/') n--;
      if (n >= PATH_MAX) {
        prepare_error = ENAMETOOLONG;
        break;
      }
      char *name = r->resolved_paths[i] + PATH_MAX;
      memcpy(name, o->unveiled[i], n);
      name[n] = '\0';
      if (o->unveiled_at[i] == NULL && plain_name(name) && strcmp(name, r->resolved_paths[i]) != 0)
        r->given_names[i] = name;
    }
    /* Each where it is placed, a shorter first, so one placed inside
     * another lands on top of it. */
    for (int i = 1; !prepare_error && i < o->unveil_count; i++) {
      for (int j = i; j > 0 &&
                      strlen(o->unveiled_at[j] != NULL ? o->unveiled_at[j] : r->resolved_paths[j]) <
                      strlen(o->unveiled_at[j - 1] != NULL ? o->unveiled_at[j - 1] : r->resolved_paths[j - 1]);
           j--) {
        char *p = r->resolved_paths[j];
        r->resolved_paths[j] = r->resolved_paths[j - 1];
        r->resolved_paths[j - 1] = p;
        char *q = r->given_names[j];
        r->given_names[j] = r->given_names[j - 1];
        r->given_names[j - 1] = q;
        const char *a = o->unveiled_at[j];
        o->unveiled_at[j] = o->unveiled_at[j - 1];
        o->unveiled_at[j - 1] = a;
        int w = o->unveiled_writable[j];
        o->unveiled_writable[j] = o->unveiled_writable[j - 1];
        o->unveiled_writable[j - 1] = w;
        int x = o->unveiled_noexec[j];
        o->unveiled_noexec[j] = o->unveiled_noexec[j - 1];
        o->unveiled_noexec[j - 1] = x;
        int m = o->unveiled_idmap[j];
        o->unveiled_idmap[j] = o->unveiled_idmap[j - 1];
        o->unveiled_idmap[j - 1] = m;
      }
    }
  }
  if (!prepare_error && o->noexec_scratch) {
    for (int i = 0; i < o->unveil_count; i++) {
      const char *placed = o->unveiled_at[i] != NULL ? o->unveiled_at[i] : r->resolved_paths[i];
      const char *name = r->given_names[i];
      if (strcmp(placed, "/") == 0 || strcmp(placed, "/noexec") == 0 ||
          strncmp(placed, "/noexec/", 8) == 0 ||
          (name != NULL && (strcmp(name, "/noexec") == 0 ||
                           strncmp(name, "/noexec/", 8) == 0))) {
        prepare_error = EINVAL;
        break;
      }
    }
  }
  if (!prepare_error && o->unveiling && !o->proc_only) {
    const char *base = getenv("TMPDIR");
    if (base == NULL || base[0] != '/') base = "/tmp";
    int length = snprintf(r->root_dir, sizeof r->root_dir, "%s/cosmic-root-XXXXXX", base);
    if (length < 0 || (size_t)length >= sizeof r->root_dir) prepare_error = ENAMETOOLONG;
    else if (mkdtemp(r->root_dir) == NULL) prepare_error = errno;
    if (prepare_error) r->root_dir[0] = '\0';
  }
  *path_given = path;
  *cwd_given = cwd;
  if (prepare_error) {
    free(r->resolved);
    r->resolved = NULL;
  }
  return prepare_error;
}

/* What `spawn` answers once the child has started or failed to: it
 * reads the errno the child wrote to `status_read` before its exec, if
 * it wrote one, closes `status_read` and removes the empty `root_dir`.
 * `pid` is the child running the program (an unveiled start's
 * program), or -1. */
static int spawn_answer (lua_State *L, int status_read, pid_t pid, const char *root_dir,
                         const struct spawn_options *o, const char *idmap_path) {
#if !defined(__linux__)
  (void)idmap_path;
#endif
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
#if defined(__APPLE__)
  /* A trampoline that was refused says why after the errno
   * (core/sandbox_rules.c's `trampoline_fail`), and ends: its text is read to the end. */
  char detail[TRAMPOLINE_MESSAGE_MAX + 1];
  size_t detail_length = 0;
  while (received == sizeof child_error && child_error != 0 && detail_length < TRAMPOLINE_MESSAGE_MAX) {
    ssize_t got = read(status_read, detail + detail_length, TRAMPOLINE_MESSAGE_MAX - detail_length);
    if (got > 0) { detail_length += (size_t)got; continue; }
    if (got < 0 && errno == EINTR) continue;
    break;
  }
#endif
  close(status_read);
  if (root_dir[0] != '\0') rmdir(root_dir);
  if (received != 0 || read_error != 0 || pid < 0) {
    int ignored; while (pid > 0 && waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
#if defined(__linux__)
    if (pid > 0) sandbox_reaped(pid);
#endif
    int number = received == sizeof child_error ? child_error : (read_error != 0 ? read_error : EIO);
#if defined(__linux__)
    int stage = number >> STAGE_SHIFT;
    if ((o->strict || stage == STAGE_RELAY || stage == STAGE_TRUNCATION) && stage != 0) {
      char message[PATH_MAX + 512];
      staged_message(number >> STAGE_SHIFT, number & ((1 << STAGE_SHIFT) - 1),
                     idmap_path[0] != '\0' ? idmap_path : NULL, message, sizeof message);
      lua_pushnil(L);
      lua_pushstring(L, message);
      lua_pushinteger(L, number & ((1 << STAGE_SHIFT) - 1));
      return 3;
    }
#endif
#if defined(__APPLE__)
    if (detail_length > 0) {
      lua_pushnil(L);
      lua_pushlstring(L, detail, detail_length);
      lua_pushinteger(L, number);
      return 3;
    }
#endif
    if (o->granting && number == EACCES) {
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

#if defined(__linux__)
/* Whether the kernel closes a range of descriptors, as [`close_child_descriptors`] (core/spawn.c)
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
#endif

COSMIC_SYSCALL(spawn, 12) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  if (!lua_isnoneornil(L, 3)) luaL_checktype(L, 3, LUA_TTABLE);
  const char *cwd = lua_isnoneornil(L, 4) ? NULL : plain_string(L, 4, "cwd");
  int process_group = lua_toboolean(L, 8);
  if (!lua_isnoneornil(L, 12) && lua_type(L, 12) != LUA_TBOOLEAN && lua_type(L, 12) != LUA_TSTRING)
    return luaL_argerror(L, 12, "terminal must be a boolean or the slave's path");
  int terminal = lua_toboolean(L, 12);
#if defined(__APPLE__)
  /* Darwin's trampoline opens the terminal by its path to acquire it as the
   * controlling terminal (core/sandbox_rules.c's `cosmic_trampoline`): fd 0 does not name it. */
  const char *terminal_path = NULL;
  if (terminal) {
    if (lua_type(L, 12) != LUA_TSTRING)
      return luaL_argerror(L, 12, "a terminal on macOS needs the slave's path");
    terminal_path = plain_string(L, 12, "the terminal's path");
    if (terminal_path[0] == '\0') return luaL_argerror(L, 12, "the terminal's path is empty");
  }
#endif
  int source[CHILD_FD_MAX + 1];
  int top;
  int descriptor_error = read_descriptors(L, source, &top);
  if (descriptor_error != 0) return cosmic_fail(L, descriptor_error);
  struct spawn_options o;
  memset(&o, 0, sizeof o);
  o.relay_channel = -1;
  o.relay_ports[0] = 3128;
  o.relay_ports[1] = 1080;
  if (!lua_isnoneornil(L, 10)) {
    int refused = read_sandbox(L, &o);
    if (refused != 0) return refused;
  }
  if (!lua_isnoneornil(L, 11)) read_credentials(L, &o);
  /* The Landlock ruleset `grants` make, built below, or -1. */
  int confine = -1;
  /* An idmapped bind's mount descriptors, and the index of the path whose
   * mount the child could not make, as `struct spawn_plan` has them. */
  int idmap_fds[UNVEIL_MAX];
  int idmap_failed = -1;
  char idmap_path[PATH_MAX];
  idmap_path[0] = '\0';
#if defined(__linux__)
  int credential_dumpable = -1;
  if (o.credentials) {
    credential_dumpable = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
    if (credential_dumpable < 0) return cosmic_fail(L, errno);
    if (credential_dumpable != 0 && credential_dumpable != 1) return cosmic_fail(L, ENOTSUP);
  }
#endif
#if !defined(__linux__)
  if (o.unveiling || o.offline || o.credentials || o.granting) return cosmic_fail(L, ENOSYS);
#else
  if (o.unveiling && !sandbox_room()) return cosmic_fail(L, errno);
#endif
  /* The child maps its own ids, or, giving root up, the user and group
   * it runs as; its namespace is mapped from outside then, with root's
   * beside them (core/sandbox_root.c's `map_from_outside`). */
  unsigned long own_uid = (unsigned long)geteuid(), own_gid = (unsigned long)getegid();
  unsigned long child_uid = o.dropping ? (unsigned long)o.drop_uid : own_uid;
  unsigned long child_gid = o.dropping ? (unsigned long)o.drop_gid : own_gid;
  char uid_map[64], gid_map[64], outer_uid_map[96], outer_gid_map[96];
  snprintf(uid_map, sizeof uid_map, "%lu %lu 1\n", child_uid, child_uid);
  snprintf(gid_map, sizeof gid_map, "%lu %lu 1\n", child_gid, child_gid);
  snprintf(outer_uid_map, sizeof outer_uid_map, "%lu %lu 1\n%lu %lu 1\n", own_uid, own_uid,
           child_uid, child_uid);
  snprintf(outer_gid_map, sizeof outer_gid_map, "%lu %lu 1\n%lu %lu 1\n", own_gid, own_gid,
           child_gid, child_gid);
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
    int number = errno; if (envp != COSMIC_ENVIRON) free_environment(envp, envc); free(argv);
    return cosmic_fail(L, number);
  }
  /* Move both ends clear of every descriptor the child is handed, so
   * closed parent stdio cannot make a pipe end collide with the
   * remapping below. These ends, and the descriptors the child moves
   * above its own (the pinned and confining ones -- on Darwin this
   * process copies the pinned ones -- and `raise_descriptor` (core/sandbox_root.c)'s), go
   * to `top` + 2 and up -- 257 and up for a relaunch, which hands the
   * child 255 (cosmic/proc.tl's CORE_FD) -- which F_DUPFD refuses past
   * RLIMIT_NOFILE's soft limit: EINVAL at it, EMFILE just under it;
   * SPAWN_PLACED_ABOVE (core/process.h) counts them. A start raises
   * that limit past macOS's default of 256
   * (core/syscalls.c's `cosmic_raise_descriptor_limit`); a hard limit that low still
   * refuses a relaunch, which cosmic.child's `start` says. Darwin's
   * start writes the pipe only from a trampoline ([`spawn_program`]), and
   * otherwise its read ends at once there; it is made all the same, so a
   * start meets the limit where it does on Linux and the count holds on
   * both. */
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
    if (envp != COSMIC_ENVIRON) free_environment(envp, envc);
    free(argv);
    return cosmic_fail(L, promote_error);
  }
  struct spawn_root root;
  root.root_dir[0] = '\0';
  root.resolved = NULL;
  if (o.unveiling || o.offline) {
    int prepare_error = resolve_root(&path, &cwd, &o, &root);
    if (prepare_error) {
      close(status_read);
      close(status_write);
      if (envp != COSMIC_ENVIRON) free_environment(envp, envc);
      free(argv);
      return cosmic_fail(L, prepare_error);
    }
  }
  char *root_dir = root.root_dir;
  char **resolved_paths = root.resolved_paths, **given_names = root.given_names;
  int unmap_root = 0;
#if defined(__linux__)
  unmap_root = (o.unveiling || o.offline) && inner_user_namespace() && geteuid() == 0;
#endif
  /* Built last of what can fail, so the one cleanup below serves it: a
   * ruleset to close is the only thing past here that is not the
   * environment's. */
  int grant_error = 0;
  /* What else holds the child (core/promises.h's COSMIC_HELD_ bits): what
   * the ruleset made from `grants` handles (core/sandbox_rules.c's `grants_ruleset`). */
  unsigned held = 0;
  char grant_message[PATH_MAX + 512];
  int unix_guard = 0;
  int unveiled_unix[UNVEIL_MAX];
  memset(unveiled_unix, 0, sizeof unveiled_unix);
#if defined(__linux__)
  /* A start that promises `nest` has no ruleset ([`cosmic.child`] gives it no
   * grants), so the root alone holds its unix sockets, at any Landlock ABI: it
   * gets COSMIC_HELD_UNIX where `root_shows_no_socket` (core/sandbox_rules.c) holds, and the child
   * checks that (`build_root` (core/sandbox_root.c)'s `unix_guard`), as for a ruleset below ABI 9.
   * It may build roots and mount, and none reaches a socket the host has:
   * - Its mount namespace holds what this start bound, each a file that is
   *   no socket, and its own tmpfs and procfs. The host's root was detached
   *   by pivot_root (core/sandbox_root.c's `build_root`), and no descriptor leads to it
   *   (core/sandbox_rules.c's `root_shows_no_socket`). Mounts it makes, in a mount namespace or a
   *   user namespace of its own, copy that and add what the kernel lets a
   *   user namespace's root mount (tmpfs, procfs, overlay of what it sees,
   *   mqueue, devpts): none shows a socket file of the host's. The
   *   mounts it copies are locked, so none is unmounted to show what is
   *   beneath. A sysfs, which the filter cannot refuse by its type, needs
   *   one already visible, as the kernel's `fs_fully_visible` asks, and
   *   holds no socket file in any case.
   * - Its procfs is of its own pid namespace, which an unveiled start
   *   always makes (core/sandbox_root.c's `start_unveiled`): /proc/N/root, cwd and fd/N are
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
  int nesting = (o.promise_bits & COSMIC_PROMISE_NEST) != 0;
  int unix_tmp = (o.granting || nesting) && o.strict && o.unveiling && !o.proc_only && o.offline &&
                 close_range_works() &&
                 root_shows_no_socket(resolved_paths, o.unveiled_at, o.unveil_count, source, top);
  if (o.granting) {
    /* A `u` grant's socket is the one a bind may show. */
    for (int i = 0; i < o.unveil_count; i++) {
      for (int j = 0; j < o.grant_count; j++) {
        char real[PATH_MAX];
        if ((o.grant_letters[j] & GRANT_UNIX) && realpath(o.grant_paths[j], real) != NULL &&
            strcmp(real, resolved_paths[i]) == 0)
          unveiled_unix[i] = 1;
      }
    }
    long version = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    unix_guard = o.strict && o.unveiling && !o.proc_only && o.offline && version < LANDLOCK_ABI_RESOLVE_UNIX &&
                 (unix_tmp || (o.sockets & COSMIC_SOCKETS_UNIX) != 0);
    confine = grants_ruleset(o.grant_paths, o.grant_letters, o.grant_count,
                             (o.sockets & COSMIC_SOCKETS_INET) != 0, o.strict && o.unveiling && !o.proc_only,
                             o.offline, unix_tmp, grant_message, sizeof grant_message, &grant_error,
                             &held);
  }
  if (nesting && unix_tmp) {
    held |= COSMIC_HELD_UNIX;
    unix_guard = 1;
  }
  /* The namespaces the child makes itself (`start_unveiled` (core/sandbox_root.c), `go_offline` (core/sandbox_root.c)):
   * a user namespace, whose capabilities the kernel does not take for the
   * initial one's, so it cannot raise a hard limit, nor for those of the
   * owner of a network namespace it did not make, so it cannot change
   * one; and for an unveiled child a pid namespace of its own. */
  if (o.unveiling || o.offline) held |= COSMIC_HELD_LIMITS | COSMIC_HELD_NETWORK;
  if (o.unveiling) held |= COSMIC_HELD_PIDS;
#endif
  if (grant_error != 0) {
    close(status_read);
    close(status_write);
    if (root_dir[0] != '\0') rmdir(root_dir);
    if (envp != COSMIC_ENVIRON) free_environment(envp, envc);
    free(argv);
    free(root.resolved);
    lua_pushnil(L);
    lua_pushstring(L, grant_message);
    lua_pushinteger(L, grant_error);
    return 3;
  }
  char **given = cosmic_coverage_environment(envp);
  struct spawn_plan plan = {
    .path = path, .argv = argv, .envp = given, .cwd = cwd, .source = source, .top = top,
    .status_read = status_read, .status_write = status_write,
    .descriptor_limit = descriptor_limit, .process_group = process_group, .terminal = terminal,
    .credentials = o.credentials, .user = o.credential_user, .group = o.credential_group,
    .confine = confine,
    .promising = o.promising, .promises = o.promise_bits, .held = held,
    .rlimit_count = o.rlimit_count, .rlimits = o.rlimits,
#if defined(__APPLE__)
    .seatbelt_profile = o.seatbelt_profile, .seatbelt_parameters = o.seatbelt_words,
    .seatbelt_parameter_count = o.seatbelt_count, .terminal_path = terminal_path,
#endif
    .unveiling = o.unveiling, .offline = o.offline, .noexec_scratch = o.noexec_scratch,
    .relay_channel = o.relay_channel, .relay_ports = { o.relay_ports[0], o.relay_ports[1] },
    .strict = o.strict, .proc_only = o.proc_only, .tmp_bytes = o.tmp_bytes, .tmp_exec = o.tmp_exec, .unix_guard = unix_guard,
    .unveiled_unix = unveiled_unix,
    .sockets = o.sockets,
    .unveiled_noexec = o.unveiled_noexec, .root_dir = root_dir,
    .resolved_paths = resolved_paths, .given_names = given_names, .bound_at = o.unveiled_at,
    .unveiled_writable = o.unveiled_writable, .unveil_count = o.unveil_count,
    .unveiled_idmap = o.idmapping ? o.unveiled_idmap : NULL, .idmap_fds = o.idmapping ? idmap_fds : NULL,
    .idmap_failed = &idmap_failed,
    .uid_map = uid_map, .gid_map = gid_map, .unmap_root = unmap_root,
    .dropping = o.dropping, .drop_uid = o.drop_uid, .drop_gid = o.drop_gid,
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
   * and the child set it (core/sandbox_root.c's `start_program`): whatever it was here, it is
   * put back once the child has exec'd. */
#if defined(__linux__)
  int dumpable = o.dropping ? prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) : -1;
#endif
  pid_t pid = start_child(&plan, &fork_error);
  /* The child has its own copy of the ruleset's descriptor from its
   * start, or never started. */
  if (o.granting) close(confine);
#if defined(__linux__)
  int restore_error = 0;
  if (o.credentials) {
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
  if (envp != COSMIC_ENVIRON) free_environment(envp, envc);
  free(argv);
  if (idmap_failed >= 0 && idmap_failed < o.unveil_count)
    snprintf(idmap_path, sizeof idmap_path, "%s", resolved_paths[idmap_failed]);
  free(root.resolved);
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
   * this process's child in its place (core/sandbox_root.c's `start_unveiled`), or failed to. */
  if (o.unveiling) {
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

  return spawn_answer(L, status_read, pid, root_dir, &o, idmap_path);
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
  /* The offset is where the stored bytes lie, which startup compares with
   * the launcher's; the length and digest are the raw core's, which it
   * compares with the executing file. A compressed core's two differ. */
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
int read_whole (const char *path, char **text, size_t *used) {
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
#elif defined(__APPLE__)
  /* libproc does not say how many children there are before it is asked.
   * So the block starts zeroed, every pid in it is a child, and one in its
   * last place asks again with a larger block. */
  struct cosmic_guard *guard = cosmic_guard_push(L, cosmic_free);
  size_t room = 64;
  pid_t *pids;
  for (;;) {
    pids = cosmic_realloc(guard->resource, room * sizeof *pids);
    if (pids == NULL) return cosmic_fail(L, ENOMEM);
    guard->resource = pids;
    memset(pids, 0, room * sizeof *pids);
    /* A refusal is answered as no children, with the errno set. */
    errno = 0;
    int got = proc_listchildpids(getpid(), pids, (int)(room * sizeof *pids));
    if (got <= 0 && errno != 0) return cosmic_fail(L, errno);
    if (pids[room - 1] == 0) break;
    if (room >= ((size_t)1 << 20)) return cosmic_fail(L, EOVERFLOW);
    room *= 4;
  }
  lua_newtable(L);
  lua_Integer count = 0;
  for (size_t at = 0; at < room; at++) {
    if (pids[at] <= 0) continue;
    lua_pushinteger(L, (lua_Integer)pids[at]);
    lua_rawseti(L, -2, ++count);
  }
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}

#if defined(__linux__)
/* How many threads this process has, as /proc/thread-self/status says
 * ("Threads:"), or -1 with the errno that refused the read in `error`,
 * EIO for a status with no such line. Read through thread-self, as
 * `children` is, so a sandbox whose /proc is the host's still names this
 * process. */
static int status_threads (int *error) {
  char *text;
  size_t used;
  *error = read_whole("/proc/thread-self/status", &text, &used);
  if (*error != 0) return -1;
  static const char field[] = "\nThreads:";
  int count = -1;
  for (size_t at = 0; at + sizeof field - 1 < used; at++) {
    if (memcmp(text + at, field, sizeof field - 1) != 0) continue;
    for (at += sizeof field - 1; at < used && text[at] != '\n'; at++) {
      if (text[at] < '0' || text[at] > '9') continue;
      if (count < 0) count = 0;
      if (count < INT_MAX / 10) count = count * 10 + (text[at] - '0');
    }
    break;
  }
  cosmic_free(text);
  if (count < 0) *error = EIO;
  return count;
}
#elif defined(__APPLE__)
/* How many threads this process has, as the kernel counts its task's
 * (proc_pidinfo's PROC_PIDTASKINFO), the ones libdispatch started for the
 * C library among them, or -1 with the errno that refused the call in
 * `error`, EIO for an answer cut short. */
static int task_thread_count (int *error) {
  struct proc_taskinfo info;
  int got = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, (int)sizeof info);
  if (got == (int)sizeof info) return (int)info.pti_threadnum;
  *error = got <= 0 ? errno : EIO;
  return -1;
}
#endif

/* How many signal guards are open, counted where they are opened below. */
static int child_guard_depth;

COSMIC_SYSCALL(fork, 1) {
  int scoped = lua_toboolean(L, 1);
#if defined(__linux__) || defined(__APPLE__)
#if defined(__APPLE__)
  /* Nothing here holds a child to its own signals, as Landlock's scope
   * does: refused whatever else would refuse it. */
  if (scoped) return cosmic_fail(L, ENOSYS);
#endif
  int error = 0;
#if defined(__APPLE__)
  int threads = task_thread_count(&error);
#else
  int threads = status_threads(&error);
#endif
  if (threads < 0) return cosmic_fail(L, error);
  if (threads != 1) return cosmic_fail(L, EBUSY);
  /* A copy would share the guard's wake pipe, and take the bytes that
   * tell this process of its signals. */
  if (child_guard_depth > 0) return cosmic_fail(L, EBUSY);
  int ruleset = -1;
#if defined(__linux__)
  if (scoped) {
    long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1) return cosmic_fail(L, abi < 0 ? errno : ENOSYS);
    if (abi < 6) return cosmic_fail(L, EOPNOTSUPP);
    /* Every ruleset refuses a move or a link between two directories that
     * no rule of its own allows (LANDLOCK_ACCESS_FS_REFER), handled or
     * not: so this one handles it, and allows it beneath the root, which
     * leaves each such move to the rulesets that hold the process
     * already and handle it, as every one this core makes does. */
    struct grants_attr attr;
    memset(&attr, 0, sizeof attr);
    attr.handled_access_fs = LANDLOCK_ACCESS_FS_REFER;
    attr.scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET | LANDLOCK_SCOPE_SIGNAL;
    long made = syscall(SYS_landlock_create_ruleset, &attr, sizeof attr, 0);
    if (made < 0) return cosmic_fail(L, errno);
    ruleset = (int)made;
    int root = open("/", O_PATH | O_CLOEXEC);
    struct landlock_path_beneath_attr beneath = {
      .allowed_access = LANDLOCK_ACCESS_FS_REFER,
      .parent_fd = root,
    };
    if (root < 0 ||
        syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0)
      error = errno;
    if (root >= 0) close(root);
    if (error != 0) {
      close(ruleset);
      return cosmic_fail(L, error);
    }
  }
#endif
  fflush(NULL);
  pid_t pid = fork();
  error = errno;
#if defined(__linux__)
  if (pid == 0) {
    /* The pairs are the parent's children, not this process's: a wait
     * here ends none of them. */
    pair_count = 0;
    if (scoped && (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 ||
                   syscall(SYS_landlock_restrict_self, ruleset, 0) != 0)) {
      /* Unheld, it would run the caller's code where the caller was
       * promised it could not reach its parent: it runs none. */
      static const char said[] = "cosmic: fork: the child could not be held to its own signals\n";
      ssize_t ignored = write(2, said, sizeof said - 1);
      (void)ignored;
      _exit(125);
    }
  }
#endif
  if (ruleset >= 0) close(ruleset);
  if (pid < 0) return cosmic_fail(L, error);
  lua_pushinteger(L, (lua_Integer)pid);
  return 1;
#else
  (void)scoped;
  return cosmic_fail(L, ENOSYS);
#endif
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

/* Milliseconds on the monotonic clock. */
static int64_t cosmic_now_ms (void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int64_t cosmic_deadline_ms (int64_t timeout) {
  if (timeout < 0) return -1;
  int64_t now = cosmic_now_ms();
  /* A timeout of 0 is a deadline already come. Any other is put one
   * millisecond on: now is counted down, so up to a millisecond of the
   * current one has gone, and a deadline of `now + timeout` would pass
   * before `timeout` had. */
  int64_t extra = timeout > 0;
  if (timeout > INT64_MAX - now - extra) return INT64_MAX;
  return now + extra + timeout;
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
